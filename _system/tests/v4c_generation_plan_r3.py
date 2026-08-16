#!/usr/bin/env python3
"""V4-C4.0 planner wrapper r3.
Fixes only new-stage Canary wrapper recursion and enforces the requested priority:
LOCKED_APPROVED > PRESERVE > PROCESS_SAFE. Frozen stages are never rerun.
"""
import json
from collections import Counter
import v4c_generation_plan as core
import v4c_generation_plan_r2 as r2

ORIGINAL_CANARY=core.canary
ORIGINAL_SELECT_CANARY=core.select_canary
FROZEN_VARIANT_PRODUCTS={'52915734564','58015741169'}


def prepare_r3(args):
    # Reuse the successful r2 global reconciliation (including no-fabrication SHA policy).
    r2.prepare_r2(args)
    rows=core.read_jsonl(args.base_state)
    preserve_origins=core.collect_preserve_sequences()
    changed=0
    for r in rows:
        seq=int(r['sequence'])
        # Requested priority: a locked-product guard may prevent PROCESS, but must never
        # downgrade a frozen PRESERVE image. LOCKED_APPROVED already has higher priority.
        if (r.get('product_id') in core.LOCKED_PRODUCT_GUARDS and
            r.get('canonical_state')=='HOLD' and
            r.get('state_reason')=='LOCKED_PRODUCT_GUARD_WITHOUT_DURABLE_SLOT_APPROVAL_FOR_THIS_SOURCE' and
            seq in preserve_origins and r.get('source_sha256')):
            r['canonical_state']='PRESERVE'; r['underlying_state']='PRESERVE'
            r['state_reason']='FROZEN_PRESERVATION_PASS_LOCKED_PRODUCT'
            r['state_evidence_references']=preserve_origins[seq]
            r['do_not_regenerate']=True; changed+=1
    core.write_jsonl(args.base_state,rows)
    prep=core.read_json(args.prepare_summary)
    counts=Counter(r['underlying_state'] for r in rows)
    prep['schema_version']='v4c4.0.prepare-r3.1'
    prep['base_state_counts']=dict(counts)
    prep['global_preserve_underlying_count']=counts['PRESERVE']
    prep['locked_approved_count']=counts['LOCKED_APPROVED']
    prep['canonical_process_safe_count']=counts['PROCESS_SAFE']
    prep['locked_preserve_priority_restored_count']=changed
    core.write_json(args.prepare_summary,prep)
    print(json.dumps(prep,ensure_ascii=False,sort_keys=True))


def feature_with_frozen_variant(pid,items,plan,taxonomy):
    f=core.features_for_product(pid,items,plan,taxonomy)
    if pid in FROZEN_VARIANT_PRODUCTS:
        f['variant_product']=True
        f['variant_evidence_reference']='frozen V4-A.3/V4-B test fixture only; not generation-safe payload'
    return f


def select_canary_r3(base_state,n=25):
    old_feature=core.features_for_product
    core.features_for_product=feature_with_frozen_variant
    try:
        return ORIGINAL_SELECT_CANARY(base_state,n)
    finally:
        core.features_for_product=old_feature


def canary_r3(args):
    old_select=core.select_canary
    core.select_canary=select_canary_r3
    try:
        return ORIGINAL_CANARY(args)
    finally:
        core.select_canary=old_select


if __name__=='__main__':
    core.prepare=prepare_r3
    core.canary=canary_r3
    core.main()
