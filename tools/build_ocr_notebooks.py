#!/usr/bin/env python3
"""Deterministic notebook sources. Run after edits; generated notebooks have no outputs."""
import hashlib
import json
from pathlib import Path
import textwrap

ROOT = Path(__file__).resolve().parents[1]


def cell(kind, source, tags=None):
    source = textwrap.dedent(source).strip() + "\n"
    result = {"cell_type": kind, "id": hashlib.sha256((kind + source).encode()).hexdigest()[:12],
              "metadata": {"tags": tags or []}, "source": source.splitlines(keepends=True)}
    if kind == "code":
        result.update(execution_count=None, outputs=[])
    return result


def md(source):
    return cell("markdown", source)


def code(source, *tags):
    return cell("code", source, list(tags))


BOOTSTRAP = '''
from pathlib import Path
import subprocess
import sys

REPO_URL = "https://github.com/danilsamchenckodmitrievich-netizen/Laba-proektx.git"
SOURCE_REF = "main"  # Можно указать ветку; фактический commit попадёт в отчёт.
REPO_DIR = Path("/content/axiora")
if not REPO_DIR.exists():
    subprocess.run(["git", "clone", "--depth", "1", "--branch", SOURCE_REF, REPO_URL, str(REPO_DIR)], check=True)
else:
    actual_origin = subprocess.check_output(["git", "-C", str(REPO_DIR), "remote", "get-url", "origin"], text=True).strip()
    if actual_origin != REPO_URL:
        raise RuntimeError("В /content/axiora находится другой проект. Выберите новый REPO_DIR.")
SOURCE_COMMIT = subprocess.check_output(["git", "-C", str(REPO_DIR), "rev-parse", "HEAD"], text=True).strip()
sys.path.insert(0, str(REPO_DIR))
subprocess.run([sys.executable, "-m", "pip", "install", "-q", "-r", str(REPO_DIR / "training/requirements-colab.txt")], check=True)
print("Версия исходников:", SOURCE_COMMIT)
'''

DRIVE = '''
if USE_GOOGLE_DRIVE:
    from google.colab import drive
    drive.mount("/content/drive")
    PERSIST_DIR = Path("/content/drive/MyDrive/Axiora/ocr")
else:
    PERSIST_DIR = Path("/content/axiora-artifacts")
PERSIST_DIR.mkdir(parents=True, exist_ok=True)
print("Артефакты и контрольные точки:", PERSIST_DIR)
'''

prepare = [
    md('''
    # Аксиора: подготовка данных для OCR

    **Этап 2, ноутбук 1 из 2.** Можно использовать обычную CPU-среду Colab: GPU понадобится во втором ноутбуке.
    Запускайте ячейки по порядку. Результат — ZIP с изображениями, LaTeX-разметкой и отдельными
    train/validation/test. По умолчанию архив сохраняется на ваш Google Drive.

    Источник реального почерка — [Google MathWriting](https://github.com/google-research/google-research/tree/master/mathwriting).
    Его данные имеют лицензию **CC BY-NC-SA 4.0**: стандартный сценарий предназначен для некоммерческих исследований.
    Полный исходный архив занимает около 2,9 ГБ и загружается во временный диск Colab; в подготовленную
    выборку попадёт только заданное число формул. Для быстрой проверки переключите `DATASET_VARIANT` на `excerpt`.
    Excerpt содержит лишь по 100 реальных формул на исходную выборку и не подходит для качественного обучения.

    Если Google AI Pro подключён к другому аккаунту, откройте Colab и подключите Drive под этим аккаунтом.
    Google AI-планы включают преимущества Colab; доступный баланс и ускорители проверьте в панели ресурсов.
    Настройки ниже работают и в базовом сценарии без подписки.

    Синтетические печатные примеры — небольшое дополнение, а не имитация настоящего почерка.
    Модель обучается одной вырезанной формуле; распознавание целой страницы и проверка решения — следующие этапы.
    '''),
    code(BOOTSTRAP, "setup", "network"),
    md('''
    ## Настройки данных

    `full` — реальное обучение, `excerpt` — быстрая проверка, `none` — только собственные изображения.
    Для собственного набора укажите путь к JSONL: каждая строка содержит `image`, `latex`, `group_id`
    и при необходимости `split` (`train`, `validation`, `test`). Изображения лежат рядом с JSONL или в его подпапках.
    Один `group_id` обозначает автора/сессию и всегда остаётся в одной выборке. Не используйте имена учеников как идентификаторы.
    Подробный пример формата — `training/README.md` в репозитории. Укажите условия использования собственных данных.
    '''),
    code('''
    DATASET_VARIANT = "full"
    LIMITS = {"train": 12000, "validation": 1000, "test": 500}
    SYNTHETIC_COUNT = 300  # Дополнительно ограничивается 10% от основного train.
    CUSTOM_MANIFEST = ""  # Например: /content/my-formulas/labels.jsonl
    CUSTOM_LICENSE = "unspecified"
    SEED = 42
    USE_GOOGLE_DRIVE = True
    DATASET_DIR = Path("/content/axiora-ocr-data")
    ''', "config"),
    code(DRIVE, "colab"),
    md('''
    ## Загрузка источника

    Во время загрузки полного архива оставьте вкладку Colab открытой. GPU для этой операции не нужен.
    Малый excerpt дополнительно проверяется по закреплённой SHA-256; для полного архива фактический хэш сохранится в отчёте.
    '''),
    code('''
    from training.data import download_mathwriting
    import time

    archive_path = None
    if DATASET_VARIANT != "none":
        last_message = [0.0]
        def progress(written, total):
            if time.monotonic() - last_message[0] > 5:
                print(f"Загружено {written / 2**20:.0f} МБ" + (f" из {total / 2**20:.0f}" if total else ""))
                last_message[0] = time.monotonic()
        archive_path = download_mathwriting(DATASET_VARIANT, Path("/content") / f"mathwriting-{DATASET_VARIANT}.tgz", progress)
        print("Архив готов:", archive_path.name)
    ''', "network"),
    md('''
    ## Растеризация и формирование выборок

    Официальные разбиения MathWriting сохраняются. Исходные writer ID не опубликованы; нельзя утверждать,
    что все авторы во всех выборках различаются. Для собственных данных применяется разделение по `group_id`.
    Идентичные изображения удаляются с приоритетом test → validation → train. Печатные примеры попадают только в train.
    '''),
    code('''
    from training.data import prepare_dataset, audit_dataset
    import json

    if not DATASET_DIR.exists():
        prepare_dataset(
            archive_path, DATASET_DIR, LIMITS, variant=DATASET_VARIANT,
            synthetic_count=SYNTHETIC_COUNT, custom_manifest=CUSTOM_MANIFEST or None,
            custom_license=CUSTOM_LICENSE, seed=SEED,
        )
    else:
        print("Набор уже существует: проверяем его. Для другой конфигурации задайте новый DATASET_DIR.")
    dataset_audit = audit_dataset(DATASET_DIR)
    print(json.dumps(dataset_audit, ensure_ascii=False, indent=2))
    ''', "prepare-data"),
    md('''
    ## Проверьте изображения и подписи

    Просмотрите несколько примеров перед обучением: формула должна целиком помещаться в кадр, а LaTeX соответствовать почерку.
    Это просмотр данных, а не оценка качества OCR.
    '''),
    code('''
    from training.data import load_manifest
    from PIL import Image
    import matplotlib.pyplot as plt
    import random

    rows = load_manifest(DATASET_DIR, "train")
    selected = random.Random(SEED).sample(rows, min(9, len(rows)))
    figure, axes = plt.subplots(3, 3, figsize=(12, 9))
    for axis, row in zip(axes.flat, selected):
        with Image.open(DATASET_DIR / row["image"]) as image:
            axis.imshow(image)
        axis.set_title(row["latex"][:65], fontsize=9)
    for axis in axes.flat:
        axis.axis("off")
    plt.tight_layout()
    plt.show()
    ''', "preview"),
    md('''
    ## Сохранение для второго ноутбука

    Один ZIP переносится между сессиями быстрее, чем тысячи мелких файлов на Drive.
    Исходные картинки и разметка не загружаются на Hugging Face автоматически.
    '''),
    code('''
    from training.data import zip_dataset

    DATASET_ZIP = PERSIST_DIR / "axiora-ocr-dataset.zip"
    checksum = zip_dataset(DATASET_DIR, DATASET_ZIP)
    DATASET_ZIP.with_suffix(".zip.sha256").write_text(checksum + "\\n")
    print("Готово:", DATASET_ZIP)
    print("SHA-256:", checksum)
    if not USE_GOOGLE_DRIVE:
        from google.colab import files
        files.download(str(DATASET_ZIP))
        files.download(str(DATASET_ZIP.with_suffix(".zip.sha256")))
    ''', "export-data"),
    md('''
    Далее откройте `02_train_ocr_colab.ipynb`, выберите **Среда выполнения → Сменить среду выполнения → T4 GPU**.
    С Drive набор подхватится по стандартному пути. Для excerpt во втором ноутбуке нужен `RUN_MODE = "smoke"`.
    '''),
]

train = [
    md('''
    # Аксиора: обучение OCR на одной T4 и экспорт на Hugging Face Hub

    **Этап 2, ноутбук 2 из 2.** Сначала выполните подготовку данных в первом ноутбуке.
    Выберите **Среда выполнения → Сменить среду выполнения → T4 GPU**. Бесплатная T4 имеет около 15 ГБ VRAM;
    базовые настройки: TrOCR-small, batch 2, накопление 8, FP16, три эпохи. Доступность GPU и длительность сессии зависят от Colab.

    Используйте тот Google-аккаунт и Drive, где подготовлены данные и доступна ваша подписка Google AI Pro.
    Аккаунт Hugging Face может быть другим; подписка не является обязательной для выбранной архитектуры.

    Перед запуском добавьте в раздел **Секреты** Colab ключ `HF_TOKEN` с правом записи в ваш репозиторий моделей
    и разрешите этому ноутбуку доступ. Создать ключ можно в https://huggingface.co/settings/tokens.
    Значение ключа нигде не печатается и не записывается в ноутбук. По умолчанию создаётся **приватный** репозиторий.
    Конечная ячейка сама вызывает `push_to_hub` и выгружает веса, процессор и отчёты. Датасет и optimizer-checkpoints не загружаются.

    Для проверки всей цепочки используйте `RUN_MODE = "smoke"`: два optimizer шага и отдельный репозиторий `axiora-ocr-smoke`.
    Такой запуск не создаёт пригодную для учеников модель. Реальное качество нужно оценивать после полного обучения.
    '''),
    code(BOOTSTRAP, "setup", "network"),
    code('''
    USE_GOOGLE_DRIVE = True
    RUN_MODE = "t4"  # "smoke" для excerpt и двух проверочных шагов.
    RUN_NAME = "trocr-small-v2"  # Новые данные/гиперпараметры требуют нового имени.
    RESUME = True
    HUB_REPO_ID = None  # None → <ваш-логин>/axiora-ocr, для smoke добавляется -smoke.
    HUB_PRIVATE = True
    PUSH_TO_HUB = True
    BENCHMARK_INT8 = True
    DATASET_DIR = Path("/content/axiora-ocr-data")
    ''', "config"),
    code(DRIVE, "colab"),
    code('''
    import torch
    from packaging.version import Version
    from training.ocr import TrainConfig, environment_report
    from transformers import set_seed

    if Version(torch.__version__.split("+")[0]) < Version("2.6.0"):
        raise RuntimeError("Нужен PyTorch >= 2.6 для безопасной загрузки исходных весов. Выберите актуальную среду Colab.")
    if not torch.cuda.is_available():
        raise RuntimeError("GPU не подключён. Выберите T4 GPU в настройках среды выполнения.")
    if torch.cuda.device_count() != 1:
        raise RuntimeError("Этот ноутбук настроен на одну GPU. Выберите среду с одной T4.")
    config = TrainConfig(mode=RUN_MODE, **({"train_batch_size": 1, "gradient_accumulation_steps": 1, "eval_samples": 2} if RUN_MODE == "smoke" else {}))
    set_seed(config.seed)
    print(environment_report())
    print("VRAM, ГБ:", round(torch.cuda.get_device_properties(0).total_memory / 2**30, 2))
    print("Эффективный batch:", config.train_batch_size * config.gradient_accumulation_steps)
    ''', "requires-gpu"),
    md('''
    ## Восстановление данных

    При использовании Drive путь совпадает с результатом первого ноутбука. Если вы скачивали ZIP на компьютер,
    отключите Drive выше и загрузите ZIP в появившемся диалоге. SHA-256 рядом с архивом проверяется при наличии.
    '''),
    code('''
    from training.data import unpack_dataset, audit_dataset, sha256_file
    DATASET_ZIP = PERSIST_DIR / "axiora-ocr-dataset.zip"
    if not DATASET_DIR.exists():
        if not DATASET_ZIP.exists() and not USE_GOOGLE_DRIVE:
            from google.colab import files
            uploaded = files.upload()
            if "axiora-ocr-dataset.zip" not in uploaded:
                raise RuntimeError("Загрузите axiora-ocr-dataset.zip из первого ноутбука.")
            DATASET_ZIP.write_bytes(uploaded["axiora-ocr-dataset.zip"])
            del uploaded
        if not DATASET_ZIP.exists():
            raise FileNotFoundError("Архив не найден: сначала выполните первый ноутбук или исправьте DATASET_ZIP.")
        checksum_file = DATASET_ZIP.with_suffix(".zip.sha256")
        if checksum_file.exists() and sha256_file(DATASET_ZIP) != checksum_file.read_text().strip():
            raise RuntimeError("SHA-256 архива не совпадает. Восстановите целый архив из первого ноутбука.")
        unpack_dataset(DATASET_ZIP, DATASET_DIR)
    dataset_audit = audit_dataset(DATASET_DIR)
    if RUN_MODE == "t4" and dataset_audit["report"]["variant"] == "excerpt":
        raise RuntimeError("Для реального обучения подготовьте full; для excerpt выберите RUN_MODE='smoke'.")
    print("Выборки:", dataset_audit["counts"])
    print("Отпечаток данных:", dataset_audit["fingerprint"])
    ''', "data"),
    md('''
    ## Модель и аудит разметки

    Используется закреплённая версия `microsoft/trocr-small-handwritten` (около 61 млн параметров).
    Исходная модель читает обычный почерк; математические формулы она изучит при дообучении.
    Словарь поддерживает стандартные LaTeX-команды. Неподдерживаемые или слишком длинные подписи явно
    исключаются и учитываются в отчёте: тихого обрезания правильного ответа нет.
    '''),
    code('''
    from dataclasses import asdict
    from training.ocr import load_base_model, filter_labels, FormulaDataset, make_trainer, ensure_run_context, training_code_fingerprint
    from training.data import load_manifest
    import random

    model, processor = load_base_model(config)
    records, label_audit = {}, {}
    for split in ("train", "validation", "test"):
        records[split], label_audit[split] = filter_labels(load_manifest(DATASET_DIR, split), processor.tokenizer, config.max_target_length)
    print("Исключения по длине/словарю:", label_audit)
    print("Осталось:", {key: len(value) for key, value in records.items()})
    print("Параметров:", sum(parameter.numel() for parameter in model.parameters()))
    validation_rows = random.Random(config.seed).sample(records["validation"], min(config.eval_samples, len(records["validation"])))
    datasets = {
        "train": FormulaDataset(DATASET_DIR, records["train"], processor, augment=True),
        "validation": FormulaDataset(DATASET_DIR, validation_rows, processor),
    }
    RUN_DIR = PERSIST_DIR / "runs" / RUN_MODE / RUN_NAME
    context = {"dataset_fingerprint": dataset_audit["fingerprint"], "training_code_fingerprint": training_code_fingerprint(), "config": asdict(config)}
    ensure_run_context(RUN_DIR, context, RESUME)
    trainer = make_trainer(model, processor, datasets, config, RUN_DIR, fp16=True)
    ''', "model", "network"),
    md('''
    ## Обучение и возобновление

    Контрольные точки содержат модель, optimizer, scheduler и состояние случайных чисел. Сохраняются до двух
    точек, включая лучшую. При обрыве запустите ноутбук заново с теми же данными, настройками и `RUN_NAME`.
    Выбор лучшей точки использует только validation и CER. Test пока не используется для выбора модели.

    Если возникнет CUDA out of memory, задайте в ячейке создания `TrainConfig` batch 1 и накопление 16,
    выберите новый `RUN_NAME` и повторите запуск. Не меняйте настройки внутри существующего run.
    '''),
    code('''
    from transformers.trainer_utils import get_last_checkpoint
    checkpoint = get_last_checkpoint(str(RUN_DIR)) if RESUME else None
    print("Продолжение:", checkpoint or "новое обучение")
    torch.cuda.reset_peak_memory_stats()
    train_result = trainer.train(resume_from_checkpoint=checkpoint)
    trainer.save_state()
    peak_vram_gib = torch.cuda.max_memory_allocated() / 2**30
    print("Пиковое выделение VRAM, ГБ:", round(peak_vram_gib, 2))
    ''', "training", "requires-gpu"),
    md('''
    ## Финальная оценка и сохранение

    После выбора контрольной точки оцениваем отложенный test. CER измеряет ошибки символов, exact match —
    совпадение записи; эти метрики не означают правильность математического решения. Отдельная метрика
    игнорирует только пробелы. Отчёт содержит число исключённых длинных/неподдерживаемых формул.
    '''),
    code('''
    from training.ocr import export_model
    from training.data import json_write
    test_dataset = FormulaDataset(DATASET_DIR, records["test"], processor)
    # Inspect held-out validation examples alongside aggregate scores.
    sample_rows = validation_rows[:12]
    preview = trainer.predict(FormulaDataset(DATASET_DIR, sample_rows, processor))
    import numpy as np
    token_ids = np.where(preview.predictions == -100, processor.tokenizer.pad_token_id, preview.predictions)
    texts = processor.batch_decode(token_ids, skip_special_tokens=True)
    validation_examples = [{"id": row["id"], "expected": row["latex"], "predicted": text}
                           for row, text in zip(sample_rows, texts)]
    for example in validation_examples:
        print(example["expected"], "→", example["predicted"])
    test_metrics = trainer.evaluate(test_dataset, metric_key_prefix="test")
    run_report = {
        "schema_version": 1, "config": asdict(config), "source_commit": SOURCE_COMMIT,
        "training_code_fingerprint": training_code_fingerprint(),
        "dataset": dataset_audit, "label_audit": label_audit,
        "retained_counts": {split: len(rows) for split, rows in records.items()},
        "validation_selection_count": len(validation_rows), "validation_examples": validation_examples,
        "train_metrics": train_result.metrics, "test_metrics": test_metrics,
        "best_checkpoint": Path(trainer.state.best_model_checkpoint).name if trainer.state.best_model_checkpoint else None,
        "environment": environment_report(), "peak_vram_gib": peak_vram_gib,
        "intended_input": "one cropped handwritten formula; not a full page or proof",
    }
    EXPORT_DIR = export_model(trainer.model, processor, RUN_DIR / "export", run_report)
    print("Сохранено:", EXPORT_DIR)
    print(test_metrics)
    ''', "evaluate", "export-model"),
    md('''
    ## CPU: скорость и необязательный INT8

    Отдельный процесс загружает экспорт на CPU, ограничивает PyTorch двумя потоками и измеряет 12 формул
    из validation после прогрева. Также сравниваются FP32 и динамический INT8, включая CER и совпадение предсказаний.
    Медиана и p95 не включают сеть и холодный запуск Space. Даже результат быстрее двух секунд нужно
    перепроверить на настоящем CPU Basic: два потока в Colab не равны аппаратной квоте Space.
    INT8 не выбирается автоматически: при ухудшении CER или совпадения предсказаний отчёт помечает регрессию качества.
    Если необязательное измерение не завершилось, веса сохранятся, а ошибка будет явно записана в отчёт.
    '''),
    code('''
    import os
    command = [sys.executable, "-m", "training.benchmark", "--model-dir", str(EXPORT_DIR),
               "--dataset-dir", str(DATASET_DIR), "--output", str(EXPORT_DIR / "cpu_benchmark.json"),
               "--samples", "12", "--max-length", str(config.max_target_length)]
    if BENCHMARK_INT8:
        command.append("--int8")
    cpu_env = {**os.environ, "CUDA_VISIBLE_DEVICES": "", "OMP_NUM_THREADS": "2", "MKL_NUM_THREADS": "2"}
    benchmark = subprocess.run(command, cwd=REPO_DIR, env=cpu_env, text=True, capture_output=True)
    if benchmark.returncode:
        error = benchmark.stderr[-3000:]
        json_write(EXPORT_DIR / "cpu_benchmark_error.json", {"status": "failed", "error": error})
        print("CPU-проверка не завершилась; перенос на Space пока не подтверждён. Веса сохранены.")
        print(error)
    else:
        print(benchmark.stdout)
    ''', "benchmark"),
    md('''
    ## Автоматическая выгрузка на Hugging Face Hub

    Последняя ячейка загружает веса через `push_to_hub`, затем согласованный процессор, карточку и отчёты.
    По умолчанию репозиторий приватный. Для чтения приватных весов будущему Space потребуется `HF_TOKEN`
    в его Secrets. Если авторизация или сеть прервались, поправьте доступ и повторите эту ячейку: заново обучать не нужно.
    Не запускайте `smoke` с именем настоящей модели: для проверочных весов требуется суффикс `-smoke`.
    '''),
    code('''
    from training.ocr import publish_to_hub
    import json
    upload_dir = PERSIST_DIR / "runs" / RUN_MODE / RUN_NAME / "export"

    if PUSH_TO_HUB:
        from transformers import TrOCRProcessor, VisionEncoderDecoderModel
        from google.colab import userdata
        if not (upload_dir / "training_report.json").exists():
            raise FileNotFoundError("Готовый экспорт не найден. Сначала завершите обучение и сохранение модели.")
        upload_report = json.loads((upload_dir / "training_report.json").read_text())
        upload_processor = TrOCRProcessor.from_pretrained(upload_dir, local_files_only=True, use_fast=False)
        upload_model = VisionEncoderDecoderModel.from_pretrained(upload_dir, local_files_only=True, use_safetensors=True)
        try:
            hf_token = userdata.get("HF_TOKEN")
        except Exception:
            raise RuntimeError("Добавьте HF_TOKEN в Секреты Colab и разрешите доступ этому ноутбуку. Веса уже сохранены на Drive.") from None
        try:
            uploaded_model = publish_to_hub(upload_model, upload_processor, upload_dir, upload_report,
                                            token=hf_token, repo_id=HUB_REPO_ID, private=HUB_PRIVATE)
        finally:
            del hf_token
        from training.data import json_write
        json_write(upload_dir.parent / "hub_upload.json", uploaded_model)
        print("Модель:", uploaded_model["url"])
        print("Версия для будущего Space:", uploaded_model["revision"])
        del upload_model, upload_processor
    else:
        print("Выгрузка не выполнялась; каталог экспорта:", upload_dir)
    ''', "push-to-hub", "colab", "network"),
    md('''
    Подготовка Этапа 2 завершена. Реальные веса и оценка качества появятся после вашего полного запуска в Colab.
    Следующий этап разработки — FastAPI,
    который загрузит указанную версию с Hub, применит тот же preprocessing и объединит OCR с SymPy и LLM-проверкой.
    '''),
]


def single_run_cells():
    """One Colab Run all: reuse the tested trainer, prepare data only if absent."""
    cells = json.loads(json.dumps(train))
    cells[0] = md('''
    # Аксиора: полный запуск OCR одной командой

    Выберите аккаунт с нужным Drive, **T4 GPU** и нажмите **Среда выполнения → Выполнить все**.
    Когда Colab запросит доступ к Drive, подтвердите его. Для автоматической выгрузки на Hub
    добавьте `HF_TOKEN` в Секреты Colab и разрешите ноутбуку доступ.
    Ноутбук сам подготовит данные при отсутствии ZIP, обучит модель и сохранит контрольные точки.
    При доступном `HF_TOKEN` веса автоматически отправятся на Hub; без ключа обучение завершится с экспортом на Drive.
    Готовый ZIP используется повторно, а совместимое обучение продолжается с последней контрольной точки.

    Чат ChatGPT после старта можно закрыть: вычисления выполняются в Colab. Саму вкладку Colab лучше оставить
    открытой. Непрерывное выполнение после её закрытия зависит от тарифа и условий Colab; Google AI Pro
    не следует считать гарантией фонового выполнения. При обрыве можно восстановиться с Drive.

    Основной профиль: полный MathWriting, 12 000 train, 1000 validation, 500 test, одна T4, FP16, три эпохи.
    Подготовка полного архива требует загрузки около 2,9 ГБ. MathWriting имеет некоммерческую лицензию CC BY-NC-SA 4.0.
    Для быстрой проверки выберите `RUN_MODE = "smoke"` и `DATASET_VARIANT = "excerpt"`; эти веса не пригодны для учеников.
    ''')
    result = []
    for item in cells:
        tags = item["metadata"].get("tags", [])
        source = "".join(item["source"])
        if "config" in tags:
            item = code(source + '''

DATASET_VARIANT = "full"
PREPARE_LIMITS = {"train": 12000, "validation": 1000, "test": 500}
SYNTHETIC_COUNT = 300
DATASET_DIR = Path("/content") / ("axiora-ocr-data-" + DATASET_VARIANT)
''', "config")
        elif item["cell_type"] == "markdown" and source.startswith("## Восстановление данных"):
            item = md('''
            ## Данные: восстановление или автоматическая подготовка

            Если ZIP на Drive уже есть, восстанавливаем его. Иначе загружаем MathWriting, формируем выборки
            и сохраняем ZIP для последующих сессий. Отдельно открывать первый ноутбук не требуется.
            ''')
        elif "data" in tags:
            item = code('''
            from training.data import (download_mathwriting, prepare_dataset, zip_dataset,
                                       unpack_dataset, audit_dataset, sha256_file)
            import time

            DATASET_ZIP = PERSIST_DIR / ("axiora-ocr-dataset-" + DATASET_VARIANT + ".zip")
            original_zip = PERSIST_DIR / "axiora-ocr-dataset.zip"
            if not DATASET_ZIP.exists() and original_zip.exists():
                import zipfile
                import json
                with zipfile.ZipFile(original_zip) as existing_archive:
                    original_variant = json.loads(existing_archive.read("dataset_report.json"))["variant"]
                if original_variant == DATASET_VARIANT or original_variant == "custom":
                    DATASET_ZIP = original_zip
            if not DATASET_DIR.exists():
                if DATASET_ZIP.exists():
                    checksum_file = DATASET_ZIP.with_suffix(".zip.sha256")
                    if checksum_file.exists() and sha256_file(DATASET_ZIP) != checksum_file.read_text().strip():
                        raise RuntimeError("SHA-256 архива не совпадает. Восстановите целый архив перед продолжением.")
                    unpack_dataset(DATASET_ZIP, DATASET_DIR)
                else:
                    print("Готового набора нет. Автоматически подготавливаем MathWriting:", DATASET_VARIANT)
                    last_message = [0.0]
                    def progress(written, total):
                        if time.monotonic() - last_message[0] > 5:
                            print(f"Загружено {written / 2**20:.0f} МБ" + (f" из {total / 2**20:.0f}" if total else ""))
                            last_message[0] = time.monotonic()
                    archive_path = download_mathwriting(DATASET_VARIANT, Path("/content") / f"mathwriting-{DATASET_VARIANT}.tgz", progress)
                    prepare_dataset(archive_path, DATASET_DIR, PREPARE_LIMITS,
                                    variant=DATASET_VARIANT, synthetic_count=SYNTHETIC_COUNT, seed=config.seed)
            dataset_audit = audit_dataset(DATASET_DIR)
            if RUN_MODE == "t4" and dataset_audit["report"]["variant"] == "excerpt":
                raise RuntimeError("Найден excerpt: выберите smoke либо подготовьте full в новом DATASET_DIR и DATASET_ZIP.")
            if not DATASET_ZIP.exists():
                checksum = zip_dataset(DATASET_DIR, DATASET_ZIP)
                DATASET_ZIP.with_suffix(".zip.sha256").write_text(checksum + "\\n")
            print("Выборки:", dataset_audit["counts"])
            print("Отпечаток данных:", dataset_audit["fingerprint"])
            ''', "data", "auto-prepare")
        result.append(item)
        if tags == ["requires-gpu"]:
            result.append(md('''
            ## Проверка доступа к Hub до долгого обучения

            Проверяем наличие `HF_TOKEN` и авторизацию заранее. Сам ключ не печатается и не сохраняется.
            Для выгрузки создайте токен с правом записи. При отсутствии ключа или ошибке авторизации обучение
            продолжается с экспортом на Drive, а выгрузка откладывается до настройки доступа.
            '''))
            result.append(code('''
            if PUSH_TO_HUB:
                from google.colab import userdata
                from huggingface_hub import HfApi
                def check_hub_access():
                    try:
                        token = userdata.get("HF_TOKEN")
                    except Exception:
                        return None
                    if not token:
                        return None
                    try:
                        return HfApi(token=token).whoami()["name"]
                    except Exception:
                        return None
                hub_owner = check_hub_access()
                if hub_owner:
                    print("Аккаунт Hub:", hub_owner)
                else:
                    PUSH_TO_HUB = False
                    print("Доступ к Hub пока не подтверждён. Обучение продолжится; веса сохранятся на Drive.")
                    print("Для последующей выгрузки добавьте HF_TOKEN, включите PUSH_TO_HUB и выполните последнюю ячейку.")
            else:
                print("Выгрузка отключена: готовые веса сохранятся на Drive.")
            ''', "hub-preflight", "colab", "network"))
    return result


def build():
    notebooks = ROOT / "notebooks"
    notebooks.mkdir(exist_ok=True)
    for filename, cells in [("00_run_ocr_end_to_end.ipynb", single_run_cells()), ("01_prepare_ocr_dataset.ipynb", prepare), ("02_train_ocr_colab.ipynb", train)]:
        metadata = {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"},
                    "language_info": {"name": "python", "version": "3.12"},
                    "colab": {"name": filename, "provenance": []}}
        if not filename.startswith("01"):
            metadata["accelerator"] = "GPU"
            metadata["colab"]["gpuType"] = "T4"
        notebook = {"cells": cells, "metadata": metadata, "nbformat": 4, "nbformat_minor": 5}
        (notebooks / filename).write_text(json.dumps(notebook, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    build()
