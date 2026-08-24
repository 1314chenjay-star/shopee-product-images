from __future__ import annotations

import json
import tempfile
from pathlib import Path

from artifact_manager import deterministic_job_id
from worker import run_task

ROOT = Path(__file__).resolve().parent


def load_json(name: str) -> dict:
    return json.loads((ROOT / name).read_text(encoding="utf-8-sig"))


def main() -> int:
    task_schema = load_json("product_task.schema.json")
    qa_schema = load_json("qa_result.schema.json")
    required_task = set(task_schema.get("required", []))
    required_qa = set(qa_schema.get("required", []))
    assert {"product_id", "variant_id", "source_image", "generation_mode", "protected_regions"} <= required_task
    assert {"source_reference", "generated_reference", "protected_reference", "qa_checks", "execution_metadata"} <= required_qa

    task = {
        "task_id": "MVP-ZERO-PAID-VALIDATION-001",
        "product_id": "VALIDATION_ONLY",
        "variant_id": "VALIDATION_ONLY",
        "source_image": "source://validation-only/no-image-read",
        "generation_mode": "dry_run",
        "protected_regions": [{"name": "validation_region", "x": 0.0, "y": 0.0, "width": 1.0, "height": 1.0, "source": "validation-only"}]
    }
    expected_job = deterministic_job_id(task)
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp)
        result = run_task(task, out)
        job_dir = out / expected_job
        assert job_dir.is_dir()
        assert (job_dir / "product_task.json").is_file()
        assert (job_dir / "qa_result.json").is_file()
        assert result["status"] == "DRY_RUN_PASS"
        meta = result["execution_metadata"]
        assert meta == {
            "generation_mode": "dry_run",
            "paid_api_called": False,
            "image_generation_called": False,
            "image_editing_called": False,
            "stable_mutation": False
        }
        assert result["qa_checks"]["provider_invoked"] is False

    print(json.dumps({
        "status": "PASS",
        "task_schema_machine_readable": True,
        "qa_schema_machine_readable": True,
        "worker_pipeline_has_dry_run_path": True,
        "artifact_manager_uses_deterministic_job_directory": True,
        "paid_api_called": False,
        "image_generation_called": False,
        "image_editing_called": False,
        "stable_mutation": False
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
