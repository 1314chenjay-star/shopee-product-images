#!/usr/bin/env python3
import argparse, json, hashlib, re, base64, gzip
from collections import Counter, defaultdict
from pathlib import Path

SCHEMA='v4c4.0.preservation-aware-five-slot.1'
BASE_HEAD='611e78576ab64a1cca088be6041bf4885716eac5'
EXPECTED_PRODUCTS=375
EXPECTED_SOURCES=2394
EXPECTED_V4C32_QUEUE=875
LOCKED_PRODUCT_GUARDS={'42833435408','52915734564','57565745174','58015741169'}
SLOT_ROLES=['MAIN','DETAIL_1','DETAIL_2','DETAIL_3','DETAIL_4']
ACTIONS={'PRESERVE','PROCESS_LOCALIZE','SAFE_DERIVATIVE','HOLD_SLOT'}
SAFE_STATES={'LOCKED_APPROVED','PRESERVE','PROCESS_SAFE'}


def read_jsonl(path):
    p=Path(path)
    if not p.exists(): raise RuntimeError(f'Missing required input: {path}')
    out=[]
    with p.open(encoding='utf-8-sig') as f:
        for i,line in enumerate(f,1):
            if not line.strip(): continue
            try: out.append(json.loads(line))
            except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out

def read_json(path):
    p=Path(path)
    if not p.exists(): raise RuntimeError(f'Missing required input: {path}')
    return json.loads(p.read_text(encoding='utf-8-sig'))

def write_json(path,obj):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')

def write_jsonl(path,rows):
    p=Path(path); p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows: f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')

def api_flags():
    return {
      'source_download_called':False,'artifact_download_called':False,'ocr_executed':False,
      'semantic_inference_executed':False,'preservation_reexecuted':False,
      'v4c2_retested':False,'v4c3_retested':False,'v4c3_1_retested':False,'v4c3_2_retested':False,
      'image_generation_called':False,'tiny_snow_api_called':False,'vision_api_called':False,
      'paid_api_called':False,'generation_executed':False
    }

def sha_from_row(r):
    for k in ('sha256','source_sha256','content_sha256','image_sha256'):
        v=r.get(k)
        if isinstance(v,str) and re.fullmatch(r'[0-9a-fA-F]{64}',v.strip()): return v.strip().lower()
    for k in ('result','source','provenance','evidence','download'):
        v=r.get(k)
        if isinstance(v,dict):
            x=sha_from_row(v)
            if x: return x
    return None

def preserve_decision(r):
    for k in ('decision','preservation_decision','final_status','preservation_status'):
        if str(r.get(k) or '').upper()=='PRESERVE': return True
    p=r.get('preservation')
    if isinstance(p,dict):
        for k in ('decision','status','final_status'):
            if str(p.get(k) or '').upper()=='PRESERVE': return True
    return False

def seq_int(r):
    try: return int(r.get('sequence'))
    except: return None

def evidence_ref(path,seq=None,extra=None):
    x={'path':str(path)}
    if seq is not None: x['sequence']=int(seq)
    if extra: x.update(extra)
    return x

def load_taxonomy():
    p=Path('_system/v4c/claim_gate/calibration/calibration_manifest.jsonl')
    out={}
    if p.exists():
        for r in read_jsonl(p):
            pid=str(r.get('product_id') or '')
            ctx=r.get('context') or {}
            fam=ctx.get('family'); sub=ctx.get('subcategory')
            if pid and (fam or sub): out[pid]={'family':fam,'subcategory':sub}
    return out

def build_approval_map(inventory_by_product):
    approved={}
    approval_files=[]
    for p in sorted(Path('_system/tests/evidence').glob('*acceptance*.json')):
        try: obj=read_json(p)
        except Exception: continue
        if not obj.get('do_not_rerun'): continue
        pid=str(obj.get('product_id') or '')
        slots=obj.get('slots') or {}
        if not pid or not isinstance(slots,dict): continue
        accepted_here=0
        for key,v in slots.items():
            if not isinstance(v,dict) or str(v.get('human_visual_result') or '').lower()!='pass': continue
            try: idx=int(v.get('source_index'))
            except: continue
            candidates=[r for r in inventory_by_product.get(pid,[]) if int(r.get('image_index',-999))==idx]
            if len(candidates)!=1: continue
            src=candidates[0]; seq=int(src['sequence'])
            outsha=str(v.get('output_sha256') or '').lower()
            if not re.fullmatch(r'[0-9a-f]{64}',outsha): continue
            role={'main':'MAIN','detail1':'DETAIL_1','detail2':'DETAIL_2','detail3':'DETAIL_3','detail4':'DETAIL_4'}.get(str(key).lower())
            if not role: continue
            approved[seq]={
              'approval_file':str(p),'approval_status':obj.get('status'),'approved_slot_role':role,
              'approved_output_sha256':outsha,'approval_run_id':str(v.get('run_id') or ''),
              'approval_head_sha':str(v.get('head_sha') or ''),'human_visual_result':'pass'
            }
            accepted_here+=1
        if accepted_here: approval_files.append({'path':str(p),'product_id':pid,'accepted_slots':accepted_here})
    return approved,approval_files

def collect_preserve_sequences():
    origins=defaultdict(list)
    direct=[
      '_system/v4c/preservation/results/image_preservation.jsonl',
      '_system/v4c/closeout/canonical_ledger.jsonl',
      '_system/v4c/evidence_hydration/evidence.jsonl',
      '_system/v4c/evidence_hydration/bartifact_recovery/materialized_evidence.jsonl',
      '_system/v4c/evidence_hydration/source_fallback/evidence.jsonl'
    ]
    for path in direct:
        p=Path(path)
        if not p.exists(): continue
        for r in read_jsonl(p):
            s=seq_int(r)
            if s is not None and preserve_decision(r): origins[s].append(evidence_ref(path,s))
    return origins

def prepare(args):
    inventory=read_jsonl(args.inventory)
    progress=read_jsonl(args.progress)
    duplicates=read_json(args.duplicates)
    closeout=read_jsonl(args.closeout)
    corrected_images=read_jsonl(args.corrected_images)
    corrected_queue=read_jsonl(args.corrected_queue)
    c32_summary=read_json(args.c32_summary)
    if len(inventory)!=EXPECTED_SOURCES: raise RuntimeError(f'BLOCK_RECONCILIATION: expected {EXPECTED_SOURCES} source images, got {len(inventory)}')
    seqs=[int(r['sequence']) for r in inventory]
    if sorted(seqs)!=list(range(1,EXPECTED_SOURCES+1)) or len(set(seqs))!=EXPECTED_SOURCES:
        raise RuntimeError('BLOCK_RECONCILIATION: source sequences are not exactly contiguous 1..2394')
    products={str(r.get('product_id') or '') for r in inventory}
    if '' in products: raise RuntimeError('BLOCK_RECONCILIATION: blank product_id in source inventory')
    if len(products)!=EXPECTED_PRODUCTS: raise RuntimeError(f'BLOCK_RECONCILIATION: expected {EXPECTED_PRODUCTS} products, got {len(products)}')
    if len(corrected_queue)!=EXPECTED_V4C32_QUEUE or int(c32_summary.get('generation_queue_count',-1))!=EXPECTED_V4C32_QUEUE:
        raise RuntimeError('BLOCK_RECONCILIATION: V4-C3.2 queue count changed')

    inv_by_seq={int(r['sequence']):dict(r) for r in inventory}
    inv_by_product=defaultdict(list)
    for r in inventory: inv_by_product[str(r['product_id'])].append(r)
    prog_by_seq={int(r['sequence']):r for r in progress if seq_int(r) is not None}
    sha_by_seq={s:sha_from_row(prog_by_seq.get(s,{})) for s in inv_by_seq}
    dup_alias={int(x['sequence']):int(x['canonical_sequence']) for x in duplicates.get('sha256_duplicates',[]) or []}
    dup_sha={int(x['sequence']):str(x.get('sha256') or '').lower() for x in duplicates.get('sha256_duplicates',[]) or []}
    if len(dup_alias)!=4: raise RuntimeError(f'BLOCK_RECONCILIATION: expected 4 SHA aliases, got {len(dup_alias)}')
    for s,sh in dup_sha.items():
        if not sha_by_seq.get(s) and re.fullmatch(r'[0-9a-f]{64}',sh): sha_by_seq[s]=sh
    missing_sha=[s for s,v in sha_by_seq.items() if not v]
    if missing_sha: raise RuntimeError(f'BLOCK_RECONCILIATION: {len(missing_sha)} source sequences lack frozen SHA256; first={missing_sha[:10]}')

    preserve_origins=collect_preserve_sequences()
    approvals,approval_files=build_approval_map(inv_by_product)
    q_by_seq={int(r['sequence']):r for r in corrected_queue}
    ci_by_seq={int(r['sequence']):r for r in corrected_images}
    close_by_seq={int(r['sequence']):r for r in closeout}
    if len(q_by_seq)!=EXPECTED_V4C32_QUEUE: raise RuntimeError('Duplicate sequence in V4-C3.2 queue')

    canonical=[]; base_counts=Counter(); locked_guard_products_present=set()
    for s in range(1,EXPECTED_SOURCES+1):
        inv=inv_by_seq[s]; pid=str(inv['product_id']); sha=sha_by_seq[s]
        row={
          'schema_version':SCHEMA,'sequence':s,'source_id':str(inv.get('source_id') or f'V4C-S{s:06d}'),
          'product_id':pid,'image_index':inv.get('image_index'),'image_type':inv.get('image_type'),
          'source_url':inv.get('url'),'source_sha256':sha,'source_action':inv.get('source_action'),
          'canonical_state':None,'underlying_state':None,'state_reason':None,'state_evidence_references':[],
          'safe_fact_ids':[],'safe_text':[],'excluded_unknown_ids':[],'excluded_conflict_ids':[],
          'excluded_forbidden_ids':[],'variant_scope':[],'product_conflict_quarantine':[],
          'approved_output_sha256':None,'approved_slot_role':None,'duplicate_canonical_sequence':None,
          'do_not_regenerate':False,'selected_for_final_5slot':False
        }
        if s in approvals:
            ap=approvals[s]; row.update({'canonical_state':'LOCKED_APPROVED','underlying_state':'LOCKED_APPROVED',
              'state_reason':'DURABLE_HUMAN_VISUAL_ACCEPTANCE','state_evidence_references':[evidence_ref(ap['approval_file'],s,{'run_id':ap['approval_run_id']})],
              'approved_output_sha256':ap['approved_output_sha256'],'approved_slot_role':ap['approved_slot_role'],'do_not_regenerate':True})
        elif s in dup_alias:
            row.update({'canonical_state':'DUPLICATE_ALIAS','underlying_state':'DUPLICATE_ALIAS','state_reason':'FROZEN_SHA_DUPLICATE_ALIAS',
              'duplicate_canonical_sequence':dup_alias[s],'state_evidence_references':[evidence_ref(args.duplicates,s,{'canonical_sequence':dup_alias[s]})],
              'do_not_regenerate':True})
        elif pid in LOCKED_PRODUCT_GUARDS:
            locked_guard_products_present.add(pid)
            row.update({'canonical_state':'HOLD','underlying_state':'HOLD','state_reason':'LOCKED_PRODUCT_GUARD_WITHOUT_DURABLE_SLOT_APPROVAL_FOR_THIS_SOURCE',
              'state_evidence_references':[{'policy':'LOCKED_PRODUCT_DO_NOT_RERUN','product_id':pid}],'do_not_regenerate':True})
        elif s in preserve_origins:
            row.update({'canonical_state':'PRESERVE','underlying_state':'PRESERVE','state_reason':'FROZEN_PRESERVATION_PASS',
              'state_evidence_references':preserve_origins[s],'do_not_regenerate':True})
        elif s in q_by_seq:
            q=q_by_seq[s]
            row.update({'canonical_state':'PROCESS_SAFE','underlying_state':'PROCESS_SAFE','state_reason':'V4_C3_2_CORRECTED_GENERATION_CANDIDATE',
              'state_evidence_references':[evidence_ref(args.corrected_queue,s)],'safe_fact_ids':list(q.get('safe_fact_ids') or []),
              'safe_text':list(q.get('safe_text') or []),'excluded_unknown_ids':list(q.get('excluded_unknown_fact_ids') or []),
              'excluded_conflict_ids':list(q.get('excluded_conflict_fact_ids') or []),'excluded_forbidden_ids':list(q.get('excluded_forbidden_fact_ids') or []),
              'variant_scope':list(q.get('variant_scope') or []),'product_conflict_quarantine':list(q.get('product_conflict_quarantine') or [])})
        else:
            ci=ci_by_seq.get(s); co=close_by_seq.get(s)
            if ci and ci.get('generation_eligibility')=='BLOCK_FACTUAL':
                st='BLOCK'; reason='V4_C3_2_BLOCK_FACTUAL'
            elif co and co.get('final_status')=='BLOCK_FINAL':
                st='BLOCK'; reason='V4_C2_BLOCK_FINAL'
            elif co and co.get('final_status')=='HOLD_FINAL':
                st='HOLD'; reason='V4_C2_HOLD_FINAL'
            else:
                st='HOLD'; reason='NO_FROZEN_PRESERVE_OR_V4_C3_2_PROCESS_SAFE_AUTHORIZATION'
            refs=[]
            if ci: refs.append(evidence_ref(args.corrected_images,s))
            if co: refs.append(evidence_ref(args.closeout,s))
            row.update({'canonical_state':st,'underlying_state':st,'state_reason':reason,'state_evidence_references':refs,'do_not_regenerate':st in {'BLOCK'}})
        base_counts[row['underlying_state']]+=1
        canonical.append(row)

    # Ensure authoritative corrected queue is represented only as safe or deliberately locked by higher priority.
    q_state=Counter(next(r for r in canonical if r['sequence']==s)['canonical_state'] for s in q_by_seq)
    unexpected={k:v for k,v in q_state.items() if k not in {'PROCESS_SAFE','LOCKED_APPROVED','PRESERVE','HOLD'}}
    if unexpected: raise RuntimeError(f'Corrected queue reconciled to unexpected states: {unexpected}')

    taxonomy=load_taxonomy()
    write_jsonl(args.base_state,canonical)
    prep={
      'schema_version':'v4c4.0.prepare.1','passed':True,'authoritative_product_count':len(products),
      'authoritative_source_image_count':len(inventory),'base_state_counts':dict(base_counts),
      'global_preserve_underlying_count':base_counts['PRESERVE'],'locked_approved_count':base_counts['LOCKED_APPROVED'],
      'raw_v4c3_2_generation_candidate_count':len(corrected_queue),'canonical_process_safe_count':base_counts['PROCESS_SAFE'],
      'duplicate_alias_count':base_counts['DUPLICATE_ALIAS'],'locked_product_guards':sorted(LOCKED_PRODUCT_GUARDS),
      'locked_product_guards_present':sorted(LOCKED_PRODUCT_GUARDS & products),'locked_approval_files':approval_files,
      'taxonomy_products_observable':len(taxonomy),'api_flags':api_flags()
    }
    write_json(args.prepare_summary,prep)
    print(json.dumps(prep,ensure_ascii=False,sort_keys=True))

def candidate_priority(r,role=None):
    rank={'LOCKED_APPROVED':0,'PRESERVE':1,'PROCESS_SAFE':2}.get(r.get('underlying_state'),9)
    approved_role=0 if role and r.get('approved_slot_role')==role else 1
    main_bonus=0 if role=='MAIN' and int(r.get('image_index') or 0)==0 else 1
    evidence_score=-(len(r.get('safe_fact_ids') or []) + len(r.get('state_evidence_references') or []))
    scope_penalty=0 if not r.get('variant_scope') else 1
    return (approved_role,rank,main_bonus,evidence_score,scope_penalty,int(r['sequence']))

def direct_slot(role,r):
    state=r['underlying_state']
    action='PRESERVE' if state in {'LOCKED_APPROVED','PRESERVE'} else 'PROCESS_LOCALIZE'
    return {
      'slot_index':SLOT_ROLES.index(role)+1,'slot_role':role,'source_sequence':int(r['sequence']),
      'source_id':r['source_id'],'source_sha256':r['source_sha256'],'action':action,'canonical_source_state':state,
      'factual_evidence_reference':list(r.get('state_evidence_references') or []),'safe_fact_ids':list(r.get('safe_fact_ids') or []),
      'safe_text':list(r.get('safe_text') or []),'excluded_unknown_ids':list(r.get('excluded_unknown_ids') or []),
      'excluded_conflict_ids':list(r.get('excluded_conflict_ids') or []),'excluded_forbidden_ids':list(r.get('excluded_forbidden_ids') or []),
      'variant_scope':list(r.get('variant_scope') or []),'product_conflict_quarantine':list(r.get('product_conflict_quarantine') or []),
      'parent_image':None,'approved_output_sha256':r.get('approved_output_sha256'),'do_not_regenerate':action=='PRESERVE'
    }

def derivative_slot(role,parent):
    return {
      'slot_index':SLOT_ROLES.index(role)+1,'slot_role':role,'source_sequence':int(parent['sequence']),
      'source_id':parent['source_id'],'source_sha256':parent['source_sha256'],'action':'SAFE_DERIVATIVE','canonical_source_state':parent['underlying_state'],
      'factual_evidence_reference':list(parent.get('state_evidence_references') or []),
      'safe_fact_ids':list(parent.get('safe_fact_ids') or []),'safe_text':list(parent.get('safe_text') or []),
      'excluded_unknown_ids':list(parent.get('excluded_unknown_ids') or []),'excluded_conflict_ids':list(parent.get('excluded_conflict_ids') or []),
      'excluded_forbidden_ids':list(parent.get('excluded_forbidden_ids') or []),'variant_scope':list(parent.get('variant_scope') or []),
      'product_conflict_quarantine':list(parent.get('product_conflict_quarantine') or []),
      'parent_image':{'source_sequence':int(parent['sequence']),'source_id':parent['source_id'],'parent_sha256':parent['source_sha256'],
                      'approved_output_sha256':parent.get('approved_output_sha256')},
      'approved_output_sha256':None,'derivative_policy':['crop','reframe','layout','background_or_composition_variation','traditional_chinese_localization_only'],
      'forbidden_derivative_additions':['size','material','brand','accessory','function','count','certification','performance','new_scene_implication'],
      'do_not_regenerate':False
    }

def hold_slot(role,source=None,reason='HOLD_PRODUCT_INSUFFICIENT_SAFE_IMAGES'):
    return {
      'slot_index':SLOT_ROLES.index(role)+1,'slot_role':role,'source_sequence':int(source['sequence']) if source else None,
      'source_id':source.get('source_id') if source else None,'source_sha256':source.get('source_sha256') if source else None,
      'action':'HOLD_SLOT','canonical_source_state':source.get('underlying_state') if source else 'HOLD',
      'factual_evidence_reference':list(source.get('state_evidence_references') or []) if source else [],
      'safe_fact_ids':[],'safe_text':[],'excluded_unknown_ids':[],'excluded_conflict_ids':[],
      'excluded_forbidden_ids':[],'variant_scope':[],'product_conflict_quarantine':[],
      'parent_image':None,'hold_reason':reason,'do_not_regenerate':True
    }

def plan_product(pid,items):
    items=sorted(items,key=lambda r:int(r['sequence']))
    approved=[r for r in items if r['underlying_state']=='LOCKED_APPROVED']
    locked_guard=pid in LOCKED_PRODUCT_GUARDS
    slots=[]; used=set(); selected_direct=[]
    if locked_guard:
        byrole={r.get('approved_slot_role'):r for r in approved if r.get('approved_slot_role')}
        if all(role in byrole for role in SLOT_ROLES):
            for role in SLOT_ROLES:
                r=byrole[role]; slots.append(direct_slot(role,r)); used.add(int(r['sequence'])); selected_direct.append(int(r['sequence']))
            status='READY_5_SLOT'
        else:
            for i,role in enumerate(SLOT_ROLES):
                src=items[i] if i<len(items) else None
                slots.append(hold_slot(role,src,'HOLD_PRODUCT_LOCKED_APPROVAL_NOT_MATERIALIZED'))
            status='HOLD_PRODUCT_LOCKED_APPROVAL_NOT_MATERIALIZED'
        return {'schema_version':SCHEMA,'product_id':pid,'product_status':status,'locked_product_guard':True,
                'source_image_count':len(items),'safe_source_count':len([x for x in items if x['underlying_state'] in SAFE_STATES]),
                'slots':slots,'selected_direct_sequences':selected_direct,'safe_not_selected_sequences':[],
                'derivative_slot_count':sum(1 for x in slots if x['action']=='SAFE_DERIVATIVE')}

    safe=[r for r in items if r['underlying_state'] in SAFE_STATES]
    # Assign direct sources, preserving approved role and preferring original main for MAIN.
    remaining=list(safe)
    for role in SLOT_ROLES:
        if not remaining: break
        remaining.sort(key=lambda r:candidate_priority(r,role))
        r=remaining.pop(0)
        slots.append(direct_slot(role,r)); used.add(int(r['sequence'])); selected_direct.append(int(r['sequence']))
    # If fewer than five safe direct sources, only derive from already verified/preserved safe sources.
    if len(slots)<5 and safe:
        parents=sorted(safe,key=lambda r:candidate_priority(r,None))
        pi=0
        while len(slots)<5:
            role=SLOT_ROLES[len(slots)]
            parent=parents[pi % len(parents)]; pi+=1
            slots.append(derivative_slot(role,parent))
    if len(slots)<5:
        while len(slots)<5:
            role=SLOT_ROLES[len(slots)]
            src=items[len(slots)] if len(slots)<len(items) else None
            slots.append(hold_slot(role,src))
    status='READY_5_SLOT' if all(x['action']!='HOLD_SLOT' for x in slots) else 'HOLD_PRODUCT_INSUFFICIENT_SAFE_IMAGES'
    nonselected=[int(r['sequence']) for r in safe if int(r['sequence']) not in used]
    return {'schema_version':SCHEMA,'product_id':pid,'product_status':status,'locked_product_guard':False,
            'source_image_count':len(items),'safe_source_count':len(safe),'slots':slots,
            'selected_direct_sequences':selected_direct,'safe_not_selected_sequences':nonselected,
            'derivative_slot_count':sum(1 for x in slots if x['action']=='SAFE_DERIVATIVE')}

def features_for_product(pid,items,plan,taxonomy):
    states=Counter(x['underlying_state'] for x in items)
    safe=states['LOCKED_APPROVED']+states['PRESERVE']+states['PROCESS_SAFE']
    return {
      'all_five_preserve_or_locked':len(plan['slots'])==5 and all(x['action']=='PRESERVE' for x in plan['slots']),
      'partial_preserve_plus_process':states['PRESERVE']+states['LOCKED_APPROVED']>0 and states['PROCESS_SAFE']>0,
      'safe_exactly_five':safe==5,'safe_more_than_five':safe>5,'safe_less_than_five_derivative':0<safe<5 and plan['derivative_slot_count']>0,
      'hold_product':plan['product_status'].startswith('HOLD_PRODUCT'),'has_true_conflict_image':states['BLOCK']>0,
      'variant_product':any(bool(x.get('variant_scope')) for x in items),'locked_product':pid in LOCKED_PRODUCT_GUARDS,
      'family':(taxonomy.get(pid) or {}).get('family'),'subcategory':(taxonomy.get(pid) or {}).get('subcategory')
    }

def select_canary(base_state,n=25):
    byprod=defaultdict(list)
    for r in base_state: byprod[r['product_id']].append(r)
    taxonomy=load_taxonomy(); plans={pid:plan_product(pid,items) for pid,items in byprod.items()}
    feat={pid:features_for_product(pid,byprod[pid],plans[pid],taxonomy) for pid in byprod}
    selected=[]; reasons=defaultdict(list)
    def take(predicate,reason):
        for pid in sorted(byprod):
            if pid in selected: continue
            if predicate(pid): selected.append(pid); reasons[pid].append(reason); return pid
        return None
    required=[
      ('all_five_preserve_or_locked',lambda p:feat[p]['all_five_preserve_or_locked']),
      ('partial_preserve_plus_process',lambda p:feat[p]['partial_preserve_plus_process']),
      ('safe_exactly_five',lambda p:feat[p]['safe_exactly_five']),
      ('safe_more_than_five',lambda p:feat[p]['safe_more_than_five']),
      ('safe_less_than_five_derivative',lambda p:feat[p]['safe_less_than_five_derivative']),
      ('hold_product',lambda p:feat[p]['hold_product']),
      ('true_conflict_product',lambda p:feat[p]['has_true_conflict_image']),
      ('variant_product',lambda p:feat[p]['variant_product']),
      ('locked_product',lambda p:feat[p]['locked_product'])]
    observed={}
    for name,pred in required: observed[name]=take(pred,name)
    # Add frozen subcategory diversity without inferring new categories.
    seen_sub={feat[p]['subcategory'] for p in selected if feat[p]['subcategory']}
    for sub in sorted({v.get('subcategory') for v in taxonomy.values() if v.get('subcategory')}):
        if len(selected)>=n: break
        if sub in seen_sub: continue
        p=take(lambda x,s=sub:feat[x]['subcategory']==s,f'subcategory:{sub}')
        if p: seen_sub.add(sub)
    # Fill with diverse state signatures deterministically.
    signatures=set()
    for p in selected:
        signatures.add(tuple(sorted(Counter(x['underlying_state'] for x in byprod[p]).items())))
    for pid in sorted(byprod):
        if len(selected)>=n: break
        if pid in selected: continue
        sig=tuple(sorted(Counter(x['underlying_state'] for x in byprod[pid]).items()))
        if sig not in signatures:
            selected.append(pid); reasons[pid].append('state_signature_diversity'); signatures.add(sig)
    for pid in sorted(byprod):
        if len(selected)>=n: break
        if pid not in selected:
            selected.append(pid); reasons[pid].append('deterministic_fill')
    return selected,{p:{'reasons':reasons[p],'features':feat[p]} for p in selected},observed

def validate_plan_rows(plans,base_by_seq,require_all_products=False):
    unknown_leak=conflict_leak=forbidden_leak=block_selected=locked_regen=duplicate_direct=0
    total_slots=0
    for p in plans:
        slots=p.get('slots') or []; total_slots+=len(slots)
        if len(slots)!=5 or [x.get('slot_role') for x in slots]!=SLOT_ROLES:
            raise RuntimeError(f'Exactly-five slot reconciliation failed product {p.get("product_id")}')
        direct=[]
        for sl in slots:
            if sl.get('action') not in ACTIONS: raise RuntimeError(f'Invalid action {sl.get("action")}')
            if sl.get('action') in {'PROCESS_LOCALIZE','SAFE_DERIVATIVE'}:
                if sl.get('excluded_unknown_ids') and any(x in set(sl.get('safe_fact_ids') or []) for x in sl.get('excluded_unknown_ids') or []): unknown_leak+=1
                if sl.get('excluded_conflict_ids') and any(x in set(sl.get('safe_fact_ids') or []) for x in sl.get('excluded_conflict_ids') or []): conflict_leak+=1
                if sl.get('excluded_forbidden_ids') and any(x in set(sl.get('safe_fact_ids') or []) for x in sl.get('excluded_forbidden_ids') or []): forbidden_leak+=1
            seq=sl.get('source_sequence')
            if seq is not None:
                src=base_by_seq.get(int(seq))
                if not src: raise RuntimeError(f'Slot source sequence missing from canonical state: {seq}')
                if sl.get('source_id')!=src.get('source_id') or sl.get('source_sha256')!=src.get('source_sha256'):
                    raise RuntimeError(f'SHA/source traceability mismatch product {p.get("product_id")} seq {seq}')
                if src.get('underlying_state')=='BLOCK' and sl.get('action')!='HOLD_SLOT': block_selected+=1
                if sl.get('action')!='SAFE_DERIVATIVE' and sl.get('action')!='HOLD_SLOT': direct.append(int(seq))
            if p.get('locked_product_guard') and sl.get('action') in {'PROCESS_LOCALIZE','SAFE_DERIVATIVE'}: locked_regen+=1
            if sl.get('action')=='SAFE_DERIVATIVE':
                par=sl.get('parent_image') or {}
                if par.get('parent_sha256')!=sl.get('source_sha256'): raise RuntimeError('Derivative parent SHA traceability failed')
        duplicate_direct += len(direct)-len(set(direct))
    return {'unknown_leak':unknown_leak,'conflict_leak':conflict_leak,'forbidden_leak':forbidden_leak,
            'block_factual_selected':block_selected,'locked_product_regeneration':locked_regen,'duplicate_direct_slot_assignment':duplicate_direct,
            'total_slots':total_slots}

def canary(args):
    base=read_jsonl(args.base_state); byprod=defaultdict(list)
    for r in base: byprod[r['product_id']].append(r)
    ids,meta,observed=select_canary(base,args.canary_size)
    plans=[plan_product(pid,byprod[pid]) for pid in ids]
    base_by_seq={int(r['sequence']):r for r in base}
    checks=validate_plan_rows(plans,base_by_seq)
    allpres=any(all(x['action']=='PRESERVE' for x in p['slots']) for p in plans)
    partial=any(meta[p['product_id']]['features']['partial_preserve_plus_process'] for p in plans)
    exact5=any(meta[p['product_id']]['features']['safe_exactly_five'] for p in plans)
    deriv=any(any(x['action']=='SAFE_DERIVATIVE' for x in p['slots']) for p in plans)
    hold=any(p['product_status'].startswith('HOLD_PRODUCT') for p in plans)
    trueconf=any(meta[p['product_id']]['features']['has_true_conflict_image'] for p in plans)
    variant=any(meta[p['product_id']]['features']['variant_product'] for p in plans)
    locked=any(p['locked_product_guard'] for p in plans)
    subcats=sorted({meta[p['product_id']]['features'].get('subcategory') for p in plans if meta[p['product_id']]['features'].get('subcategory')})
    must={'all_five_preserve':allpres,'partial_preserve_plus_process':partial,'exactly_five_safe':exact5,
          'safe_derivative_case':deriv,'hold_case':hold,'true_conflict_case':trueconf,'variant_case':variant,'locked_case':locked,
          'frozen_subcategory_diversity_count':len(subcats)}
    failed=[k for k,v in must.items() if k!='frozen_subcategory_diversity_count' and v is not True]
    # At least 3 distinct frozen subcategories where observable; no semantic inference is introduced here.
    if len(subcats)<3: failed.append('frozen_subcategory_diversity_count<3')
    if any(checks[k] for k in ('unknown_leak','conflict_leak','forbidden_leak','block_factual_selected','locked_product_regeneration','duplicate_direct_slot_assignment')):
        failed.append('safety_check_nonzero')
    if failed: raise RuntimeError('V4-C4.0 Canary failed: '+','.join(failed))
    write_jsonl(args.canary_manifest,[{'product_id':p,'reasons':meta[p]['reasons'],'features':meta[p]['features']} for p in ids])
    write_jsonl(args.canary_plan,plans)
    val={'schema_version':'v4c4.0.canary-validation.1','passed':True,'input_products':len(ids),'exactly_five_slot_reconciliation':True,
         'sha_source_traceability':True,'duplicate_not_selected_twice':checks['duplicate_direct_slot_assignment']==0,
         'unknown_leak':checks['unknown_leak'],'conflict_leak':checks['conflict_leak'],'forbidden_leak':checks['forbidden_leak'],
         'block_factual_selected':checks['block_factual_selected'],'locked_product_regeneration':checks['locked_product_regeneration'],
         'paid_generation_executed':False,'representative_cases':must,'frozen_subcategories':subcats,'observed_case_product_ids':observed,'api_flags':api_flags()}
    write_json(args.canary_validation,val); print(json.dumps(val,ensure_ascii=False,sort_keys=True))

def full(args):
    base=read_jsonl(args.base_state); prep=read_json(args.prepare_summary); can=read_json(args.canary_validation)
    if not can.get('passed'): raise RuntimeError('Canary is not PASS')
    byprod=defaultdict(list)
    for r in base: byprod[r['product_id']].append(r)
    if len(byprod)!=EXPECTED_PRODUCTS: raise RuntimeError('Full planner product reconciliation changed')
    plans=[plan_product(pid,byprod[pid]) for pid in sorted(byprod)]
    base_by_seq={int(r['sequence']):dict(r) for r in base}
    checks=validate_plan_rows(plans,base_by_seq,True)
    if any(checks[k] for k in ('unknown_leak','conflict_leak','forbidden_leak','block_factual_selected','locked_product_regeneration','duplicate_direct_slot_assignment')):
        raise RuntimeError(f'Full planning safety check failed: {checks}')

    selected=set(); safe_not_selected=set()
    for p in plans:
        selected.update(int(x) for x in p.get('selected_direct_sequences') or [])
        safe_not_selected.update(int(x) for x in p.get('safe_not_selected_sequences') or [])
    canonical=[]
    for s in sorted(base_by_seq):
        r=base_by_seq[s]
        if s in selected: r['selected_for_final_5slot']=True
        if s in safe_not_selected and r['underlying_state'] in SAFE_STATES:
            r['canonical_state']='SAFE_NOT_SELECTED'; r['state_reason']='SAFE_SOURCE_NOT_SELECTED_FOR_EXACTLY_FIVE_PLAN'; r['do_not_regenerate']=True
        canonical.append(r)
    if len(canonical)!=EXPECTED_SOURCES or len({int(x['sequence']) for x in canonical})!=EXPECTED_SOURCES:
        raise RuntimeError('Canonical image state reconciliation failed')

    preserve_manifest=[]
    for r in canonical:
        if r['underlying_state'] in {'LOCKED_APPROVED','PRESERVE'}:
            preserve_manifest.append({'schema_version':SCHEMA,'sequence':r['sequence'],'source_id':r['source_id'],'product_id':r['product_id'],
              'source_sha256':r['source_sha256'],'preserve_class':r['underlying_state'],'selected_for_final_5slot':r['selected_for_final_5slot'],
              'approved_output_sha256':r.get('approved_output_sha256'),'evidence_references':r.get('state_evidence_references') or [],'do_not_regenerate':True})

    queue=[]; holds=[]; slot_action=Counter(); queue_products=set(); ready=holdp=0
    for p in plans:
        if p['product_status']=='READY_5_SLOT': ready+=1
        else:
            holdp+=1; holds.append({'record_type':'PRODUCT','product_id':p['product_id'],'status':p['product_status'],'locked_product_guard':p['locked_product_guard']})
        for sl in p['slots']:
            slot_action[sl['action']]+=1
            if sl['action'] in {'PROCESS_LOCALIZE','SAFE_DERIVATIVE'}:
                q={'schema_version':'v4c4.0.generation-plan-queue.1','product_id':p['product_id'],'slot_index':sl['slot_index'],'slot_role':sl['slot_role'],
                   'action':sl['action'],'source_sequence':sl['source_sequence'],'source_id':sl['source_id'],'source_sha256':sl['source_sha256'],
                   'safe_fact_ids':sl['safe_fact_ids'],'safe_text':sl['safe_text'],'excluded_unknown_ids':sl['excluded_unknown_ids'],
                   'excluded_conflict_ids':sl['excluded_conflict_ids'],'excluded_forbidden_ids':sl['excluded_forbidden_ids'],
                   'product_conflict_quarantine':sl['product_conflict_quarantine'],'variant_scope':sl['variant_scope'],'parent_image':sl.get('parent_image'),
                   'planning_only':True,'generation_executed':False}
                queue.append(q); queue_products.add(p['product_id'])
    for r in canonical:
        if r['canonical_state'] in {'HOLD','BLOCK','DUPLICATE_ALIAS'}:
            holds.append({'record_type':'IMAGE','sequence':r['sequence'],'source_id':r['source_id'],'product_id':r['product_id'],
                          'source_sha256':r['source_sha256'],'state':r['canonical_state'],'reason':r['state_reason'],
                          'duplicate_canonical_sequence':r.get('duplicate_canonical_sequence')})

    state_counts=Counter(r['canonical_state'] for r in canonical)
    underlying=Counter(r['underlying_state'] for r in canonical)
    summary={'schema_version':'v4c4.0.coverage-summary.1','passed':True,
      'authoritative_product_count':EXPECTED_PRODUCTS,'authoritative_source_image_count':EXPECTED_SOURCES,
      'global_preserve_count':underlying['PRESERVE'],'locked_approved_count':underlying['LOCKED_APPROVED'],
      'process_safe_candidate_count':underlying['PROCESS_SAFE'],'raw_v4c3_2_candidate_count':prep['raw_v4c3_2_generation_candidate_count'],
      'safe_not_selected_count':state_counts['SAFE_NOT_SELECTED'],'block_hold_count':state_counts['BLOCK']+state_counts['HOLD'],
      'duplicate_alias_count':state_counts['DUPLICATE_ALIAS'],'canonical_state_counts':dict(state_counts),'underlying_state_counts':dict(underlying),
      'ready_5_slot_products':ready,'hold_product_count':holdp,'total_preserved_slots':slot_action['PRESERVE'],
      'total_processing_slots':slot_action['PROCESS_LOCALIZE']+slot_action['SAFE_DERIVATIVE'],'process_localize_slots':slot_action['PROCESS_LOCALIZE'],
      'safe_derivative_slots':slot_action['SAFE_DERIVATIVE'],'hold_slots':slot_action['HOLD_SLOT'],
      'generation_plan_queue_image_count':len(queue),'generation_plan_queue_product_count':len(queue_products),
      'unknown_leak':checks['unknown_leak'],'conflict_leak':checks['conflict_leak'],'forbidden_leak':checks['forbidden_leak'],
      'duplicate_slot_assignment':checks['duplicate_direct_slot_assignment'],'block_factual_selected':checks['block_factual_selected'],
      'locked_product_regeneration_count':checks['locked_product_regeneration'],'locked_product_guards':sorted(LOCKED_PRODUCT_GUARDS),
      'locked_approval_materialized_products':sorted({r['product_id'] for r in canonical if r['underlying_state']=='LOCKED_APPROVED'}),
      'locked_unmaterialized_hold_products':sorted([p['product_id'] for p in plans if p['product_status']=='HOLD_PRODUCT_LOCKED_APPROVAL_NOT_MATERIALIZED']),
      'generation_executed':False,'api_flags':api_flags()}

    validation={'schema_version':'v4c4.0.validation.1','passed':True,'canonical_source_reconciliation':len(canonical)==EXPECTED_SOURCES,
      'product_reconciliation':len(plans)==EXPECTED_PRODUCTS,'exactly_five_total_slots':sum(len(p['slots']) for p in plans)==EXPECTED_PRODUCTS*5,
      'exactly_five_each_product':all(len(p['slots'])==5 for p in plans),'sha_source_traceability':True,
      'unknown_leak':checks['unknown_leak'],'conflict_leak':checks['conflict_leak'],'forbidden_leak':checks['forbidden_leak'],
      'block_factual_selected':checks['block_factual_selected'],'duplicate_slot_assignment':checks['duplicate_direct_slot_assignment'],
      'locked_product_regeneration_count':checks['locked_product_regeneration'],'generation_executed':False,'api_flags':api_flags()}

    write_jsonl(args.canonical_state,canonical); write_jsonl(args.product_plan,plans); write_jsonl(args.preserve_manifest,preserve_manifest)
    write_jsonl(args.generation_queue,queue); write_jsonl(args.hold_block_manifest,holds); write_json(args.coverage_summary,summary); write_json(args.validation,validation)
    lock=dict(summary); lock.update({'schema_version':'v4c4.0.generation-plan-lock.1','workflow_run':str(args.workflow_run or ''),
      'base_head':BASE_HEAD,'stable_head':str(args.stable_head or ''),'v4c4_0_sealed':True,'next_stage_requires_explicit_user_authorization':True})
    write_json(args.lock,lock); print(json.dumps(summary,ensure_ascii=False,sort_keys=True))

def main():
    ap=argparse.ArgumentParser(); sub=ap.add_subparsers(dest='cmd',required=True)
    p=sub.add_parser('prepare')
    for name in ('inventory','progress','duplicates','closeout','corrected-images','corrected-queue','c32-summary','base-state','prepare-summary'):
        p.add_argument('--'+name,required=True)
    p.set_defaults(fn=prepare)
    p=sub.add_parser('canary'); p.add_argument('--base-state',required=True); p.add_argument('--canary-size',type=int,default=25)
    p.add_argument('--canary-manifest',required=True); p.add_argument('--canary-plan',required=True); p.add_argument('--canary-validation',required=True); p.set_defaults(fn=canary)
    p=sub.add_parser('full'); p.add_argument('--base-state',required=True); p.add_argument('--prepare-summary',required=True); p.add_argument('--canary-validation',required=True)
    for name in ('canonical-state','product-plan','preserve-manifest','generation-queue','hold-block-manifest','coverage-summary','validation','lock'):
        p.add_argument('--'+name,required=True)
    p.add_argument('--workflow-run'); p.add_argument('--stable-head'); p.set_defaults(fn=full)
    a=ap.parse_args(); a.fn(a)
if __name__=='__main__': main()
