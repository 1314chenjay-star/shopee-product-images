#!/usr/bin/env python3
import argparse,json,re,hashlib,sys
from pathlib import Path
SCHEMA='v4c2.1.claim-level-evidence.1'
OCR_MIN=0.90
NUM=re.compile(r'(?i)\d+(?:\.\d+)?(?:\s*[x×*]\s*\d+(?:\.\d+)?){0,2}\s*(?:mm|cm|m|kg|g|lb|lbs|oz|inch|in|吋|公分|公斤|克|磅|ml|l|mah|wh|w|v|%)')
MATERIALS=['不鏽鋼','不锈钢','鋁合金','铝合金','EVA','PU','PVC','TPU','TPE','尼龍','尼龙','聚酯','棉','乳膠','乳胶','橡膠','橡胶','矽膠','硅胶','皮革','鈦','钛']
FEATURES=['防水','防曬','防晒','速乾','速干','透氣','透气','防滑','耐磨','加厚','可調','可调','折疊','折叠','免搭建','自動','自动','彈力','弹力','吸汗','防雨','遮陽','遮阳']
FIELD_MAP={
 'dimensions':'numeric_dimension','size':'numeric_dimension','weight':'numeric_weight','material':'material','waterproof_rating':'waterproof_rating','resistance':'numeric_load','load_rating':'numeric_load','capacity':'numeric_capacity','battery':'battery_spec','battery_spec':'battery_spec','power':'battery_spec','brand':'brand','accessories':'accessories','bundle_count':'bundle_count'
}
def read_jsonl(path):
 out=[]
 for i,line in enumerate(Path(path).open(encoding='utf-8-sig'),1):
  if line.strip():
   try:out.append(json.loads(line))
   except Exception as e:raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
 return out
def norm(s):return re.sub(r'\s+','',str(s or '')).lower()
def cid(seq,kind,value):return hashlib.sha256(f'{seq}|{kind}|{norm(value)}'.encode('utf-8')).hexdigest()[:20]
def ocr_rows(rec):
 rows=[]
 for i,x in enumerate((((rec.get('visual_evidence') or {}).get('ocr') or {}).get('texts') or [])):
  try:c=float(x.get('confidence',0) or 0)
  except:c=0
  t=str(x.get('text','')).strip()
  if t and c>=OCR_MIN:rows.append({'index':i,'text':t,'confidence':c,'norm':norm(t)})
 return rows
def exact_in_ocr(value,rows):
 v=norm(value)
 hits=[r for r in rows if v and v in r['norm']]
 return sorted(hits,key=lambda r:r['confidence'],reverse=True)
def add_claim(claims,seq,kind,value,status,evidence=None,usage='FACT_EXACT_ONLY',origin='derived',reason=None):
 key=(kind,norm(value));
 if not key[1] or key in {(c['type'],norm(c['value'])) for c in claims}:return
 c={'claim_id':cid(seq,kind,value),'type':kind,'value':value,'status':status,'origin':origin,'allowed_usage':usage if status=='VERIFIED_SOURCE' else 'NONE','evidence':evidence or []}
 if reason:c['reason']=reason
 claims.append(c)
def resolve(rec):
 seq=int(rec.get('sequence',0)); rows=ocr_rows(rec); title=str(((rec.get('context') or {}).get('product_name')) or '')
 risk=list(((rec.get('context') or {}).get('risk_fields')) or [])
 claims=[]
 input_block=(str(((rec.get('gate') or {}).get('status',''))).upper()=='BLOCK' or str(rec.get('semantic_status','')).upper()=='BLOCKED')
 # High-confidence visible source text is verified as text only; it never licenses unstated facts.
 for r in rows:
  add_claim(claims,seq,'source_text',r['text'],'VERIFIED_SOURCE',[{'kind':'ocr','index':r['index'],'confidence':r['confidence'],'exact_text':r['text']}],'SOURCE_TEXT_LOCALIZATION_ONLY','ocr_visible_text')
 # Numeric/material/feature facts that are explicitly visible in OCR are source facts.
 for r in rows:
  for m in NUM.finditer(r['text']):
   v=m.group(0).strip(); low=norm(v)
   kind='numeric_spec'
   if re.search(r'(?i)(mm|cm|m|inch|in|吋|公分)$',low):kind='numeric_dimension'
   elif re.search(r'(?i)(kg|g|lb|lbs|oz|公斤|克|磅)$',low):kind='numeric_weight'
   elif re.search(r'(?i)(ml|l)$',low):kind='numeric_capacity'
   elif re.search(r'(?i)(mah|wh|w|v)$',low):kind='battery_spec'
   add_claim(claims,seq,kind,v,'VERIFIED_SOURCE',[{'kind':'ocr','index':r['index'],'confidence':r['confidence'],'exact_text':r['text']}],'FACT_EXACT_ONLY','ocr_explicit_fact')
  for mat in MATERIALS:
   if norm(mat) in r['norm']:add_claim(claims,seq,'material',mat,'VERIFIED_SOURCE',[{'kind':'ocr','index':r['index'],'confidence':r['confidence'],'exact_text':r['text']}],'FACT_EXACT_ONLY','ocr_explicit_fact')
  for feat in FEATURES:
   if norm(feat) in r['norm']:add_claim(claims,seq,'feature',feat,'VERIFIED_SOURCE',[{'kind':'ocr','index':r['index'],'confidence':r['confidence'],'exact_text':r['text']}],'FACT_EXACT_ONLY','ocr_explicit_fact')
 # Listing-title claims are candidates only. Exact high-confidence OCR match upgrades them.
 for m in NUM.finditer(title):
  v=m.group(0).strip();hits=exact_in_ocr(v,rows);add_claim(claims,seq,'title_numeric_spec',v,'VERIFIED_SOURCE' if hits else 'UNKNOWN',[{'kind':'ocr','index':h['index'],'confidence':h['confidence'],'exact_text':h['text']} for h in hits],'FACT_EXACT_ONLY','listing_title_candidate',None if hits else 'NOT_EXPLICITLY_VERIFIED_IN_SOURCE')
 for mat in MATERIALS:
  if norm(mat) in norm(title):
   hits=exact_in_ocr(mat,rows);add_claim(claims,seq,'title_material',mat,'VERIFIED_SOURCE' if hits else 'UNKNOWN',[{'kind':'ocr','index':h['index'],'confidence':h['confidence'],'exact_text':h['text']} for h in hits],'FACT_EXACT_ONLY','listing_title_candidate',None if hits else 'NOT_EXPLICITLY_VERIFIED_IN_SOURCE')
 for feat in FEATURES:
  if norm(feat) in norm(title):
   hits=exact_in_ocr(feat,rows);add_claim(claims,seq,'title_feature',feat,'VERIFIED_SOURCE' if hits else 'UNKNOWN',[{'kind':'ocr','index':h['index'],'confidence':h['confidence'],'exact_text':h['text']} for h in hits],'FACT_EXACT_ONLY','listing_title_candidate',None if hits else 'NOT_EXPLICITLY_VERIFIED_IN_SOURCE')
 # Risk fields become independent claims. Unknown fields do not poison verified neighbors.
 verified_types={c['type'] for c in claims if c['status']=='VERIFIED_SOURCE'}
 corpus=' '.join(r['norm'] for r in rows)
 for field in risk:
  f=str(field);target=FIELD_MAP.get(f,f);ok=False;ev=[]
  if target=='numeric_dimension':ok=bool({'numeric_dimension','title_numeric_spec'}&verified_types)
  elif target=='numeric_weight':ok=bool({'numeric_weight','title_numeric_spec'}&verified_types)
  elif target=='material':ok=bool({'material','title_material'}&verified_types)
  elif target=='waterproof_rating':ok=False # “防水” verifies function, never a rating without an explicit rating.
  elif target=='numeric_load':ok=False
  elif target=='numeric_capacity':ok='numeric_capacity' in verified_types
  elif target=='battery_spec':ok='battery_spec' in verified_types
  elif target in {'brand','accessories','bundle_count'}:ok=False
  if ok:
   ev=[{'kind':'verified_claim_reference','claim_ids':[c['claim_id'] for c in claims if c['status']=='VERIFIED_SOURCE' and c['type'] in {target,'numeric_dimension','numeric_weight','material','title_numeric_spec','title_material'}]}]
  add_claim(claims,seq,'risk_field',f,'VERIFIED_SOURCE' if ok else 'UNKNOWN',ev,'FACT_EXACT_ONLY','product_context_risk_field',None if ok else 'SOURCE_EVIDENCE_INSUFFICIENT')
 verified=[c for c in claims if c['status']=='VERIFIED_SOURCE'];unknown=[c for c in claims if c['status']=='UNKNOWN']
 factual_verified=[c for c in verified if c['type']!='source_text']
 if input_block:gate='BLOCK'
 elif not verified:gate='HOLD'
 elif unknown:gate='PARTIAL_SAFE'
 else:gate='PASS'
 allowed=[c['claim_id'] for c in verified]
 return {'schema_version':SCHEMA,'sequence':seq,'source_id':rec.get('source_id'),'product_id':rec.get('product_id'),'sha256':rec.get('sha256'),'input_semantic_status':rec.get('semantic_status'),'input_gate_status':((rec.get('gate') or {}).get('status')),'claim_gate_status':gate,'claims':claims,'allowed_claim_ids':allowed,'unknown_claim_ids':[c['claim_id'] for c in unknown],'safe_actions':{'may_preserve_source_image':gate!='BLOCK','may_localize_verified_source_text':bool(verified),'may_use_verified_facts_only':bool(factual_verified),'may_generate_unknown_claims':False,'may_infer_missing_specs':False},'provenance':{'semantic_evidence_reused':True,'source_download_called':False,'ocr_rerun':False,'semantic_inference_rerun':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'sha_reused_without_refetch':True},'counts':{'verified_source':len(verified),'unknown':len(unknown),'verified_factual':len(factual_verified)}}
def selftest():
 base={'sequence':1,'source_id':'s','product_id':'p','sha256':'a'*64,'semantic_status':'DONE','gate':{'status':'HOLD'},'context':{'product_name':'150cm 不鏽鋼 防水訓練架','risk_fields':['dimensions','material','waterproof_rating','brand']},'visual_evidence':{'ocr':{'texts':[{'text':'150cm 不鏽鋼','confidence':0.99}]}}}
 r=resolve(base);assert r['claim_gate_status']=='PARTIAL_SAFE';assert any(c['value']=='dimensions' and c['status']=='VERIFIED_SOURCE' for c in r['claims']);assert any(c['value']=='waterproof_rating' and c['status']=='UNKNOWN' for c in r['claims']);assert not r['safe_actions']['may_generate_unknown_claims']
 no=json.loads(json.dumps(base));no['visual_evidence']['ocr']['texts']=[];r2=resolve(no);assert r2['claim_gate_status']=='HOLD'
 bl=json.loads(json.dumps(base));bl['gate']['status']='BLOCK';assert resolve(bl)['claim_gate_status']=='BLOCK'
 print('CLAIM_LEVEL_SELFTEST=true');print('NO_FETCH=true');print('NO_OCR_RERUN=true');print('NO_INFERENCE_RERUN=true')
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--input');ap.add_argument('--output');ap.add_argument('--self-test',action='store_true');a=ap.parse_args()
 if a.self_test:selftest();return 0
 if not a.input or not a.output:ap.error('--input and --output required')
 rows=read_jsonl(a.input);out=[resolve(r) for r in rows];Path(a.output).parent.mkdir(parents=True,exist_ok=True);Path(a.output).write_text('\n'.join(json.dumps(x,ensure_ascii=False,separators=(',',':')) for x in out)+'\n',encoding='utf-8')
 print(f'CLAIM_LEVEL_RECORDS={len(out)}');return 0
if __name__=='__main__':sys.exit(main())