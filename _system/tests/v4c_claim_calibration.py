#!/usr/bin/env python3
import argparse,json,hashlib,sys
from collections import defaultdict,Counter
from pathlib import Path
from v4c_claim_level_gate import read_jsonl,resolve,OCR_MIN,norm

def choose(rows,n):
 by=defaultdict(list)
 for r in rows:
  ctx=r.get('context') or {};vis=r.get('visual_evidence') or {};ocr=(vis.get('ocr') or {}).get('texts') or []
  key=(str(ctx.get('family','')),str(ctx.get('subcategory','')),str(vis.get('visual_consistency','')),str(r.get('analysis_mode','')),bool(ocr))
  by[key].append(r)
 for k in by:by[k].sort(key=lambda x:(str(x.get('product_id','')),int(x.get('sequence',0))))
 out=[];used=set();product_counts=Counter();keys=sorted(by.keys(),key=lambda x:tuple(str(v) for v in x))
 # Always include SHA_REUSE if present so reuse behavior is represented.
 reuse=[r for r in rows if str(r.get('analysis_mode',''))=='SHA_REUSE']
 for r in sorted(reuse,key=lambda x:int(x.get('sequence',0))):
  s=int(r['sequence'])
  if s not in used and len(out)<n:out.append(r);used.add(s);product_counts[str(r.get('product_id',''))]+=1
 round_no=0
 while len(out)<n:
  advanced=False
  for k in keys:
   candidates=by[k]
   pick=None
   for r in candidates:
    s=int(r['sequence']);pid=str(r.get('product_id',''))
    if s in used:continue
    if product_counts[pid]>=3 and any(int(x['sequence']) not in used and product_counts[str(x.get('product_id',''))]<3 for x in rows):continue
    pick=r;break
   if pick is not None:
    out.append(pick);used.add(int(pick['sequence']));product_counts[str(pick.get('product_id',''))]+=1;advanced=True
    if len(out)>=n:break
  round_no+=1
  if not advanced:
   for r in sorted(rows,key=lambda x:int(x.get('sequence',0))):
    if int(r['sequence']) not in used:
     out.append(r);used.add(int(r['sequence']));product_counts[str(r.get('product_id',''))]+=1
     if len(out)>=n:break
   break
 return sorted(out,key=lambda x:int(x['sequence']))

def write_jsonl(path,rows):
 Path(path).parent.mkdir(parents=True,exist_ok=True)
 Path(path).write_text('\n'.join(json.dumps(r,ensure_ascii=False,separators=(',',':')) for r in rows)+'\n',encoding='utf-8')
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def validate(sample,resolved):
 if len(sample)!=len(resolved):raise RuntimeError('Calibration input/output count mismatch')
 by={int(r['sequence']):r for r in sample};seen=set();status=Counter();verified=unknown=0
 for out in resolved:
  seq=int(out['sequence']);status[out['claim_gate_status']]+=1
  if seq in seen:raise RuntimeError(f'Duplicate calibration sequence {seq}')
  seen.add(seq)
  src=by.get(seq)
  if not src:raise RuntimeError(f'Unexpected calibration sequence {seq}')
  if str(out.get('sha256','')).lower()!=str(src.get('sha256','')).lower():raise RuntimeError(f'SHA changed at {seq}')
  p=out.get('provenance') or {}
  forbidden=['source_download_called','ocr_rerun','semantic_inference_rerun','image_generation_called','tiny_snow_api_called','paid_api_called','vision_api_called']
  if any(bool(p.get(k)) for k in forbidden):raise RuntimeError(f'Forbidden operation flag at {seq}')
  claims=out.get('claims') or [];allowed=set(out.get('allowed_claim_ids') or []);unknown_ids=set(out.get('unknown_claim_ids') or [])
  for c in claims:
   st=c.get('status');cid=c.get('claim_id')
   if st=='VERIFIED_SOURCE':
    verified+=1
    if cid not in allowed:raise RuntimeError(f'Verified claim not allowed at {seq}')
    if not c.get('evidence'):raise RuntimeError(f'Verified claim lacks evidence at {seq}: {cid}')
   elif st=='UNKNOWN':
    unknown+=1
    if cid in allowed:raise RuntimeError(f'Unknown claim leaked into allowed set at {seq}')
    if cid not in unknown_ids:raise RuntimeError(f'Unknown claim missing from unknown set at {seq}')
   else:raise RuntimeError(f'Unexpected claim status {st} at {seq}')
  if out['claim_gate_status']=='PARTIAL_SAFE':
   if not any(c.get('status')=='VERIFIED_SOURCE' for c in claims) or not any(c.get('status')=='UNKNOWN' for c in claims):raise RuntimeError(f'Invalid PARTIAL_SAFE at {seq}')
  if out['claim_gate_status']=='PASS' and any(c.get('status')=='UNKNOWN' for c in claims):raise RuntimeError(f'PASS contains UNKNOWN at {seq}')
  if out['claim_gate_status']=='HOLD' and any(c.get('status')=='VERIFIED_SOURCE' for c in claims):raise RuntimeError(f'HOLD still contains verified claim at {seq}; should be PARTIAL_SAFE')
 if status['PARTIAL_SAFE']<1:raise RuntimeError('Calibration failed: no PARTIAL_SAFE records produced')
 if unknown<1:raise RuntimeError('Calibration failed: UNKNOWN separation not exercised')
 return status,verified,unknown

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--input',required=True);ap.add_argument('--out-dir',required=True);ap.add_argument('--sample-size',type=int,default=40);a=ap.parse_args()
 rows=read_jsonl(a.input)
 if len(rows)!=140:raise RuntimeError(f'Expected frozen 140 semantic evidence records, got {len(rows)}')
 if not 30<=a.sample_size<=50:raise RuntimeError('Calibration sample size must stay within 30..50')
 sample=choose(rows,a.sample_size);resolved=[resolve(r) for r in sample]
 status,verified,unknown=validate(sample,resolved)
 out=Path(a.out_dir);out.mkdir(parents=True,exist_ok=True)
 write_jsonl(out/'calibration_manifest.jsonl',sample);write_jsonl(out/'claim_level_results.jsonl',resolved)
 families=Counter(str((r.get('context') or {}).get('family','')) for r in sample);subs=Counter(str((r.get('context') or {}).get('subcategory','')) for r in sample);products=len({str(r.get('product_id','')) for r in sample})
 summary={'schema_version':'v4c2.1.claim-calibration.1','passed':True,'source_semantic_count':len(rows),'sample_count':len(sample),'sample_product_count':products,'family_coverage':dict(families),'subcategory_coverage':dict(subs),'gate_status_counts':dict(status),'verified_source_claim_count':verified,'unknown_claim_count':unknown,'input_semantic_evidence_sha256':sha(a.input),'calibration_manifest_sha256':sha(out/'calibration_manifest.jsonl'),'claim_results_sha256':sha(out/'claim_level_results.jsonl'),'ocr_confidence_floor':OCR_MIN,'source_download_called':False,'ocr_rerun':False,'semantic_inference_rerun':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False}
 (out/'calibration_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
 print('CLAIM_CALIBRATION_PASS=true');print(f'CALIBRATION_SAMPLE={len(sample)}');print(f'PARTIAL_SAFE={status["PARTIAL_SAFE"]}');print(f'PASS={status["PASS"]}');print(f'HOLD={status["HOLD"]}');print(f'BLOCK={status["BLOCK"]}');print('SOURCE_DOWNLOAD_CALLED=false');print('OCR_RERUN=false');print('SEMANTIC_INFERENCE_RERUN=false');return 0
if __name__=='__main__':sys.exit(main())