#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, os, pathlib, subprocess
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
TOPOLOGY = ROOT / "_system/control/topology.json"
ROLE_POLICY = ROOT / "_system/control/role_policy.json"
CHECKPOINT = ROOT / "_system/control/execution_checkpoint.json"
QUEUE = ROOT / "_system/agent_queue/queue.jsonl"
INBOX = ROOT / "_system/agent_queue/inbox/pending_commands.jsonl"
COMPLETED_DIR = ROOT / "_system/agent_queue/completed"
PROCESSING_DIR = ROOT / "_system/agent_queue/processing"

def read_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))

def read_jsonl(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    return [json.loads(x) for x in path.read_text(encoding="utf-8-sig").splitlines() if x.strip()]

def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()

def fail(code: str, detail: Any = None) -> None:
    payload = {"control_plane_preflight": "FAIL", "code": code}
    if detail is not None:
        payload["detail"] = detail
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    raise SystemExit(2)

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--role", required=True, choices=["ORCHESTRATOR","WORKER","MONITOR","SUPERVISOR"])
    ap.add_argument("--write-intent", default="read")
    args = ap.parse_args()

    topology = read_json(TOPOLOGY)
    roles = read_json(ROLE_POLICY)["roles"]
    if args.role not in roles:
        fail("UNKNOWN_ROLE", args.role)

    canonical_repo = topology["repository_full_name"]
    target_branch = topology["experimental_branch"]
    repo_env = os.getenv("GITHUB_REPOSITORY")
    if repo_env and repo_env != canonical_repo:
        fail("REPOSITORY_IDENTITY_MISMATCH", {"actual": repo_env, "expected": canonical_repo})

    explicit_target = os.getenv("TINYSNOW_TARGET_BRANCH", target_branch)
    if explicit_target != target_branch:
        fail("BRANCH_IDENTITY_MISMATCH", {"actual": explicit_target, "expected": target_branch})

    remote_branch = git("ls-remote", "origin", f"refs/heads/{target_branch}")
    if not remote_branch:
        fail("CANONICAL_BRANCH_NOT_FOUND_INSIDE_CANONICAL_REPOSITORY", target_branch)

    stable_actual = git("ls-remote", "origin", f"refs/heads/{topology['stable_branch']}").split()[0]
    if stable_actual != topology["stable_head_locked"]:
        fail("STABLE_HEAD_MISMATCH", {"actual": stable_actual, "expected": topology["stable_head_locked"]})

    if args.role == "MONITOR" and args.write_intent != "read":
        fail("MONITOR_WRITE_FORBIDDEN", args.write_intent)
    if args.role == "ORCHESTRATOR" and args.write_intent not in {"read","command","decision","dispatch_metadata"}:
        fail("ORCHESTRATOR_IMPLEMENTATION_FORBIDDEN", args.write_intent)
    if args.role == "SUPERVISOR" and args.write_intent not in {"read","dispatch_recovery"}:
        fail("SUPERVISOR_SCOPE_FORBIDDEN", args.write_intent)

    cp = read_json(CHECKPOINT)
    completed = list(cp.get("completed", []))
    pending = list(cp.get("pending", []))
    if len(completed) != len(set(completed)) or len(pending) != len(set(pending)):
        fail("CHECKPOINT_DUPLICATE_ENTRIES")
    overlap = sorted(set(completed) & set(pending))
    if overlap:
        fail("CHECKPOINT_COMPLETED_PENDING_OVERLAP", overlap)
    if not cp.get("checkpoint"):
        fail("CHECKPOINT_MISSING")

    queue = read_jsonl(QUEUE)
    active_status = {"PENDING","RECOVERING","PROCESSING","STALLED_WORKER"}
    active_tasks = [x for x in queue if x.get("status") in active_status]
    if len(active_tasks) > 1:
        fail("MULTIPLE_ACTIVE_QUEUE_TASKS", [x.get("task_id") for x in active_tasks])
    task = active_tasks[0] if active_tasks else None
    if task:
        if task.get("checkpoint") != cp.get("checkpoint"):
            fail("QUEUE_CHECKPOINT_MISMATCH", {"queue": task.get("checkpoint"), "checkpoint": cp.get("checkpoint")})
        if pending and task.get("next_action") != pending[0]:
            fail("QUEUE_NEXT_ACTION_MISMATCH", {"queue": task.get("next_action"), "first_pending": pending[0]})
        if task.get("paid") or task.get("generation") or task.get("owner_decision_required"):
            if args.role in {"WORKER","SUPERVISOR"} and args.write_intent != "read":
                fail("OWNER_BOUNDARY_AUTOMATION_FORBIDDEN", task.get("task_id"))

    tracked = git("ls-files").splitlines()
    bad_public = []
    for path in tracked:
        for frag in topology.get("forbidden_public_name_fragments", []):
            if frag.lower() in path.lower():
                bad_public.append(path)
                break
    if bad_public:
        fail("PRIVATE_CONTEXT_NAME_IN_PUBLIC_REPO", sorted(set(bad_public)))

    commands = [x for x in read_jsonl(INBOX) if x.get("status") == "PENDING"]
    if commands:
        current_head = git("rev-parse", "HEAD")
        required = ["command_id","issuer_role","repository_full_name","branch","task_id","expected_checkpoint","observed_head","idempotency_key"]
        seen_keys = set()
        completed_keys = set()
        if COMPLETED_DIR.exists():
            for p in COMPLETED_DIR.glob("*.json"):
                try:
                    row = read_json(p)
                    if row.get("idempotency_key"):
                        completed_keys.add(str(row["idempotency_key"]))
                except Exception:
                    pass
        processing = list(PROCESSING_DIR.glob("*.json")) if PROCESSING_DIR.exists() else []
        if len(processing) > 1:
            fail("MULTIPLE_PROCESSING_COMMANDS", [p.name for p in processing])

        for cmd in commands:
            missing = [k for k in required if not cmd.get(k)]
            if missing:
                fail("COMMAND_CONTROL_FIELDS_MISSING", {"command_id":cmd.get("command_id"),"missing":missing})
            if cmd["issuer_role"] != "ORCHESTRATOR":
                fail("COMMAND_ISSUER_ROLE_FORBIDDEN", cmd["issuer_role"])
            if cmd["repository_full_name"] != canonical_repo:
                fail("COMMAND_REPOSITORY_MISMATCH", cmd["repository_full_name"])
            if cmd["branch"] != target_branch:
                fail("COMMAND_BRANCH_MISMATCH", cmd["branch"])
            if task and cmd["task_id"] != task.get("task_id"):
                fail("COMMAND_TASK_MISMATCH", {"command":cmd["task_id"],"queue":task.get("task_id")})
            if cmd["expected_checkpoint"] != cp.get("checkpoint"):
                fail("STALE_COMMAND_CHECKPOINT", {"command":cmd["expected_checkpoint"],"current":cp.get("checkpoint")})
            if cmd["observed_head"] != current_head:
                fail("STALE_COMMAND_HEAD", {"command":cmd["observed_head"],"current":current_head})
            key = str(cmd["idempotency_key"])
            if key in seen_keys or key in completed_keys:
                fail("DUPLICATE_COMMAND_IDEMPOTENCY_KEY", key)
            seen_keys.add(key)

    result = {"control_plane_preflight":"PASS","role":args.role,"write_intent":args.write_intent,"repository_full_name":canonical_repo,"experimental_branch":target_branch,"stable_unchanged":True,"checkpoint":cp.get("checkpoint"),"first_pending":pending[0] if pending else None,"active_task":task.get("task_id") if task else None,"pending_commands":len(commands)}
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
