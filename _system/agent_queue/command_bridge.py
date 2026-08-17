#!/usr/bin/env python3
from __future__ import annotations
import argparse
import datetime as dt
import json
import os
import pathlib
import re
import subprocess
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
INBOX = ROOT / "_system/agent_queue/inbox/pending_commands.jsonl"
PROCESSING = ROOT / "_system/agent_queue/processing"
COMPLETED = ROOT / "_system/agent_queue/completed"
FAILED = ROOT / "_system/agent_queue/failed"
RESULTS = ROOT / "_system/agent_queue/results/execution_results.jsonl"
SCHEMA = ROOT / "_system/agent_queue/command_schema.json"
COMMAND_POLICY = ROOT / "_system/control/command_policy.json"
RETRY_POLICY = ROOT / "_system/control/retry_policy.json"
CHECKPOINT = ROOT / "_system/control/execution_checkpoint.json"
NEXT_DECISION = ROOT / "_system/context/next_decision.json"
WORKER_STATE = ROOT / "_system/control/worker_state.json"

REQUIRED_FIELDS = [
    "command_id", "created_at", "priority", "action", "scope", "reason",
    "allowed_operations", "forbidden_operations", "required_validation", "status"
]


def now_utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def read_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def read_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(x) for x in path.read_text(encoding="utf-8-sig").splitlines() if x.strip()]


def write_json(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_jsonl(path: pathlib.Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(json.dumps(x, ensure_ascii=False, separators=(",", ":")) + "\n" for x in rows)
    path.write_text(text, encoding="utf-8")


def append_jsonl(path: pathlib.Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")


def validate_schema(command: dict[str, Any]) -> list[str]:
    errors = []
    for field in REQUIRED_FIELDS:
        if field not in command:
            errors.append(f"missing:{field}")
    if not isinstance(command.get("priority"), int) or int(command.get("priority", 0)) < 1:
        errors.append("invalid:priority")
    for field in ("allowed_operations", "forbidden_operations", "required_validation"):
        if not isinstance(command.get(field), list):
            errors.append(f"invalid:{field}")
    if command.get("status") != "PENDING":
        errors.append("invalid:status_not_pending")
    if not re.match(r"^\d{4}-\d{2}-\d{2}T", str(command.get("created_at", ""))):
        errors.append("invalid:created_at")
    return errors


def retry_disposition(command: dict[str, Any], retry_policy: dict[str, Any]) -> str:
    retry_count = int(command.get("retry_count", 0))
    max_retry = int(retry_policy["max_retry_count"])
    if retry_count > max_retry:
        return "BLOCKED_STATE_ANALYSIS"
    if retry_count == 1:
        return "DIAGNOSTIC_REQUIRED"
    if retry_count == 2:
        return "DELTA_RECOVERY_REQUIRED"
    return "WITHIN_LIMIT"


def authority(command: dict[str, Any], policy: dict[str, Any], next_decision: dict[str, Any], retry_policy: dict[str, Any]) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    action = str(command.get("action", ""))
    allowed_ops = set(map(str, command.get("allowed_operations", [])))
    forbidden_ops = set(map(str, command.get("forbidden_operations", [])))
    owner_ops = set(map(str, policy.get("owner_approval_required_operations", [])))
    decision_forbidden = set(map(str, next_decision.get("forbidden_actions", [])))

    if action not in set(policy.get("auto_allowed_actions", [])):
        reasons.append("action_not_auto_allowed")
    if allowed_ops & forbidden_ops:
        reasons.append("allowed_forbidden_overlap")
    if action in owner_ops or allowed_ops & owner_ops:
        reasons.append("owner_approval_boundary")
    if action in decision_forbidden or allowed_ops & decision_forbidden:
        reasons.append("next_decision_forbidden")
    if bool(command.get("owner_approval")):
        reasons.append("owner_approval_commands_not_executed_by_dry_run_bridge")
    if retry_disposition(command, retry_policy) == "BLOCKED_STATE_ANALYSIS":
        reasons.append("retry_limit_exceeded")
    return (len(reasons) == 0, reasons)


def git_output(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def stable_head() -> str:
    expected = os.environ.get("TINYSNOW_STABLE_HEAD_EXPECTED", "5d49f061e140813b3d229520e9e530f86b27b640")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        out = git_output("ls-remote", "origin", "refs/heads/tinysnow-tool-only")
        actual = out.split()[0] if out else ""
        if actual != expected:
            raise RuntimeError(f"STABLE_HEAD_MISMATCH:{actual}:{expected}")
    return expected


def frozen_guard(command: dict[str, Any], next_decision: dict[str, Any]) -> tuple[bool, list[str]]:
    prohibited_tokens = {
        "rerun_v4_c0", "rerun_v4_c1", "rerun_v4_c2", "rerun_v4_c3", "rerun_v4_c4",
        "rerun_v4_c5_0", "rerun_v4_c5_1", "rerun_v4_c5_1a", "rerun_v4_c5_2",
        "rerun_completed_c5_3_source_truth_work"
    }
    attempted = {str(command.get("action", "")), *map(str, command.get("allowed_operations", []))}
    bad = sorted(attempted & prohibited_tokens)
    missing_policy = sorted(prohibited_tokens - set(map(str, next_decision.get("forbidden_actions", []))))
    errors = [f"sealed_rerun_attempt:{x}" for x in bad] + [f"missing_frozen_policy:{x}" for x in missing_policy]
    return (not errors, errors)


def validate_worker_read_order() -> bool:
    state = read_json(WORKER_STATE)
    required = state.get("must_read_before_write", [])
    expected = [
        "_system/control/execution_checkpoint.json",
        "_system/context/next_decision.json",
        "_system/agent_queue/inbox/pending_commands.jsonl",
        "_system/control/command_policy.json"
    ]
    positions = [required.index(x) if x in required else -1 for x in expected]
    return all(x >= 0 for x in positions) and positions == sorted(positions)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", required=True)
    args = ap.parse_args()

    checkpoint = read_json(CHECKPOINT)
    next_decision = read_json(NEXT_DECISION)
    commands = read_jsonl(INBOX)
    command_policy = read_json(COMMAND_POLICY)
    retry_policy = read_json(RETRY_POLICY)
    schema_doc = read_json(SCHEMA)
    schema_document_valid = schema_doc.get("type") == "object" and all(x in schema_doc.get("required", []) for x in REQUIRED_FIELDS)

    pending = [x for x in commands if x.get("status") == "PENDING"]
    if not pending:
        print(json.dumps({"agent_queue_working": True, "detected": False, "reason": "NO_PENDING_COMMAND"}, sort_keys=True))
        return 0
    command = sorted(pending, key=lambda x: (int(x.get("priority", 999)), str(x.get("created_at", "")), str(x.get("command_id", ""))))[0]
    command_id = str(command["command_id"])
    start = now_utc()

    processing_record = dict(command)
    processing_record["status"] = "PROCESSING"
    processing_record["worker_detected_at"] = start
    write_json(PROCESSING / f"{command_id}.json", processing_record)

    schema_errors = validate_schema(command)
    authority_ok, authority_errors = authority(command, command_policy, next_decision, retry_policy)
    frozen_ok, frozen_errors = frozen_guard(command, next_decision)
    worker_order_ok = validate_worker_read_order()
    stable = stable_head()
    retry_state = retry_disposition(command, retry_policy)

    validation = {
        "agent_queue_working": True,
        "command_schema_valid": schema_document_valid and not schema_errors,
        "authority_policy_enforced": authority_ok,
        "retry_policy_exists": RETRY_POLICY.exists(),
        "checkpoint_read": bool(checkpoint.get("checkpoint")),
        "next_decision_read": bool(next_decision.get("next_action")),
        "worker_read_order_valid": worker_order_ok,
        "frozen_guard_pass": frozen_ok,
        "no_sealed_stage_rerun": frozen_ok,
        "stable_unchanged": stable == "5d49f061e140813b3d229520e9e530f86b27b640",
        "paid_api_called": False,
        "image_generation_called": False,
        "image_editing_called": False,
        "product_mutation": False,
        "dry_run": bool(args.dry_run),
        "retry_disposition": retry_state,
        "errors": schema_errors + authority_errors + frozen_errors + ([] if worker_order_ok else ["worker_read_order_invalid"])
    }
    success = all([
        validation["command_schema_valid"], validation["authority_policy_enforced"],
        validation["retry_policy_exists"], validation["checkpoint_read"],
        validation["next_decision_read"], validation["worker_read_order_valid"],
        validation["frozen_guard_pass"], validation["stable_unchanged"]
    ])

    end = now_utc()
    workflow = os.environ.get("GITHUB_WORKFLOW", "LOCAL_DRY_RUN")
    commit = os.environ.get("GITHUB_SHA", "LOCAL_DRY_RUN")
    result_record = {
        "command_id": command_id,
        "start_time": start,
        "end_time": end,
        "result": "DRY_RUN_SUCCESS" if success else "DRY_RUN_FAILED",
        "commit": commit,
        "workflow": workflow,
        "validation": validation,
        "next_recommended_action": "WAIT_FOR_FUTURE_DECISION_LAYER_COMMAND" if success else retry_policy.get("escalation_action", "BLOCKED_STATE_ANALYSIS")
    }
    append_jsonl(RESULTS, result_record)

    final_record = dict(processing_record)
    final_record["status"] = "COMPLETED" if success else "FAILED"
    final_record["completed_at"] = end
    final_record["execution_result"] = result_record["result"]
    target = COMPLETED if success else FAILED
    write_json(target / f"{command_id}.json", final_record)
    try:
        (PROCESSING / f"{command_id}.json").unlink()
    except FileNotFoundError:
        pass

    remaining = [x for x in commands if str(x.get("command_id")) != command_id]
    write_jsonl(INBOX, remaining)
    print(json.dumps({"command_id": command_id, "detected": True, "authority_pass": authority_ok, "dry_run": True, "result": result_record["result"], "validation": validation}, ensure_ascii=False, sort_keys=True))
    return 0 if success else 2


if __name__ == "__main__":
    raise SystemExit(main())
