#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, os, pathlib, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
VALID = {"RUNNING","SUCCESS","FAILED","BLOCKED_CAPABILITY","BLOCKED_EVIDENCE","BLOCKED_OWNER_DECISION","WAITING_EXTERNAL","RECOVERING","PENDING"}

def read_json(p): return json.loads((ROOT/p).read_text(encoding="utf-8-sig"))
def read_queue():
    rows=[]
    for line in (ROOT/"_system/agent_queue/queue.jsonl").read_text(encoding="utf-8-sig").splitlines():
        if line.strip(): rows.append(json.loads(line))
    return rows

def github_active(repo, token, current_run):
    if not repo or not token: return {"checked":False,"active":[]}
    req=urllib.request.Request(f"https://api.github.com/repos/{repo}/actions/runs?branch=v4c-universal-product-engine&per_page=50",headers={"Authorization":f"Bearer {token}","Accept":"application/vnd.github+json","User-Agent":"TinySnow-Watchdog"})
    with urllib.request.urlopen(req, timeout=20) as r: data=json.load(r)
    active=[]
    for x in data.get("workflow_runs",[]):
        if str(x.get("id"))==str(current_run): continue
        if x.get("status") in {"queued","in_progress","waiting","requested","pending"}:
            active.append({"id":x.get("id"),"name":x.get("name"),"status":x.get("status"),"head_sha":x.get("head_sha")})
    return {"checked":True,"active":active}

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--dry-run",action="store_true"); args=ap.parse_args()
    cap=read_json("_system/control/capability_state.json")
    plan=read_json("_system/control/recovery_plan.json")
    checkpoint=read_json("_system/control/execution_checkpoint.json")
    queue=read_queue()
    bad=[r for r in queue if r.get("status") not in VALID]
    if bad: raise SystemExit("INVALID_QUEUE_STATUS")
    pending=[r for r in queue if r.get("status") in {"PENDING","RECOVERING","FAILED","BLOCKED_CAPABILITY","WAITING_EXTERNAL"}]
    task=sorted(pending,key=lambda r:(int(r.get("priority",999)),r.get("task_id","")))[0] if pending else None
    active=github_active(os.getenv("GITHUB_REPOSITORY"),os.getenv("GITHUB_TOKEN"),os.getenv("GITHUB_RUN_ID"))
    decision="IDLE_SUCCESS"; reason="no pending action"; missing=[]
    if task:
        required=next((x.get("required_capabilities",[]) for x in plan.get("pending_actions",[]) if x.get("action_id") in task.get("task_id","") or x.get("action_id")=="C5_3_SOURCE_TRUTH_REPAIR"),[])
        missing=[k for k in required if cap.get("capabilities",{}).get(k) is not True]
        if task.get("owner_decision_required") or task.get("paid") or task.get("generation"):
            decision="NEEDS_OWNER_DECISION"; reason="task crosses owner/paid/generation boundary"
        elif missing:
            decision="NEEDS_CAPABILITY"; reason="required capability unavailable"
        elif active.get("active"):
            decision="WAIT_ACTIVE"; reason="another workflow is active"
        else:
            decision="AUTO_RECOVER"; reason="safe pending zero-paid action with no other active workflow"
    report={
      "schema_version":"tinysnow.recovery-report.1","stage":checkpoint.get("stage"),"checkpoint":checkpoint.get("checkpoint"),
      "pending_task":task,"active_workflows":active,"decision":decision,"reason":reason,"missing_capabilities":missing,
      "dry_run":args.dry_run,"paid_api_called":False,"image_generation_called":False,"stable_mutation":False
    }
    out=ROOT/"_system/agent_queue/recovery_report.json"; out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,ensure_ascii=False,sort_keys=True))
    if decision in {"NEEDS_CAPABILITY","NEEDS_OWNER_DECISION"}: return 2
    return 0

if __name__=="__main__": raise SystemExit(main())
