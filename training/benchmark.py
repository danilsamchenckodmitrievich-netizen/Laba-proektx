"""Run in a fresh CPU process: python -m training.benchmark --help."""
from __future__ import annotations

import argparse
import gc
import json
from pathlib import Path
import resource
import time

import numpy as np
from PIL import Image

from training.data import json_write, load_manifest, normalize_image
from training.ocr import filter_labels, text_metrics


def run_benchmark(model_dir, dataset_dir, output, *, samples=12, max_length=128, int8=False):
    import torch
    from transformers import TrOCRProcessor, VisionEncoderDecoderModel
    if samples < 1 or not 8 <= max_length <= 512:
        raise ValueError("Invalid benchmark sample count or decoder length")
    torch.set_num_threads(2)
    torch.set_num_interop_threads(2)
    started = time.perf_counter()
    processor = TrOCRProcessor.from_pretrained(model_dir, local_files_only=True, use_fast=False)
    model = VisionEncoderDecoderModel.from_pretrained(model_dir, local_files_only=True, use_safetensors=True).float().eval().to("cpu")
    load_seconds = time.perf_counter() - started
    rows, excluded = filter_labels(load_manifest(Path(dataset_dir), "validation"), processor.tokenizer, max_length)
    rows = rows[:samples]

    def infer(candidate, row):
        before = time.perf_counter()
        with Image.open(Path(dataset_dir) / row["image"]) as source:
            image = normalize_image(source)
        pixels = processor(images=image, return_tensors="pt").pixel_values
        with torch.inference_mode():
            ids = candidate.generate(pixels, max_length=max_length, num_beams=1, do_sample=False, use_cache=True)
        text = processor.batch_decode(ids, skip_special_tokens=True)[0]
        return text, time.perf_counter() - before, int(ids.shape[-1])

    def measure(candidate):
        infer(candidate, rows[0])  # Untimed warm-up; cold loading is reported separately.
        values = [infer(candidate, row) for row in rows]
        seconds = [value[1] for value in values]
        return {
            "samples": len(rows), "seconds_median": float(np.median(seconds)),
            "seconds_p95": float(np.percentile(seconds, 95)), "seconds_min": min(seconds),
            "generated_tokens_median": float(np.median([value[2] for value in values])),
            "within_2s_median_target": bool(np.median(seconds) <= 2),
            "quality": text_metrics([value[0] for value in values], [row["latex"] for row in rows]),
        }, [value[0] for value in values]

    fp32, original_text = measure(model)
    report = {
        "schema_version": 1, "torch": torch.__version__, "threads": torch.get_num_threads(),
        "generation_max_length": max_length, "cold_model_load_seconds": load_seconds,
        "excluded_validation_labels": excluded, "fp32": fp32,
        "timing_scope": "warm single cropped formula, disk image read + preprocessing + greedy cached decoding; no network; validation subset; two software threads are not a CPU Basic quota guarantee",
    }
    training_report = Path(model_dir) / "training_report.json"
    report["model_training_mode"] = json.loads(training_report.read_text())["config"]["mode"] if training_report.exists() else "unknown"
    if int8:
        supported = torch.backends.quantized.supported_engines
        engine = next((name for name in ("x86", "fbgemm", "qnnpack") if name in supported), None)
        if engine is None:
            report["int8_unavailable"] = "No supported dynamic quantization engine"
        else:
            torch.backends.quantized.engine = engine
            try:
                candidate = torch.ao.quantization.quantize_dynamic(model, {torch.nn.Linear}, dtype=torch.qint8, inplace=False).eval()
                quantized, quantized_text = measure(candidate)
                quantized["engine"] = engine
                quantized["prediction_agreement_with_fp32"] = sum(left == right for left, right in zip(original_text, quantized_text)) / len(rows)
                quantized["cer_delta_vs_fp32"] = quantized["quality"]["cer"] - fp32["quality"]["cer"]
                quantized["quality_regression_detected"] = quantized["cer_delta_vs_fp32"] > 0.005 or quantized["prediction_agreement_with_fp32"] < 0.99
                report["int8"] = quantized
                del candidate
                gc.collect()
            except (RuntimeError, NotImplementedError, AttributeError) as error:
                report["int8_error"] = f"{type(error).__name__}: {str(error)[:500]}"
    report["process_peak_rss_mib"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    report["memory_scope"] = "Linux process peak includes model loading and, when enabled, both models during INT8 conversion"
    json_write(Path(output), report)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--dataset-dir", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--samples", type=int, default=12)
    parser.add_argument("--max-length", type=int, default=128)
    parser.add_argument("--int8", action="store_true")
    args = parser.parse_args()
    result = run_benchmark(args.model_dir, args.dataset_dir, args.output, samples=args.samples, max_length=args.max_length, int8=args.int8)
    print(json.dumps(result, ensure_ascii=False, indent=2))
