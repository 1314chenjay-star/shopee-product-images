#!/usr/bin/env python3
from __future__ import annotations
import datetime as dt, json, pathlib, sys

ROOT=pathlib.Path(__file__).resolve().parents[2]
REPORT=ROOT/"_system/v4c/source_truth_recovery/recovery_report.json"

def load(p):
    return json.loads((ROOT/p).read_text(encoding="utf-8-sig"))

def save(p,obj):
    q=ROOT/p
    q.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")

def main():
    if not REPORT.exists():
        raise SystemExit("RECOVERY_REPORT_MISSING")
    report=json.loads(REPORT.read_text(encoding="utf-8"))
    if report.get("status")!="PASS":
        raise SystemExit("RECOVERY_REPORT_NOT_PASS")
    counts=report.get("counts",{})
    if [counts.get("products"),counts.get("gallery_images"),counts.get("variant_options"),counts.get("gallery_exact_product_url_matches")] != [375,2394,2673,2394]:
        raise SystemExit("RECOVERY_RECONCILIATION_COUNTS_NOT_PASS")
    if report.get("paid_api_called") or report.get("image_generation_called") or report.get("tiny_snow_api_called") or report.get("stable_mutation") or report.get("sealed_stage_rerun"):
        raise SystemExit("FORBIDDEN_SIDE_EFFECT_FLAG")

    now=dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00","Z")
    new_checkpoint="C5_3_RECONCILED_375_2394_2673"

    cp=load("_system/control/execution_checkpoint.json")
    for item in [
        "agent queue/watchdog replacement dispatch validation",
        "authoritative workbook SHA validation",
        "source manifest extraction",
        "SourceTruth importer/bootstrap",
        "375/2394/2673 reconciliation",
    ]:
        if item not in cp.setdefault("completed",[]): cp["completed"].append(item)
    old_pending=cp.get("pending",[])
    remove={
        "agent queue/watchdog validation",
        "authoritative workbook SHA validation",
        "source manifest extraction",
        "SourceTruth importer/resolver/bootstrap",
        "375/2394/2673 reconciliation",
    }
    cp["pending"]=[x for x in old_pending if x not in remove]
    if "SourceTruth resolver" not in cp["pending"]:
        cp["pending"].insert(0,"SourceTruth resolver")
    cp["checkpoint"]=new_checkpoint
    cp["last_recovery_heartbeat_utc"]=now
    cp["resume_rule"]="Never repeat completed entries; fingerprint then continue first pending action."
    save("_system/control/execution_checkpoint.json",cp)

    live=load("_system/control/live_status.json")
    live.update({
      "status":"RECOVERY_READY",
      "stage":"V4-C5.3 Source Truth Repair",
      "checkpoint":new_checkpoint,
      "last_update":now,
      "worker_state":"RECOVERING",
      "next_action":"Build/validate SourceTruth resolver, then apply the 145 product / 549 slot overlay from authoritative variant bindings. No paid or image generation.",
      "original_task_retry_allowed":False,
      "sealed_data_modified":False
    })
    save("_system/control/live_status.json",live)

    worker=load("_system/control/worker_state.json")
    worker.update({
      "status":"RECOVERING",
      "stage":"V4-C5.3 Source Truth Repair",
      "last_heartbeat_utc":now,
      "last_durable_worker_signal_utc":now,
      "resume_mode":"FIRST_PENDING_DELTA_ONLY",
      "original_task_retry_allowed":False,
      "human_orchestration_required":False
    })
    save("_system/control/worker_state.json",worker)

    qpath=ROOT/"_system/agent_queue/queue.jsonl"
    rows=[json.loads(x) for x in qpath.read_text(encoding="utf-8-sig").splitlines() if x.strip()]
    found=False
    for row in rows:
        if row.get("task_id")=="TASK-C5-3-SOURCE-TRUTH-REPAIR":
            found=True
            row["status"]="PENDING"
            row["checkpoint"]=new_checkpoint
            row["next_action"]="Build/validate SourceTruth resolver, then authoritative 145/549 overlay; continue delta-only."
            row["next_workflow"]=None
            row["dispatch_hold_reason"]="NEXT_DELTA_DRIVER_MUST_BE_WIRED_FROM_NEW_CHECKPOINT; do not redispatch bootstrap."
            row["owner_decision_required"]=False
            row["paid"]=False
            row["generation"]=False
    if not found: raise SystemExit("C5_3_QUEUE_TASK_MISSING")
    qpath.write_text("\n".join(json.dumps(x,ensure_ascii=False,separators=(",",":")) for x in rows)+"\n",encoding="utf-8")

    print(json.dumps({"status":"PASS","checkpoint":new_checkpoint,"heartbeat":now,"next_workflow":None},sort_keys=True))

if __name__=="__main__":
    raise SystemExit(main())
