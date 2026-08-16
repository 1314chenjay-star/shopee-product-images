param(
  [string]$QueuePath = '_system/v4c/preservation/results/preservation_semantic_queue.jsonl',
  [string]$WorkerProgressPath = 'artifacts/semantic-work/semantic_progress.jsonl',
  [string]$WorkerManifestPath = 'artifacts/preservation-semantic-plan/worker_manifest.jsonl',
  [string]$ReuseManifestPath = 'artifacts/preservation-semantic-plan/sha_reuse_manifest.jsonl',
  [string]$SourceEvidencePath = '_system/v4c/results/source_evidence.jsonl',
  [string]$OutputDir = 'artifacts/preservation-semantic-final'
)
$ErrorActionPreference='Stop'
$Baseline='a7447b792e65780bc95aa248b9e3a2fd0466f142'
function Read-Jsonl([string]$Path){
  $items=@(); if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"}
  Get-Content $Path -Encoding UTF8 | ForEach-Object { if(-not[string]::IsNullOrWhiteSpace($_)){ $items += ($_ | ConvertFrom-Json) } }
  return $items
}
function Write-Jsonl([string]$Path,$Items){
  $enc=New-Object System.Text.UTF8Encoding($false); $lines=@()
  foreach($item in @($Items)){ $lines += ($item | ConvertTo-Json -Depth 50 -Compress) }
  [System.IO.File]::WriteAllLines($Path,$lines,$enc)
}
function Clone-Object($Obj){ return (($Obj | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json) }
$queue=@(Read-Jsonl $QueuePath); $workerManifest=@(Read-Jsonl $WorkerManifestPath); $reuseManifest=@(Read-Jsonl $ReuseManifestPath); $progress=@(Read-Jsonl $WorkerProgressPath); $source=@(Read-Jsonl $SourceEvidencePath)
$queueBySeq=@{}; foreach($q in $queue){$queueBySeq[[int]$q.sequence]=$q}
$workerExpected=@{}; foreach($q in $workerManifest){$workerExpected[[int]$q.sequence]=$true}
$sourceBySeq=@{}; foreach($s in $source){$sourceBySeq[[int]$s.sequence]=$s}
if($sourceBySeq.Count -ne 2394){throw "Frozen V4-C1 source evidence expected 2394; got $($sourceBySeq.Count)"}
$records=@{}; foreach($r in $progress){
  $seq=[int]$r.sequence
  if($records.ContainsKey($seq)){throw "Duplicate worker semantic sequence: $seq"}
  if(-not $workerExpected.ContainsKey($seq)){throw "Worker produced sequence not in canonical worker manifest: $seq"}
  if([string]$r.semantic_status -notin @('DONE','BLOCKED')){throw "Non-terminal worker semantic sequence: $seq"}
  $records[$seq]=$r
}
if($records.Count -ne $workerExpected.Count){throw "Worker terminal count $($records.Count) != planned worker count $($workerExpected.Count)"}
$reuseRecords=@()
foreach($m in $reuseManifest){
  $seq=[int]$m.sequence; $canonical=[int]$m.canonical_sequence
  if(-not $records.ContainsKey($canonical)){throw "SHA reuse canonical semantic result missing: $canonical for $seq"}
  if(-not $queueBySeq.ContainsKey($seq)){throw "SHA reuse sequence missing from filtered queue: $seq"}
  $q=$queueBySeq[$seq]; $base=Clone-Object $records[$canonical]
  if([string]$base.product_id -ne [string]$q.product_id){throw "Unsafe cross-product semantic reuse rejected: $seq -> $canonical"}
  if(([string]$base.sha256).ToLowerInvariant() -ne ([string]$q.sha256).ToLowerInvariant()){throw "SHA reuse digest mismatch: $seq -> $canonical"}
  $src=$sourceBySeq[$seq]
  $base.sequence=$seq; $base.source_id=[string]$q.source_id; $base.product_id=[string]$q.product_id; $base.sha256=([string]$q.sha256).ToLowerInvariant(); $base.canonical_sequence=$canonical
  $base.analysis_mode='SHA_REUSE'; $base.semantic_status='REUSED'
  $base.provenance.source_status=[string]$q.v4c1_status; $base.provenance.sha_verified=$true; $base.provenance.byte_count_v4c1=$src.byte_count; $base.provenance.byte_count_semantic=$null; $base.provenance.semantic_image_fetch=$false; $base.provenance.source_pipeline_redownload=$false; $base.provenance.sha256_state='REUSED_CANONICAL'
  $base.reuse=[ordered]@{canonical_sequence=$canonical;canonical_sha256=([string]$q.sha256).ToLowerInvariant();model_inference_reused=$true;semantic_image_fetch=$false;same_product_context=$true}
  $base.flags.image_generation_called=$false; $base.flags.tiny_snow_api_called=$false; $base.flags.paid_api_called=$false; $base.flags.vision_api_called=$false; $base.flags.local_model_only=$true
  $reuseRecords += $base
}
$all=@($records.Values)+@($reuseRecords); $all=@($all|Sort-Object {[int]$_.sequence})
if($all.Count -ne $queue.Count){throw "Filtered semantic reconciliation failed: $($all.Count) != $($queue.Count)"}
$seen=@{}; foreach($r in $all){$seq=[int]$r.sequence;if($seen.ContainsKey($seq)){throw "Duplicate final semantic sequence: $seq"};$seen[$seq]=$true;if(-not $queueBySeq.ContainsKey($seq)){throw "Final semantic result outside filtered queue: $seq"}}
$pass=@($all|Where-Object{[string]$_.gate.status -eq 'PASS'});$hold=@($all|Where-Object{[string]$_.gate.status -eq 'HOLD'});$block=@($all|Where-Object{[string]$_.gate.status -eq 'BLOCK'});$reuse=@($all|Where-Object{[string]$_.analysis_mode -eq 'SHA_REUSE'});$local=@($all|Where-Object{[string]$_.analysis_mode -eq 'LOCAL_SEMANTIC'})
New-Item -ItemType Directory -Force $OutputDir|Out-Null
Write-Jsonl (Join-Path $OutputDir 'semantic_progress.jsonl') $all
Write-Jsonl (Join-Path $OutputDir 'semantic_evidence.jsonl') $all
Write-Jsonl (Join-Path $OutputDir 'semantic_pass.jsonl') $pass
Write-Jsonl (Join-Path $OutputDir 'semantic_hold.jsonl') $hold
Write-Jsonl (Join-Path $OutputDir 'semantic_block.jsonl') $block
Write-Jsonl (Join-Path $OutputDir 'remaining_semantic_queue.jsonl') @()
$progressPath=Join-Path $OutputDir 'semantic_progress.jsonl';$hash=(Get-FileHash $progressPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checkpoint=[ordered]@{schema_version='v4c2.preservation-filtered-checkpoint.1';phase='PRESERVATION_FILTERED_COMPLETE';v4c1_baseline_head=$Baseline;filtered_queue_count=$queue.Count;local_semantic_count=$local.Count;sha_reuse_count=$reuse.Count;terminal_count=$all.Count;remaining_count=0;progress_sha256=$hash;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;source_pipeline_redownload=$false}
$checkpoint|ConvertTo-Json -Depth 30|Set-Content (Join-Path $OutputDir 'semantic_checkpoint.json') -Encoding UTF8
$summary=[ordered]@{schema_version='v4c2.preservation-filtered-summary.1';phase='PRESERVATION_FILTERED_COMPLETE';filtered_queue_count=$queue.Count;local_semantic_count=$local.Count;sha_reuse_count=$reuse.Count;gate_pass=$pass.Count;gate_hold=$hold.Count;gate_block=$block.Count;terminal_count=$all.Count;remaining_semantic=0;same_product_sha_reuse_only=$true;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;local_model_only=$true;source_pipeline_redownload=$false}
$summary|ConvertTo-Json -Depth 30|Set-Content (Join-Path $OutputDir 'semantic_summary.json') -Encoding UTF8
Write-Host "FILTERED_SEMANTIC_TERMINAL=$($all.Count)";Write-Host "LOCAL_SEMANTIC_COUNT=$($local.Count)";Write-Host "SHA_REUSE_COUNT=$($reuse.Count)";Write-Host "SEMANTIC_PASS=$($pass.Count)";Write-Host "SEMANTIC_HOLD=$($hold.Count)";Write-Host "SEMANTIC_BLOCK=$($block.Count)";Write-Host 'SEMANTIC_REMAINING=0';Write-Host 'SOURCE_PIPELINE_REDOWNLOAD=false';Write-Host 'IMAGE_GENERATION_CALLED=false'
