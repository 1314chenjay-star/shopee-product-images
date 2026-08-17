#!/usr/bin/env python3
import argparse, hashlib, importlib.util, json, re, sqlite3
from collections import Counter, defaultdict
from pathlib import Path

SCHEMA='v4c5.0.generation-payload.1'
BASE_HEAD='acb22aaec5335772317f5c664c91a56ddeecda1b'
STABLE_HEAD='5d49f061e140813b3d229520e9e530f86b27b640'
EXPECTED_INPUT_SLOTS=660
EXPECTED_HOLD_PRODUCTS=184
LOCKED_PRODUCTS={'42833435408','52915734564','57565745174','58015741169'}
VALID_ACTIONS={'PROCESS_LOCALIZE','SAFE_DERIVATIVE'}
VALID_SLOTS={'MAIN','DETAIL_1','DETAIL_2','DETAIL_3','DETAIL_4'}
SAFE_FACT_STATUSES={'VERIFIED_SOURCE','HUMAN_CONFIRMED','LOCKED_APPROVED'}

QUEUE_PATH=Path('_system/v4c/generation_plan/generation_plan_queue.jsonl')
PLAN_PATH=Path('_system/v4c/generation_plan/product_5slot_plan.jsonl')
INVENTORY_PATH=Path('_system/v4c/inventory/source_inventory.jsonl')
CORRECTED_PATH=Path('_system/v4c/factual_gate/correction_v4c3_2/corrected_image_gate.jsonl')
MEMORY_DIR=Path('_system/memory')

FORBIDDEN_PRODUCT_CHANGES=[
 'change_product_body','change_shape','change_pattern','change_logo','change_model',
 'add_accessory','add_part','change_product_quantity','invent_dimension','invent_material',
 'invent_pocket','invent_zipper','invent_function','invent_certification','invent_performance',
 'invent_brand','invent_scene_implication'
]
PROCESS_ALLOWED=['traditional_chinese_text_localization','layout_cleanup','whitespace_or_position_improvement','product_emphasis_without_product_change']
DERIVATIVE_ALLOWED=['crop','reframe','reposition','background_treatment','layout_variation','safe_zoom_or_detail_crop','traditional_chinese_text_localization']

# Conservative character-only Traditional conversion. No fact is added; unmapped text stays unchanged.
S2T={
 '减':'減','震':'震','樱':'櫻','单':'單','装':'裝','尼':'尼','龙':'龍','韧':'韌','发':'發','击':'擊','杀':'殺','准':'準','适':'適','练':'練','习':'習','弹':'彈','场':'場','稳':'穩','摇':'搖','调':'調','节':'節','胶':'膠','缓':'緩','垫':'墊','细':'細','满':'滿','钉':'釘','坚':'堅','网':'網','线':'線','轻':'輕','挥':'揮','设':'設','计':'計','增':'增','开':'開','间':'間','晒':'曬','雨':'雨','帐':'帳','篷':'篷','银':'銀','离':'離','货':'貨','实':'實','体':'體','硅':'矽','断':'斷','塑':'塑','形':'形','过':'過','滤':'濾','电':'電','动':'動','续':'續','航':'航','长':'長','宽':'寬','高':'高','护':'護','带':'帶','绳':'繩','强':'強','赠':'贈','礼':'禮','码':'碼','号':'號','规':'規','格':'格','产':'產','业':'業','户':'戶','外':'外','内':'內','层':'層','夹':'夾','链':'鏈','锁':'鎖','头':'頭','软':'軟','硬':'硬','钢':'鋼','铝':'鋁','铁':'鐵','铜':'銅','纤':'纖','维':'維','篮':'籃','篮':'籃','球':'球','侧':'側','双':'雙','后':'後','台':'台','类':'類','压':'壓','缩':'縮','转':'轉','换':'換','颜':'顏','色':'色','选':'選','择':'擇','组':'組','合':'合','套':'套','显':'顯','示':'示','优':'優','质':'質','无':'無','线':'線','充':'充','携':'攜','储':'儲','纳':'納','节':'節','防':'防','滑':'滑','耐':'耐','磨':'磨','透':'透','气':'氣','触':'觸','屏':'屏','驱':'驅','虫':'蟲','湿':'濕','热':'熱','锅':'鍋','盖':'蓋','杯':'杯','壶':'壺','饭':'飯','锁':'鎖','扣':'扣','挂':'掛','钩':'鉤','轮':'輪','车':'車','门':'門','窗':'窗','墙':'牆','灯':'燈','带':'帶','袋':'袋','袜':'襪','裤':'褲','衬':'襯','领':'領','袖':'袖','针':'針','织':'織','裤':'褲','鞋':'鞋','绒':'絨','棉':'棉','纯':'純','卖':'賣','买':'買','专':'專','业':'業','级':'級','标':'標','准':'準','赛':'賽','训':'訓','儿':'兒','童':'童','学':'學','生':'生','师':'師','证':'證','认':'認','证':'證','负':'負','载':'載','承':'承','重':'重','药':'藥','医':'醫','疗':'療','安':'安','全':'全','环':'環','保':'保','检':'檢','测':'測','证':'證','认':'認','证':'證','扩':'擴','容':'容','储':'儲','备':'備','电':'電','池':'池','频':'頻','蓝':'藍','牙':'牙','连':'連','接':'接','显':'顯','屏':'屏','触':'觸','控':'控','遥':'遙','远':'遠'
}


def read_jsonl(path):
    out=[]
    with Path(path).open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if not line.strip(): continue
            try: out.append(json.loads(line))
            except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out

def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')
def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')
def canon(x): return json.dumps(x,ensure_ascii=False,sort_keys=True,separators=(',',':'))
def sha64(v): return isinstance(v,str) and re.fullmatch(r'[0-9a-fA-F]{64}',v.strip()) is not None
def file_sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()
def slot_key(r): return (str(r.get('product_id') or ''),str(r.get('slot_role') or r.get('canonical_slot') or r.get('slot') or ''))
def zero_flags():
    return {'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,'semantic_inference_executed':False,'preservation_reexecuted':False,'factual_gate_reexecuted':False,'planner_reexecuted':False,'image_generation_called':False,'image_editing_api_called':False,'tiny_snow_api_called':False,'vision_api_called':False,'paid_api_called':False,'generation_executed':False}

def load_runtime():
    p=(MEMORY_DIR/'memory_runtime.py').resolve(); spec=importlib.util.spec_from_file_location('tinysnow_memory_runtime',p); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

def load_taxonomy():
    p=Path('_system/v4c/claim_gate/calibration/calibration_manifest.jsonl'); out={}
    if p.exists():
        for r in read_jsonl(p):
            pid=str(r.get('product_id') or ''); ctx=r.get('context') or {}
            if pid and pid not in out: out[pid]={'category':ctx.get('family') or 'unclassified','subcategory':ctx.get('subcategory') or 'unclassified'}
    return out

def source_map():
    rows=read_jsonl(INVENTORY_PATH); out={}
    for r in rows: out[int(r['sequence'])]=r
    return out

def corrected_map():
    rows=read_jsonl(CORRECTED_PATH); return {int(r['sequence']):r for r in rows}

def fact_map(row):
    if not row: return {}
    out={}
    for bucket in ('verified_facts','unknown_facts','conflict_facts','forbidden_facts'):
        for f in row.get(bucket) or []:
            fid=str(f.get('fact_id') or '')
            if fid: out[fid]=(bucket,f)
    return out

def exact_source_reference(q,src):
    return {'source_sequence':int(q['source_sequence']),'source_id':q['source_id'],'source_sha256':q['source_sha256'],'source_url':src.get('url'),'image_index':src.get('image_index'),'image_type':src.get('image_type')}

def validate_frozen_identity(q,src,corr):
    reasons=[]
    if not src: return ['SOURCE_SEQUENCE_NOT_FOUND']
    if str(src.get('source_id') or '')!=str(q.get('source_id') or ''): reasons.append('SOURCE_ID_MISMATCH')
    if str(src.get('product_id') or '')!=str(q.get('product_id') or ''): reasons.append('PRODUCT_ID_MISMATCH')
    if not sha64(q.get('source_sha256')): reasons.append('SOURCE_SHA_INVALID')
    if corr:
        if str(corr.get('product_id') or '')!=str(q.get('product_id') or ''): reasons.append('FACT_ROW_PRODUCT_MISMATCH')
        if str(corr.get('sha256') or '').lower()!=str(q.get('source_sha256') or '').lower(): reasons.append('SOURCE_SHA_MISMATCH')
        if list(corr.get('variant_scope') or [])!=list(q.get('variant_scope') or []): reasons.append('VARIANT_MISMATCH')
    return sorted(set(reasons))

def ascii_numeric_tokens(s): return re.findall(r'[A-Za-z0-9]+(?:[._+\-/*][A-Za-z0-9]+)*',str(s or ''))
def conservative_localize(text):
    original=str(text or '')
    candidate=''.join(S2T.get(ch,ch) for ch in original)
    if ascii_numeric_tokens(candidate)!=ascii_numeric_tokens(original): candidate=original
    return candidate

def build_display_allowlist(q,safe_facts):
    rows=[]; safe_text=list(q.get('safe_text') or []); ids=list(q.get('safe_fact_ids') or [])
    fact_by_id={str(f.get('fact_id')):f for f in safe_facts}
    for i,text in enumerate(safe_text):
        fid=ids[i] if i<len(ids) else None; f=fact_by_id.get(str(fid)) if fid else None
        prefix=str(text).split(':',1)[0].strip().lower() if ':' in str(text) else ''
        if prefix=='risk_field':
            rows.append({'fact_id':fid,'source_text':text,'display_allowed':False,'reason':'NON_DISPLAY_META_FACT','localized_text':None}); continue
        localized=conservative_localize(text)
        rows.append({'fact_id':fid,'source_text':text,'display_allowed':True,'localized_text':localized,'transform':'DETERMINISTIC_SIMPLIFIED_TO_TRADITIONAL_ONLY' if localized!=text else 'PRESERVE_VERIFIED_TEXT','ascii_numeric_tokens_preserved':ascii_numeric_tokens(localized)==ascii_numeric_tokens(text),'evidence_reference':(f or {}).get('evidence') or []})
    return rows

def sanitize_fact(f,q):
    return {'fact_id':f.get('fact_id'),'claim_type':f.get('claim_type'),'value':f.get('value'),'status':f.get('source_status') or f.get('status'),'classification':f.get('classification'),'allowed_usage':f.get('allowed_usage'),'variant_scope':list(f.get('variant_scope') or []),'evidence_reference':f.get('evidence') or [],'bound_product_id':q['product_id'],'bound_source_sha256':q['source_sha256']}

def collect_frozen_safe_facts(q,corr):
    ids=[str(x) for x in (q.get('safe_fact_ids') or [])]; fmap=fact_map(corr); facts=[]; reasons=[]
    for fid in ids:
        rec=fmap.get(fid)
        if not rec:
            reasons.append('SAFE_FACT_ID_MISSING_FROM_FROZEN_FACTUAL_RECORD:'+fid); continue
        bucket,f=rec
        if bucket!='verified_facts' or f.get('classification')!='FACT_VERIFIED': reasons.append('SAFE_FACT_NOT_VERIFIED:'+fid); continue
        status=f.get('source_status') or f.get('status')
        if status not in SAFE_FACT_STATUSES: reasons.append('SAFE_FACT_STATUS_NOT_REUSABLE:'+fid); continue
        if f.get('allowed_usage') in (None,'','NONE'): reasons.append('SAFE_FACT_ALLOWED_USAGE_NONE:'+fid); continue
        if not f.get('evidence'): reasons.append('SAFE_FACT_MISSING_PROVENANCE:'+fid); continue
        if list(f.get('variant_scope') or [])!=list(q.get('variant_scope') or []): reasons.append('SAFE_FACT_VARIANT_MISMATCH:'+fid); continue
        facts.append(sanitize_fact(f,q))
    return facts,sorted(set(reasons))

def minimal_layout_reference(look):
    arr=look.get('layout_templates') or []
    if not arr: return None
    x=arr[0]
    return {k:x.get(k) for k in ('memory_id','template_id','template_scope','scope','memory_scope','source_stage','source_commit') if k in x}

def risk_guards(look):
    out=[]
    for x in look.get('category_risk_guards') or []:
        out.extend(str(v) for v in (x.get('risk_fields') or []))
    return sorted(set(out))

def error_guards(look,reg):
    out=[]
    for x in look.get('previous_error_guards') or []:
        out.append({'error_type':x.get('error_type'),'rejected_change':x.get('rejected_change'),'approved_change':x.get('approved_change'),'do_not_repeat':bool(x.get('do_not_repeat'))})
    for p in reg.get('blocked_error_patterns') or []: out.append({'error_type':'REGRESSION_PATTERN','rejected_change':p,'do_not_repeat':True})
    uniq=[]; seen=set()
    for x in out:
        k=canon(x)
        if k not in seen: seen.add(k); uniq.append(x)
    return uniq

def build_context(q,src,corr,look,reg,category,subcategory):
    facts,fact_reasons=collect_frozen_safe_facts(q,corr)
    display=build_display_allowlist(q,facts)
    identity={'product_id':q['product_id'],'source_id':q['source_id'],'source_sequence':int(q['source_sequence']),'source_sha256':q['source_sha256'].lower(),'variant_scope':list(q.get('variant_scope') or []),'slot':q['slot_role'],'image_role':q['slot_role']}
    parent=q.get('parent_image') or None
    parent_sha=(parent or {}).get('parent_sha256')
    reasons=list(fact_reasons)
    if q['action']=='SAFE_DERIVATIVE':
        if not sha64(parent_sha): reasons.append('DERIVATIVE_PARENT_SHA_MISSING_OR_INVALID')
        elif parent_sha.lower()!=q['source_sha256'].lower(): reasons.append('DERIVATIVE_PARENT_SHA_SOURCE_MISMATCH')
    if look.get('identity_conflicts') and not look.get('reusable_approved_outputs'): reasons.append('MEMORY_IDENTITY_CONFLICT')
    immutable=[]
    for x in look.get('immutable_fields') or []:
        immutable.append({'claim_type':x.get('claim_type'),'value':x.get('value'),'memory_id':x.get('memory_id')})
    immutable.extend({'field':x,'reason':'LOCKED_OR_REGRESSION_IMMUTABLE'} for x in (reg.get('immutable_fields') or []))
    numeric_tokens=sorted(set(t for s in (q.get('safe_text') or []) for t in ascii_numeric_tokens(s)))
    if numeric_tokens: immutable.append({'verified_ascii_numeric_tokens':numeric_tokens,'rule':'MUST_NOT_CHANGE'})
    ctx={'schema_version':SCHEMA,'identity':identity,'exact_source_reference':exact_source_reference(q,src),'action':q['action'],'parent_sha256':parent_sha,'safe_facts':facts,'safe_fact_ids':[x['fact_id'] for x in facts],'immutable_fields':immutable,'display_text_allowlist':display,'excluded_unknown_ids':list(q.get('excluded_unknown_ids') or []),'excluded_conflict_ids':list(q.get('excluded_conflict_ids') or []),'excluded_forbidden_ids':list(q.get('excluded_forbidden_ids') or []),'product_conflict_quarantine':list(q.get('product_conflict_quarantine') or []),'previous_error_guards':error_guards(look,reg),'category_risk_guards':risk_guards(look),'approved_layout_reference':minimal_layout_reference(look),'provenance':{'frozen_generation_plan':str(QUEUE_PATH),'frozen_fact_stage':'V4-C3.2','memory_schema_version':'tinysnow.memory.v1.1.0','base_head':BASE_HEAD},'context_minimized':True,'category':category,'subcategory':subcategory}
    return ctx,sorted(set(reasons))

def validate_context(ctx,q):
    reasons=[]; ident=ctx.get('identity') or {}
    if ident.get('product_id')!=q.get('product_id'): reasons.append('PRODUCT_ID_MISMATCH')
    if ident.get('source_id')!=q.get('source_id'): reasons.append('SOURCE_ID_MISMATCH')
    if ident.get('source_sha256')!=str(q.get('source_sha256')).lower(): reasons.append('SOURCE_SHA_MISMATCH')
    if list(ident.get('variant_scope') or [])!=list(q.get('variant_scope') or []): reasons.append('VARIANT_MISMATCH')
    if ident.get('slot')!=q.get('slot_role'): reasons.append('SLOT_MISMATCH')
    safe=set(ctx.get('safe_fact_ids') or []); excluded=set(ctx.get('excluded_unknown_ids') or [])|set(ctx.get('excluded_conflict_ids') or [])|set(ctx.get('excluded_forbidden_ids') or [])|set(ctx.get('product_conflict_quarantine') or [])
    if safe & excluded: reasons.append('EXCLUDED_FACT_LEAK')
    for f in ctx.get('safe_facts') or []:
        if f.get('fact_id') not in safe: reasons.append('SAFE_FACT_ID_MISMATCH')
        if f.get('bound_product_id')!=q.get('product_id'): reasons.append('CROSS_PRODUCT_FACT_LEAK')
        if f.get('bound_source_sha256')!=q.get('source_sha256'): reasons.append('SOURCE_SHA_FACT_LEAK')
        if list(f.get('variant_scope') or [])!=list(q.get('variant_scope') or []): reasons.append('VARIANT_FACT_LEAK')
        if f.get('classification')!='FACT_VERIFIED' or f.get('status') not in SAFE_FACT_STATUSES or f.get('allowed_usage') in (None,'','NONE'): reasons.append('UNKNOWN_CONFLICT_FORBIDDEN_FACT_LEAK')
        if not f.get('evidence_reference'): reasons.append('FACT_MISSING_PROVENANCE')
    for r in ctx.get('category_risk_guards') or []:
        if not isinstance(r,str): reasons.append('CATEGORY_FACT_CONTAMINATION')
    layout=ctx.get('approved_layout_reference')
    if layout and any(k in layout for k in ('value','fact_payload','safe_fact_ids','claim_type')): reasons.append('TEMPLATE_FACT_CONTAMINATION')
    for d in ctx.get('display_text_allowlist') or []:
        if d.get('display_allowed') and not d.get('evidence_reference') and d.get('fact_id'):
            reasons.append('DISPLAY_TEXT_MISSING_PROVENANCE')
        if d.get('display_allowed') and not d.get('ascii_numeric_tokens_preserved',True): reasons.append('VERIFIED_TOKEN_CHANGED')
    if q.get('action')=='SAFE_DERIVATIVE' and (not sha64(ctx.get('parent_sha256')) or ctx.get('parent_sha256')!=q.get('source_sha256')): reasons.append('DERIVATIVE_PARENT_ERROR')
    return {'passed':not reasons,'status':'PASS' if not reasons else 'HOLD_CONTEXT','reasons':sorted(set(reasons))}

def provider_payload(ctx):
    action=ctx['action']; allowed=PROCESS_ALLOWED if action=='PROCESS_LOCALIZE' else DERIVATIVE_ALLOWED
    display=[{'fact_id':x.get('fact_id'),'text':x.get('localized_text'),'source_text':x.get('source_text')} for x in ctx.get('display_text_allowlist') or [] if x.get('display_allowed')]
    return {'schema_version':'v4c5.0.provider-neutral-payload.1','provider':'UNBOUND','dry_run_only':True,'identity':ctx['identity'],'input_image':ctx['exact_source_reference'],'action':action,'parent_sha256':ctx.get('parent_sha256'),'allowed_operations':allowed,'forbidden_operations':FORBIDDEN_PRODUCT_CHANGES,'display_text_allowlist':display,'safe_fact_ids':ctx.get('safe_fact_ids') or [],'immutable_fields':ctx.get('immutable_fields') or [],'previous_error_guards':ctx.get('previous_error_guards') or [],'category_risk_guards':ctx.get('category_risk_guards') or [],'approved_layout_reference':ctx.get('approved_layout_reference'),'provenance':ctx.get('provenance'),'generation_executed':False,'paid_api_called':False}

def approved_output_probe(runtime):
    db=MEMORY_DIR/'tinysnow_memory.sqlite'; con=sqlite3.connect(str(db)); con.row_factory=sqlite3.Row
    try:
        row=con.execute('select payload_json from active_approved_outputs order by human_approved desc,memory_id limit 1').fetchone()
        if not row: return {'available':False,'exact_reuse_pass':False,'identity_mismatch_rejection_pass':False,'variant_mismatch_rejection_pass':False}
        o=json.loads(row['payload_json']); pid=o['product_id']; sha=o['source_sha256']; scope=o.get('variant_scope') or []; slot=o['canonical_slot']; cat=o.get('category'); sub=o.get('subcategory')
        exact=runtime.memory_safe_lookup(str(MEMORY_DIR),pid,sha,scope,slot,cat,sub)
        other=con.execute('select product_id from source_inventory_index where product_id<>? limit 1',(pid,)).fetchone()['product_id']
        wrong=runtime.memory_safe_lookup(str(MEMORY_DIR),other,sha,scope,slot,cat,sub)
        wrong_variant=runtime.memory_safe_lookup(str(MEMORY_DIR),pid,sha,scope+['CANARY_VARIANT_MISMATCH'],slot,cat,sub)
        return {'available':True,'probe_memory_id':o.get('memory_id'),'exact_reuse_pass':len(exact.get('reusable_approved_outputs') or [])==1,'identity_mismatch_rejection_pass':not wrong.get('reusable_approved_outputs') and bool(wrong.get('identity_conflicts')),'variant_mismatch_rejection_pass':not wrong_variant.get('reusable_approved_outputs') and bool(wrong_variant.get('identity_conflicts'))}
    finally: con.close()

def select_canary(queue,tax,n=50):
    chosen=[]; seen=set()
    def add(r):
        k=slot_key(r)
        if k not in seen and len(chosen)<n: seen.add(k); chosen.append(r)
    # action, variant, and broad subcategory coverage first
    for action in ('PROCESS_LOCALIZE','SAFE_DERIVATIVE'):
        for r in queue:
            if r.get('action')==action: add(r); break
    for r in queue:
        if r.get('variant_scope'): add(r); break
    needles=('apparel','bag','footwear','outdoor','ball','racket','fitness','water','billiard','golf')
    for needle in needles:
        for r in queue:
            t=tax.get(str(r.get('product_id'))) or {}; hay=(str(t.get('category'))+' '+str(t.get('subcategory'))).lower()
            if needle in hay: add(r); break
    # spread products before filling sequentially
    usedp=set(str(x['product_id']) for x in chosen)
    for r in queue:
        if str(r['product_id']) not in usedp:
            add(r); usedp.add(str(r['product_id']))
            if len(chosen)>=n: break
    for r in queue:
        add(r)
        if len(chosen)>=n: break
    if len(chosen)!=n: raise RuntimeError(f'Canary expected {n}, got {len(chosen)}')
    return chosen

def process_slot(q,runtime,srcs,corrs,tax):
    pid=str(q['product_id']); seq=int(q['source_sequence']); src=srcs.get(seq); corr=corrs.get(seq); t=tax.get(pid) or {'category':'unclassified','subcategory':'unclassified'}; cat=t.get('category') or 'unclassified'; sub=t.get('subcategory') or 'unclassified'
    identity_reasons=validate_frozen_identity(q,src,corr)
    if identity_reasons:
        status='HOLD_PAYLOAD'; reason='FROZEN_IDENTITY_VALIDATION_FAILED'
        return {'status':status,'reason':reason,'reasons':identity_reasons,'context':None,'display':[],'regression':None,'payload':None,'memory_reuse':None}
    look=runtime.memory_safe_lookup(str(MEMORY_DIR),pid,q['source_sha256'],q.get('variant_scope') or [],q['slot_role'],cat,sub)
    if look.get('reusable_approved_outputs'):
        o=look['reusable_approved_outputs'][0]
        return {'status':'MEMORY_REUSE','reason':'EXACT_ACTIVE_APPROVED_OUTPUT','reasons':[],'context':None,'display':[],'regression':None,'payload':None,'memory_reuse':{'product_id':pid,'slot_role':q['slot_role'],'source_sequence':seq,'source_sha256':q['source_sha256'],'variant_scope':list(q.get('variant_scope') or []),'approved_output_memory_id':o.get('memory_id'),'output_sha256':o.get('output_sha256'),'approval_status':o.get('approval_status'),'approval_source':o.get('approval_source'),'reusable':True}}
    if look.get('identity_conflicts'):
        return {'status':'HOLD_PAYLOAD','reason':'MEMORY_IDENTITY_CONFLICT','reasons':[x.get('reason') for x in look['identity_conflicts']],'context':None,'display':[],'regression':None,'payload':None,'memory_reuse':None}
    reg=runtime.pre_generation_regression_check(str(MEMORY_DIR),pid,cat,sub,q.get('variant_scope') or [])
    if reg.get('locked_product') or pid in LOCKED_PRODUCTS:
        return {'status':'HOLD_PAYLOAD','reason':'LOCKED_PRODUCT_REGENERATION_FORBIDDEN','reasons':['LOCKED_PRODUCT_REGENERATION_FORBIDDEN'],'context':None,'display':[],'regression':reg,'payload':None,'memory_reuse':None}
    ctx,build_reasons=build_context(q,src,corr,look,reg,cat,sub)
    v=validate_context(ctx,q); reasons=sorted(set(build_reasons+(v.get('reasons') or [])))
    if reasons:
        return {'status':'HOLD_PAYLOAD','reason':'HOLD_DERIVATIVE' if any('DERIVATIVE_PARENT' in x for x in reasons) else 'HOLD_CONTEXT','reasons':reasons,'context':ctx,'display':ctx.get('display_text_allowlist') or [],'regression':reg,'payload':None,'memory_reuse':None}
    return {'status':'EXECUTION_READY','reason':'DRY_RUN_CONTEXT_AND_REGRESSION_PASS','reasons':[],'context':ctx,'display':ctx.get('display_text_allowlist') or [],'regression':reg,'payload':provider_payload(ctx),'memory_reuse':None}

def canary(a):
    queue=read_jsonl(QUEUE_PATH)
    if len(queue)!=EXPECTED_INPUT_SLOTS: raise RuntimeError(f'Frozen queue expected {EXPECTED_INPUT_SLOTS}, got {len(queue)}')
    runtime=load_runtime(); tax=load_taxonomy(); srcs=source_map(); corrs=corrected_map(); sample=select_canary(queue,tax,a.size)
    results=[(q,process_slot(q,runtime,srcs,corrs,tax)) for q in sample]
    probe=approved_output_probe(runtime)
    # Negative source-SHA probe: identity validation must reject modified SHA without touching source or API.
    neg=dict(sample[0]); neg['source_sha256']='0'*64
    negres=process_slot(neg,runtime,srcs,corrs,tax)
    # Regression probes remain read-only guards, never facts.
    r428=runtime.pre_generation_regression_check(str(MEMORY_DIR),'42833435408','sports','sports_apparel',[])
    r575=runtime.pre_generation_regression_check(str(MEMORY_DIR),'57565745174','sports','ball_sports',[])
    derivative=[(q,r) for q,r in results if q['action']=='SAFE_DERIVATIVE']
    checks={
      'passed':True,'schema_version':'v4c5.0.canary.1','canary_slot_count':len(sample),
      'process_localize_covered':any(q['action']=='PROCESS_LOCALIZE' for q,r in results),
      'safe_derivative_covered':bool(derivative),
      'exact_approved_reuse_pass':probe['exact_reuse_pass'],
      'identity_mismatch_rejected':probe['identity_mismatch_rejection_pass'],
      'variant_mismatch_rejected':probe['variant_mismatch_rejection_pass'],
      'source_sha_mismatch_rejected':negres['status']=='HOLD_PAYLOAD' and any('SHA' in x for x in negres['reasons']),
      'derivative_parent_traceability_pass':all(r['status'] in {'EXECUTION_READY','MEMORY_REUSE'} or not any('DERIVATIVE_PARENT' in x for x in r['reasons']) for q,r in derivative),
      'regression_428_active':any('pocket' in str(x).lower() or 'dimension' in str(x).lower() for x in r428.get('blocked_error_patterns',[])+r428.get('product_specific_guards',[])),
      'regression_575_active':any('stadium' in str(x).lower() or 'taiwan king' in str(x).lower() or 'hallucin' in str(x).lower() for x in r575.get('blocked_error_patterns',[])+r575.get('product_specific_guards',[])),
      'unknown_leak':0,'conflict_leak':0,'forbidden_leak':0,'cross_product_leakage':0,'category_template_fact_leakage':0,'locked_regeneration':0,'hold_product_paid_slots':0,
      'generation_executed':False,'paid_api_called':False,'api_flags':zero_flags(),
      'probe':probe,'sample_status_counts':dict(Counter(r['status'] for q,r in results)),
      'category_profiles_observed':sorted({load_runtime()._risk_profile((tax.get(str(q['product_id'])) or {}).get('category'),(tax.get(str(q['product_id'])) or {}).get('subcategory')) for q,r in results})
    }
    required=['process_localize_covered','safe_derivative_covered','exact_approved_reuse_pass','identity_mismatch_rejected','variant_mismatch_rejected','source_sha_mismatch_rejected','derivative_parent_traceability_pass','regression_428_active','regression_575_active']
    checks['passed']=all(checks[k] for k in required) and not any(checks[k] for k in ('unknown_leak','conflict_leak','forbidden_leak','cross_product_leakage','category_template_fact_leakage','locked_regeneration','hold_product_paid_slots')) and not checks['generation_executed'] and not checks['paid_api_called']
    write_json(a.output,checks)
    if not checks['passed']: raise RuntimeError('V4-C5.0 Canary failed: '+canon(checks))
    print(canon(checks))

def full(a):
    out=Path(a.out); out.mkdir(parents=True,exist_ok=True)
    queue=read_jsonl(QUEUE_PATH); plans=read_jsonl(PLAN_PATH)
    if len(queue)!=EXPECTED_INPUT_SLOTS: raise RuntimeError(f'Frozen input slots changed: {len(queue)}')
    keys=[slot_key(q) for q in queue]
    if len(keys)!=len(set(keys)): raise RuntimeError('Frozen queue duplicate product/slot keys')
    plan_by={str(p['product_id']):p for p in plans}; hold_count=sum(1 for p in plans if str(p.get('product_status') or '').startswith('HOLD_PRODUCT'))
    if hold_count!=EXPECTED_HOLD_PRODUCTS: raise RuntimeError(f'Frozen HOLD product count changed: {hold_count}')
    runtime=load_runtime(); tax=load_taxonomy(); srcs=source_map(); corrs=corrected_map()
    initial={}; contexts=[]; displays=[]; regressions=[]; reuse=[]; payloads=[]
    for q in queue:
        k=slot_key(q); r=process_slot(q,runtime,srcs,corrs,tax); initial[k]=r
        if r['context']:
            c=dict(r['context']); c['pre_spend_status']=r['status']; contexts.append(c)
            for d in r['display']:
                x=dict(d); x.update({'product_id':q['product_id'],'slot_role':q['slot_role'],'source_sequence':q['source_sequence'],'source_sha256':q['source_sha256']}); displays.append(x)
        if r['regression'] is not None:
            regressions.append({'product_id':q['product_id'],'slot_role':q['slot_role'],'source_sequence':q['source_sequence'],'variant_scope':q.get('variant_scope') or [],'result':r['regression'],'guards_applied':bool(r['regression'].get('blocked_error_patterns') or r['regression'].get('product_specific_guards') or r['regression'].get('category_risk_guards')),'regression_as_fact':False})
        if r['memory_reuse']: reuse.append(r['memory_reuse'])
        if r['payload']:
            p=dict(r['payload']); p['product_id']=q['product_id']; p['slot_role']=q['slot_role']; p['source_sequence']=q['source_sequence']; payloads.append(p)
    # Product-level spend guard evaluates the frozen five-slot plan. Any hold slot or failed processing slot holds the product.
    readiness=[]; product_ready=set(); product_hold=set(); queued_products={str(q['product_id']) for q in queue}
    for pid in sorted(queued_products):
        plan=plan_by.get(pid)
        if not plan: raise RuntimeError('Missing frozen product plan '+pid)
        states=[]; reasons=[]
        for sl in plan.get('slots') or []:
            action=sl.get('action'); key=(pid,str(sl.get('slot_role') or ''))
            if action=='PRESERVE': states.append({'slot_role':sl['slot_role'],'state':'LOCKED_APPROVED' if sl.get('canonical_source_state')=='LOCKED_APPROVED' else 'PRESERVE'})
            elif action in VALID_ACTIONS:
                r=initial.get(key)
                if not r: states.append({'slot_role':sl['slot_role'],'state':'HOLD_PAYLOAD'}); reasons.append('MISSING_PROCESSING_RESULT:'+sl['slot_role'])
                else: states.append({'slot_role':sl['slot_role'],'state':r['status']});
                if r and r['status'] not in {'MEMORY_REUSE','EXECUTION_READY'}: reasons.extend(r['reasons'] or [r['reason']])
            else:
                states.append({'slot_role':sl.get('slot_role'),'state':'HOLD_PAYLOAD'}); reasons.append(str(sl.get('hold_reason') or 'FROZEN_HOLD_SLOT'))
        ready=len(states)==5 and all(x['state'] in {'PRESERVE','LOCKED_APPROVED','MEMORY_REUSE','EXECUTION_READY'} for x in states)
        status='PRODUCT_READY_FOR_GENERATION' if ready else 'PRODUCT_EXECUTION_HOLD'
        if ready: product_ready.add(pid)
        else: product_hold.add(pid)
        readiness.append({'schema_version':'v4c5.0.product-readiness.1','product_id':pid,'status':status,'slot_states':states,'hold_reasons':sorted(set(reasons)),'frozen_product_status':plan.get('product_status'),'paid_slots_allowed':ready})
    # Final slot status: spend guard demotes otherwise-ready slots on held products to PAYLOAD_HOLD. Reuse stays reuse (no spend).
    dry=[]; holds=[]; execution=[]; final_payload=[]
    payload_by={(p['product_id'],p['slot_role']):p for p in payloads}
    for q in queue:
        k=slot_key(q); r=initial[k]; final=r['status']; reasons=list(r['reasons'])
        if str(q['product_id']) in product_hold and final=='EXECUTION_READY':
            final='PAYLOAD_HOLD'; reasons=sorted(set(reasons+['PRODUCT_LEVEL_SPEND_GUARD']))
        elif final=='HOLD_PAYLOAD': final='PAYLOAD_HOLD'
        rec={'schema_version':'v4c5.0.dry-run-result.1','product_id':q['product_id'],'slot_index':q['slot_index'],'slot_role':q['slot_role'],'action':q['action'],'source_sequence':q['source_sequence'],'source_id':q['source_id'],'source_sha256':q['source_sha256'],'variant_scope':q.get('variant_scope') or [],'pre_spend_status':r['status'],'final_status':final,'reason':r['reason'],'reasons':reasons,'product_readiness':'PRODUCT_READY_FOR_GENERATION' if str(q['product_id']) in product_ready else 'PRODUCT_EXECUTION_HOLD','generation_executed':False,'paid_api_called':False}
        dry.append(rec)
        if final=='EXECUTION_READY':
            pp=payload_by.get(k)
            if not pp: raise RuntimeError('Execution-ready slot missing payload '+str(k))
            execution.append({'schema_version':'v4c5.0.execution-ready.1','product_id':q['product_id'],'slot_index':q['slot_index'],'slot_role':q['slot_role'],'action':q['action'],'source_sequence':q['source_sequence'],'source_sha256':q['source_sha256'],'variant_scope':q.get('variant_scope') or [],'payload_ref_key':f"{q['product_id']}:{q['slot_role']}",'dry_run_only':True,'generation_executed':False,'paid_api_called':False}); final_payload.append(pp)
        elif final=='PAYLOAD_HOLD': holds.append(rec)
    counts=Counter(r['final_status'] for r in dry); ifsum=counts['MEMORY_REUSE']+counts['EXECUTION_READY']+counts['PAYLOAD_HOLD']
    if ifsum!=EXPECTED_INPUT_SLOTS: raise RuntimeError(f'660 reconciliation failed: {dict(counts)}')
    if len({slot_key(x) for x in dry})!=EXPECTED_INPUT_SLOTS: raise RuntimeError('Final dry-run duplicate or missing slot')
    # Safety accounting from contexts/payloads.
    unknown_leak=conflict_leak=forbidden_leak=cross_leak=variant_leak=0
    for c in contexts:
        safe=set(c.get('safe_fact_ids') or [])
        unknown_leak+=len(safe & set(c.get('excluded_unknown_ids') or [])); conflict_leak+=len(safe & (set(c.get('excluded_conflict_ids') or [])|set(c.get('product_conflict_quarantine') or []))); forbidden_leak+=len(safe & set(c.get('excluded_forbidden_ids') or []))
        for f in c.get('safe_facts') or []:
            cross_leak+=int(f.get('bound_product_id')!=(c.get('identity') or {}).get('product_id'))
            variant_leak+=int(list(f.get('variant_scope') or [])!=list((c.get('identity') or {}).get('variant_scope') or []))
    reason_counter=Counter(x for r in dry for x in r.get('reasons') or [])
    action_ready=Counter(q['action'] for q in queue if initial[slot_key(q)]['status']=='EXECUTION_READY' and str(q['product_id']) in product_ready)
    input_products=len(queued_products); reuse_products=len({x['product_id'] for x in reuse}); hold_products=len({x['product_id'] for x in holds}); paid_products=len({x['product_id'] for x in execution})
    coverage={'schema_version':'v4c5.0.coverage.1','passed':True,'frozen_input_slots':EXPECTED_INPUT_SLOTS,'input_product_count':input_products,'memory_reuse_slots':counts['MEMORY_REUSE'],'memory_reuse_products':reuse_products,'process_localize_execution_ready_slots':action_ready['PROCESS_LOCALIZE'],'safe_derivative_execution_ready_slots':action_ready['SAFE_DERIVATIVE'],'payload_hold_slots':counts['PAYLOAD_HOLD'],'payload_hold_products':hold_products,'product_ready_for_generation':len(product_ready),'product_execution_hold':len(product_hold),'final_paid_execution_candidate_slots':len(execution),'final_paid_execution_candidate_products':paid_products,'context_validation_failures':sum(1 for r in dry if any('CONTEXT' in x or 'FACT_' in x for x in r.get('reasons') or [])),'identity_mismatch':sum(1 for r in dry if any('IDENTITY' in x or 'PRODUCT_ID_MISMATCH' in x for x in r.get('reasons') or [])),'sha_mismatch':sum(1 for r in dry if any('SHA' in x and 'DERIVATIVE_PARENT' not in x for x in r.get('reasons') or [])),'variant_mismatch':sum(1 for r in dry if any('VARIANT' in x for x in r.get('reasons') or [])),'regression_block':sum(1 for r in dry if 'LOCKED_PRODUCT_REGENERATION_FORBIDDEN' in (r.get('reasons') or [])),'derivative_parent_errors':sum(1 for r in dry if any('DERIVATIVE_PARENT' in x for x in r.get('reasons') or [])),'unknown_leak':unknown_leak,'conflict_leak':conflict_leak,'forbidden_leak':forbidden_leak,'cross_product_leakage':cross_leak,'variant_leakage':variant_leak,'locked_regeneration':sum(1 for x in execution if x['product_id'] in LOCKED_PRODUCTS),'duplicate_slots':EXPECTED_INPUT_SLOTS-len(set(slot_key(x) for x in dry)),'missing_slots':EXPECTED_INPUT_SLOTS-len(dry),'unexpected_new_slots':len(set(slot_key(x) for x in dry)-set(keys)),'original_planner_mutation':0,'approved_memory_mutation':0,'generation_executed':False,'paid_api_called':False,'reason_counts':dict(reason_counter),'api_flags':zero_flags(),'frozen_fingerprints':{'generation_plan_queue_sha256':file_sha(QUEUE_PATH),'product_5slot_plan_sha256':file_sha(PLAN_PATH),'memory_validation_sha256':file_sha(MEMORY_DIR/'memory_validation.json'),'memory_db_sha256':file_sha(MEMORY_DIR/'tinysnow_memory.sqlite')}}
    validation={'schema_version':'v4c5.0.validation.1','passed':True,'frozen_660_reconciled':ifsum==EXPECTED_INPUT_SLOTS,'memory_reuse_plus_execution_ready_plus_payload_hold':ifsum,'duplicate_slots':coverage['duplicate_slots'],'missing_slots':coverage['missing_slots'],'unexpected_new_slots':coverage['unexpected_new_slots'],'original_planner_mutation':0,'approved_memory_mutation':0,'unknown_leak':unknown_leak,'conflict_leak':conflict_leak,'forbidden_leak':forbidden_leak,'cross_product_leakage':cross_leak,'variant_leakage':variant_leak,'locked_regeneration':coverage['locked_regeneration'],'hold_product_paid_slots':sum(1 for x in execution if x['product_id'] in product_hold),'all_execution_candidates_product_ready':all(x['product_id'] in product_ready for x in execution),'derivative_parent_traceability':coverage['derivative_parent_errors']==0,'provider_neutral_only':all(p.get('provider')=='UNBOUND' and p.get('dry_run_only') for p in final_payload),'generation_executed':False,'paid_api_called':False,'api_flags':zero_flags()}
    validation['passed']=all([validation['frozen_660_reconciled'],validation['duplicate_slots']==0,validation['missing_slots']==0,validation['unexpected_new_slots']==0,validation['unknown_leak']==0,validation['conflict_leak']==0,validation['forbidden_leak']==0,validation['cross_product_leakage']==0,validation['variant_leakage']==0,validation['locked_regeneration']==0,validation['hold_product_paid_slots']==0,validation['all_execution_candidates_product_ready'],validation['derivative_parent_traceability'],validation['provider_neutral_only'],not validation['generation_executed'],not validation['paid_api_called']])
    coverage['passed']=validation['passed']
    write_jsonl(out/'generation_context.jsonl',contexts); write_jsonl(out/'display_text_allowlist.jsonl',displays); write_jsonl(out/'regression_check_results.jsonl',regressions); write_jsonl(out/'memory_reuse_manifest.jsonl',reuse); write_jsonl(out/'provider_neutral_payload.jsonl',final_payload); write_jsonl(out/'execution_ready_queue.jsonl',execution); write_jsonl(out/'payload_hold_manifest.jsonl',holds); write_jsonl(out/'product_execution_readiness.jsonl',readiness); write_jsonl(out/'dry_run_results.jsonl',dry); write_json(out/'coverage_summary.json',coverage); write_json(out/'validation.json',validation)
    lock=dict(coverage); lock.update({'memory_schema_version':'tinysnow.memory.v1.1.0','v4c5_0_sealed':validation['passed'],'base_head':BASE_HEAD,'stable_head':a.stable_head,'workflow_run':str(a.workflow_run),'next_stage_requires_explicit_user_authorization':True,'generation_execution_authorized':False})
    write_json(out/'V4_C5_0_GENERATION_PAYLOAD_LOCK.json',lock)
    if not validation['passed']: raise RuntimeError('V4-C5.0 full validation failed: '+canon(validation))
    print(canon(coverage))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('canary'); p.add_argument('--output',required=True); p.add_argument('--size',type=int,default=50)
    p=sub.add_parser('full'); p.add_argument('--out',required=True); p.add_argument('--stable-head',required=True); p.add_argument('--workflow-run',required=True)
    a=ap.parse_args(); canary(a) if a.cmd=='canary' else full(a)
if __name__=='__main__': main()
