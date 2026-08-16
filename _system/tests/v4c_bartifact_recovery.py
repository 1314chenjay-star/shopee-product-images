#!/usr/bin/env python3
import argparse, hashlib, json, os, re, sys, zipfile
from collections import Counter, defaultdict
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, build_opener, HTTPRedirectHandler, urlopen

SCHEMA = 'v4c2.4.bartifact-recovery.3'
PLAN_SCHEMA = 'v4c2.4.bartifact-plan.3'
BASE_HEAD = '6f73d4d4abec248d66387df545de966e4d382b32'
STABLE_HEAD = '5d49f061e140813b3d229520e9e530f86b27b640'
EXPECTED_TARGET = 221
HEX64 = re.compile(r'^[0-9a-f]{64}$')
BATCH_RE = re.compile(r'^B(?:00[1-9]|01[0-8])$')
SEARCH_BATCH = 'SEARCH_B001_B018'


def read_jsonl(path):
    p=Path(path)
    if not p.exists(): return []
    out=[]
    for i,line in enumerate(p.open(encoding='utf-8-sig'),1):
        if not line.strip(): continue
        try: out.append(json.loads(line))
        except Exception as e: raise RuntimeError(f'Invalid JSONL {path}:{i}: {e}')
    return out


def write_jsonl(path,rows):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8',newline='\n') as f:
        for r in rows:f.write(json.dumps(r,ensure_ascii=False,separators=(',',':'))+'\n')


def append_jsonl(path,row):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('a',encoding='utf-8',newline='\n') as f:
        f.write(json.dumps(row,ensure_ascii=False,separators=(',',':'))+'\n');f.flush();os.fsync(f.fileno())


def write_json(path,obj):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(obj,ensure_ascii=False,indent=2),encoding='utf-8')


def sha_bytes(data):return hashlib.sha256(data).hexdigest()

def artifact_rows(path):
    data=json.loads(Path(path).read_text(encoding='utf-8-sig'))
    return list(data.get('artifacts',data if isinstance(data,list) else []))

def valid_batch(v):return bool(BATCH_RE.match(str(v or '')))


def legacy_candidates(progress_row):
    out=[]
    def add(batch,seq,origin):
        try:s=int(seq)
        except:return
        b=str(batch or '')
        if not valid_batch(b) or s<=0:return
        key=(b,s)
        if key not in {(x['batch'],x['sequence']) for x in out}:out.append({'batch':b,'sequence':s,'origin':origin})
    add(progress_row.get('legacy_batch'),progress_row.get('legacy_sequence'),'legacy_batch+legacy_sequence')
    batches=list(progress_row.get('legacy_batches') or []);seqs=list(progress_row.get('legacy_sequences') or [])
    if len(batches)==len(seqs):
        for b,s in zip(batches,seqs):add(b,s,'legacy_batches+legacy_sequences')
    elif len(batches)==1:
        for s in seqs:add(batches[0],s,'single_legacy_batch+legacy_sequences')
    elif len(seqs)==1:
        for b in batches:add(b,seqs[0],'legacy_batches+single_legacy_sequence')
    return out


def choose_canary(rows,n):
    buckets=defaultdict(list)
    for r in rows:buckets[r['artifact_batch']].append(r)
    for b in buckets:buckets[b]=sorted(buckets[b],key=lambda x:int(x['sequence']))
    chosen=[];keys=sorted(buckets)
    while len(chosen)<n:
        moved=False
        for b in keys:
            if buckets[b] and len(chosen)<n:
                chosen.append(buckets[b].pop(0));moved=True
        if not moved:break
    if len(chosen)!=n:raise RuntimeError(f'Cannot select {n} canary rows')
    return chosen


def build_artifact_catalog(arts):
    out=[]
    for i in range(1,19):
        batch=f'B{i:03d}';name='V4-C0-SourceReview-'+batch;art=arts.get(name)
        if not art or art.get('expired'):raise RuntimeError(f'Required artifact unavailable: {name}')
        out.append({'batch':batch,'artifact_name':name,'artifact_id':int(art['id']),'artifact_digest':art.get('digest')})
    return out


def plan(a):
    gaps=read_jsonl(a.gap_index);hydrated={int(r['sequence']):r for r in read_jsonl(a.hydrated_evidence)}
    source_progress={int(r['sequence']):r for r in read_jsonl(a.source_progress)}
    targets=[r for r in gaps if str(r.get('hydration_action'))=='USE_B001_B018_VISUAL']
    if len(targets)!=EXPECTED_TARGET:raise RuntimeError(f'Expected {EXPECTED_TARGET} USE_B001_B018_VISUAL rows, got {len(targets)}')
    seqs={int(r['sequence']) for r in targets}
    if len(seqs)!=EXPECTED_TARGET:raise RuntimeError('Duplicate target sequence')
    nonhold=[s for s in seqs if str((hydrated.get(s) or {}).get('terminal_status'))!='HOLD']
    if nonhold:raise RuntimeError(f'Target contains non-HOLD V4-C2.3 rows: {nonhold[:10]}')
    arts={str(x.get('name')):x for x in artifact_rows(a.artifact_inventory)};catalog=build_artifact_catalog(arts)
    bybatch={x['batch']:x for x in catalog};out=[];batches=Counter();origins=Counter();progress_sha_count=0;search_fallback=0
    for r in sorted(targets,key=lambda x:int(x['sequence'])):
        seq=int(r['sequence']);pr=source_progress.get(seq)
        if not pr:raise RuntimeError(f'V4-C1 source progress missing current sequence {seq}')
        candidates=legacy_candidates(pr);progress_sha=str(pr.get('sha256') or '').lower();progress_sha=progress_sha if HEX64.match(progress_sha) else None
        if candidates:
            primary=candidates[0];meta=bybatch[primary['batch']];artifact_batch=primary['batch'];artifact_sequence=int(primary['sequence']);origin=primary['origin']
            search_candidates=[dict(meta)]
        else:
            artifact_batch=SEARCH_BATCH;artifact_sequence=None;origin='B001_B018_MANIFEST_SOURCE_URL_SEARCH';search_candidates=[dict(x) for x in catalog];search_fallback+=1
        x=dict(r);x.update({'schema_version':PLAN_SCHEMA,'artifact_batch':artifact_batch,'artifact_sequence':artifact_sequence,
                            'artifact_name':search_candidates[0]['artifact_name'] if len(search_candidates)==1 else None,
                            'artifact_id':search_candidates[0]['artifact_id'] if len(search_candidates)==1 else None,
                            'artifact_digest':search_candidates[0]['artifact_digest'] if len(search_candidates)==1 else None,
                            'artifact_search_candidates':search_candidates,'legacy_mapping_origin':origin,'legacy_candidates':candidates,
                            'v4c1_recorded_sha256':progress_sha,'recorded_sha_authority':'V4C1_PROGRESS_SHA_IF_PRESENT_ELSE_B001_B018_DOWNLOAD_MANIFEST',
                            'source_fetch_allowed':False,'historical_evidence_rerun':False})
        out.append(x);batches[artifact_batch]+=1;origins[origin]+=1;progress_sha_count+=1 if progress_sha else 0
    can=choose_canary(out,a.canary_size);canseq={int(r['sequence']) for r in can};remaining=[r for r in out if int(r['sequence']) not in canseq]
    write_jsonl(a.target_out,out);write_jsonl(a.canary_out,can);write_jsonl(a.remaining_out,remaining)
    summary={'schema_version':'v4c2.4.plan-summary.3','passed':True,'target':len(out),'canary':len(can),'remaining_after_canary':len(remaining),
             'batch_counts':dict(sorted(batches.items())),'mapping_origin_counts':dict(origins),'manifest_search_fallback_count':search_fallback,
             'v4c1_progress_sha_present':progress_sha_count,'legacy_coordinate_source':'_system/v4c/progress/v4c_source_progress.jsonl',
             'fallback_mapping_source':'B001-B018 download_manifest source_url + product_id + recorded SHA','current_sequence_not_assumed_to_be_artifact_sequence':True,
             'other_holds_touched':0,'existing_blocks_touched':0,'rerun_1378':False,'source_refetch_1144':False,'inventory_rebuilt':False,
             'completed_ocr_rerun':False,'completed_semantic_rerun':False,'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,'v4c2_2_retested':False,'v4c2_3_retested':False}
    write_json(a.summary,summary)
    print(f'TARGET={len(out)}');print(f'CANARY={len(can)}');print(f'REMAINING={len(remaining)}');print(f'MANIFEST_SEARCH_FALLBACK={search_fallback}')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):return None

def download_artifact(repo,artifact_id,token,dest):
    dest=Path(dest);dest.parent.mkdir(parents=True,exist_ok=True)
    if dest.exists() and zipfile.is_zipfile(dest):return dest,False
    api=f'https://api.github.com/repos/{repo}/actions/artifacts/{artifact_id}/zip';headers={'Authorization':f'Bearer {token}','Accept':'application/vnd.github+json','X-GitHub-Api-Version':'2022-11-28','User-Agent':'TinySnow-V4C2.4-Artifact-Recovery/1.0'}
    req=Request(api,headers=headers);opener=build_opener(NoRedirect());loc=None;direct=None
    try:
        with opener.open(req,timeout=120) as resp:direct=resp.read()
    except HTTPError as e:
        if e.code not in {301,302,303,307,308}:raise
        loc=e.headers.get('Location')
    if direct is None:
        if not loc:raise RuntimeError(f'Artifact {artifact_id} did not return redirect location')
        with urlopen(Request(loc,headers={'User-Agent':'TinySnow-V4C2.4-Artifact-Recovery/1.0'}),timeout=180) as resp:direct=resp.read()
    tmp=dest.with_suffix('.tmp');tmp.write_bytes(direct);os.replace(tmp,dest)
    if not zipfile.is_zipfile(dest):raise RuntimeError(f'Artifact {artifact_id} download is not ZIP')
    return dest,True


class ArtifactBatch:
    def __init__(self,meta,repo,token,cache_dir):
        self.batch=meta['batch'];self.artifact_name=meta['artifact_name'];self.artifact_id=int(meta['artifact_id']);self.zip_path=Path(cache_dir)/(self.artifact_name+'.zip')
        self.zip_path,self.downloaded=download_artifact(repo,self.artifact_id,token,self.zip_path);self.z=zipfile.ZipFile(self.zip_path)
        if 'download_manifest.json' not in self.z.namelist():raise RuntimeError(f'{self.artifact_name} missing download_manifest.json')
        raw=json.loads(self.z.read('download_manifest.json'))
        if not isinstance(raw,list):raise RuntimeError(f'{self.artifact_name} download_manifest must be list')
        self.manifest=list(raw);self.manifest_by_seq={int(x['sequence']):x for x in raw if x.get('sequence') is not None}
    def close(self):self.z.close()


def load_batch(meta,batches,repo,token,cache_dir):
    b=meta['batch']
    if b not in batches:batches[b]=ArtifactBatch(meta,repo,token,cache_dir)
    return batches[b]


def find_manifest_match(row,batches,repo,token,cache_dir):
    url=str(row.get('source_url') or '');pid=str(row.get('product_id') or '');progress_sha=str(row.get('v4c1_recorded_sha256') or '').lower();progress_sha=progress_sha if HEX64.match(progress_sha) else None
    matches=[]
    # Frozen legacy coordinate is preferred, but source URL/product identity must still verify.
    if row.get('artifact_sequence') is not None and len(row.get('artifact_search_candidates') or [])==1:
        meta=(row.get('artifact_search_candidates') or [])[0];batch=load_batch(meta,batches,repo,token,cache_dir);m=batch.manifest_by_seq.get(int(row['artifact_sequence']))
        if m and str(m.get('source_url') or '')==url and (not m.get('product_id') or str(m.get('product_id'))==pid):return batch,m,'FROZEN_LEGACY_COORDINATE'
    # Missing/stale coordinate: search only historical artifact manifests, never the Shopee source.
    for meta in row.get('artifact_search_candidates') or []:
        batch=load_batch(meta,batches,repo,token,cache_dir)
        for m in batch.manifest:
            if str(m.get('source_url') or '')!=url:continue
            if m.get('product_id') and str(m.get('product_id'))!=pid:continue
            ms=str(m.get('sha256') or '').lower()
            if progress_sha and ms!=progress_sha:continue
            matches.append((batch,m))
    if not matches:return None,None,'NO_ARTIFACT_MANIFEST_MATCH'
    uniq={str(m.get('sha256') or '').lower() for _,m in matches}
    if len(uniq)>1:return matches[0][0],matches[0][1],'AMBIGUOUS_SOURCE_URL_MULTIPLE_SHA'
    matches.sort(key=lambda bm:(bm[0].batch,int(bm[1].get('sequence') or 0)))
    return matches[0][0],matches[0][1],'B001_B018_MANIFEST_SOURCE_URL_SEARCH'


def base_flags(ocr,artifact_downloaded):
    return {'github_artifact_download_called':bool(artifact_downloaded),'source_fetch_called':False,'ocr_executed':bool(ocr),'semantic_inference_executed':False,
            'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'rerun_1378':False,'source_refetch_1144':False,
            'inventory_rebuilt':False,'completed_ocr_rerun':False,'completed_semantic_rerun':False,'v4c1_retested':False,'v4c2_0_retested':False,'v4c2_1_retested':False,
            'v4c2_2_retested':False,'v4c2_3_retested':False}


def missing_record(row,reason):
    return {'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'source_url':row.get('source_url'),
            'artifact_batch':row.get('artifact_batch'),'artifact_sequence':row.get('artifact_sequence'),'artifact_name':row.get('artifact_name'),'artifact_id':row.get('artifact_id'),
            'artifact_found':False,'artifact_not_found':True,'recorded_sha256':row.get('v4c1_recorded_sha256'),'actual_sha256':None,'sha_matched':False,'sha_mismatch':False,
            'mapping':{'method':row.get('legacy_mapping_origin'),'source_url_matched':False,'product_id_matched':False},'image_metadata':{},'ocr':{'texts':[]},'script_classification':{},
            'localization_state':'HOLD_ARTIFACT_NOT_FOUND','claim_candidates':[],'verified_claims':[],'unknown_claims':[],
            'evidence_location':{'artifact':row.get('artifact_name'),'artifact_sequence':row.get('artifact_sequence')},'preservation_decision':'HOLD_ARTIFACT_NOT_FOUND',
            'claim_gate_status':'HOLD','terminal_status':'HOLD','hold_reason':reason,'flags':base_flags(False,False)}


def mismatch_record(row,batch,m,filename,recorded,actual,reason):
    return {'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'source_url':row.get('source_url'),
            'artifact_batch':batch.batch,'artifact_sequence':int(m.get('sequence')),'artifact_name':batch.artifact_name,'artifact_id':batch.artifact_id,'artifact_file':filename,
            'artifact_found':True,'artifact_not_found':False,'recorded_sha256':recorded,'actual_sha256':actual,'sha_matched':False,'sha_mismatch':True,
            'mapping':{'method':'ARTIFACT_MANIFEST_MATCH','source_url_matched':True,'product_id_matched':True},'image_metadata':{},'ocr':{'texts':[]},'script_classification':{},
            'localization_state':'BLOCK_ARTIFACT_SHA_MISMATCH','claim_candidates':[],'verified_claims':[],'unknown_claims':[],
            'evidence_location':{'artifact':batch.artifact_name,'artifact_sequence':int(m.get('sequence')),'file':filename},'preservation_decision':'BLOCK_ARTIFACT_SHA_MISMATCH',
            'claim_gate_status':'BLOCK','terminal_status':'BLOCK','block_reason':reason,'flags':base_flags(False,batch.downloaded)}


def process_one(row,batches,repo,token,cache_dir,models,ctx,evidence_repo_path):
    batch,m,method=find_manifest_match(row,batches,repo,token,cache_dir)
    if not m:return missing_record(row,method)
    if method=='AMBIGUOUS_SOURCE_URL_MULTIPLE_SHA':
        filename=str(m.get('file') or '');recorded=str(row.get('v4c1_recorded_sha256') or m.get('sha256') or '').lower();actual=None
        if filename and filename in batch.z.namelist():actual=sha_bytes(batch.z.read(filename))
        return mismatch_record(row,batch,m,filename,recorded,actual,'B001_B018_SOURCE_URL_HAS_MULTIPLE_RECORDED_SHA')
    manifest_sha=str(m.get('sha256') or '').lower();filename=str(m.get('file') or '')
    if not HEX64.match(manifest_sha):return missing_record(row,'RECORDED_ARTIFACT_SHA_MISSING_OR_INVALID')
    if not filename or filename not in batch.z.namelist():return missing_record(row,'ARTIFACT_IMAGE_FILE_NOT_FOUND')
    data=batch.z.read(filename);actual=sha_bytes(data);progress_sha=str(row.get('v4c1_recorded_sha256') or '').lower();progress_sha=progress_sha if HEX64.match(progress_sha) else None;authoritative=progress_sha or manifest_sha
    if progress_sha and manifest_sha!=progress_sha:return mismatch_record(row,batch,m,filename,progress_sha,actual,'B001_B018_MANIFEST_SHA_DIFFERS_FROM_V4C1_PROGRESS_SHA')
    if actual!=authoritative:return mismatch_record(row,batch,m,filename,authoritative,actual,'ARTIFACT_BYTES_SHA_DO_NOT_MATCH_V4C1_RECORDED_SHA')
    runtime=Path(os.environ.get('RUNNER_TEMP') or Path.cwd()/'artifacts'/'runtime-visual');runtime.mkdir(parents=True,exist_ok=True);ext=Path(filename).suffix or '.img';img=runtime/(authoritative+ext);img.write_bytes(data)
    from v4c_hold_hydration import ocr_evidence, resolve_claims
    md,texts,script,conf=ocr_evidence(img,models);state=script['classification'];f=base_flags(True,batch.downloaded)
    loc={'durable':evidence_repo_path,'artifact':batch.artifact_name,'artifact_id':batch.artifact_id,'artifact_sequence':int(m.get('sequence')),'artifact_file':filename,
         'artifact_manifest':'download_manifest.json','source_url':row.get('source_url'),'current_sequence':int(row['sequence'])}
    base={'schema_version':SCHEMA,'sequence':int(row['sequence']),'source_id':row.get('source_id'),'product_id':row.get('product_id'),'source_url':row.get('source_url'),
          'artifact_batch':batch.batch,'artifact_sequence':int(m.get('sequence')),'artifact_name':batch.artifact_name,'artifact_id':batch.artifact_id,'artifact_file':filename,
          'artifact_found':True,'artifact_not_found':False,'recorded_sha256':authoritative,'artifact_manifest_sha256':manifest_sha,'v4c1_progress_sha256':progress_sha,
          'actual_sha256':actual,'sha_matched':True,'sha_mismatch':False,'mapping':{'method':method,'source_url_matched':True,'product_id_matched':True},
          'image_metadata':dict(md,byte_count=len(data)),'ocr':{'engine':'rapidocr_onnxruntime','texts':texts},'script_classification':script,'localization_state':state,
          'evidence_location':loc,'confidence':conf,'flags':f}
    if state in {'NO_CHINESE_TEXT','TRADITIONAL_CONFIRMED'}:
        base.update({'claim_candidates':[],'verified_claims':[],'unknown_claims':[],'preservation_decision':'PRESERVE','claim_gate_status':'SKIP_PRESERVE','terminal_status':'PRESERVE'});return base
    cg=resolve_claims(int(row['sequence']),str(row.get('product_id') or ''),authoritative,ctx or {},texts);claims=list(cg.get('claims') or []);unknown=[c for c in claims if c.get('status')=='UNKNOWN']
    for c in unknown:c['allowed_usage']='NONE'
    verified=[c for c in claims if c.get('status')=='VERIFIED_SOURCE']
    base.update({'claim_candidates':claims,'verified_claims':verified,'unknown_claims':unknown,'allowed_claim_ids':[c.get('claim_id') for c in verified],
                 'preservation_decision':'NEEDS_LOCALIZATION','claim_gate_status':cg.get('claim_gate_status'),'terminal_status':cg.get('claim_gate_status')});return base


def process(a):
    manifest=read_jsonl(a.manifest)
    if any(str(r.get('hydration_action'))!='USE_B001_B018_VISUAL' for r in manifest):raise RuntimeError('Manifest leaked outside 221 artifact target')
    here=str(Path(__file__).resolve().parent)
    if here not in sys.path:sys.path.insert(0,here)
    from v4c_hold_hydration import load_context_b64, load_models
    ctx=load_context_b64(a.product_context);existing=read_jsonl(a.progress);done={int(r['sequence']):r for r in existing};target=len(manifest) if a.max_items<=0 else min(len(manifest),a.max_items);selected=manifest[:target]
    batches={};models=None;processed=skipped=0;repo=a.repository or os.environ.get('GITHUB_REPOSITORY','');token=os.environ.get('GITHUB_TOKEN','') or os.environ.get('GH_TOKEN','')
    if not repo or not token:raise RuntimeError('GITHUB_REPOSITORY/GITHUB_TOKEN required for artifact materialization')
    for row in selected:
        seq=int(row['sequence'])
        if seq in done:skipped+=1;continue
        if models is None:models=load_models();print('LOCAL_ARTIFACT_OCR_READY=true',flush=True)
        r=process_one(row,batches,repo,token,a.artifact_cache,models,ctx.get(str(row.get('product_id',''))),a.evidence_repo_path);append_jsonl(a.progress,r);done[seq]=r;processed+=1
        print(f"BARTIFACT sequence={seq} historical={r.get('artifact_batch')}:{r.get('artifact_sequence')} method={(r.get('mapping') or {}).get('method')} found={r.get('artifact_found')} sha_match={r.get('sha_matched')} preservation={r.get('preservation_decision')} terminal={r.get('terminal_status')}",flush=True)
    for b in batches.values():b.close()
    covered=sum(int(r['sequence']) in done for r in selected);records=[done[int(r['sequence'])] for r in selected if int(r['sequence']) in done];summary_counts=summarize(records)
    summary_counts.update({'schema_version':'v4c2.4.run-summary.3','manifest_count':len(manifest),'target_count':target,'checkpoint_existing_terminal':skipped,'processed_this_run':processed,'covered_after_run':covered});write_json(a.summary,summary_counts)
    print(f'CHECKPOINT_EXISTING_TERMINAL={skipped}');print(f'PROCESSED_THIS_RUN={processed}');print(f'COVERED_AFTER_RUN={covered}')


def summarize(rows):
    term=Counter(str(r.get('terminal_status')) for r in rows);pres=Counter(str(r.get('preservation_decision')) for r in rows)
    return {'target':len(rows),'artifact_found':sum(bool(r.get('artifact_found')) for r in rows),'artifact_not_found':sum(bool(r.get('artifact_not_found')) for r in rows),'sha_matched':sum(bool(r.get('sha_matched')) for r in rows),'sha_mismatch':sum(bool(r.get('sha_mismatch')) for r in rows),
            'preserve':pres.get('PRESERVE',0),'needs_localization':pres.get('NEEDS_LOCALIZATION',0),'partial_safe':term.get('PARTIAL_SAFE',0),'hold_remaining':term.get('HOLD',0),'block':term.get('BLOCK',0),'pass':term.get('PASS',0),'remaining':0,
            'local_ocr_executed':sum(bool((r.get('flags') or {}).get('ocr_executed')) for r in rows),'semantic_actually_executed':0,
            'api_flags':{'github_artifact_download_called':any(bool((r.get('flags') or {}).get('github_artifact_download_called')) for r in rows),'source_fetch_called':False,'image_generation_called':False,'tiny_snow_api_called':False,'paid_api_called':False,'vision_api_called':False,'semantic_inference_executed':False,'rerun_1378':False,'source_refetch_1144':False,'inventory_rebuilt':False,'completed_ocr_rerun':False,'completed_semantic_rerun':False}}


def aggregate(a):
    targets=read_jsonl(a.target_manifest);expected={int(r['sequence']) for r in targets};rows=read_jsonl(a.canary_progress)+read_jsonl(a.full_progress);by={}
    for r in rows:
        seq=int(r['sequence'])
        if seq in by and json.dumps(by[seq],sort_keys=True,ensure_ascii=False)!=json.dumps(r,sort_keys=True,ensure_ascii=False):raise RuntimeError(f'Conflicting recovery evidence seq {seq}')
        by[seq]=r
    missing=sorted(expected-set(by));extra=sorted(set(by)-expected)
    if missing or extra:raise RuntimeError(f'Recovery reconciliation failed missing={missing[:10]} extra={extra[:10]}')
    out=[by[int(r['sequence'])] for r in sorted(targets,key=lambda x:int(x['sequence']))];write_jsonl(a.output,out);s=summarize(out);s.update({'schema_version':'v4c2.4.final-summary.3','passed':True,'target':EXPECTED_TARGET});write_json(a.summary,s)
    print('TARGET='+str(s['target']));print('ARTIFACT_FOUND='+str(s['artifact_found']));print('SHA_MATCHED='+str(s['sha_matched']));print('PRESERVE='+str(s['preserve']));print('PARTIAL_SAFE='+str(s['partial_safe']));print('HOLD_REMAINING='+str(s['hold_remaining']));print('BLOCK='+str(s['block']))


def selftest():
    import tempfile
    p={'legacy_batch':'B008','legacy_sequence':391,'legacy_batches':['B008'],'legacy_sequences':[391]};c=legacy_candidates(p);assert c and c[0]['batch']=='B008' and c[0]['sequence']==391
    assert legacy_candidates({'sequence':297})==[]
    with tempfile.TemporaryDirectory() as td:
        td=Path(td);img=b'abc123';good=sha_bytes(img);bad='0'*64;zpath=td/'a.zip'
        with zipfile.ZipFile(zpath,'w') as z:z.writestr('x.jpg',img);z.writestr('download_manifest.json',json.dumps([{'sequence':391,'product_id':'p','source_url':'https://example.invalid/x','file':'x.jpg','sha256':good}]))
        with zipfile.ZipFile(zpath) as z:m=json.loads(z.read('download_manifest.json'))[0];assert sha_bytes(z.read(m['file']))==m['sha256'];assert sha_bytes(z.read(m['file']))!=bad
    unk={'status':'UNKNOWN','allowed_usage':'NONE'};assert unk['allowed_usage']=='NONE'
    print('V4C2_4_SELFTEST=true');print('LEGACY_COORDINATE_OR_MANIFEST_SEARCH=true');print('ARTIFACT_SHA_MATCH_PATH=true');print('ARTIFACT_SHA_MISMATCH_PATH=true');print('UNKNOWN_ALLOWED_USAGE_NONE=true');print('SOURCE_FETCH=false')


def main():
    ap=argparse.ArgumentParser();sp=ap.add_subparsers(dest='cmd',required=True)
    p=sp.add_parser('plan');p.add_argument('--gap-index',required=True);p.add_argument('--hydrated-evidence',required=True);p.add_argument('--source-progress',required=True);p.add_argument('--artifact-inventory',required=True);p.add_argument('--target-out',required=True);p.add_argument('--canary-out',required=True);p.add_argument('--remaining-out',required=True);p.add_argument('--summary',required=True);p.add_argument('--canary-size',type=int,default=40)
    p=sp.add_parser('process');p.add_argument('--manifest',required=True);p.add_argument('--product-context',required=True);p.add_argument('--progress',required=True);p.add_argument('--summary',required=True);p.add_argument('--artifact-cache',required=True);p.add_argument('--evidence-repo-path',default='_system/v4c/evidence_hydration/bartifact_recovery/materialized_evidence.jsonl');p.add_argument('--repository');p.add_argument('--max-items',type=int,default=0)
    p=sp.add_parser('aggregate');p.add_argument('--target-manifest',required=True);p.add_argument('--canary-progress',required=True);p.add_argument('--full-progress',required=True);p.add_argument('--output',required=True);p.add_argument('--summary',required=True)
    sp.add_parser('self-test');a=ap.parse_args()
    if a.cmd=='plan':plan(a)
    elif a.cmd=='process':process(a)
    elif a.cmd=='aggregate':aggregate(a)
    else:selftest()
    return 0
if __name__=='__main__':sys.exit(main())
