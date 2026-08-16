#!/usr/bin/env python3
import argparse,json,os,re,sys,time,hashlib,tempfile
from pathlib import Path
from urllib.request import Request,urlopen
SCHEMA='v4c2.semantic-evidence.1'; BASE='a7447b792e65780bc95aa248b9e3a2fd0466f142'; TERMINAL={'DONE','REUSED','BLOCKED'}
NUM=re.compile(r'(?i)\d+(?:\.\d+)?(?:\s*[x×*]\s*\d+(?:\.\d+)?){0,2}\s*(?:mm|cm|kg|g|lb|lbs|oz|inch|in|吋|公分|公斤|克|磅|ml|mah|wh|w|v|%)')
MATS=['不鏽鋼','不锈钢','鋁合金','铝合金','EVA','PU','PVC','TPU','TPE','尼龍','尼龙','聚酯','棉','乳膠','乳胶','橡膠','橡胶','矽膠','硅胶','皮革']
SIM=set('这专业体质发赠轻软绳护练户开带场装训图规选绷稳宽适动弹钢铝网层')
FAM={'bags':['backpack','rucksack','purse','handbag','wallet','duffel','bag'],'shoes':['running shoe','sandal','loafer','clog','shoe','sneaker','boot'],'apparel':['jersey','sweatshirt','cardigan','maillot','miniskirt','kimono','shirt','trouser','jean','coat','sock'],'sports':['tennis ball','soccer ball','football','basketball','baseball','volleyball','golf ball','ping-pong ball','racket','dumbbell','barbell','punching bag','horizontal bar','bow','ski','swimming','snorkel','paddle','helmet','knee pad']}
SUB={'racket_sports':['tennis','racket','ping-pong','badminton'],'ball_sports':['ball','basketball','football','soccer','baseball','volleyball'],'combat_martial_arts':['punching bag','boxing','glove','helmet'],'fitness_training':['dumbbell','barbell','horizontal bar','exercise'],'protective_gear':['helmet','knee pad','brace','mouth guard'],'outdoor_camping':['tent','sleeping bag','backpack','camp'],'billiards':['pool table','billiard','cue'],'water_sports':['snorkel','swimming','paddle','kayak'],'outdoor_games':['frisbee','croquet','ball'],'golf':['golf ball','golfcart','golf'],'sports_apparel':['jersey','maillot','shirt','trouser','sock'],'sports_footwear':['running shoe','sandal','shoe','sneaker'],'sports_bag':['backpack','rucksack','duffel','bag']}
def rows(p):
 out=[]; p=Path(p)
 if not p.exists(): return out
 for i,l in enumerate(p.open(encoding='utf-8-sig'),1):
  if l.strip():
   try: out.append(json.loads(l))
   except Exception as e: raise RuntimeError(f'Invalid JSONL {p}:{i}: {e}')
 return out
def norm(s): return re.sub(r'\s+','',str(s or '')).lower()
def claims(title):
 title=str(title or '');out=[];seen=set()
 for m in NUM.finditer(title):
  v=m.group(0).strip();k=norm(v)
  if k not in seen:out.append({'type':'numeric_spec','value':v,'source':'listing_title_unverified'});seen.add(k)
 for v in MATS:
  if v.lower() in title.lower() and v.lower() not in seen:out.append({'type':'material_term','value':v,'source':'listing_title_unverified'});seen.add(v.lower())
 return out
def match(cs,texts):
 corpus=norm(' '.join(x.get('text','') for x in texts));yes=[];no=[]
 for c in cs:
  q=dict(c); ok=bool(norm(c['value']) and norm(c['value']) in corpus);q['evidence']='visual_text_exact_match' if ok else 'not_observed_in_ocr';(yes if ok else no).append(q)
 return yes,no
def risks(fields,supported,texts):
 nums=[c for c in supported if c['type']=='numeric_spec'];mats=[c for c in supported if c['type']=='material_term'];corpus=norm(' '.join(x.get('text','') for x in texts));yes=[];hold=[]
 for f in fields or []:
  f=str(f).strip();ok=False
  if f in {'dimensions','size'}:ok=any(re.search(r'(?i)(mm|cm|inch|in|吋|公分|m)$',norm(c['value'])) for c in nums)
  elif f=='weight':ok=any(re.search(r'(?i)(kg|g|lb|lbs|oz|公斤|克|磅)$',norm(c['value'])) for c in nums)
  elif f=='material':ok=bool(mats)
  elif f in {'resistance','load_rating'}:ok=any(re.search(r'(?i)(kg|lb|lbs|磅)',norm(c['value'])) for c in nums)
  elif f=='waterproof_rating':ok=('防水' in corpus or 'waterproof' in corpus) and bool(nums)
  elif f=='capacity':ok=any(re.search(r'(?i)(ml|l)$',norm(c['value'])) for c in nums)
  elif f=='battery_spec':ok=any(re.search(r'(?i)(mah|wh|w|v)$',norm(c['value'])) for c in nums)
  (yes if ok else hold).append(f)
 return yes,hold
def consistency(topk,family,subcat):
 labels=' | '.join(str(x.get('label','')).lower() for x in topk)
 if any(t in labels for t in FAM.get(str(family),[])) or any(t in labels for t in SUB.get(str(subcat),[])):return 'SUPPORTED'
 other=any(any(t in labels for t in ts) for fam,ts in FAM.items() if fam!=family)
 return 'CONFLICT' if other and topk and float(topk[0].get('probability',0))>=.45 else 'UNRESOLVED'
def load_models():
 from PIL import Image
 import torch
 from torchvision.models import mobilenet_v3_small,MobileNet_V3_Small_Weights
 from rapidocr_onnxruntime import RapidOCR
 w=MobileNet_V3_Small_Weights.DEFAULT;m=mobilenet_v3_small(weights=w);m.eval();return Image,torch,m,w.transforms(),w.meta['categories'],RapidOCR()
def fetch(r,cache,retries=3,timeout=35):
 sha=str(r.get('sha256','')).lower()
 if not re.fullmatch(r'[a-f0-9]{64}',sha):raise ValueError('MISSING_OR_INVALID_SHA256')
 d=Path(cache);d.mkdir(parents=True,exist_ok=True);p=d/(sha+'.img')
 if p.exists() and hashlib.sha256(p.read_bytes()).hexdigest()==sha:return p,p.stat().st_size,False
 if p.exists():p.unlink()
 url=str(r.get('url') or '')
 if not url.startswith('https://'):raise ValueError('INVALID_SOURCE_URL')
 last=None
 for a in range(1,retries+1):
  try:
   with urlopen(Request(url,headers={'User-Agent':'TinySnow-V4C2-Semantic/1.0'}),timeout=timeout) as z:data=z.read()
   actual=hashlib.sha256(data).hexdigest()
   if actual!=sha:raise ValueError('SOURCE_SHA_MISMATCH:'+actual)
   tmp=p.with_suffix('.tmp');tmp.write_bytes(data);os.replace(tmp,p);return p,len(data),True
  except Exception as e:last=e;time.sleep(1.5*a) if a<retries else None
 raise RuntimeError('FETCH_FAILED:'+str(last))
def infer(path,models):
 Image,torch,model,transform,categories,ocr=models
 with Image.open(path) as base:fmt=base.format;img=base.convert('RGB')
 w,h=img.size
 with torch.inference_mode():
  pr=torch.nn.functional.softmax(model(transform(img).unsqueeze(0))[0],dim=0);vals,idx=torch.topk(pr,k=5)
 top=[{'label':categories[int(i)],'probability':round(float(v),6)} for v,i in zip(vals.tolist(),idx.tolist())]
 ocrpath=str(path);tmp=None
 if max(w,h)>1600:
  ratio=1600/max(w,h);small=img.resize((max(1,int(w*ratio)),max(1,int(h*ratio))));fd,tmp=tempfile.mkstemp(suffix='.jpg');os.close(fd);small.save(tmp,quality=92);ocrpath=tmp
 try:
  result,_=ocr(ocrpath);texts=[]
  for x in result or []:
   try:texts.append({'text':str(x[1])[:300],'confidence':round(float(x[2]),6)})
   except Exception:pass
  texts=texts[:80]
 finally:
  if tmp:
   try:os.remove(tmp)
   except OSError:pass
 return {'image':{'decoded':True,'format':fmt,'width_px':w,'height_px':h},'classifier':{'provider':'torchvision','model':'mobilenet_v3_small_imagenet1k_v1','local_only':True,'topk':top},'ocr':{'provider':'rapidocr_onnxruntime','local_only':True,'text_count':len(texts),'texts':texts}}
def blocked(r,c,reason,byte=None,fetched=False):
 rf=list((c or {}).get('risk_fields') or [])
 return {'schema_version':SCHEMA,'sequence':int(r.get('sequence',0)),'source_id':str(r.get('source_id','')),'product_id':str(r.get('product_id','')),'sha256':str(r.get('sha256','')).lower(),'canonical_sequence':None,'analysis_mode':'LOCAL_SEMANTIC','semantic_status':'BLOCKED','provenance':{'v4c1_baseline_head':BASE,'source_status':str(r.get('source_status','DONE')),'sha_verified':False,'byte_count_v4c1':r.get('byte_count_v4c1'),'byte_count_semantic':byte,'semantic_image_fetch':bool(fetched),'source_pipeline_redownload':False},'context':{'product_name':str((c or {}).get('product_name','')),'shopee_category':(c or {}).get('shopee_category'),'family':str((c or {}).get('family','UNKNOWN')),'subcategory':str((c or {}).get('subcategory','UNKNOWN')),'risk_fields':rf,'context_semantics':'listing_context_unverified_until_visual_evidence'},'visual_evidence':{'image':{'decoded':False,'format':None,'width_px':None,'height_px':None},'classifier':{'provider':'torchvision','model':'mobilenet_v3_small_imagenet1k_v1','local_only':True,'topk':[]},'ocr':{'provider':'rapidocr_onnxruntime','local_only':True,'text_count':0,'texts':[]},'visual_consistency':'NOT_AVAILABLE'},'claim_gate':{'title_claim_candidates':claims((c or {}).get('product_name','')),'supported_claims':[],'held_fields':[],'blocked_fields':rf},'gate':{'status':'BLOCK','reasons':[reason]},'reuse':None,'flags':{'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'local_model_only':True}}
def analyze(r,c,cache,models):
 if not c:return blocked(r,None,'MISSING_PRODUCT_CONTEXT')
 try:p,n,fetched=fetch(r,cache)
 except Exception as e:
  s=str(e);reason='SOURCE_SHA_MISMATCH' if 'SOURCE_SHA_MISMATCH' in s else ('FETCH_FAILED' if s.startswith('FETCH_FAILED') else s);return blocked(r,c,reason,None,True)
 try:v=infer(p,models)
 except Exception:return blocked(r,c,'LOCAL_MODEL_OR_DECODE_FAILURE',n,fetched)
 cs=claims(c.get('product_name',''));sup,unsup=match(cs,v['ocr']['texts']);sf,hf=risks(c.get('risk_fields') or [],sup,v['ocr']['texts']);con=consistency(v['classifier']['topk'],c.get('family'),c.get('subcategory'));v['visual_consistency']=con;simp=sorted({ch for x in v['ocr']['texts'] for ch in str(x.get('text','')) if ch in SIM})[:32]
 why=[]
 if hf:why.append('UNVERIFIED_RISK_FIELDS')
 if con=='UNRESOLVED':why.append('VISUAL_CATEGORY_UNRESOLVED')
 elif con=='CONFLICT':why.append('VISUAL_CATEGORY_POSSIBLE_CONFLICT')
 if simp:why.append('SIMPLIFIED_TEXT_OBSERVED')
 if unsup:why.append('TITLE_CLAIMS_NOT_VISUALLY_CONFIRMED')
 gate='HOLD' if why else 'PASS'
 return {'schema_version':SCHEMA,'sequence':int(r['sequence']),'source_id':str(r['source_id']),'product_id':str(r['product_id']),'sha256':str(r['sha256']).lower(),'canonical_sequence':int(r['sequence']),'analysis_mode':'LOCAL_SEMANTIC','semantic_status':'DONE','provenance':{'v4c1_baseline_head':BASE,'source_status':str(r.get('source_status','DONE')),'sha_verified':True,'byte_count_v4c1':r.get('byte_count_v4c1'),'byte_count_semantic':n,'semantic_image_fetch':bool(fetched),'source_pipeline_redownload':False},'context':{'product_name':str(c.get('product_name','')),'shopee_category':c.get('shopee_category'),'family':str(c.get('family','')),'subcategory':str(c.get('subcategory','')),'risk_fields':list(c.get('risk_fields') or []),'context_semantics':'listing_context_unverified_until_visual_evidence'},'visual_evidence':v,'claim_gate':{'title_claim_candidates':cs,'supported_claims':sup,'unsupported_title_claims':unsup,'supported_fields':sf,'held_fields':hf,'blocked_fields':[],'simplified_text_markers':simp},'gate':{'status':gate,'reasons':why},'reuse':None,'flags':{'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'local_model_only':True}}
def append(p,o):
 p=Path(p);p.parent.mkdir(parents=True,exist_ok=True)
 with p.open('a',encoding='utf-8',newline='\n') as f:f.write(json.dumps(o,ensure_ascii=False,separators=(',',':'))+'\n');f.flush();os.fsync(f.fileno())
def selftest():
 c={'product_name':'150cm 不鏽鋼訓練棍','family':'sports','subcategory':'fitness_training','risk_fields':['dimensions','material','brand']};sup,_=match(claims(c['product_name']),[{'text':'150cm 不鏽鋼'}]);sf,hf=risks(c['risk_fields'],sup,[{'text':'150cm 不鏽鋼'}]);assert 'dimensions'in sf and'material'in sf and'brand'in hf;assert blocked({'sequence':1,'source_id':'x','product_id':'p','sha256':'0'*64},c,'SOURCE_SHA_MISMATCH')['gate']['status']=='BLOCK';print('SELF_TEST_HOLD_GATE=true');print('SELF_TEST_BLOCK_GATE=true');print('SELF_TEST_IMAGE_GENERATION_CALLED=false');print('SELF_TEST_PAID_API_CALLED=false')
def main():
 a=argparse.ArgumentParser();a.add_argument('--manifest');a.add_argument('--context');a.add_argument('--progress',default='semantic_progress.jsonl');a.add_argument('--summary',default='semantic_worker_summary.json');a.add_argument('--cache-dir',default='artifacts/semantic-cache');a.add_argument('--max-items',type=int,default=0);a.add_argument('--self-test',action='store_true');x=a.parse_args()
 if x.self_test:selftest();return 0
 if not x.manifest or not x.context:a.error('--manifest and --context are required')
 manifest=rows(x.manifest);ctx={str(r['product_id']):r for r in rows(x.context)};prev=rows(x.progress);terminal={int(r['sequence']):r for r in prev if str(r.get('semantic_status')) in TERMINAL};skip=[r['sequence'] for r in manifest if int(r['sequence']) in terminal];pending=[r for r in manifest if int(r['sequence']) not in terminal];pending=pending[:x.max_items] if x.max_items else pending
 models=None;done=blocks=holds=passes=0;start=time.time()
 for r in pending:
  if models is None:
   try:models=load_models();print('LOCAL_MODEL_READY=true',flush=True)
   except Exception as e:
    print('LOCAL_MODEL_READY=false error='+str(e),flush=True)
    for q in pending:append(x.progress,blocked(q,ctx.get(str(q.get('product_id'))),'LOCAL_MODEL_UNAVAILABLE'));blocks+=1
    done+=len(pending);break
  rec=analyze(r,ctx.get(str(r.get('product_id'))),x.cache_dir,models);append(x.progress,rec);done+=1;blocks+=rec['gate']['status']=='BLOCK';holds+=rec['gate']['status']=='HOLD';passes+=rec['gate']['status']=='PASS';print(f"SEMANTIC sequence={rec['sequence']} gate={rec['gate']['status']} mode={rec['analysis_mode']}",flush=True)
 by={int(r['sequence']):r for r in rows(x.progress)};covered=sum(int(r['sequence']) in by for r in manifest);s={'schema_version':SCHEMA,'manifest_count':len(manifest),'checkpoint_existing_terminal':len(terminal),'checkpoint_skipped_this_run':len(skip),'processed_this_run':done,'covered_after_run':covered,'gate_pass_this_run':passes,'gate_hold_this_run':holds,'gate_block_this_run':blocks,'elapsed_seconds':round(time.time()-start,3),'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'local_model_only':True,'source_pipeline_redownload':False};Path(x.summary).parent.mkdir(parents=True,exist_ok=True);Path(x.summary).write_text(json.dumps(s,ensure_ascii=False,indent=2),encoding='utf-8');print('WORKER_SUMMARY='+json.dumps(s,separators=(',',':')),flush=True);return 0
if __name__=='__main__':sys.exit(main())
