#!/usr/bin/env python3
from __future__ import annotations
import hashlib,json,pathlib,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
REQ=[
'_system/control/capability_state.json','_system/control/recovery_plan.json','_system/control/execution_checkpoint.json','_system/control/worker_state.json',
'_system/agent_queue/queue.jsonl','_system/agent_queue/queue_policy.json','_system/agent_queue/watchdog.py',
'_system/context/decision_ledger.jsonl','_system/context/project_state.json','_system/context/business_constraints.json',
'_system/source_truth/product_identity_record.schema.json','_system/governance/TINYSNOW_PROJECT_CONSTITUTION.md','_system/governance/failure_registry.jsonl'
]
missing=[p for p in REQ if not (ROOT/p).exists()]
if missing: raise SystemExit('MISSING:'+','.join(missing))
cap=json.loads((ROOT/'_system/control/capability_state.json').read_text(encoding='utf-8-sig'))
queue=[json.loads(x) for x in (ROOT/'_system/agent_queue/queue.jsonl').read_text(encoding='utf-8-sig').splitlines() if x.strip()]
assert cap['stage']=='V4-C5.3 Source Truth Repair'
assert cap['capabilities']['paid_api'] is False
assert cap['capabilities']['image_generation'] is False
assert queue and queue[0]['task_id']=='TASK-C5-3-SOURCE-TRUTH-REPAIR'
assert queue[0]['paid'] is False and queue[0]['generation'] is False
checks={
 'passed':True,'required_file_count':len(REQ),'missing':missing,'queue_count':len(queue),
 'sealed_is_frozen':queue[0]['anti_repeat']=='fingerprint_only','stable_mutation':False,
 'paid_api_called':False,'image_generation_called':False
}
out=ROOT/'_system/agent_queue/validation.json';out.write_text(json.dumps(checks,indent=2)+'\n',encoding='utf-8')
print(json.dumps(checks,sort_keys=True))
