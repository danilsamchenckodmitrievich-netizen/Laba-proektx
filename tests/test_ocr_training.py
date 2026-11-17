from dataclasses import asdict
import json
import contextlib
import io
from pathlib import Path
import tempfile
from types import SimpleNamespace, ModuleType
import unittest
from unittest.mock import Mock, patch

import nbformat

from training.ocr import TrainConfig, edit_distance, ensure_run_context, filter_labels, model_card, publish_to_hub, text_metrics


class TokenizerFixture:
    unk_token_id = 99

    def __call__(self, text, **kwargs):
        return SimpleNamespace(input_ids=[99] if "?" in text else list(range(len(text) + 2)))


class OcrTrainingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def report(self, mode="t4"):
        return {"config": asdict(TrainConfig(mode=mode)), "dataset": {"report": {"mathwriting": {"license": "cc-by-nc-sa-4.0"}, "custom_license": None}}}

    def test_metrics_distinguish_characters_exact_and_whitespace(self):
        metrics = text_metrics(["x = 2", "x=4"], ["x=2", "x=3"])
        self.assertEqual(metrics["exact_match"], 0)
        self.assertEqual(metrics["exact_match_ignore_whitespace"], 0.5)
        self.assertEqual(metrics["cer"], 3 / 6)
        self.assertEqual(edit_distance("kitten", "sitting"), 3)
        with self.assertRaises(ValueError):
            text_metrics(["x"], [""])

    def test_labels_are_excluded_with_audit_and_never_truncated(self):
        rows = [{"latex": "xx"}, {"latex": "xxxxx"}, {"latex": "?"}]
        kept, audit = filter_labels(rows, TokenizerFixture(), 4)
        self.assertEqual(kept, [rows[0]])
        self.assertEqual(audit, {"too_long": 1, "unknown_token": 1})
        self.assertEqual(rows[1]["latex"], "xxxxx")

    def test_resume_requires_same_dataset_and_settings(self):
        output = self.root / "run"
        context = {"fingerprint": "one", "batch": 2}
        ensure_run_context(output, context, True)
        ensure_run_context(output, context, True)
        with self.assertRaisesRegex(ValueError, "differs"):
            ensure_run_context(output, {"fingerprint": "two", "batch": 2}, True)
        (output / "checkpoint-2").mkdir()
        with self.assertRaises(ValueError):
            ensure_run_context(output, context, False)

    def test_unknown_checkpoints_are_not_resumed(self):
        (self.root / "checkpoint-4").mkdir()
        with self.assertRaisesRegex(ValueError, "Unidentified"):
            ensure_run_context(self.root, {"fingerprint": "one"}, True)

    def test_upload_uses_weight_processor_and_complete_artifact_without_token_on_disk(self):
        model, processor, api = Mock(), Mock(), Mock()
        api.whoami.return_value = {"name": "fixture-owner"}
        api.upload_folder.return_value = SimpleNamespace(oid="fixture-revision")
        result = publish_to_hub(model, processor, self.root, self.report(), token="secret-fixture-token", api=api)
        self.assertEqual(result["repo_id"], "fixture-owner/axiora-ocr")
        self.assertEqual(result["revision"], "fixture-revision")
        self.assertTrue(model.push_to_hub.call_args.kwargs["safe_serialization"])
        self.assertTrue(model.push_to_hub.call_args.kwargs["private"])
        processor.push_to_hub.assert_called_once()
        self.assertNotIn("*.png", api.upload_folder.call_args.kwargs["allow_patterns"])
        self.assertNotIn("secret-fixture-token", (self.root / "README.md").read_text())
        self.assertIn("cc-by-nc-sa-4.0", (self.root / "README.md").read_text())

    def test_smoke_run_has_separate_hub_name(self):
        api = Mock()
        api.whoami.return_value = {"name": "fixture-owner"}
        api.upload_folder.return_value = SimpleNamespace(oid="fixture-revision")
        result = publish_to_hub(Mock(), Mock(), self.root, self.report("smoke"), token="token", api=api)
        self.assertTrue(result["repo_id"].endswith("-smoke"))
        api.reset_mock()
        with self.assertRaisesRegex(ValueError, "Smoke"):
            publish_to_hub(Mock(), Mock(), self.root, self.report("smoke"), token="token", repo_id="fixture-owner/production", api=api)
        api.create_repo.assert_not_called()

    def test_missing_token_does_not_start_upload(self):
        api = Mock()
        with self.assertRaisesRegex(ValueError, "HF_TOKEN"):
            publish_to_hub(Mock(), Mock(), self.root, self.report(), token=None, api=api)
        api.create_repo.assert_not_called()

    def test_invalid_training_configuration_is_rejected(self):
        for kwargs in ({"mode": "unknown"}, {"max_target_length": 1024}, {"train_batch_size": 0}, {"learning_rate": -1}):
            with self.subTest(kwargs=kwargs), self.assertRaises(ValueError):
                TrainConfig(**kwargs)

    def test_notebooks_validate_compile_and_contain_no_execution_outputs(self):
        root = Path(__file__).resolve().parents[1]
        notebooks = list((root / "notebooks").glob("*.ipynb"))
        self.assertEqual({path.name for path in notebooks}, {"00_run_ocr_end_to_end.ipynb", "01_prepare_ocr_dataset.ipynb", "02_train_ocr_colab.ipynb"})
        for path in notebooks:
            notebook = nbformat.read(path, as_version=4)
            nbformat.validate(notebook)
            for index, cell in enumerate(notebook.cells):
                if cell.cell_type == "code":
                    compile(cell.source, f"{path}:{index}", "exec")
                    self.assertEqual(cell.outputs, [])
                    self.assertIsNone(cell.execution_count)
            self.assertNotRegex(json.dumps(notebook), r"hf_[A-Za-z0-9]{20,}")

    def test_single_run_can_train_without_hub_credentials_and_does_not_print_them(self):
        root = Path(__file__).resolve().parents[1]
        notebook = nbformat.read(root / "notebooks/00_run_ocr_end_to_end.ipynb", as_version=4)
        source = next(cell.source for cell in notebook.cells if "hub-preflight" in cell.metadata.get("tags", []))
        for missing, invalid in [(True, False), (False, True), (False, False)]:
            with self.subTest(missing=missing, invalid=invalid):
                google = ModuleType("google")
                colab = ModuleType("google.colab")
                colab.userdata = Mock()
                colab.userdata.get.return_value = None if missing else "fixture-secret"
                google.colab = colab
                hub = ModuleType("huggingface_hub")
                hub.HfApi = Mock()
                hub.HfApi.return_value.whoami.return_value = {"name": "fixture-owner"}
                if invalid:
                    hub.HfApi.return_value.whoami.side_effect = RuntimeError("invalid credentials")
                namespace = {"PUSH_TO_HUB": True}
                output = io.StringIO()
                with patch.dict("sys.modules", {"google": google, "google.colab": colab, "huggingface_hub": hub}), contextlib.redirect_stdout(output):
                    exec(compile(source, "notebook-hub-preflight", "exec"), namespace)
                self.assertEqual(namespace["PUSH_TO_HUB"], not (missing or invalid))
                self.assertNotIn("fixture-secret", output.getvalue())
                if missing:
                    hub.HfApi.assert_not_called()


if __name__ == "__main__":
    unittest.main()
