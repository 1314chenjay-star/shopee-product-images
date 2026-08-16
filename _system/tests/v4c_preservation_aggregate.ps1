param(
 [Parameter(Mandatory=$true)][string]$ProgressPath,
 [Parameter(Mandatory=$true)][string]$ManifestPath,
 [string]$OutDir='artifacts/preservation-aggregate'
)
$ErrorActionPreference='Stop'
function Read-Jsonl([string]$Path){if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"};$a=@();Get-Content $Path -Encoding UTF8|ForEach-Object{if(-not[string]::IsNullOrWhiteSpace($_)){$a+=($_|ConvertFrom-Json)}};return $a}
function Write-Jsonl([string]$Path,$Items){$d=Split-Path -Parent $Path;if($d){New-Item -ItemType Directory -Force $d|Out-Null};$e=New-Object Text.UTF8Encoding($false);$lines=@();foreach($x in @($Items)){$lines+=($x|ConvertTo-Json -Depth 30 -Compress)};[IO.File]::WriteAllLines($Path,$lines,$e)}
$manifest=@(Read-Jsonl $ManifestPath);$progress=@(Read-Jsonl $ProgressPath)
$mBySeq=@{};foreach($m in $manifest){$mBySeq[[int]$m.sequence]=$m}
$bySeq=@{};foreach($r in $progress){$s=[int]$r.sequence;if($bySeq.ContainsKey($s)){throw "Duplicate preservation sequence: $s"};$bySeq[$s]=$r}
if($bySeq.Count-ne$manifest.Count){throw "Preservation reconciliation failed manifest=$($manifest.Count) progress=$($bySeq.Count)"}
foreach($m in $manifest){if(-not$bySeq.ContainsKey([int]$m.sequence)){throw "Missing preservation sequence $($m.sequence)"}}
$all=@($bySeq.Values|Sort-Object {[int]$_.sequence});$preserve=@($all|Where-Object{[string]$_.decision-eq'PRESERVE'});$semantic=@($all|Where-Object{[string]$_.decision-eq'SEMANTIC_REQUIRED'});$block=@($all|Where-Object{[string]$_.decision-eq'BLOCK'})
$semanticQueue=@();foreach($r in $semantic){$m=$mBySeq[[int]$r.sequence];$semanticQueue+=[ordered]@{sequence=[int]$m.sequence;source_id=[string]$m.source_id;product_id=[string]$m.product_id;image_index=[int]$m.image_index;image_type=[string]$m.image_type;url=[string]$m.url;sha256=[string]$m.sha256;v4c1_status=[string]$m.v4c1_status;preservation_decision='SEMANTIC_REQUIRED';preservation_state=[string]$r.localization_state;preservation_evidence_method=[string]$r.evidence.method;semantic_status='PENDING'}}
$productSummaries=@();$mixed=0;$complete=0;$allNeed=0;$blockedProducts=0
foreach($g in @($all|Group-Object product_id)){
 $rows=@($g.Group|Sort-Object {[int]$_.image_index});$p=@($rows|Where-Object{[string]$_.decision-eq'PRESERVE'});$s=@($rows|Where-Object{[string]$_.decision-eq'SEMANTIC_REQUIRED'});$b=@($rows|Where-Object{[string]$_.decision-eq'BLOCK'});$state=''
 if($b.Count-gt0){$state='BLOCKED';$blockedProducts++}elseif($p.Count-gt0-and$s.Count-gt0){$state='MIXED_PARTIAL';$mixed++}elseif($p.Count-eq$rows.Count){$state='COMPLETE_PRESERVE';$complete++}else{$state='ALL_SEMANTIC_REQUIRED';$allNeed++}
 $productSummaries+=[ordered]@{product_id=[string]$g.Name;product_state=$state;image_count=$rows.Count;preserve_count=$p.Count;semantic_required_count=$s.Count;block_count=$b.Count;preserved_sequences=@($p|ForEach-Object{[int]$_.sequence});semantic_sequences=@($s|ForEach-Object{[int]$_.sequence})}
}
$confirmed=@();$seenSha=@{};foreach($r in $preserve){$sha=[string]$r.sha256;if(-not$seenSha.ContainsKey($sha)){$seenSha[$sha]=$true;$confirmed+=[ordered]@{sha256=$sha;confirmed_by='V4-C2.0 Preservation Smoke';canonical_sequence=[int]$r.sequence;localization_state=[string]$r.localization_state;product_id=[string]$r.product_id}}}
$replay=@();foreach($r in $preserve|Select-Object -First 10){$replay+=$mBySeq[[int]$r.sequence]}
if($replay.Count-lt1){throw 'Preservation smoke found no PRESERVE records; cannot validate historical SHA skip'}
New-Item -ItemType Directory -Force $OutDir|Out-Null
Write-Jsonl (Join-Path $OutDir 'image_preservation.jsonl') $all;Write-Jsonl (Join-Path $OutDir 'preservation_ledger.jsonl') $all;Write-Jsonl (Join-Path $OutDir 'preservation_semantic_queue.jsonl') $semanticQueue;Write-Jsonl (Join-Path $OutDir 'preserved_images.jsonl') $preserve;Write-Jsonl (Join-Path $OutDir 'blocked_images.jsonl') $block;Write-Jsonl (Join-Path $OutDir 'product_preservation_summary.jsonl') $productSummaries;Write-Jsonl (Join-Path $OutDir 'confirmed_sha256_from_smoke.jsonl') $confirmed;Write-Jsonl (Join-Path $OutDir 'history_replay_manifest.jsonl') $replay
$mainPreserve=@($preserve|Where-Object{[bool]$_.is_main_image}).Count;$shaReuse=@($all|Where-Object{[string]$_.evidence.method-eq'SHA_REUSE'}).Count
[ordered]@{phase='Smoke';image_count=$all.Count;preserve_count=$preserve.Count;semantic_required_count=$semantic.Count;semantic_queue_count=$semanticQueue.Count;block_count=$block.Count;product_count=$productSummaries.Count;mixed_partial_products=$mixed;complete_preserve_products=$complete;all_semantic_products=$allNeed;blocked_products=$blockedProducts;main_image_preserve_count=$mainPreserve;sha_reuse_count=$shaReuse;history_replay_count=$replay.Count;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;source_pipeline_redownload=$false}|ConvertTo-Json -Depth 20|Set-Content (Join-Path $OutDir 'preservation_summary.json') -Encoding UTF8
Write-Host "PRESERVE_COUNT=$($preserve.Count)";Write-Host "SEMANTIC_REQUIRED_COUNT=$($semantic.Count)";Write-Host "SEMANTIC_QUEUE_COUNT=$($semanticQueue.Count)";Write-Host "BLOCK_COUNT=$($block.Count)";Write-Host "MIXED_PARTIAL_PRODUCTS=$mixed";Write-Host "MAIN_IMAGE_PRESERVE_COUNT=$mainPreserve";Write-Host "SHA_REUSE_COUNT=$shaReuse"
