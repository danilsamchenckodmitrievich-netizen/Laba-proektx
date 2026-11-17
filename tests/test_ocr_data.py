from collections import Counter
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile

from PIL import Image, ImageDraw

from training.data import (ImageConfig, audit_dataset, grouped_split, load_manifest, normalize_image,
                           prepare_dataset, read_inkml, render_ink, safe_image_path, synthetic_formulas,
                           unpack_dataset, zip_dataset)


def ink(label, split="train", variant=1):
    return f'''<ink xmlns="http://www.w3.org/2003/InkML">
      <annotation type="label">original</annotation>
      <annotation type="normalizedLabel">{label}</annotation>
      <annotation type="splitTagOriginal">{split}</annotation>
      <trace>0 0 0, 15 22 1, 30 {variant + 2} 2</trace>
    </ink>'''.encode()


class OcrDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def archive(self):
        path = self.root / "source.tgz"
        with tarfile.open(path, "w:gz") as archive:
            bad = tarfile.TarInfo("../../train/escape.inkml")
            content = ink("evil")
            bad.size = len(content)
            archive.addfile(bad, io.BytesIO(content))
            for split, offset in [("train", 0), ("valid", 4), ("test", 8)]:
                for index in range(3):
                    content = ink(f"x+{offset + index + 1}", split, offset + index + 1)
                    member = tarfile.TarInfo(f"dataset/{split}/{index}.inkml")
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
        return path

    def dataset(self):
        path = self.root / "prepared"
        prepare_dataset(self.archive(), path, {"train": 3, "validation": 3, "test": 3}, variant="excerpt", synthetic_count=0)
        return path

    def test_ink_uses_normalized_label_and_xy(self):
        label, strokes, metadata = read_inkml(ink(r"\frac{1}{2}"))
        self.assertEqual(label, r"\frac{1}{2}")
        self.assertEqual(strokes[0][1], (15, 22))
        self.assertEqual(metadata["label"], "original")

    def test_invalid_ink_cannot_enter_training(self):
        for content in [b"<!DOCTYPE x><ink/>", b'<ink><trace>0 nan</trace></ink>', ink(""), ink("x").replace(b"normalizedLabel", b"other")]:
            with self.subTest(content=content[:30]), self.assertRaises(ValueError):
                read_inkml(content)

    def test_single_points_render_without_division_by_zero(self):
        image = render_ink([[(2, 2)]])
        self.assertEqual(image.size, (384, 384))
        self.assertLess(min(image.getextrema()[0]), 255)

    def test_normalization_flattens_alpha_and_rejects_blank(self):
        image = Image.new("RGBA", (60, 20), (0, 0, 0, 0))
        ImageDraw.Draw(image).line((5, 10, 55, 10), fill="black", width=2)
        result = normalize_image(image)
        self.assertEqual(result.mode, "RGB")
        self.assertEqual(result.size, (384, 384))
        self.assertEqual(result.getpixel((0, 0)), (255, 255, 255))
        with self.assertRaises(ValueError):
            normalize_image(Image.new("RGB", (10, 10), "white"))

    def test_limits_are_checked_before_image_processing(self):
        with self.assertRaises(ValueError):
            ImageConfig(size=32, padding=20)
        with self.assertRaises(ValueError):
            normalize_image(Image.new("RGB", (10, 10)), ImageConfig(max_image_pixels=20))

    def test_original_splits_and_checksums_survive_packaging(self):
        path = self.dataset()
        audit = audit_dataset(path)
        self.assertEqual(audit["counts"], {"train": 3, "validation": 3, "test": 3})
        self.assertTrue(all(row["source"] == "mathwriting-human" for row in load_manifest(path, "test")))
        zip_dataset(path, self.root / "data.zip")
        unpack_dataset(self.root / "data.zip", self.root / "restored")
        self.assertEqual(audit_dataset(self.root / "restored")["fingerprint"], audit["fingerprint"])
        self.assertFalse((self.root / "escape.inkml").exists())

    def test_modified_image_is_detected(self):
        path = self.dataset()
        row = load_manifest(path, "train")[0]
        Image.new("RGB", (384, 384), "black").save(path / row["image"])
        with self.assertRaisesRegex(ValueError, "checksum"):
            audit_dataset(path)

    def test_existing_dataset_is_not_overwritten(self):
        path = self.dataset()
        before = audit_dataset(path)["fingerprint"]
        with self.assertRaises(ValueError):
            prepare_dataset(None, path)
        self.assertEqual(audit_dataset(path)["fingerprint"], before)

    def test_group_splits_are_stable_and_do_not_use_row_order(self):
        groups = [f"writer-{index}" for index in range(100)]
        expected = {group: grouped_split(group) for group in groups}
        self.assertEqual(expected, {group: grouped_split(group) for group in reversed(groups)})
        self.assertEqual(set(expected.values()), {"train", "validation", "test"})

    def test_conflicting_custom_writer_groups_are_rejected(self):
        manifest = self.root / "custom.jsonl"
        manifest.write_text("\n".join(json.dumps({"image": "a.png", "latex": "x", "group_id": "same-writer", "split": split}) for split in ("train", "test")))
        with self.assertRaisesRegex(ValueError, "group"):
            prepare_dataset(None, self.root / "custom", custom_manifest=manifest)

    def test_custom_group_is_required(self):
        manifest = self.root / "custom.jsonl"
        manifest.write_text(json.dumps({"image": "a.png", "latex": "x"}))
        with self.assertRaisesRegex(ValueError, "group_id"):
            prepare_dataset(None, self.root / "custom", custom_manifest=manifest)

    def test_own_photos_can_build_a_complete_grouped_dataset(self):
        rows = []
        for index, split in enumerate(("train", "validation", "test")):
            image = Image.new("RGB", (80, 60), "white")
            draw = ImageDraw.Draw(image)
            draw.line((10, 10, 60, 45), fill="black", width=3)
            draw.line((10, 20 + index * 8, 60, 20 + index * 8), fill="black", width=3)
            image.save(self.root / f"own-{index}.png")
            rows.append({"image": f"own-{index}.png", "latex": f"x={index}", "group_id": f"writer-{index}", "split": split})
        manifest = self.root / "own.jsonl"
        manifest.write_text("\n".join(json.dumps(row) for row in rows))
        report = prepare_dataset(None, self.root / "own-data", custom_manifest=manifest, custom_license="own-permission")
        self.assertEqual(report["variant"], "custom")
        self.assertIsNone(report["mathwriting"])
        self.assertEqual(audit_dataset(self.root / "own-data")["counts"], {"train": 1, "validation": 1, "test": 1})

    def test_image_path_cannot_escape_root(self):
        for path in ("../private.png", "/tmp/private.png", "images\\private.png"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                safe_image_path(self.root, path)

    def test_zip_traversal_and_oversize_are_rejected_atomically(self):
        path = self.root / "evil.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("../escape.txt", "bad")
        with self.assertRaises(ValueError):
            unpack_dataset(path, self.root / "unpack")
        self.assertFalse((self.root / "unpack").exists())
        with self.assertRaises(ValueError):
            unpack_dataset(path, self.root / "unpack", max_bytes=1)

    def test_synthetic_labels_are_varied_deterministic_and_unique(self):
        first = list(synthetic_formulas(50))
        self.assertEqual(first, list(synthetic_formulas(50)))
        self.assertEqual(len(set(first)), 50)
        self.assertTrue(any(r"\frac" in label for label in first))


if __name__ == "__main__":
    unittest.main()
