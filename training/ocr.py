"""Lazy-loaded training helpers; importing this file does not load torch or weights."""
from __future__ import annotations

from dataclasses import asdict, dataclass
import json
import hashlib
from pathlib import Path
import platform
import re

from PIL import Image

from training.data import IMAGE_CONFIG, augment_image, json_write, safe_image_path

BASE_MODEL = "microsoft/trocr-small-handwritten"
BASE_REVISION = "b4648cfa171985a6745f37ddd637e98c0da958ac"


@dataclass(frozen=True)
class TrainConfig:
    mode: str = "t4"
    seed: int = 42
    max_target_length: int = 128
    train_batch_size: int = 2
    gradient_accumulation_steps: int = 8
    learning_rate: float = 5e-5
    epochs: int = 3
    eval_samples: int = 200
    eval_steps: int = 250
    base_model: str = BASE_MODEL
    base_revision: str = BASE_REVISION

    def __post_init__(self):
        if self.mode not in ("t4", "smoke"):
            raise ValueError("Choose t4 or smoke mode")
        if not 8 <= self.max_target_length <= 512:
            raise ValueError("TrOCR labels must fit its 512-position decoder")
        if min(self.train_batch_size, self.gradient_accumulation_steps, self.epochs, self.eval_samples, self.eval_steps) < 1:
            raise ValueError("Training counts must be positive")
        if not 0 < self.learning_rate < 1:
            raise ValueError("Invalid learning rate")


def edit_distance(left: str, right: str) -> int:
    if len(left) > len(right):
        left, right = right, left
    previous = list(range(len(left) + 1))
    for i, right_char in enumerate(right, 1):
        current = [i]
        for j, left_char in enumerate(left, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (left_char != right_char)))
        previous = current
    return previous[-1]


def text_metrics(predictions, references):
    if len(predictions) != len(references) or not references or any(not ref for ref in references):
        raise ValueError("Metrics require paired predictions and nonempty references")
    normalized = lambda text: re.sub(r"\s+", "", text)
    return {
        "cer": sum(edit_distance(pred, ref) for pred, ref in zip(predictions, references)) / sum(map(len, references)),
        "exact_match": sum(pred == ref for pred, ref in zip(predictions, references)) / len(references),
        "exact_match_ignore_whitespace": sum(normalized(pred) == normalized(ref) for pred, ref in zip(predictions, references)) / len(references),
    }


def filter_labels(records, tokenizer, max_length):
    kept, rejected = [], {"too_long": 0, "unknown_token": 0}
    for row in records:
        ids = tokenizer(row["latex"], add_special_tokens=True, truncation=False).input_ids
        if len(ids) > max_length:
            rejected["too_long"] += 1
        elif tokenizer.unk_token_id in ids:
            rejected["unknown_token"] += 1
        else:
            kept.append(row)
    if not kept:
        raise ValueError("No supported labels remain; inspect the tokenizer/length audit")
    return kept, rejected


class FormulaDataset:
    def __init__(self, root, records, processor, *, augment=False):
        self.root, self.records, self.processor, self.augment = Path(root), records, processor, augment

    def __len__(self):
        return len(self.records)

    def __getitem__(self, index):
        row = self.records[index]
        with Image.open(safe_image_path(self.root, row["image"])) as source:
            image = source.convert("RGB")
        if self.augment:
            image = augment_image(image)
        pixels = self.processor(images=image, return_tensors="pt").pixel_values[0]
        labels = self.processor.tokenizer(row["latex"], add_special_tokens=True, truncation=False).input_ids
        return {"pixel_values": pixels, "labels": labels}


class FormulaCollator:
    def __init__(self, tokenizer):
        self.tokenizer = tokenizer

    def __call__(self, examples):
        import torch
        labels = self.tokenizer.pad({"input_ids": [item["labels"] for item in examples]}, padding=True, return_tensors="pt")
        label_ids = labels.input_ids.masked_fill(labels.attention_mask.eq(0), -100)
        return {"pixel_values": torch.stack([item["pixel_values"] for item in examples]), "labels": label_ids}


def metric_callback(tokenizer):
    def compute(prediction):
        import numpy as np
        predictions, labels = prediction.predictions, prediction.label_ids
        if isinstance(predictions, tuple):
            predictions = predictions[0]
        predictions = np.where(predictions == -100, tokenizer.pad_token_id, predictions)
        labels = np.where(labels == -100, tokenizer.pad_token_id, labels)
        return text_metrics(tokenizer.batch_decode(predictions, skip_special_tokens=True), tokenizer.batch_decode(labels, skip_special_tokens=True))
    return compute


def load_base_model(config: TrainConfig):
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel
    processor = TrOCRProcessor.from_pretrained(config.base_model, revision=config.base_revision, use_fast=False)
    # Upstream publishes a PyTorch bin. torch >= 2.6 is required by transformers'
    # safe weights-only loader. Our trained export is always safetensors.
    model = VisionEncoderDecoderModel.from_pretrained(config.base_model, revision=config.base_revision)
    model.config.decoder_start_token_id = processor.tokenizer.cls_token_id
    model.config.pad_token_id = processor.tokenizer.pad_token_id
    model.config.eos_token_id = processor.tokenizer.eos_token_id
    model.config.vocab_size = model.config.decoder.vocab_size
    model.decoder.config.use_cache = False
    model.generation_config.decoder_start_token_id = processor.tokenizer.cls_token_id
    model.generation_config.pad_token_id = processor.tokenizer.pad_token_id
    model.generation_config.eos_token_id = processor.tokenizer.eos_token_id
    model.generation_config.num_beams = 1
    model.generation_config.max_length = config.max_target_length
    model.generation_config.use_cache = True
    return model, processor


def ensure_run_context(output_dir, context, resume):
    output_dir = Path(output_dir)
    path = output_dir / "axiora_run_context.json"
    if path.exists():
        previous = json.loads(path.read_text(encoding="utf-8"))
        if previous != context:
            raise ValueError("Checkpoint context differs: choose a new run directory for changed data/settings")
        if not resume and any(output_dir.glob("checkpoint-*")):
            raise ValueError("Checkpoints exist; resume them or choose a new run directory")
    elif any(output_dir.glob("checkpoint-*")):
        raise ValueError("Unidentified checkpoints: refuse to resume with an unknown dataset")
    else:
        json_write(path, context)


def training_code_fingerprint():
    root = Path(__file__).resolve().parent
    digest = hashlib.sha256()
    for name in ("data.py", "ocr.py", "requirements-colab.txt"):
        digest.update(name.encode())
        digest.update((root / name).read_bytes())
    return digest.hexdigest()


def make_trainer(model, processor, datasets, config: TrainConfig, output_dir, *, fp16):
    from transformers import Seq2SeqTrainer, Seq2SeqTrainingArguments
    steps = 2 if config.mode == "smoke" else config.eval_steps
    arguments = Seq2SeqTrainingArguments(
        output_dir=str(output_dir), per_device_train_batch_size=config.train_batch_size,
        per_device_eval_batch_size=1, gradient_accumulation_steps=config.gradient_accumulation_steps,
        num_train_epochs=config.epochs, max_steps=2 if config.mode == "smoke" else -1,
        learning_rate=config.learning_rate, warmup_ratio=0.05, weight_decay=0.01,
        max_grad_norm=1.0, fp16=fp16, bf16=False, optim="adamw_torch",
        eval_strategy="steps", eval_steps=steps, save_strategy="steps", save_steps=steps,
        logging_steps=1 if config.mode == "smoke" else 25,
        load_best_model_at_end=True, metric_for_best_model="cer", greater_is_better=False,
        save_total_limit=2, save_safetensors=True, predict_with_generate=True,
        generation_max_length=config.max_target_length, generation_num_beams=1,
        eval_accumulation_steps=1, remove_unused_columns=False, label_names=["labels"],
        dataloader_num_workers=0, dataloader_pin_memory=fp16,
        seed=config.seed, data_seed=config.seed, report_to=[],
        use_cpu=not fp16, push_to_hub=False,
    )
    trainer = Seq2SeqTrainer(
        model=model, args=arguments, train_dataset=datasets["train"], eval_dataset=datasets["validation"],
        data_collator=FormulaCollator(processor.tokenizer), processing_class=processor,
        compute_metrics=metric_callback(processor.tokenizer),
    )
    # VisionEncoderDecoder uses its native token loss; do not forward Trainer's
    # num_items_in_batch through **kwargs into the DeiT encoder.
    trainer.model_accepts_loss_kwargs = False
    return trainer


def export_model(model, processor, destination, run_report):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    model.config.decoder.use_cache = True
    model.decoder.config.use_cache = True
    model.generation_config.use_cache = True
    model.save_pretrained(destination, safe_serialization=True)
    processor.save_pretrained(destination)
    json_write(destination / "axiora_preprocessing.json", asdict(IMAGE_CONFIG))
    json_write(destination / "training_report.json", run_report)
    return destination


def model_card(report, repo_id):
    uses_mathwriting = report["dataset"]["report"].get("mathwriting") is not None
    license_line = "license: cc-by-nc-sa-4.0" if uses_mathwriting else "license: other\nlicense_name: custom-training-data-terms\nlicense_link: README.md#data-and-licensing"
    mode = report["config"]["mode"]
    return f'''---
{license_line}
base_model: {report["config"]["base_model"]}
pipeline_tag: image-to-text
tags: [trocr, latex, handwriting, math, axiora]
---
# Axiora handwritten formula OCR

Compact TrOCR-small fine-tuned to transcribe **one cropped formula** to LaTeX.
Training mode: **{mode}**. A smoke run validates the pipeline and is not a usable educational OCR model.

Use `TrOCRProcessor` and `VisionEncoderDecoderModel` with these exported weights.
Before the processor, apply the crop/white-alpha-compositing/letterboxing contract in
`axiora_preprocessing.json` (implementation: `training/data.py` in the Axiora repository).
Inference should use `model.eval()`, `torch.inference_mode()`, and greedy cached decoding.
Use the exact model revision returned after uploading for reproducible deployment.

## Evaluation

Metrics, retained/excluded label counts, data fingerprint, base revision and environment
are recorded in `training_report.json`. `cer` is character error rate, not semantic math correctness.
`exact_match_ignore_whitespace` is reported separately from literal exact match.
The test split is used only for final evaluation, after checkpoint selection on validation data.
CPU timings, if run, are in `cpu_benchmark.json`; they are not guaranteed Hugging Face Space timings.

## Limitations

This model does not check solutions or proofs, read diagrams, or transcribe whole notebook pages.
Russian prose and multi-line page layout are outside the training target. OCR errors need user correction.
Long/unsupported labels excluded from training and evaluation are counted in the report.
Uploaded artifacts contain weights, processor and aggregate reports; dataset images and checkpoints are not uploaded.

## Data and licensing

MathWriting: Google LLC, https://github.com/google-research/google-research/tree/master/mathwriting,
CC BY-NC-SA 4.0; underlying Wikipedia expressions can also carry CC BY-SA terms.
The default MathWriting-trained artifact is conservatively marked for noncommercial use.
Own-data terms: {report["dataset"]["report"].get("custom_license") or "no custom data"}.
Printed auxiliary formulas are training-only and do not replace real handwritten samples.
Official MathWriting splits are preserved; original writer IDs are unavailable and not all writers are disjoint.
Own photos use author/session groups that cannot cross splits. Consult the source/base-model terms
before changing the use or distribution of the resulting model.

Repository: `{repo_id}`. Base model revision: `{report["config"]["base_revision"]}`.
'''


def publish_to_hub(model, processor, export_dir, report, *, token, repo_id=None, private=True, api=None):
    """Automatic final-cell upload. Credentials are never written into artifacts."""
    if not token:
        raise ValueError("Add HF_TOKEN to Colab Secrets with model-repository write access")
    if api is None:
        from huggingface_hub import HfApi
        api = HfApi(token=token)
    owner = api.whoami(token=token)["name"]
    default_name = "axiora-ocr-smoke" if report["config"]["mode"] == "smoke" else "axiora-ocr"
    repo_id = repo_id or f"{owner}/{default_name}"
    if report["config"]["mode"] == "smoke" and not repo_id.endswith("-smoke"):
        raise ValueError("Smoke uploads must use a distinct repository ending in -smoke")
    export_dir = Path(export_dir)
    (export_dir / "README.md").write_text(model_card(report, repo_id), encoding="utf-8")
    api.create_repo(repo_id=repo_id, repo_type="model", private=private, exist_ok=True, token=token)
    model.push_to_hub(repo_id, private=private, token=token, safe_serialization=True, commit_message="Upload Axiora OCR weights")
    processor.push_to_hub(repo_id, private=private, token=token, commit_message="Upload matching OCR processor")
    result = api.upload_folder(
        repo_id=repo_id, repo_type="model", folder_path=str(export_dir), token=token,
        allow_patterns=["*.json", "*.safetensors", "*.model", "*.txt", "README.md"],
        commit_message="Publish complete Axiora OCR export and reports",
    )
    return {"repo_id": repo_id, "revision": result.oid, "url": f"https://huggingface.co/{repo_id}"}


def environment_report():
    from importlib.metadata import version
    import torch
    return {"python": platform.python_version(), "torch": torch.__version__,
            "transformers": version("transformers"), "accelerate": version("accelerate"),
            "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None}
