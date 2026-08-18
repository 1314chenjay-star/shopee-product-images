#!/usr/bin/env python3
from __future__ import annotations
import argparse, datetime as dt, json, os, pathlib, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
VALID = {"RUNNING","SUCCESS","FAILED","BLOCKED_CAPABILITY","BLOCKED_EVIDENCE","BLOCKED_OWNER_DECISION","WAITING_EXTERNAL","RECOVERING","PENDING","STALLED_WORKER"}

def read_json(p):
    return json.loads((ROOT/p).read_text(encoding="utf-8-sig"))

def read_json_optional(p, default=None):
    q=ROOT/p
    return json.loads(q.read_text(encoding="utf-8-sig")) if q.exists() else default

def read_queue():
    rows=[]
    for line in (ROOT/"_system/agent_queue/queue.jsonl").read_text(encoding="utf-8-sig").splitlines():
        if line.strip(): rows.append(json.loads(line))
    return rows

def parse_utc(value):
    if not value: return None
    try: return dt.datetime.fromisoformat(str(value).replace("Z","+00:00"))
    except ValueError: return None

def github_active(repo, token, current_run):
    if not repo or not token: return {"checked":False,"active":[],"error":"GITHUB_CONTEXT_UNAVAILABLE"}
    try:
        req=urllib.request.Request(
            f"https://api.github.com/repos/{repo}/actions/runs?branch=v4c-universal-product-engine&per_page=50",
            headers={"Authorization":f"Bearer {token}","Accept":"application/vnd.github+json","User-Agent":"TinySnow-Watchdog"})
        with urllib.request.urlopen(req, timeout=20) as r: data=json.load(r)
        active=[]
        for x in data.get("workflow_runs",[]):
            if str(x.get("id"))==str(current_run): continue
            if x.get("status") in {"queued","in_progress","waiting","requested","pending"}:
                active.append({"id":x.get("id"),"name":x.get("name"),"status":x.get("status"),"head_sha":x.get("head_sha")})
        return {"checked":True,"active":active,"error":None}
    except Exception as e:
        return {"checked":False,"active":[],"error":type(e).__name__}

def timeout_guard(checkpoint, active):
    policy=read_json_optional("_system/control/timeout_policy.json",{}) or {}
    live=read_json_optional("_system/control/live_status.json",{}) or {}
    worker=read_json_optional("_system/control/worker_state.json",{}) or {}
    limit=int(policy.get("same_checkpoint_timeout_minutes",30))
    now=dt.datetime.now(dt.timezone.utc)
    last=parse_utc(live.get("last_update"))
    elapsed=((now-last).total_seconds()/60.0) if last else None
    same_checkpoint=bool(live.get("checkpoint")) and live.get("checkpoint")==checkpoint.get("checkpoint")
    explicit_stalled=worker.get("status")=="STALLED_WORKER" or live.get("worker_state")=="STALLED_WORKER"
    timed_out=bool(same_checkpoint and elapsed is not None and elapsed>=limit and active.get("checked") and not active.get("active"))
    stalled=explicit_stalled or timed_out
    return {
        "stalled":stalled,"explicit_stalled":explicit_stalled,"timed_out":timed_out,
        "same_checkpoint":same_checkpoint,"same_checkpoint_timeout_minutes":limit,
        "minutes_since_live_update":round(elapsed,2) if elapsed is not None else None,
        "original_task_retry_allowed":False if stalled else None,
        "recovery_action":policy.get("recovery_action") if stalled else None
    }

def write_stall_diagnostic(checkpoint, guard, active):
    path=ROOT/"_system/control/stalled_execution_report.json"
    current=read_json_optional("_system/control/stalled_execution_report.json",{}) or {}
    current.update({
        "schema_version":"tinysnow.stalled-execution-report.1",
        "status":"STALLED_WORKER",
        "stage":checkpoint.get("stage"),
        "checkpoint":checkpoint.get("checkpoint"),
        "watchdog_detected_at_utc":dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00","Z"),
        "watchdog_timeout_guard":guard,
        "watchdog_active_workflows":active,
        "resume_point":"CAPABILITY_RECOVERY_BOOTSTRAP:first_pending_delta_only",
        "recommended_action":"STOP_WAITING; preserve checkpoint; suppress original-attempt retry; replacement worker may fingerprint and resume first pending delta only.",
        "sealed_data_modified":False,
        "original_task_retried":False
    })
    path.write_text(json.dumps(current,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--dry-run",action="store_true"); args=ap.parse_args()
    cap=read_json("_system/control/capability_state.json")
    plan=read_json("_system/control/recovery_plan.json")
    checkpoint=read_json("_system/control/execution_checkpoint.json")
    queue=read_queue()
    bad=[r for r in queue if r.get("status") not in VALID]
    if bad: raise SystemExit("INVALID_QUEUE_STATUS")
    pending=[r for r in queue if r.get("status") in {"PENDING","RECOVERING","FAILED","BLOCKED_CAPABILITY","WAITING_EXTERNAL","STALLED_WORKER"}]
    task=sorted(pending,key=lambda r:(int(r.get("priority",999)),r.get("task_id","")))[0] if pending else None
    active=github_active(os.getenv("GITHUB_REPOSITORY"),os.getenv("GITHUB_TOKEN"),os.getenv("GITHUB_RUN_ID"))
    guard=timeout_guard(checkpoint,active)
    decision="IDLE_SUCCESS"; reason="no pending action"; missing=[]
    required=[]
    if task:
        required=next((x.get("required_capabilities",[]) for x in plan.get("pending_actions",[]) if x.get("action_id") in task.get("task_id","") or x.get("action_id")=="C5_3_SOURCE_TRUTH_REPAIR"),[])
        missing=[k for k in required if cap.get("capabilities",{}).get(k) is not True]
    if guard.get("stalled"):
        write_stall_diagnostic(checkpoint,guard,active)
        if not task:
            decision="STALLED_WORKER"; reason="stalled marker active but no pending replacement task"
        elif task.get("owner_decision_required") or task.get("paid") or task.get("generation"):
            decision="NEEDS_OWNER_DECISION"; reason="replacement task crosses owner/paid/generation boundary"
        elif missing:
            decision="NEEDS_CAPABILITY"; reason="replacement task required capability unavailable"
        elif active.get("active"):
            decision="WAIT_ACTIVE"; reason="another workflow is active; preserve stalled checkpoint"
        else:
            decision="AUTO_RECOVER"; reason="original worker stalled; suppress original retry and dispatch replacement workflow from preserved checkpoint"
    elif task:
        if task.get("owner_decision_required") or task.get("paid") or task.get("generation"):
            decision="NEEDS_OWNER_DECISION"; reason="task crosses owner/paid/generation boundary"
        elif missing:
            decision="NEEDS_CAPABILITY"; reason="required capability unavailable"
        elif active.get("active"):
            decision="WAIT_ACTIVE"; reason="another workflow is active"
        else:
            decision="AUTO_RECOVER"; reason="safe pending zero-paid action with no other active workflow"
    report={
      "schema_version":"tinysnow.recovery-report.3","stage":checkpoint.get("stage"),"checkpoint":checkpoint.get("checkpoint"),
      "pending_task":task,"active_workflows":active,"decision":decision,"reason":reason,"missing_capabilities":missing,
      "timeout_guard":guard,"dry_run":args.dry_run,"paid_api_called":False,"image_generation_called":False,"stable_mutation":False,
      "sealed_stage_rerun":False,"original_task_retried":False,"replacement_worker_allowed":bool(guard.get("stalled") and decision=="AUTO_RECOVER")
    }
    out=ROOT/"_system/agent_queue/recovery_report.json"; out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,ensure_ascii=False,sort_keys=True))
    if decision in {"NEEDS_CAPABILITY","NEEDS_OWNER_DECISION"}: return 2
    return 0

if __name__=="__main__": raise SystemExit(main())
