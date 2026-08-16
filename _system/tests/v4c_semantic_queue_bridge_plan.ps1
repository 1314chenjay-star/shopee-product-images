param(
  [string]$QueuePath = '_system/v4c/preservation/results/preservation_semantic_queue.jsonl',
  [string]$DuplicateMapPath = '_system/v4c/results/duplicate_map.json',
  [string]$GateLockPath = '_system/v4c/preservation/PRESERVATION_GATE_LOCK.json',
  [string]$OutputDir = 'artifacts/preservation-semantic-plan'
)
$ErrorActionPreference = 'Stop'
function Read-Jsonl([string]$Path){
  $items=@(); if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"}
  Get-Content $Path -Encoding UTF8 | ForEach-Object { if(-not[string]::IsNullOrWhiteSpace($_)){ $items += ($_ | ConvertFrom-Json) } }
  return $items
}
function Write-Jsonl([string]$Path,$Items){
  $enc=New-Object System.Text.UTF8Encoding($false); $lines=@()
  foreach($item in @($Items)){ $lines += ($item | ConvertTo-Json -Depth 30 -Compress) }
  [System.IO.File]::WriteAllLines($Path,$lines,$enc)
}
if(-not(Test-Path $GateLockPath)){throw "Missing Preservation Gate lock: $GateLockPath"}
$lock=Get-Content $GateLockPath -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not[bool]$lock.smoke_passed){throw 'Preservation Gate lock is not PASS'}
$queue=@(Read-Jsonl $QueuePath)
$expected=[int]$lock.semantic_required_count
if($queue.Count -ne $expected){throw "Filtered semantic queue count $($queue.Count) != gate lock semantic_required_count $expected"}
$bySeq=@{}; foreach($q in $queue){
  $seq=[int]$q.sequence
  if($bySeq.ContainsKey($seq)){throw "Duplicate filtered queue sequence: $seq"}
  if([string]$q.preservation_decision -ne 'SEMANTIC_REQUIRED'){throw "Queue sequence $seq is not SEMANTIC_REQUIRED"}
  if([string]$q.semantic_status -ne 'PENDING'){throw "Queue sequence $seq is not PENDING"}
  if([string]::IsNullOrWhiteSpace([string]$q.sha256)){throw "Queue sequence $seq missing frozen SHA256"}
  $bySeq[$seq]=$q
}
$dup=Get-Content $DuplicateMapPath -Raw -Encoding UTF8 | ConvertFrom-Json
$reuse=@(); $reuseSeq=@{}
foreach($d in @($dup.sha256_duplicates)){
  $ds=[int]$d.sequence; $cs=[int]$d.canonical_sequence
  if(-not $bySeq.ContainsKey($ds) -or -not $bySeq.ContainsKey($cs)){continue}
  $dq=$bySeq[$ds]; $cq=$bySeq[$cs]
  $sameProduct=([string]$dq.product_id -eq [string]$cq.product_id)
  $sameSha=([string]$dq.sha256).ToLowerInvariant() -eq ([string]$cq.sha256).ToLowerInvariant()
  if($sameProduct -and $sameSha){
    $reuse += [pscustomobject][ordered]@{sequence=$ds;canonical_sequence=$cs;product_id=[string]$dq.product_id;sha256=([string]$dq.sha256).ToLowerInvariant();reason='SAME_PRODUCT_IDENTICAL_SHA_SAFE_REUSE'}
    $reuseSeq[$ds]=$true
  }
}
$worker=@($queue | Where-Object { -not $reuseSeq.ContainsKey([int]$_.sequence) } | Sort-Object {[int]$_.sequence})
$reuse=@($reuse | Sort-Object {[int]$_.sequence})
if($worker.Count + $reuse.Count -ne $queue.Count){throw 'Bridge plan reconciliation failed'}
New-Item -ItemType Directory -Force $OutputDir | Out-Null
Write-Jsonl (Join-Path $OutputDir 'worker_manifest.jsonl') $worker
Write-Jsonl (Join-Path $OutputDir 'sha_reuse_manifest.jsonl') $reuse
$summary=[ordered]@{
  schema_version='v4c2.preservation-semantic-plan.1'; preservation_gate_passed=$true
  filtered_queue_count=$queue.Count; worker_count=$worker.Count; sha_reuse_count=$reuse.Count
  same_product_sha_reuse_only=$true; cross_product_sha_reuse_for_claim_gate=$false
  source_pipeline_redownload=$false; image_generation_called=$false; tiny_snow_api_called=$false; paid_api_called=$false; vision_api_called=$false
}
$summary | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $OutputDir 'plan_summary.json') -Encoding UTF8
Write-Host "FILTERED_SEMANTIC_QUEUE=$($queue.Count)"
Write-Host "SEMANTIC_WORKER_COUNT=$($worker.Count)"
Write-Host "SHA_REUSE_COUNT=$($reuse.Count)"
Write-Host 'CROSS_PRODUCT_SHA_REUSE_FOR_CLAIM_GATE=false'
Write-Host 'SOURCE_PIPELINE_REDOWNLOAD=false'
Write-Host 'IMAGE_GENERATION_CALLED=false'
