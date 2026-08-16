#!/usr/bin/env python3
import argparse,json,sys
from pathlib import Path
from collections import Counter,defaultdict

def rows(path):
 out=[]
 for i,l in enumerate(Path(path).open(encoding='utf-8-sig'),1):
  if l.strip():
   try:out.append(json.loads(l))
   except Exception as e:raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
 return out

def check_claims(r):
 cg=r.get('claim_gate') or {};claims=list(cg.get('claims') or []);by={str(x.get('claim_id')):x for x in claims}
 for c in claims:
  if c.get('status')=='UNKNOWN' and c.get('allowed_usage')!='NONE':raise RuntimeError(f'UNKNOWN allowed at seq {r["sequence"]}')
 for cid in cg.get('allowed_claim_ids') or []:
  c=by.get(str(cid))
  if not c or c.get('status')!='VERIFIED_SOURCE':raise RuntimeError(f'Non-VERIFIED_SOURCE allowed at seq {r["sequence"]}')
 if cg.get('status')=='PARTIAL_SAFE':
  for cid in cg.get('allowed_claim_ids') or []:
   if by[str(cid)].get('status')=='UNKNOWN':raise RuntimeError(f'PARTIAL_SAFE contains UNKNOWN at seq {r["sequence"]}')

def frozen_fixtures(old_preservation,old_semantic):
 p=rows(old_preservation);s=rows(old_semantic);sseq={int(x['sequence']) for x in s}
 preserve=[x for x in p if str(x.get('decision'))=='PRESERVE_DIRECT']
 if not preserve:raise RuntimeError('No frozen PRESERVE fixture')
 leak=sorted(int(x['sequence']) for x in preserve if int(x['sequence']) in sseq)
 if leak:raise RuntimeError(f'Frozen PRESERVE leaked to semantic: {leak[:10]}')
 byp=defaultdict(set)
 for x in p:byp[str(x.get('product_id',''))].add(str(x.get('decision','')))
 mixed=[pid for pid,d in byp.items() if 'PRESERVE_DIRECT'in d and 'SEMANTIC_REQUIRED'in d]
 if not mixed:raise RuntimeError('No frozen mixed-partial routing fixture')
 sha13=[x for x in p if int(x.get('sequence',0))==13]
 if not sha13 or int(((sha13[0].get('evidence') or {}).get('sha_reuse_from_sequence') or 0))!=7:raise RuntimeError('Frozen SHA reuse 13->7 missing')
 return len(preserve),len(mixed),True

def validate(a):
 manifest=rows(a.manifest);progress=rows(a.progress);by={int(x['sequence']):x for x in progress};mseq=[int(x['sequence']) for x in manifest]
 expected=int(a.expected)
 if len(manifest)!=expected:raise RuntimeError(f'Manifest expected {expected}, got {len(manifest)}')
 if len(set(mseq))!=len(mseq):raise RuntimeError('Manifest duplicate sequence')
 missing=sorted(set(mseq)-set(by));extra=sorted(set(by)-set(mseq)) if a.mode=='full' else []
 if missing:raise RuntimeError(f'Missing terminal records: {missing[:10]}')
 if extra:raise RuntimeError(f'Progress extra records outside full manifest: {extra[:10]}')
 selected=[by[x] for x in mseq]
 for r in selected:
  if not r.get('terminal_status'):raise RuntimeError(f'Non-terminal seq {r["sequence"]}')
  check_claims(r)
  pr=r.get('provenance') or {}
  for k in ['source_download_called','ocr_rerun','semantic_inference_rerun','semantic_inference_executed','image_generation_called','tiny_snow_api_called','paid_api_called','vision_api_called']:
   if bool(pr.get(k)):raise RuntimeError(f'Forbidden flag {k}=true seq {r["sequence"]}')
  if (r.get('preservation_gate') or {}).get('status')=='PRESERVE' and (r.get('claim_gate') or {}).get('status')!='SKIP_PRESERVE':raise RuntimeError(f'PRESERVE entered claim gate seq {r["sequence"]}')
 preserve_fixture,mixed_fixture,sha_fixture=frozen_fixtures(a.old_preservation,a.old_semantic)
 st=Counter(str(r.get('terminal_status')) for r in selected);sha_reuse=sum(bool(r.get('sha_reuse')) for r in selected)
 if a.mode=='canary':
  seed=json.loads(Path(a.seed_summary).read_text(encoding='utf-8-sig'));resume=json.loads(Path(a.resume_summary).read_text(encoding='utf-8-sig'))
  if int(seed.get('processed_this_run',-1))!=50 or int(seed.get('checkpoint_existing_terminal',-1))!=0:raise RuntimeError('Canary seed checkpoint proof failed')
  if int(resume.get('checkpoint_existing_terminal',-1))!=50 or int(resume.get('processed_this_run',-1))!=expected-50:raise RuntimeError('Canary resume checkpoint proof failed')
 out={'schema_version':'v4c2.2.progressive-validation.1','phase':a.mode.upper(),'passed':True,'input_count':len(manifest),'terminal_count':len(selected),
      'preserve':st.get('PRESERVE',0),'sha_reuse':sha_reuse,'partial_safe':st.get('PARTIAL_SAFE',0),'hold':st.get('HOLD',0),'block':st.get('BLOCK',0),
      'semantic_actually_executed':0,'remaining':0,'frozen_preserve_skip_fixture_count':preserve_fixture,'frozen_mixed_partial_product_fixture_count':mixed_fixture,
      'frozen_sha_reuse_13_to_7':sha_fixture,'unknown_allowed_usage_none':True,'partial_safe_contains_unknown':False,'input_output_reconciliation':True,
      'source_download_called':False,'ocr_rerun':False,'semantic_140_retested':False,'v4c1_retested':False,'v4c2_0_smoke_retested':False,'v4c2_1_calibration_retested':False,'v4b_retested':False,
      'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False}
 Path(a.output).parent.mkdir(parents=True,exist_ok=True);Path(a.output).write_text(json.dumps(out,ensure_ascii=False,indent=2),encoding='utf-8')
 print(f'{a.mode.upper()}_PASS=true');print(f'INPUT={len(manifest)}');print(f'PRESERVE={out["preserve"]}');print(f'SHA_REUSE={sha_reuse}');print(f'PARTIAL_SAFE={out["partial_safe"]}');print(f'HOLD={out["hold"]}');print(f'BLOCK={out["block"]}');print('SEMANTIC_ACTUALLY_EXECUTED=0');print('REMAINING=0')

def main():
 p=argparse.ArgumentParser();p.add_argument('--mode',choices=['canary','full'],required=True);p.add_argument('--manifest',required=True);p.add_argument('--progress',required=True);p.add_argument('--expected',required=True,type=int);p.add_argument('--old-preservation',required=True);p.add_argument('--old-semantic',required=True);p.add_argument('--output',required=True);p.add_argument('--seed-summary');p.add_argument('--resume-summary');a=p.parse_args()
 if a.mode=='canary' and (not a.seed_summary or not a.resume_summary):p.error('canary requires seed/resume summaries')
 validate(a);return 0
if __name__=='__main__':sys.exit(main())