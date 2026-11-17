"""Small-memory MathWriting preparation, handwritten InkML rendering and dataset IO.

No archive member is extracted to its original path. Images are rendered/copied
under generated names; official held-out splits are never randomly reassigned.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import asdict, dataclass
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import random
import stat
import tarfile
import tempfile
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET
import zipfile

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageOps

SPLITS = ("train", "validation", "test")
MATHWRITING_URLS = {
    "excerpt": "https://storage.googleapis.com/mathwriting_data/mathwriting-2024-excerpt.tgz",
    "full": "https://storage.googleapis.com/mathwriting_data/mathwriting-2024.tgz",
}
EXCERPT_SHA256 = "cba038def001480a89962b25cb20a60df4c4145e94c86ef9d2af65f192cb82bc"
DATA_LICENSE = "cc-by-nc-sa-4.0"


@dataclass(frozen=True)
class ImageConfig:
    version: int = 1
    size: int = 384
    padding: int = 20
    trim_threshold: int = 245
    max_image_pixels: int = 32_000_000

    def __post_init__(self):
        if self.size < 32 or not 0 <= self.padding < self.size // 2:
            raise ValueError("Invalid image size or padding")
        if not 1 <= self.trim_threshold <= 255 or self.max_image_pixels < 1:
            raise ValueError("Invalid image limits")


IMAGE_CONFIG = ImageConfig()


def json_write(path: Path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def normalize_image(image: Image.Image, config: ImageConfig = IMAGE_CONFIG) -> Image.Image:
    """The same crop, alpha flattening and letterboxing must be used at inference."""
    if image.width * image.height > config.max_image_pixels:
        raise ValueError("Image exceeds the pixel limit; resize the photo first")
    image = ImageOps.exif_transpose(image).convert("RGBA")
    white = Image.new("RGBA", image.size, "white")
    image = Image.alpha_composite(white, image).convert("RGB")
    ink = image.convert("L").point(lambda value: 255 if value < config.trim_threshold else 0)
    bounds = ink.getbbox()
    if bounds is None:
        raise ValueError("Blank formula image")
    image = image.crop(bounds)
    available = config.size - 2 * config.padding
    scale = min(available / image.width, available / image.height)
    resized = image.resize((max(1, round(image.width * scale)), max(1, round(image.height * scale))), Image.Resampling.LANCZOS)
    result = Image.new("RGB", (config.size, config.size), "white")
    result.paste(resized, ((config.size - resized.width) // 2, (config.size - resized.height) // 2))
    return result


def augment_image(image: Image.Image, rng=None) -> Image.Image:
    """Training only: mild camera/pen variation, never validation or test augmentation."""
    rng = rng or random
    image = image.rotate(rng.uniform(-3, 3), resample=Image.Resampling.BICUBIC, fillcolor="white")
    image = ImageEnhance.Contrast(image).enhance(rng.uniform(0.75, 1.25))
    if rng.random() < 0.4:
        image = image.filter(ImageFilter.GaussianBlur(rng.uniform(0.1, 0.6)))
    if rng.random() < 0.4:
        pixels = np.asarray(image, dtype=np.float32)
        shade = np.linspace(rng.uniform(0.88, 1), 1, image.width, dtype=np.float32)[None, :, None]
        image = Image.fromarray(np.clip(pixels * shade, 0, 255).astype(np.uint8))
    return image


def read_inkml(content: bytes, max_points=200_000):
    if len(content) > 2 * 1024 * 1024 or b"<!DOCTYPE" in content.upper() or b"<!ENTITY" in content.upper():
        raise ValueError("Unsafe or oversized InkML")
    root = ET.fromstring(content)
    annotations, strokes, total = {}, [], 0
    for element in root.iter():
        tag = element.tag.rsplit("}", 1)[-1]
        if tag == "annotation":
            annotations[element.attrib.get("type", "")] = (element.text or "").strip()
        if tag == "trace":
            stroke = []
            for point in (element.text or "").split(","):
                columns = point.strip().split()
                if not columns:
                    continue
                if len(columns) < 2:
                    raise ValueError("InkML point has no x/y pair")
                xy = tuple(map(float, columns[:2]))
                if not all(math.isfinite(value) for value in xy):
                    raise ValueError("Nonfinite ink coordinate")
                stroke.append(xy)
                total += 1
                if total > max_points:
                    raise ValueError("Too many ink points")
            if stroke:
                strokes.append(stroke)
    label = annotations.get("normalizedLabel")
    if not label or not strokes:
        raise ValueError("A formula needs normalizedLabel and ink strokes")
    return label, strokes, annotations


def render_ink(strokes, size=384, padding=24, supersampling=3):
    points = np.asarray([point for stroke in strokes for point in stroke], dtype=np.float64)
    if points.size == 0 or not np.isfinite(points).all():
        raise ValueError("Empty or invalid ink")
    low, high = points.min(axis=0), points.max(axis=0)
    extent = np.maximum(high - low, 1)
    scale = (size - 2 * padding) / max(extent)
    offset = (np.array([size, size]) - (high - low) * scale) / 2
    image = Image.new("RGB", (size * supersampling, size * supersampling), "white")
    draw = ImageDraw.Draw(image)
    width = 3 * supersampling
    for stroke in strokes:
        xy = [tuple(((np.asarray(point) - low) * scale + offset) * supersampling) for point in stroke]
        if len(xy) > 1:
            draw.line(xy, fill="black", width=width, joint="curve")
        for x, y in (xy[0], xy[-1]):
            radius = width / 2
            draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill="black")
    return image.resize((size, size), Image.Resampling.LANCZOS)


def download_mathwriting(variant: str, destination: Path, progress=None) -> Path:
    url = MATHWRITING_URLS[variant]
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if variant != "excerpt" or sha256_file(destination) == EXCERPT_SHA256:
            return destination
        raise ValueError("Cached MathWriting excerpt checksum mismatch")
    partial = destination.with_suffix(destination.suffix + ".part")
    try:
        with urlopen(Request(url, headers={"User-Agent": "Axiora-OCR/1"}), timeout=60) as response, partial.open("wb") as target:
            total = int(response.headers.get("Content-Length", 0))
            written = 0
            for block in iter(lambda: response.read(2 * 1024 * 1024), b""):
                written += len(block)
                if written > 4 * 1024 ** 3:
                    raise ValueError("Archive exceeds the download limit")
                target.write(block)
                if progress:
                    progress(written, total)
            if total and written != total:
                raise ValueError("Incomplete archive download")
        if variant == "excerpt" and sha256_file(partial) != EXCERPT_SHA256:
            raise ValueError("MathWriting excerpt checksum mismatch")
        partial.replace(destination)
    finally:
        partial.unlink(missing_ok=True)
    return destination


def grouped_split(group: str, seed=42):
    bucket = int(hashlib.sha256(f"{seed}:{group}".encode()).hexdigest()[:8], 16) / 2 ** 32
    return "train" if bucket < 0.8 else "validation" if bucket < 0.9 else "test"


def safe_image_path(root: Path, value: str) -> Path:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value:
        raise ValueError("Image path must stay inside the dataset")
    resolved = (Path(root) / value).resolve()
    if not resolved.is_relative_to(Path(root).resolve()):
        raise ValueError("Image symlink escapes the dataset")
    return resolved


def load_manifest(root: Path, split: str, verify_images=False):
    if split not in SPLITS:
        raise ValueError("Unknown split")
    rows, identifiers = [], set()
    for line_number, line in enumerate((Path(root) / f"{split}.jsonl").read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        row = json.loads(line)
        if not isinstance(row.get("latex"), str) or not row["latex"].strip() or row.get("id") in identifiers or not row.get("id"):
            raise ValueError(f"Invalid/duplicate record at {split}:{line_number}")
        path = safe_image_path(root, row["image"])
        if not path.is_file():
            raise ValueError(f"Missing image at {split}:{line_number}")
        if verify_images:
            with Image.open(path) as image:
                image.verify()
        identifiers.add(row["id"])
        rows.append(row)
    if not rows:
        raise ValueError(f"Empty {split} split")
    return rows


def synthetic_formulas(count: int, seed=42):
    if count < 0:
        raise ValueError("Synthetic sample count cannot be negative")
    if count == 0:
        return
    rng, seen = random.Random(seed), set()
    templates = [r"{a}x+{b}={c}", r"x^2+{a}x+{b}=0", r"\frac{{{a}}}{{{b}}}=x", r"\sqrt{{{a}}}+{b}=x", r"v=\frac{{{a}}}{{{b}}}", r"F={a}\cdot {b}", r"\rho=\frac{{{a}}}{{{b}}}", r"E=\frac{{{a}\cdot {b}^2}}{{2}}", r"\eta=\frac{{{a}}}{{{b}}}\cdot100\%"]
    for _ in range(max(100, count * 20)):
        label = rng.choice(templates).format(a=rng.randint(1, 99), b=rng.randint(1, 99), c=rng.randint(1, 99))
        if label not in seen:
            seen.add(label)
            yield label
            if len(seen) >= count:
                return


def render_printed_formula(label: str, seed=42):
    from matplotlib import mathtext, rc_context
    rng = random.Random(seed)
    output = io.BytesIO()
    with rc_context({"mathtext.fontset": rng.choice(["dejavusans", "stix"])}):
        mathtext.math_to_image("$" + label + "$", output, dpi=rng.choice([130, 160, 190]), format="png", color="black")
    output.seek(0)
    with Image.open(output) as image:
        return normalize_image(image)


def prepare_dataset(archive: Path | None, destination: Path, limits=None, *, variant="full", synthetic_count=300, custom_manifest=None, custom_license="unspecified", seed=42):
    """Build a new dataset atomically. Existing datasets are never overwritten."""
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Dataset already exists; use a new destination to rebuild")
    limits = limits or {"train": 12_000, "validation": 1000, "test": 500}
    if set(limits) != set(SPLITS) or any(not isinstance(value, int) or value < 1 for value in limits.values()):
        raise ValueError("Each official split needs a positive sample limit")
    if archive is None and custom_manifest is None:
        raise ValueError("Provide MathWriting or a custom dataset")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".axiora-data-", dir=destination.parent) as temporary:
        root = Path(temporary) / "dataset"
        root.mkdir()
        records = {split: [] for split in SPLITS}
        skipped = Counter()

        def add(split, image, label, source, identifier, group):
            if not label.strip() or len(label) > 512:
                skipped["empty_or_long_label"] += 1
                return
            image = normalize_image(image)
            relative = f"images/{split}/{identifier}.png"
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            image.save(path)
            records[split].append({"id": identifier, "image": relative, "latex": label.strip(), "source": source, "group_id": group, "image_sha256": sha256_file(path)})

        if archive is not None:
            mapping = {"train": "train", "valid": "validation", "test": "test"}
            with tarfile.open(archive, "r|gz") as source:
                for member in source:
                    parts = PurePosixPath(member.name).parts
                    if not member.isfile() or member.size > 2 * 1024 ** 2 or len(parts) < 2 or ".." in parts or member.name.startswith("/"):
                        continue
                    split = mapping.get(parts[-2])
                    if split is None or not member.name.endswith(".inkml") or len(records[split]) >= limits[split]:
                        continue
                    try:
                        label, strokes, annotations = read_inkml(source.extractfile(member).read())
                        if annotations.get("splitTagOriginal") != parts[-2]:
                            raise ValueError("InkML split differs from archive split")
                        identifier = "mw-" + split + "-" + hashlib.sha256(member.name.encode()).hexdigest()[:16]
                        add(split, render_ink(strokes), label, "mathwriting-human", identifier, identifier)
                    except (ValueError, ET.ParseError) as error:
                        skipped[type(error).__name__] += 1
                    if all(len(records[key]) >= limits[key] for key in SPLITS):
                        break

        if custom_manifest is not None:
            manifest = Path(custom_manifest)
            custom = [json.loads(line) for line in manifest.read_text(encoding="utf-8").splitlines() if line.strip()]
            explicit = {}
            for row in custom:
                group = row.get("group_id")
                if not isinstance(group, str) or not group.strip():
                    raise ValueError("Custom samples require a writer/session group_id")
                if "split" in row:
                    if row["split"] not in SPLITS or (group in explicit and explicit[group] != row["split"]):
                        raise ValueError("A custom group cannot cross dataset splits")
                    explicit[group] = row["split"]
            for index, row in enumerate(custom):
                if not isinstance(row.get("latex"), str):
                    raise ValueError("Custom labels must be strings")
                group = hashlib.sha256(row["group_id"].encode()).hexdigest()[:24]
                split = explicit.get(row["group_id"], grouped_split(group, seed))
                image_path = safe_image_path(manifest.parent, row["image"])
                identifier = "custom-" + hashlib.sha256(f"{row['image']}:{index}".encode()).hexdigest()[:16]
                with Image.open(image_path) as image:
                    add(split, image, row["latex"], "custom", identifier, "custom-" + group)

        held_out = {"".join(row["latex"].split()) for split in ("validation", "test") for row in records[split]}
        count = min(max(0, synthetic_count), len(records["train"]) // 10)
        for index, label in enumerate(synthetic_formulas(count * 2, seed) if count else []):
            if "".join(label.split()) in held_out:
                skipped["synthetic_matches_held_out"] += 1
                continue
            identifier = "printed-" + hashlib.sha256(label.encode()).hexdigest()[:16]
            add("train", render_printed_formula(label, seed + index), label, "printed-synthetic", identifier, identifier)
            count -= 1
            if count == 0:
                break

        # Give held-out samples priority when exactly identical raster images occur.
        seen_hashes, all_ids, custom_groups = set(), set(), {}
        for split in ("test", "validation", "train"):
            unique = []
            for row in records[split]:
                if row["id"] in all_ids:
                    raise ValueError("Duplicate sample ID")
                all_ids.add(row["id"])
                if row["source"] == "custom":
                    previous = custom_groups.setdefault(row["group_id"], split)
                    if previous != split:
                        raise ValueError("Custom writer/session group crosses splits")
                if row["image_sha256"] in seen_hashes:
                    skipped["duplicate_image"] += 1
                    (root / row["image"]).unlink()
                    continue
                seen_hashes.add(row["image_sha256"])
                unique.append(row)
            records[split] = unique
            if not unique:
                raise ValueError(f"No samples in {split}; provide more writer groups or explicit custom splits")
            (root / f"{split}.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in unique), encoding="utf-8")
        report = {
            "schema_version": 1, "variant": variant if archive is not None else "custom", "seed": seed,
            "counts": {split: len(records[split]) for split in SPLITS},
            "sources": dict(Counter(row["source"] for rows in records.values() for row in rows)),
            "skipped": dict(skipped), "image_config": asdict(IMAGE_CONFIG),
            "mathwriting": None if archive is None else {"url": MATHWRITING_URLS[variant], "archive_sha256": sha256_file(archive), "license": DATA_LICENSE, "split_policy": "official; writer IDs are not published; not all writers are disjoint"},
            "custom_license": custom_license if custom_manifest is not None else None,
            "synthetic_policy": "printed auxiliary samples, training only, at most 10% of base train count; not a substitute for handwriting",
        }
        json_write(root / "dataset_report.json", report)
        root.replace(destination)
    return report


def zip_dataset(root: Path, destination: Path):
    root, destination = Path(root), Path(destination)
    files = [root / "dataset_report.json"]
    for split in SPLITS:
        rows = load_manifest(root, split)
        files.append(root / f"{split}.jsonl")
        files.extend(root / row["image"] for row in rows)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, path.relative_to(root).as_posix())
    temporary.replace(destination)
    return sha256_file(destination)


def audit_dataset(root: Path):
    root = Path(root)
    digest, image_hashes, identifiers, groups = hashlib.sha256(), set(), set(), {}
    report = json.loads((root / "dataset_report.json").read_text(encoding="utf-8"))
    if report.get("schema_version") != 1 or report.get("image_config") != asdict(IMAGE_CONFIG):
        raise ValueError("Dataset version/preprocessing does not match the training pipeline")
    counts = {}
    for split in SPLITS:
        rows = load_manifest(root, split, verify_images=True)
        digest.update((root / f"{split}.jsonl").read_bytes())
        counts[split] = len(rows)
        for row in rows:
            actual_hash = sha256_file(safe_image_path(root, row["image"]))
            if actual_hash != row.get("image_sha256"):
                raise ValueError("Image checksum does not match its manifest")
            if row["id"] in identifiers or actual_hash in image_hashes:
                raise ValueError("Duplicate ID/image in the dataset")
            identifiers.add(row["id"])
            image_hashes.add(actual_hash)
            if row.get("source") == "printed-synthetic" and split != "train":
                raise ValueError("Printed synthetic images must not enter held-out splits")
            if row.get("source") == "custom":
                previous = groups.setdefault(row["group_id"], split)
                if previous != split:
                    raise ValueError("A custom writer/session group crosses splits")
    if report.get("counts") != counts:
        raise ValueError("Dataset report counts differ from the manifests")
    digest.update((root / "dataset_report.json").read_bytes())
    return {"fingerprint": digest.hexdigest(), "counts": counts, "report": report}


def unpack_dataset(archive_path: Path, destination: Path, max_bytes=2 * 1024 ** 3):
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Extraction destination already exists")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".axiora-unpack-", dir=destination.parent) as temporary:
        root = Path(temporary) / "dataset"
        root.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            if sum(item.file_size for item in archive.infolist()) > max_bytes:
                raise ValueError("Dataset archive exceeds the unpacked size limit")
            for item in archive.infolist():
                path = safe_image_path(root, item.filename)
                if stat.S_ISLNK(item.external_attr >> 16):
                    raise ValueError("Symlinks are forbidden in dataset archives")
                if item.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, path.open("wb") as target:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        target.write(block)
        for split in SPLITS:
            load_manifest(root, split, verify_images=True)
        if not (root / "dataset_report.json").is_file():
            raise ValueError("Missing dataset report")
        root.replace(destination)
    return destination
