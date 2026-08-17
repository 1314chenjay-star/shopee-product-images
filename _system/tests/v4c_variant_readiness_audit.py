#!/usr/bin/env python3
import hashlib, json, os, re, sys
from collections import Counter, defaultdict
from pathlib import Path

try: sys.stdout.reconfigure(encoding='utf-8', errors='backslashreplace')
except Exception: pass

R=Path('.')
O=R/'_system/v4c/variant_readiness_audit'
DISCOVERY=31997341246
BASE=os.environ.get('AUDIT_BASE_HEAD','bd6d92873d5b26aeb986e1615e3eb3c2e482b814')
RUN=os.environ.get('GITHUB_RUN_ID','')
EXEC_HEAD=os.environ.get('GITHUB_SHA','')
STABLE='5d49f061e140813b3d229520e9e530f86b27b640'

P={
 'ready':R/'_system/v4c/generation_payload/execution_ready_queue.jsonl',
 'c5dry':R/'_system/v4c/generation_payload/dry_run_results.jsonl',
 'c5ctx':R/'_system/v4c/generation_payload/generation_context.jsonl',
 'c5lock':R/'_system/v4c/generation_payload/V4_C5_0_GENERATION_PAYLOAD_LOCK.json',
 'c4canon':R/'_system/v4c/generation_plan/canonical_image_state.jsonl',
 'c4plan':R/'_system/v4c/generation_plan/product_5slot_plan.jsonl',
 'c4queue':R/'_system/v4c/generation_plan/generation_plan_queue.jsonl',
 'c32img':R/'_system/v4c/factual_gate/correction_v4c3_2/corrected_image_gate.jsonl',
 'c32prod':R/'_system/v4c/factual_gate/correction_v4c3_2/corrected_product_gate.jsonl',
 'c32queue':R/'_system/v4c/factual_gate/correction_v4c3_2/corrected_generation_queue.jsonl',
 'source':R/'_system/v4c/results/source_evidence.jsonl',
 'semqueue':R/'_system/v4c/results/semantic_evidence_queue.jsonl',
 'semev':R/'_system/v4c/semantic/preservation/semantic_evidence.jsonl',
 'bridge':R/'_system/v4c/claim_gate/bridge/unfiltered_semantic_claim_gate_queue.jsonl',
 'calib':R/'_system/v4c/claim_gate/calibration/claim_level_results.jsonl',
 'prog':R/'_system/v4c/progressive_claim/progress.jsonl',
 'inventory':R/'_system/v4c/inventory/source_inventory.jsonl',
 'memfact':R/'_system/memory/approved_fact_memory.jsonl',
 'memout':R/'_system/memory/approved_output_memory.jsonl',
 'memdb':R/'_system/memory/tinysnow_memory.sqlite',
 'api':R/'_system/start/api_v2.ps1',
}
FROZEN=['inventory','c32img','c32prod','c32queue','c4canon','c4plan','c4queue','ready','c5dry','c5ctx','c5lock','memfact','memout','memdb','api']
PC=['A_NO_PRODUCT_VARIANTS','B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE','C_VARIANT_SCOPE_PROPAGATION_LOSS','D_VARIANT_MAPPING_AMBIGUOUS','E_VARIANT_CONFLICT_UNSAFE']
SS=['NO_VARIANTS','COMMON_TO_ALL_VARIANTS','SPECIFIC_VARIANT','VARIANT_MAPPING_UNKNOWN','VARIANT_CONFLICT']
SENSITIVE=('color','colour','顏色','颜色','size','尺寸','quantity','bundle','pack','piece','pcs','數量','数量','style','款式','model','型號','型号','handed','left','right','左右手','accessory','配件','gift','贈品','赠品','capacity','容量','length','長度','长度','width','寬度','宽度','material','材質','材质')
MAP_PAT=(r'mapping_required',r'require.*mapping',r'requires?_.*mapping',r'must_follow_exact_selected_source',r'follow_exact_selected_source',r'source_specific',r'must_not_be_mixed',r'must_remain_isolated',r'_isolated',r'exact_.*mapping',r'map_.*sellable_options',r'catalog_options_require',r'options_require_.*mapping',r'variant_mapping',r'cannot_be_mapped',r'cannot_be_generalized_to_all_options')
CONFLICT_PAT=(r'identity_conflict',r'brand_conflict',r'variant_conflict',r'source_catalog_product_identity_conflict')
NO_PAT=(r'no_catalog_options',r'no_variants',r'no_variant_options',r'zero_catalog_options')
ONE_PAT=(r'single_catalog_option_only',r'single_listed_variant',r'one_catalog_option_only')

def jl(path):
 out=[]
 if not path.exists(): return out
 for n,line in enumerate(path.read_text(encoding='utf-8-sig',errors='replace').splitlines(),1):
  if not line.strip(): continue
  try: x=json.loads(line)
  except Exception as e: raise RuntimeError(f'bad jsonl {path}:{n}: {e}')
  if isinstance(x,dict): out.append(x)
 return out

def js(path): return json.loads(path.read_text(encoding='utf-8-sig'))
def wj(path,x): path.parent.mkdir(parents=True,exist_ok=True); path.write_text(json.dumps(x,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def wjl(path,rows): path.parent.mkdir(parents=True,exist_ok=True); path.write_text(''.join(json.dumps(x,ensure_ascii=False,separators=(',',':'))+'\n' for x in rows),encoding='utf-8')
def h(path):
 q=hashlib.sha256()
 with path.open('rb') as f:
  for c in iter(lambda:f.read(1048576),b''): q.update(c)
 return q.hexdigest()
def fps():
 z={}
 for k in FROZEN:
  if not P[k].exists(): raise RuntimeError(f'missing frozen path {P[k]}')
  z[P[k].as_posix()]=h(P[k])
 return z

def pid(x): return str(x or '').strip()
def seq(x):
 try:
  n=int(x); return n if n>0 else None
 except Exception:return None

def sv(v):
 if v is None:return []
 if isinstance(v,str):
  s=v.strip()
  if not s or s in ('[]','{}','null','None'):return []
  try:return sv(json.loads(s))
  except Exception:return [s]
 if isinstance(v,dict): return [f'{k}={json.dumps(v[k],ensure_ascii=False,sort_keys=True)}' for k in sorted(v) if v[k] not in (None,'',[],{})]
 if isinstance(v,(list,tuple,set)):
  a=[]
  for x in v:a+=sv(x)
  return sorted(set(a))
 return [str(v)]
def nonempty(v): return bool(sv(v))

def byseq(rows):
 z={}
 for r in rows:
  s=seq(r.get('sequence') or r.get('source_sequence'))
  if s:z[s]=r
 return z
def bypid(rows): return {pid(r.get('product_id')):r for r in rows if pid(r.get('product_id'))}

def nested_scopes(obj,allowed):
 out=[]
 def walk(x,path='$'):
  if isinstance(x,dict):
   if 'variant_scope' in x and nonempty(x.get('variant_scope')):
    fid=str(x.get('fact_id') or x.get('claim_id') or x.get('memory_id') or '')
    st=str(x.get('status') or x.get('classification') or x.get('approval_status') or '').upper()
    use=str(x.get('allowed_usage') or '').upper()
    if fid: trusted=fid in allowed
    else: trusted=st in ('VERIFIED_SOURCE','FACT_VERIFIED','APPROVED','PASS','PARTIAL_SAFE')
    if st in ('UNKNOWN','FACT_UNKNOWN','FACT_CONFLICT','FACT_FORBIDDEN','BLOCK','HOLD','REJECTED','REVOKED') or use=='NONE': trusted=False
    out.append({'path':path,'variant_scope':x.get('variant_scope'),'scope_values':sv(x.get('variant_scope')),'fact_or_claim_id':fid,'status':st,'allowed_usage':use,'trusted':trusted})
   for k,v in x.items():walk(v,path+'.'+str(k))
  elif isinstance(x,list):
   for i,v in enumerate(x):walk(v,f'{path}[{i}]')
 walk(obj)
 return out

def stage(name,r,allowed):
 if not r:return {'stage':name,'record_present':False,'top_level_scope':[],'trusted_nested_scopes':[],'has_trusted_specific_scope':False}
 top=sv(r.get('variant_scope')); nested=[x for x in nested_scopes(r,allowed) if x['trusted']]
 return {'stage':name,'record_present':True,'top_level_scope':top,'trusted_nested_scopes':nested,'has_trusted_specific_scope':bool(top or nested)}

def anypat(t,pats): return any(re.search(p,t,re.I) for p in pats)
def reporttext(r): return ' '.join([str(r.get('verdict') or '')]+[str(x) for x in r.get('variant_constraints') or []]+[str(x) for x in r.get('blocked_claim_keys') or []]+[str(x) for x in r.get('next_evidence_required') or []]).lower()
def sensitive(f): return any(x.lower() in (' '.join([str(f.get('claim_type') or ''),str(f.get('value') or ''),str(f.get('reason') or '')]).lower()) for x in SENSITIVE)

def option_hint(r):
 if not r:return None
 t=' '.join(str(x) for x in r.get('variant_constraints') or []).lower(); vals=[]
 for p in (r'(\d{1,3})[_ ]catalog[_ ]options?',r'(\d{1,3})[_ ]sellable[_ ]options?',r'(\d{1,3})[_ ]listed[_ ]options?',r'(\d{1,3})[_ ]options?[_ ]require',r'(\d{1,3})\s+catalog\s+options?'):
  vals += [int(m.group(1)) for m in re.finditer(p,t)]
 if vals:return max(vals)
 return 1 if anypat(t,ONE_PAT) else None

def load_reports():
 latest={}; hist=defaultdict(list); vp=set(); cc=0; files=sorted((R/'_system/reports').glob('v4c0_b*_semantic_review*.json'))
 for f in files:
  for x in js(f).get('products') or []:
   if not isinstance(x,dict) or not pid(x.get('product_id')):continue
   y=dict(x); y['_report_file']=f.as_posix(); q=list(y.get('variant_constraints') or [])
   if q:vp.add(pid(y.get('product_id'))); cc+=len(q)
   hist[pid(y.get('product_id'))].append(y); latest[pid(y.get('product_id'))]=y
 return latest,hist,len(vp),cc,[f.as_posix() for f in files]

def main():
 before=fps(); ready=jl(P['ready'])
 if len(ready)!=549:raise RuntimeError(f'READY slots {len(ready)} != 549')
 rp=sorted({pid(x.get('product_id')) for x in ready if pid(x.get('product_id'))})
 if len(rp)!=145:raise RuntimeError(f'READY products {len(rp)} != 145')
 if any(nonempty(x.get('variant_scope')) for x in ready):raise RuntimeError('READY variant_scope drifted non-empty after discovery PASS')
 rb=defaultdict(list)
 for x in ready:rb[pid(x.get('product_id'))].append(x)
 latest,hist,vpc,vcc,report_files=load_reports()
 if (vpc,vcc)!=(162,648):raise RuntimeError(f'V4-C0 discovery reconciliation drift {(vpc,vcc)}')
 inventory=jl(P['inventory']); ip={pid(x.get('product_id')) for x in inventory if pid(x.get('product_id'))}
 if len(inventory)!=2394 or len(ip)!=375:raise RuntimeError(f'inventory drift {len(inventory)}/{len(ip)}')

 I=byseq(jl(P['c32img'])); PR=bypid(jl(P['c32prod'])); Q=byseq(jl(P['c32queue'])); C=byseq(jl(P['c4canon'])); CQ=byseq(jl(P['c4queue'])); PL=bypid(jl(P['c4plan']))
 U=[('SOURCE_EVIDENCE',byseq(jl(P['source']))),('SEMANTIC_EVIDENCE_QUEUE',byseq(jl(P['semqueue']))),('SEMANTIC_EVIDENCE',byseq(jl(P['semev']))),('CLAIM_BRIDGE',byseq(jl(P['bridge']))),('CLAIM_CALIBRATION',byseq(jl(P['calib']))),('PROGRESSIVE_CLAIM',byseq(jl(P['prog']))),('C3_2_FACTUAL_GATE',I),('C3_2_QUEUE',Q),('C4_CANONICAL',C)]
 plans={}
 for p0,rec in PL.items():
  for sl in rec.get('slots') or []:
   try:plans[(p0,int(sl.get('slot_index')))]=sl
   except Exception:pass
 memfact=jl(P['memfact']); memout=jl(P['memout']); mby=defaultdict(list)
 for x in memfact:
  s=seq(x.get('source_sequence'))
  if s:mby[s].append(x)
 memstats={'approved_fact_memory_nonempty_variant_scope':sum(nonempty(x.get('variant_scope')) for x in memfact),'approved_output_memory_nonempty_variant_scope':sum(nonempty(x.get('variant_scope')) for x in memout),'ready_product_approved_fact_nonempty_variant_scope':sum(pid(x.get('product_id')) in set(rp) and nonempty(x.get('variant_scope')) for x in memfact)}

 products=[]; slots=[]; overlay=[]; traces=[]; gaps=[]; pc=Counter(); sc=Counter(); affected=set(); aseq=set(); aslots=[]; firstloss=Counter(); contamination=0
 for p0 in rp:
  rr=sorted(rb[p0],key=lambda x:int(x.get('slot_index') or 0)); rep=latest.get(p0); tx=reporttext(rep or {}); cons=list((rep or {}).get('variant_constraints') or []); hint=option_hint(rep)
  seqs=sorted({seq(x.get('source_sequence')) for x in rr if seq(x.get('source_sequence'))})
  imgs=[I[s] for s in seqs if s in I]
  conflict=[]
  if PR.get(p0,{}).get('variant_conflicts'):conflict.append({'stage':'C3.2_PRODUCT_GATE','variant_conflicts':PR[p0]['variant_conflicts']})
  for x in imgs:
   if x.get('variant_conflicts'):conflict.append({'stage':'C3.2_IMAGE_GATE','sequence':x.get('sequence'),'variant_conflicts':x['variant_conflicts']})
  repconf=anypat(tx,CONFLICT_PAT) or 'conflict' in str((rep or {}).get('verdict') or '').lower()
  no=anypat(tx,NO_PAT); variants=bool(cons) and not no; one=anypat(tx,ONE_PAT) or hint==1; ambiguous=anypat(tx,MAP_PAT)
  temp=[]; ctr=[]; allfacts=[]
  for r0 in rr:
   s=seq(r0.get('source_sequence')); idx=int(r0.get('slot_index') or 0); ps=plans.get((p0,idx),{}); safe={str(x) for x in ps.get('safe_fact_ids') or [] if str(x)}
   if not safe and s:safe={str(x) for x in CQ.get(s,{}).get('safe_fact_ids') or [] if str(x)}
   facts=[]
   for k in ('verified_facts','conflict_facts','unknown_facts','forbidden_facts'):
    for f in I.get(s or -1,{}).get(k) or []:
     if str(f.get('fact_id') or '') in safe:facts.append(f)
   allfacts+=facts; st=[]
   if s:
    for name,ix in U:st.append(stage(name,ix.get(s),safe))
    if mby.get(s):st.append(stage('PERSISTENT_MEMORY_FACT',{'facts':mby[s]},safe))
   st.append(stage('C4_PLAN',ps,safe)); st.append(stage('C5_READY_QUEUE',r0,safe))
   ni=[i for i,x in enumerate(st) if x.get('has_trusted_specific_scope')]; loss=False; last=None; first=None
   if ni and not nonempty(r0.get('variant_scope')):
    li=max(ni); later=[x for x in st[li+1:] if x.get('record_present') and not x.get('has_trusted_specific_scope')]
    if later:loss=True; last=st[li]['stage']; first=later[0]['stage']
   tr={'product_id':p0,'slot_index':idx,'slot_role':r0.get('slot_role'),'source_sequence':s,'safe_fact_ids':sorted(safe),'c_candidate':loss,'last_specific_scope_stage':last,'first_loss_stage':first,'stages':st}
   if loss:
    ctr.append(tr); traces.append(tr); affected.add(p0); firstloss[first]+=1 if first else 0
    if s:aseq.add(s)
    aslots.append({'product_id':p0,'slot_index':idx,'source_sequence':s})
   temp.append((r0,ps,sorted(safe),facts,loss))
  sf=[f for f in allfacts if sensitive(f)]
  if conflict or repconf: cl='E_VARIANT_CONFLICT_UNSAFE'; reason='frozen variant conflict evidence exists'
  elif ctr: cl='C_VARIANT_SCOPE_PROPAGATION_LOSS'; reason='trusted specific-variant scope existed upstream for READY safe evidence and is empty downstream'
  elif no: cl='A_NO_PRODUCT_VARIANTS'; reason='frozen V4-C0 metadata explicitly proves no product variants/options'
  elif variants:
   if ambiguous:cl='D_VARIANT_MAPPING_AMBIGUOUS'; reason='variants are proven but exact image/fact-to-variant mapping is not reliable'
   elif one:cl='B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE'; reason='single catalog option is the complete variant universe; READY facts are common to all available variants'
   elif sf:cl='D_VARIANT_MAPPING_AMBIGUOUS'; reason='variant-sensitive READY facts exist without reliable specific-variant mapping'
   else:cl='B_VARIANTS_EXIST_SHARED_IMAGE_SCOPE_SAFE'; reason='variants exist, no trusted specific mapping exists, and READY safe facts exclude variant-specific attributes'
  else:cl='D_VARIANT_MAPPING_AMBIGUOUS'; reason='no durable zero-option proof and no reliable specific/common mapping; no mapping invented'
  pc[cl]+=1; pse=[]
  for r0,ps,safe,facts,loss in temp:
   idx=int(r0.get('slot_index') or 0); s=seq(r0.get('source_sequence'))
   sem='NO_VARIANTS' if cl==PC[0] else 'COMMON_TO_ALL_VARIANTS' if cl==PC[1] else ('SPECIFIC_VARIANT' if loss else 'VARIANT_MAPPING_UNKNOWN') if cl==PC[2] else 'VARIANT_MAPPING_UNKNOWN' if cl==PC[3] else 'VARIANT_CONFLICT'
   sc[sem]+=1; pse.append(sem); ssf=[f for f in facts if sensitive(f)]
   if sem=='COMMON_TO_ALL_VARIANTS' and not one and ssf:contamination+=len(ssf)
   slots.append({'schema_version':'v4c5.1a-variant-readiness-audit-1','product_id':p0,'slot_index':idx,'slot_role':r0.get('slot_role'),'source_sequence':s,'source_sha256':r0.get('source_sha256'),'action':r0.get('action'),'product_variant_class':cl,'scope_semantics':sem,'legacy_variant_scope':r0.get('variant_scope') or [],'safe_fact_ids':safe,'variant_sensitive_safe_fact_ids':[str(f.get('fact_id') or '') for f in ssf if f.get('fact_id')],'specific_scope_propagation_loss':loss,'mapping_invented':False,'generation_executed':False,'paid_api_called':False,'audit_only_overlay':True})
   overlay.append({'schema_version':'v4c5.1a-scope-semantics-overlay-1','product_id':p0,'slot_index':idx,'slot_role':r0.get('slot_role'),'source_sequence':s,'scope_semantics':sem,'variant_scope_source_of_truth':'AUDIT_OVERLAY_ONLY','frozen_v4c5_variant_scope_unchanged':True})
  products.append({'schema_version':'v4c5.1a-variant-readiness-audit-1','product_id':p0,'classification':cl,'classification_reason':reason,'scope_semantics':sorted(set(pse)),'ready_slot_count':len(rr),'source_sequences':seqs,'v4c0_report_file':(rep or {}).get('_report_file'),'v4c0_report_history_files':[x.get('_report_file') for x in hist.get(p0,[])],'v4c0_verdict':(rep or {}).get('verdict'),'v4c0_variant_constraints':cons,'explicit_catalog_option_count_hint':hint,'variants_proven_by_frozen_metadata':variants,'explicit_no_variants_proven':no,'single_option_only':one,'mapping_ambiguous_evidence':ambiguous,'variant_conflict_evidence':conflict,'specific_scope_loss_slot_count':len(ctr),'variant_sensitive_ready_safe_fact_count':len(sf),'mapping_invented':False,'hold_block_upgraded':False,'generation_executed':False,'paid_api_called':False})
  if len(gaps)<40 and cl!=PC[0]:gaps.append({'product_id':p0,'classification':cl,'reason':reason,'v4c0_verdict':(rep or {}).get('verdict'),'variant_constraints':cons[:8],'ready_slots':len(rr),'specific_scope_loss_slots':len(ctr)})

 if sum(pc.values())!=145 or sum(sc.values())!=549:raise RuntimeError('classification reconciliation failed')
 c=pc[PC[2]]; specific=sc['SPECIFIC_VARIANT']>0; safe_common=pc[PC[0]]+pc[PC[1]]
 if c: policy='STILL_BLOCKED'; deferred=False; resume=False; rec='V4-C5.1b Targeted Variant Scope Propagation Fix'
 elif specific: policy='MANDATORY'; deferred=False; resume=safe_common>0; rec='Specific-variant sample remains mandatory because a true SPECIFIC_VARIANT PRODUCT_READY candidate exists.'
 elif safe_common>0: policy='CONDITIONAL'; deferred=True; resume=True; rec='Specific-variant paid sample is required only when a true SPECIFIC_VARIANT PRODUCT_READY candidate exists; retain wrong-variant negative probes and variant-isolation regression, select COMMON_TO_ALL_VARIANTS when available, and exclude C/D/E from paid selection.'
 else: policy='STILL_BLOCKED'; deferred=True; resume=False; rec='No A/B audit-safe READY product exists for a paid Canary; keep Paid Canary blocked.'
 canary={'schema_version':'v4c5.1a-canary-policy-1','discovery_run_reused':DISCOVERY,'specific_variant_ready_available':specific,'specific_variant_paid_sample_requirement':policy,'variant_paid_canary_deferred':deferred,'dedicated_variant_paid_canary_required_in_future':True,'future_trigger':'first SPECIFIC_VARIANT + PRODUCT_READY candidate before bulk variant generation','wrong_variant_negative_probe_required':True,'variant_isolation_regression_required':True,'common_to_all_canary_required_when_available':pc[PC[1]]>0,'common_to_all_fact_rule':'COMMON_TO_ALL_VARIANTS may use only verified facts applicable to every variant; no single-variant color/size/quantity/style/accessory claim.','audit_safe_paid_canary_product_classes':[PC[0],PC[1]],'audit_excluded_paid_canary_product_classes':[PC[2],PC[3],PC[4]],'safe_common_canary_products':safe_common,'paid_canary_may_safely_resume_after_explicit_authorization':resume,'automatic_paid_canary_restart':False,'recommendation':rec}
 coverage={'schema_version':'v4c5.1a-coverage-1','authoritative_variant_source_used':{'primary':'frozen V4-C0 structured semantic review variant_constraints','files':report_files,'specific_scope_provenance':[P[x].as_posix() for x in ('source','semqueue','semev','bridge','calib','prog','c32img','c32queue','c4canon','c4plan','ready','memfact')],'discovery_run':DISCOVERY},'historical_variant_option_count':None,'historical_variant_option_count_claimed':2673,'historical_variant_option_count_status':'HISTORICAL_VARIANT_OPTION_COUNT_NOT_CANONICALLY_RECONCILABLE','historical_variant_option_count_reason':'Discovery 31997341246 found no durable canonical 2,673-row variant-option source; V4-C0 constraint prose is not re-expanded into guessed option rows.','v4c0_proven_variant_constrained_products':vpc,'v4c0_variant_constraint_count':vcc,'source_inventory_products':len(ip),'source_inventory_sources':len(inventory),'persistent_memory_variant_fields':memstats,'ready_products':145,'ready_slots':549,'product_class_counts':{k:pc[k] for k in PC},'slot_scope_counts':{k:sc[k] for k in SS},'specific_variant_ready_availability':specific,'c_affected_product_ids':sorted(affected),'c_affected_source_sequences':sorted(aseq),'c_affected_slots':aslots,'first_propagation_loss_stage_counts':dict(firstloss),'cross_variant_contamination':contamination,'invented_variant_mapping':0,'v4c5_queue_mutation':0,'approved_memory_mutation':0,'hold_block_upgraded':0,'locked_products_regenerated':0,'generation_executed':False,'paid_api_called':False}
 after=fps(); unchanged=before==after
 validation={'schema_version':'v4c5.1a-validation-1','passed':False,'ready_product_reconciliation':len(products)==145,'ready_slot_reconciliation':len(slots)==549,'each_product_exactly_one_class':len({x['product_id'] for x in products})==145 and all(x['classification'] in PC for x in products),'each_slot_exactly_one_scope_semantics':len(slots)==549 and all(x['scope_semantics'] in SS for x in slots),'variant_metadata_provenance_traceable':all(bool(x.get('v4c0_report_file')) or x['classification']==PC[3] for x in products),'no_invented_variant_mapping':all(not x['mapping_invented'] for x in products),'cross_variant_contamination':contamination,'hold_block_upgraded':0,'locked_products_regenerated':0,'v4c5_queue_mutation':0 if unchanged else 1,'approved_memory_mutation':0 if unchanged else 1,'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'factual_gate_retested':False,'planner_retested':False,'payload_retested':False,'memory_bootstrap_retested':False,'image_generation_called':False,'image_editing_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,'generation_executed':False,'frozen_fingerprints_unchanged':unchanged,'stable_head_expected':STABLE}
 validation['passed']=all((validation['ready_product_reconciliation'],validation['ready_slot_reconciliation'],validation['each_product_exactly_one_class'],validation['each_slot_exactly_one_scope_semantics'],validation['variant_metadata_provenance_traceable'],validation['no_invented_variant_mapping'],contamination==0,unchanged,validation['v4c5_queue_mutation']==0,validation['approved_memory_mutation']==0))
 O.mkdir(parents=True,exist_ok=True); wj(O/'coverage_summary.json',coverage); wj(O/'validation.json',validation)
 if not validation['passed']:raise RuntimeError('V4-C5.1a validation failed: '+json.dumps(validation,ensure_ascii=False))
 wjl(O/'ready_product_variant_classification.jsonl',products); wjl(O/'ready_slot_variant_classification.jsonl',slots); wjl(O/'scope_semantics_overlay.jsonl',overlay); wjl(O/'scope_propagation_trace.jsonl',traces); wjl(O/'variant_gap_examples.jsonl',gaps); wj(O/'canary_policy_recommendation.json',canary)
 lock={'schema_version':'v4c5.1a-variant-readiness-audit-lock-1','passed':True,'sealed':True,'stage':'V4-C5.1a Full Variant Classification + Scope Semantics Seal','discovery_run_reused':DISCOVERY,'broad_discovery_rerun':False,'audit_base_head':BASE,'audit_execution_head':EXEC_HEAD,'workflow_run':RUN,'stable_head_expected':STABLE,'historical_variant_option_count':None,'historical_variant_option_count_status':coverage['historical_variant_option_count_status'],'v4c0_proven_variant_constrained_products':vpc,'v4c0_variant_constraint_count':vcc,'source_inventory_products':len(ip),'source_inventory_sources':len(inventory),'persistent_memory_variant_fields':memstats,'ready_products':145,'ready_slots':549,'product_class_counts':coverage['product_class_counts'],'slot_scope_counts':coverage['slot_scope_counts'],'c_affected_product_ids':coverage['c_affected_product_ids'],'first_propagation_loss_stage_counts':coverage['first_propagation_loss_stage_counts'],'specific_variant_ready_availability':specific,'paid_canary_policy':policy,'variant_paid_canary_deferred':deferred,'dedicated_variant_paid_canary_required_in_future':True,'paid_canary_may_safely_resume_after_explicit_authorization':resume,'paid_canary_restarted':False,'v4c5_queue_mutation':0,'approved_memory_mutation':0,'generation_executed':False,'paid_api_called':False,'api_flags':{'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'factual_gate_retested':False,'planner_retested':False,'payload_retested':False,'memory_bootstrap_retested':False,'image_generation_called':False,'image_editing_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False},'frozen_fingerprints':after,'next_stage_requires_explicit_user_authorization':True}
 wj(O/'V4_C5_1A_VARIANT_READINESS_AUDIT_LOCK.json',lock)
 print(json.dumps({'passed':True,'ready_products':145,'ready_slots':549,'product_class_counts':coverage['product_class_counts'],'slot_scope_counts':coverage['slot_scope_counts'],'c_affected_product_ids':coverage['c_affected_product_ids'],'paid_canary_policy':policy,'variant_paid_canary_deferred':deferred,'paid_canary_may_resume_after_explicit_authorization':resume,'generation_executed':False,'paid_api_called':False},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
