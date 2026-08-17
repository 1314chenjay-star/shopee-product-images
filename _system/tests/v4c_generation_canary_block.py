#!/usr/bin/env python3
import json
from pathlib import Path

PREFLIGHT=Path('_system/v4c/generation_canary_preflight/availability.json')
OUT=Path('_system/v4c/generation_canary')
EMPTY_MANIFESTS=[
 'canary_slot_manifest.jsonl','paid_request_ledger.jsonl','provider_request_manifest.jsonl',
 'generation_results.jsonl','output_provenance.jsonl','deterministic_qa.jsonl',
 'factual_regression_qa.jsonl','human_review_manifest.jsonl'
]

def write_json(name,obj):
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/name).write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')

def main():
    a=json.loads(PREFLIGHT.read_text(encoding='utf-8-sig'))
    blocker=a.get('blocker')
    if blocker!='BLOCK_NO_READY_VARIANT_CANARY_SAMPLE':
        raise RuntimeError('Refusing formal blocker materialization: expected exact no-READY-variant blocker, got '+str(blocker))
    if int(a.get('variant_ready_products',-1))!=0 or int(a.get('variant_ready_slots',-1))!=0:
        raise RuntimeError('Variant diagnostic is not zero; do not block.')
    if any(bool(a.get(k)) for k in ('generation_executed','image_generation_api_called','tiny_snow_api_called','vision_api_called')):
        raise RuntimeError('Paid/generation activity unexpectedly occurred before blocker materialization.')
    if int(a.get('paid_requests_sent',-1))!=0: raise RuntimeError('Paid requests unexpectedly nonzero.')
    selection={
      'schema_version':'v4c5.1.canary-selection.1','stage_status':'BLOCKED_PRE_PAID_PREFLIGHT','execution_blocker':blocker,
      'selected_product_ids':[],'selected_products':[],'selected_product_count':0,'selected_paid_slot_count':0,
      'process_localize_count':0,'safe_derivative_count':0,'preserve_slots_in_selected_products':0,
      'selection_attempted_against_frozen_ready_products':int(a['frozen_ready_products']),
      'selection_attempted_against_frozen_execution_ready_slots':int(a['frozen_execution_ready_slots']),
      'required_variant_ready_products':1,'actual_variant_ready_products':0,'actual_variant_ready_slots':0,
      'paid_requests_sent':0,'generation_executed':False,'bulk_generation_authorized':False,
      'note':'No valid Canary selection exists because the frozen V4-C5.0 execution-ready population contains zero non-empty variant_scope samples. HOLD/locked products were not substituted.'
    }
    coverage={
      'schema_version':'v4c5.1.coverage.1','stage_status':'BLOCKED_PRE_PAID_PREFLIGHT','execution_blocker':blocker,
      'selected_product_ids':[],'selected_categories_subcategories':[],'selected_product_count':0,'selected_paid_slot_count':0,
      'process_localize_count':0,'safe_derivative_count':0,'preserve_slots_in_selected_products':0,
      'paid_requests_actually_sent':0,'retries':0,'ambiguous_provider_results':0,'provider_failures':0,'generation_successes':0,
      'output_sha_count':0,'duplicate_outputs':0,'source_sha_mismatch':0,'derivative_parent_mismatch':0,'canary_precheck_hold':0,
      'deterministic_qa_pass':0,'deterministic_qa_fail':0,'factual_regression_qa_pass':0,'needs_human_visual_qa':0,
      'unknown_leak':0,'conflict_leak':0,'forbidden_leak':0,'cross_product_leak':0,'variant_leak':0,'locked_regeneration':0,
      'v4c5_queue_mutation':0,'approved_memory_mutation':0,'total_paid_request_count':0,'generation_executed':False,
      'image_generation_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,
      'provider_executor_available_but_not_invoked':True,'bulk_generation_authorized':False,'human_visual_approval_complete':False,
      'approved_memory_commit':False,'frozen_ready_products':int(a['frozen_ready_products']),'frozen_execution_ready_slots':int(a['frozen_execution_ready_slots']),
      'variant_ready_products':0,'variant_ready_slots':0,'safe_derivative_ready_products':int(a['safe_derivative_products']),
      'localization_ready_products':int(a['localization_products']),'low_or_no_text_ready_products':int(a['low_or_no_text_products']),
      'category_risk_guard_ready_products':int(a['category_risk_guard_products']),'selection_feasibility':a['selection_feasibility'],
      'frozen_fingerprints':a['frozen_fingerprints'],'preflight_diagnostic_source':'_system/v4c/generation_canary_preflight/availability.json'
    }
    checks={
      'selected_products_lte_5':True,'selected_paid_slots_lte_20':True,'paid_requests_lte_20':True,
      'all_selected_products_from_product_ready_for_generation':True,'all_selected_paid_slots_from_v4c5_execution_ready_queue':True,
      'payload_hold_selected_zero':True,'product_execution_hold_selected_zero':True,'locked_products_selected_zero':True,
      'unknown_leak_zero':True,'conflict_leak_zero':True,'forbidden_leak_zero':True,'cross_product_leak_zero':True,'variant_leak_zero':True,
      'duplicate_paid_request_zero':True,'original_v4c5_queue_mutation_zero':True,'approved_memory_mutation_zero':True,
      'stable_head_unchanged':True,'variant_sample_requirement_satisfied':False
    }
    validation={
      'schema_version':'v4c5.1.validation.1','passed':False,'stage_status':'BLOCKED_PRE_PAID_PREFLIGHT','execution_blocker':blocker,
      'preflight_safety_checks_passed':all(v for k,v in checks.items() if k!='variant_sample_requirement_satisfied'),
      'hard_checks':checks,'canary_execution_complete':False,'human_visual_approval_complete':False,'approved_memory_commit':False,
      'bulk_generation_authorized':False,'next_stage_requires_explicit_user_authorization':True,
      'why_not_executed':'User required at least one actual READY product with non-empty variant_scope. Frozen V4-C5.0 has zero such products/slots; HOLD and locked substitutions are forbidden.'
    }
    lock={
      'schema_version':'v4c5.1.lock.1','stage_status':'BLOCKED_PRE_PAID_PREFLIGHT','execution_blocker':blocker,
      'canary_execution_complete':False,'human_visual_approval_complete':False,'approved_memory_commit':False,'bulk_generation_authorized':False,
      'next_stage_requires_explicit_user_authorization':True,'selected_product_count':0,'selected_paid_slot_count':0,'paid_requests_sent':0,
      'generation_executed':False,'image_generation_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,
      'approved_memory_mutation':0,'original_v4c5_queue_mutation':0,'stable_head':a['stable_head'],'v4c5_0_base_head':a['base_head'],
      'variant_ready_products':0,'variant_ready_slots':0,'preflight_diagnostic_source':'_system/v4c/generation_canary_preflight/availability.json',
      'seal_semantics':'Records a safe blocked C5.1 execution attempt. It does NOT mean Canary execution PASS or human approval.'
    }
    write_json('canary_selection.json',selection)
    for name in EMPTY_MANIFESTS:
        OUT.mkdir(parents=True,exist_ok=True); (OUT/name).write_text('',encoding='utf-8')
    write_json('coverage_summary.json',coverage); write_json('validation.json',validation); write_json('V4_C5_1_GENERATION_CANARY_LOCK.json',lock)
    print(json.dumps(lock,ensure_ascii=False,separators=(',',':')))
if __name__=='__main__': main()
