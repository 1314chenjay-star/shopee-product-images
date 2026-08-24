from __future__ import annotations

import hashlib
import json
from pathlib import Path


def deterministic_job_id(task: dict) -> str:
    canonical = json.dumps(task, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:20]


def prepare_job_directory(root: Path, task: dict) -> Path:
    job_dir = root / deterministic_job_id(task)
    job_dir.mkdir(parents=True, exist_ok=True)
    return job_dir


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
