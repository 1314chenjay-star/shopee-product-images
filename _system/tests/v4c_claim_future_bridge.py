#!/usr/bin/env python3
import argparse,json,hashlib,sys
from pathlib import Path

def read_jsonl(path):
 out=[]
 for i,line in enumerate(Path(path).open(encoding='utf-8-sig'),1):
  if line.strip():
   try:out.append(json.loads(line))
   except Exception as e:raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
 return out
def write_jsonl(path,rows):Path(path).write_text('\n'.join(json.dumps(x,ensure_ascii=False,separators=(',',':')) for x in rows)+'\n',encoding='utf-8')
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--semantic-queue',required=True);ap.add_argument('--preservation-results',required=True);ap.add_argument('--calibration-summary',required=True);ap.add_argument('--out-dir',required=True);a=ap.parse_args()
 cal=json.loads(Path(a.calibration_summary).read_text(encoding='utf-8-sig'))
 if not cal.get('passed'):raise RuntimeError('Claim-level calibration did not PASS')
 queue=read_jsonl(a.semantic_queue);pres=read_jsonl(a.preservation_results)
 if len(queue)!=1544:raise RuntimeError(f'Frozen V4-C1 semantic queue expected 1544, got {len(queue)}')
 if len(pres)!=167:raise RuntimeError(f'Frozen Preservation Smoke result expected 167, got {len(pres)}')
 qseq={int(x['sequence']) for x in queue};pby={int(x['sequence']):x for x in pres};pseq=set(pby)
 if len(pseq)!=len(pres):raise RuntimeError('Duplicate sequence in frozen preservation results')
 # V4-C1 semantic_evidence_queue intentionally excludes SHA_DUPLICATE rows. Preservation may still
 # contain such a row through SHA_REUSE (known example 13 -> 7). Accept only that exact evidence path.
 outside=sorted(pseq-qseq);outside_reuse=[]
 for seq in outside:
  r=pby[seq];ev=r.get('evidence') or {};method=str(ev.get('method',''));canonical=ev.get('sha_reuse_from_sequence')
  if method!='SHA_REUSE' or canonical is None or int(canonical) not in qseq:
   raise RuntimeError(f'Unexpected Preservation result outside semantic queue: sequence={seq} method={method} canonical={canonical}')
  outside_reuse.append({'sequence':seq,'canonical_sequence':int(canonical),'sha256':r.get('sha256')})
 evaluated_in_queue=pseq&qseq
 remaining=[]
 for q in queue:
  seq=int(q['sequence'])
  if seq in evaluated_in_queue:continue
  r=dict(q);r['v4c2_1_route']='PRESERVATION_GATE_THEN_CLAIM_LEVEL_EVIDENCE';r['claim_gate_schema']='v4c2.1.claim-level-evidence.1';r['preservation_evaluated']=False;r['claim_level_evidence_ready']=False;r['semantic_inference_allowed_now']=False;r['source_download_allowed_now']=False
  remaining.append(r)
 if len(remaining)!=len(queue)-len(evaluated_in_queue):raise RuntimeError('Future bridge reconciliation mismatch')
 out=Path(a.out_dir);out.mkdir(parents=True,exist_ok=True);future=out/'unfiltered_semantic_claim_gate_queue.jsonl';write_jsonl(future,remaining)
 summary={'schema_version':'v4c2.1.claim-future-bridge.1','passed':True,'frozen_semantic_queue_count':len(queue),'preservation_result_count':len(pres),'preservation_evaluated_inside_semantic_queue_count':len(evaluated_in_queue),'preservation_sha_reuse_outside_semantic_queue_count':len(outside_reuse),'preservation_sha_reuse_outside_semantic_queue':outside_reuse,'already_semantic_completed_count':140,'remaining_not_yet_preservation_filtered_count':len(remaining),'route':'PRESERVATION_GATE_THEN_CLAIM_LEVEL_EVIDENCE','calibration_passed':True,'calibration_sample_count':int(cal.get('sample_count',0)),'full_remaining_execution_started':False,'source_download_called':False,'preservation_smoke_retested':False,'semantic_140_retested':False,'ocr_rerun':False,'semantic_inference_rerun':False,'v4c1_retested':False,'v4b_retested':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'semantic_queue_sha256':sha(a.semantic_queue),'preservation_results_sha256':sha(a.preservation_results),'future_queue_sha256':sha(future)}
 (out/'bridge_summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
 print('CLAIM_FUTURE_BRIDGE_PASS=true');print(f'PRESERVATION_IN_QUEUE={len(evaluated_in_queue)}');print(f'PRESERVATION_SHA_REUSE_OUTSIDE_QUEUE={len(outside_reuse)}');print(f'REMAINING_NOT_YET_PRESERVATION_FILTERED={len(remaining)}');print('FULL_REMAINING_EXECUTION_STARTED=false');print('SOURCE_DOWNLOAD_CALLED=false');print('SEMANTIC_140_RETESTED=false');return 0
if __name__=='__main__':sys.exit(main())