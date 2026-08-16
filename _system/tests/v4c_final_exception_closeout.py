#!/usr/bin/env python3
import argparse, base64, gzip, json, hashlib
from collections import Counter
from pathlib import Path

SCHEMA='v4c2.6.final-exception-closeout.1'
BASE_HEAD='e0fafa8f6ea76c254af2682239f7d7955a5d3b9f'
EXPECTED_BASE=1378
EXPECTED_HOLD_TARGET=13
EXPECTED_BLOCK_TARGET=13
KNOWN_NO_VERIFIED={41,312,320}
ALLOWED_FINAL={'PRESERVE','NEEDS_LOCALIZATION','PARTIAL_SAFE','HOLD_FINAL','BLOCK_FINAL'}


def read_jsonl(path):
    out=[]
    p=Path(path)
    if not p.exists(): raise RuntimeError(f'Missing required frozen input: {path}')
    for i,line in enumerate(p.open(encoding='utf-8-sig'),1):
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out


def write_jsonl(path,rows):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows:f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')


def write_json(path,obj):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')


def load_context(path):
    raw=base64.b64decode(Path(path).read_text(encoding='ascii').strip())
    text=gzip.decompress(raw).decode('utf-8-sig')
    out={}
    for line in text.splitlines():
        if line.strip():
            r=json.loads(line);out[str(r.get('product_id',''))]=r
    return out


def safe_verified(rec):
    out=[]
    for c in rec.get('verified_claims') or []:
        if c.get('status')=='VERIFIED_SOURCE' and c.get('allowed_usage') not in {None,'','NONE'}:
            out.append(c)
    return out


def unknown_safe(rec):
    return all(c.get('allowed_usage')=='NONE' for c in (rec.get('unknown_claims') or []))


def triage_hold(rec,context_present):
    seq=int(rec['sequence']); verified=safe_verified(rec); unknown_ok=unknown_safe(rec)
    prior=str(rec.get('prior_hold_reason') or rec.get('hold_reason') or '')
    if seq in KNOWN_NO_VERIFIED and not verified:
        reason='NO_VERIFIED_SOURCE_CLAIMS_FROM_EXISTING_OCR';status='HOLD_FINAL'
    elif str(rec.get('preservation_decision'))=='PRESERVE':
        reason='EXISTING_PRESERVATION_DECISION';status='PRESERVE'
    elif verified and unknown_ok:
        reason='EXISTING_VERIFIED_SOURCE_SUPPORTS_PARTIAL_SAFE';status='PARTIAL_SAFE'
    else:
        reason=prior or ('NO_VERIFIED_SOURCE_CLAIMS_FROM_EXISTING_OCR' if not verified else 'EXISTING_EVIDENCE_INSUFFICIENT_FOR_SAFE_UPGRADE')
        status='HOLD_FINAL'
    return {
      'schema_version':SCHEMA,'exception_type':'HOLD','sequence':seq,'product_id':str(rec.get('product_id','')),
      'sha256':str(rec.get('expected_sha256') or rec.get('sha256') or rec.get('actual_sha256') or ''),
      'prior_status':'HOLD','final_status':status,'exact_reason':reason,'prior_hold_reason':prior or None,
      'product_context_present':bool(context_present),'verified_claims':rec.get('verified_claims') or [],
      'unknown_claims':rec.get('unknown_claims') or [],'preservation_decision':rec.get('preservation_decision'),
      'evidence_source':'_system/v4c/evidence_hydration/source_fallback/evidence.jsonl',
      'download_or_ocr_or_inference_executed':False
    }


def classify_block(gap,rec,source,dup_entries):
    gaps=set(gap.get('gap_types') or []); reasons=list(gap.get('gap_reasons') or [])
    joined='|'.join(reasons)
    loc=str(rec.get('localization_state') or '')
    if loc=='BLOCK_SOURCE_CHANGED' or 'SOURCE_CHANGED' in joined: return 'SOURCE_CHANGED'
    if 'VARIANT_CONFLICT' in gaps or 'MULTIPLE_SHA_FOR_PRODUCT_IMAGE_INDEX' in joined: return 'VARIANT_CONFLICT'
    if dup_entries and ('SHA_DUPLICATE' in str((source or {}).get('status')) or 'DUPLICATE' in joined): return 'DUPLICATE_CONFLICT'
    if any(x in joined for x in ['V4C2_2_SHA_DIFFERS_FROM_V4C1','SOURCE_LEDGER_ROW_MISSING','V4C1_SHA_MISSING_OR_INVALID']): return 'DATA_MAPPING_CONFLICT'
    if 'SOURCE_CONFLICT' in gaps: return 'TRUE_SOURCE_CONFLICT'
    return 'OTHER_BLOCK'


def triage_block(rec,gap,source,dup_entries):
    cls=classify_block(gap,rec,source,dup_entries)
    reasons=list(gap.get('gap_reasons') or [])
    return {
      'schema_version':SCHEMA,'exception_type':'BLOCK','sequence':int(rec['sequence']),'product_id':str(rec.get('product_id','')),
      'sha256':str(rec.get('sha256') or (source or {}).get('sha256') or ''),'prior_status':'BLOCK','final_status':'BLOCK_FINAL',
      'block_classification':cls,'exact_reason':reasons or [str(rec.get('block_reason') or 'SOURCE_OR_VARIANT_CONFLICT')],
      'gap_types':gap.get('gap_types') or [],'source_status':(source or {}).get('status'),'source_sha256':(source or {}).get('sha256'),
      'duplicate_evidence':dup_entries,'verified_claims':rec.get('verified_claims') or [],'unknown_claims':rec.get('unknown_claims') or [],
      'evidence_source':'_system/v4c/evidence_hydration/evidence.jsonl + evidence_gap_index.jsonl + V4-C1 source_evidence/duplicate_map',
      'resolved':False,'download_or_ocr_or_inference_executed':False
    }


def canonical_row(rec,evidence_source,exception=None):
    if exception:
        status=exception['final_status']; reason=exception.get('exact_reason'); verified=exception.get('verified_claims') or []; unknown=exception.get('unknown_claims') or []
    else:
        term=str(rec.get('terminal_status') or rec.get('claim_gate_status') or '')
        pres=str(rec.get('preservation_decision') or '')
        verified=rec.get('verified_claims') or [];unknown=rec.get('unknown_claims') or []
        if pres=='PRESERVE' or term=='PRESERVE':status='PRESERVE'
        elif term=='PARTIAL_SAFE':status='PARTIAL_SAFE'
        elif term=='PASS' and pres=='NEEDS_LOCALIZATION':status='NEEDS_LOCALIZATION'
        elif term=='BLOCK' or pres.startswith('BLOCK'):status='BLOCK_FINAL'
        else:status='HOLD_FINAL'
        reason=rec.get('hold_reason') or rec.get('prior_hold_reason') or rec.get('block_reason')
    if status in {'PARTIAL_SAFE','NEEDS_LOCALIZATION'} and not safe_verified({'verified_claims':verified}):
        status='HOLD_FINAL';reason=reason or 'NO_SAFE_VERIFIED_SOURCE_FOR_DOWNSTREAM'
    generation_allowed=status in {'PARTIAL_SAFE','NEEDS_LOCALIZATION'}
    if status=='PRESERVE': generation_allowed=False
    downstream_allowed=generation_allowed
    if status in {'HOLD_FINAL','BLOCK_FINAL'}: downstream_allowed=False;generation_allowed=False
    return {
      'schema_version':'v4c2.canonical-closeout.1','sequence':int(rec['sequence']),'product_id':str(rec.get('product_id','')),
      'sha256':str(rec.get('expected_sha256') or rec.get('sha256') or rec.get('actual_sha256') or ''),'final_status':status,
      'evidence_source':evidence_source,'verified_claims':verified,'unknown_claims':unknown,'hold_or_block_reason':reason,
      'downstream_eligibility':{'downstream_generation_allowed':bool(downstream_allowed),'generation_allowed':bool(generation_allowed)}
    }


def run(a):
    v23=read_jsonl(a.v23_evidence);v24=read_jsonl(a.v24_evidence);v25=read_jsonl(a.v25_evidence)
    gaps={int(r['sequence']):r for r in read_jsonl(a.gap_index)}
    sources={int(r['sequence']):r for r in read_jsonl(a.source_evidence)}
    dup=json.loads(Path(a.duplicate_map).read_text(encoding='utf-8-sig'))
    dup_by={}
    for d in dup.get('sha256_duplicates',[]):
        dup_by.setdefault(int(d['sequence']),[]).append(d)
        dup_by.setdefault(int(d['canonical_sequence']),[]).append(d)
    ctx=load_context(a.product_context)
    if len(v23)!=EXPECTED_BASE: raise RuntimeError(f'Expected frozen V4-C2.3 base {EXPECTED_BASE}, got {len(v23)}')
    holds=[r for r in v25 if str(r.get('terminal_status'))=='HOLD']
    blocks=[r for r in v23 if str(r.get('terminal_status'))=='BLOCK']
    if len(holds)!=EXPECTED_HOLD_TARGET: raise RuntimeError(f'Expected 13 V4-C2.5 HOLD, got {len(holds)}')
    if len(blocks)!=EXPECTED_BLOCK_TARGET: raise RuntimeError(f'Expected 13 original BLOCK, got {len(blocks)}')
    hold_triage=[triage_hold(r,str(r.get('product_id','')) in ctx) for r in sorted(holds,key=lambda x:int(x['sequence']))]
    block_triage=[]
    for r in sorted(blocks,key=lambda x:int(x['sequence'])):
        seq=int(r['sequence']);block_triage.append(triage_block(r,gaps.get(seq,{}) ,sources.get(seq),dup_by.get(seq,[])))
    write_jsonl(a.hold_out,hold_triage);write_jsonl(a.block_out,block_triage)
    latest={int(r['sequence']):(r,'_system/v4c/evidence_hydration/evidence.jsonl') for r in v23}
    for r in v24: latest[int(r['sequence'])]=(r,'_system/v4c/evidence_hydration/bartifact_recovery/materialized_evidence.jsonl')
    for r in v25: latest[int(r['sequence'])]=(r,'_system/v4c/evidence_hydration/source_fallback/evidence.jsonl')
    ex={int(r['sequence']):r for r in hold_triage+block_triage}
    ledger=[]
    for seq in sorted(latest):
        r,src=latest[seq];ledger.append(canonical_row(r,src,ex.get(seq)))
    if len(ledger)!=EXPECTED_BASE: raise RuntimeError(f'Canonical ledger expected {EXPECTED_BASE}, got {len(ledger)}')
    write_jsonl(a.ledger_out,ledger)
    counts=Counter(r['final_status'] for r in ledger)
    hold_resolved=sum(r['final_status']!='HOLD_FINAL' for r in hold_triage)
    block_resolved=sum(bool(r.get('resolved')) for r in block_triage)
    targeted_hold_final=sum(r['final_status']=='HOLD_FINAL' for r in hold_triage)
    targeted_block_final=sum(r['final_status']=='BLOCK_FINAL' for r in block_triage)
    downstream=sum(bool(r['downstream_eligibility']['downstream_generation_allowed']) for r in ledger)
    preserved=counts.get('PRESERVE',0)
    inherited_hold_final=counts.get('HOLD_FINAL',0)-targeted_hold_final
    summary={'schema_version':'v4c2.6.closeout-summary.1','passed':True,'target':26,'hold_target':13,'hold_resolved':hold_resolved,
             'hold_final_targeted':targeted_hold_final,'block_target':13,'block_resolved':block_resolved,'block_final_targeted':targeted_block_final,
             'canonical_total':len(ledger),'canonical_counts':dict(sorted(counts.items())),'downstream_eligible_count':downstream,'preserved_count':preserved,
             'inherited_frozen_hold_final_not_retriaged':inherited_hold_final,'block_classification_counts':dict(Counter(r['block_classification'] for r in block_triage)),
             'api_flags':{'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,
                          'preservation_reexecuted':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,
                          'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_retested':False,'v4c2_3_retested':False,'v4c2_4_retested':False,'v4c2_5_retested':False}}
    write_json(a.summary_out,summary)
    print('TARGET=26');print('HOLD_RESOLVED='+str(hold_resolved));print('HOLD_FINAL_TARGETED='+str(targeted_hold_final));print('BLOCK_RESOLVED='+str(block_resolved));print('BLOCK_FINAL_TARGETED='+str(targeted_block_final));print('CANONICAL_COUNTS='+json.dumps(dict(counts),sort_keys=True));print('DOWNSTREAM_ELIGIBLE='+str(downstream));print('PRESERVED='+str(preserved));print('INHERITED_FROZEN_HOLD_FINAL='+str(inherited_hold_final))


def validate(a):
    h=read_jsonl(a.hold_triage);b=read_jsonl(a.block_triage);l=read_jsonl(a.ledger);s=json.loads(Path(a.summary).read_text(encoding='utf-8-sig'))
    if len(h)!=13 or len(b)!=13 or len(l)!=1378: raise RuntimeError('Closeout reconciliation count mismatch')
    if {int(x['sequence']) for x in h}&{int(x['sequence']) for x in b}: raise RuntimeError('HOLD/BLOCK target overlap')
    known={int(x['sequence']):x for x in h}
    for seq in KNOWN_NO_VERIFIED:
        x=known.get(seq)
        if not x: raise RuntimeError(f'Known HOLD missing: {seq}')
        if not x.get('verified_claims') and x.get('exact_reason')!='NO_VERIFIED_SOURCE_CLAIMS_FROM_EXISTING_OCR': raise RuntimeError(f'Known HOLD reason changed: {seq}')
    for x in h:
        if not unknown_safe(x): raise RuntimeError(f'UNKNOWN allowed_usage violation seq {x["sequence"]}')
        if x['final_status']=='PARTIAL_SAFE' and not safe_verified(x): raise RuntimeError(f'PARTIAL_SAFE without VERIFIED_SOURCE seq {x["sequence"]}')
    for x in b:
        if x.get('final_status')!='BLOCK_FINAL': raise RuntimeError('Block resolved without explicit evidence')
        if x.get('block_classification') not in {'TRUE_SOURCE_CONFLICT','VARIANT_CONFLICT','SOURCE_CHANGED','DUPLICATE_CONFLICT','DATA_MAPPING_CONFLICT','OTHER_BLOCK'}: raise RuntimeError('Invalid block classification')
    counts=Counter()
    for x in l:
        st=x.get('final_status');counts[st]+=1
        if st not in ALLOWED_FINAL: raise RuntimeError(f'Invalid canonical status {st}')
        unk=x.get('unknown_claims') or []
        if any(c.get('allowed_usage')!='NONE' for c in unk): raise RuntimeError(f'Canonical UNKNOWN allowed seq {x["sequence"]}')
        e=x.get('downstream_eligibility') or {}
        if st in {'HOLD_FINAL','BLOCK_FINAL','PRESERVE'} and e.get('generation_allowed') is not False: raise RuntimeError(f'Forbidden generation eligibility seq {x["sequence"]}')
        if st in {'HOLD_FINAL','BLOCK_FINAL'} and e.get('downstream_generation_allowed') is not False: raise RuntimeError(f'Exception downstream allowed seq {x["sequence"]}')
        if st in {'PARTIAL_SAFE','NEEDS_LOCALIZATION'}:
            if not safe_verified(x): raise RuntimeError(f'Downstream status without safe VERIFIED_SOURCE seq {x["sequence"]}')
            if e.get('downstream_generation_allowed') is not True: raise RuntimeError(f'Downstream status disabled seq {x["sequence"]}')
    if dict(sorted(counts.items()))!=dict(sorted((s.get('canonical_counts') or {}).items())): raise RuntimeError('Summary canonical counts mismatch')
    flags=s.get('api_flags') or {}
    if any(flags.values()): raise RuntimeError(f'Forbidden/retest flag true: {flags}')
    write_json(a.validation_out,{'schema_version':'v4c2.6.validation.1','passed':True,'target':26,'canonical_total':len(l),'canonical_counts':dict(sorted(counts.items())),'downstream_eligible_count':s.get('downstream_eligible_count'),'preserved_count':s.get('preserved_count'),'api_flags':flags})
    print('V4_C2_6_VALIDATION=PASS')


def self_test():
    r={'sequence':41,'product_id':'p','terminal_status':'HOLD','verified_claims':[],'unknown_claims':[{'allowed_usage':'NONE'}],'preservation_decision':'NEEDS_LOCALIZATION'}
    x=triage_hold(r,True)
    assert x['final_status']=='HOLD_FINAL' and x['exact_reason']=='NO_VERIFIED_SOURCE_CLAIMS_FROM_EXISTING_OCR'
    r2=dict(r,sequence=99,verified_claims=[{'status':'VERIFIED_SOURCE','allowed_usage':'FACT_EXACT_ONLY'}])
    assert triage_hold(r2,True)['final_status']=='PARTIAL_SAFE'
    print('SELF_TEST=PASS')


def main():
    p=argparse.ArgumentParser();sub=p.add_subparsers(dest='cmd',required=True)
    sub.add_parser('self-test')
    r=sub.add_parser('run')
    for n in ['v23-evidence','v24-evidence','v25-evidence','gap-index','source-evidence','duplicate-map','product-context','hold-out','block-out','ledger-out','summary-out']:
        r.add_argument('--'+n,required=True)
    v=sub.add_parser('validate')
    for n in ['hold-triage','block-triage','ledger','summary','validation-out']:v.add_argument('--'+n,required=True)
    a=p.parse_args()
    if a.cmd=='self-test':self_test()
    elif a.cmd=='run':run(a)
    else:validate(a)
if __name__=='__main__':main()
