from __future__ import annotations

import json
from pathlib import Path

from artifact_manager import prepare_job_directory, write_json

REQUIRED = ("task_id", "product_id", "variant_id", "source_image", "generation_mode", "protected_regions")


def validate_task(task: dict) -> None:
    missing = [key for key in REQUIRED if key not in task]
    if missing:
        raise ValueError(f"TASK_REQUIRED_FIELD_MISSING:{','.join(missing)}")
    if task["generation_mode"] not in {"dry_run", "protected_generate"}:
        raise ValueError("UNSUPPORTED_GENERATION_MODE")


def run_task(task: dict, output_root: Path, *, allow_generation: bool = False) -> dict:
    validate_task(task)
    mode = task["generation_mode"]
    if mode != "dry_run" and not allow_generation:
        raise RuntimeError("GENERATION_NOT_AUTHORIZED")

    job_dir = prepare_job_directory(output_root, task)
    write_json(job_dir / "product_task.json", task)

    # MVP dry-run deliberately stops before any provider or image operation.
    result = {
        "task_id": task["task_id"],
        "status": "DRY_RUN_PASS" if mode == "dry_run" else "FAIL",
        "source_reference": task["source_image"],
        "generated_reference": None,
        "protected_reference": None,
        "protected_regions_restored": False,
        "qa_checks": {
            "task_valid": True,
            "protected_regions_loaded": isinstance(task["protected_regions"], list),
            "provider_invoked": False,
            "artifact_directory_deterministic": True
        },
        "execution_metadata": {
            "generation_mode": mode,
            "paid_api_called": False,
            "image_generation_called": False,
            "image_editing_called": False,
            "stable_mutation": False
        }
    }
    write_json(job_dir / "qa_result.json", result)
    return result


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("task")
    parser.add_argument("--output-root", default="tinysnow/mvp/artifacts")
    args = parser.parse_args()
    task = json.loads(Path(args.task).read_text(encoding="utf-8-sig"))
    print(json.dumps(run_task(task, Path(args.output_root)), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
