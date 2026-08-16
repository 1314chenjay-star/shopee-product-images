param(
    [ValidateSet('Smoke','Final')][string]$Phase = 'Smoke',
    [string]$QueuePath = '_system/v4c/results/semantic_evidence_queue.jsonl',
    [string]$SourceEvidencePath = '_system/v4c/results/source_evidence.jsonl',
    [string]$DuplicateMapPath = '_system/v4c/results/duplicate_map.json',
    [string]$SeedProgressPath = '', [string]$ShardResultRoot = '',
    [string]$OutputDir = 'artifacts/semantic-aggregate'
)
$ErrorActionPreference = 'Stop'
$Baseline = 'a7447b792e65780bc95aa248b9e3a2fd0466f142'
function Read-Jsonl([string]$Path) { $items=@(); if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) { return $items }; Get-Content $Path -Encoding UTF8 | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $items += ($_ | ConvertFrom-Json) } }; return $items }
function Write-Jsonl([string]$Path,$Items) { $dir=Split-Path -Parent $Path; if($dir){New-Item -ItemType Directory -Force $dir|Out-Null}; $enc=New-Object System.Text.UTF8Encoding($false); $lines=@(); foreach($item in @($Items)){$lines+=($item|ConvertTo-Json -Depth 40 -Compress)}; [System.IO.File]::WriteAllLines($Path,$lines,$enc) }
function Clone-Object($Obj) { return (($Obj | ConvertTo-Json -Depth 40 -Compress) | ConvertFrom-Json) }
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$queue=@(Read-Jsonl $QueuePath); if($queue.Count -ne 1544){throw "V4-C1 semantic queue must remain 1544; got $($queue.Count)"}
$queueSeq=@{}; foreach($q in $queue){$queueSeq[[int]$q.sequence]=$q}
$source=@(Read-Jsonl $SourceEvidencePath); $sourceBySeq=@{}; foreach($s in $source){$sourceBySeq[[int]$s.sequence]=$s}; if($sourceBySeq.Count -ne 2394){throw "V4-C1 source evidence expected 2394; got $($sourceBySeq.Count)"}
$recordsBySeq=@{}
foreach($r in @(Read-Jsonl $SeedProgressPath)){ if([string]$r.analysis_mode -eq 'SHA_REUSE'){continue}; $seq=[int]$r.sequence; if($recordsBySeq.ContainsKey($seq)){throw "Duplicate semantic seed sequence: $seq"}; $recordsBySeq[$seq]=$r }
if(-not [string]::IsNullOrWhiteSpace($ShardResultRoot) -and (Test-Path $ShardResultRoot)){
  Get-ChildItem $ShardResultRoot -Recurse -Filter '*.progress.jsonl' | Sort-Object FullName | ForEach-Object {
    foreach($r in @(Read-Jsonl $_.FullName)){ $seq=[int]$r.sequence; if($recordsBySeq.ContainsKey($seq)){throw "Duplicate semantic result sequence while merging: $seq ($($_.FullName))"}; $recordsBySeq[$seq]=$r }
  }
}
foreach($seq in @($recordsBySeq.Keys)){if(-not $queueSeq.ContainsKey([int]$seq)){throw "Semantic worker produced non-pending sequence: $seq"}}
$duplicateMap=Get-Content $DuplicateMapPath -Raw -Encoding UTF8|ConvertFrom-Json; $reuseRecords=@()
foreach($d in @($duplicateMap.sha256_duplicates)){
  $dupSeq=[int]$d.sequence; $canonical=[int]$d.canonical_sequence
  if(-not $recordsBySeq.ContainsKey($canonical)){continue}
  if(-not $sourceBySeq.ContainsKey($dupSeq)){throw "Duplicate source sequence missing from V4-C1 source evidence: $dupSeq"}
  $base=Clone-Object $recordsBySeq[$canonical]; $src=$sourceBySeq[$dupSeq]
  $base.sequence=$dupSeq; $base.source_id=[string]$src.source_id; $base.product_id=[string]$src.product_id; $base.sha256=[string]$d.sha256; $base.canonical_sequence=$canonical
  $base.analysis_mode='SHA_REUSE'; $base.semantic_status='REUSED'; $base.provenance.source_status=[string]$src.status; $base.provenance.sha_verified=$true; $base.provenance.byte_count_v4c1=$src.byte_count; $base.provenance.byte_count_semantic=$null; $base.provenance.semantic_image_fetch=$false; $base.provenance.source_pipeline_redownload=$false
  $base.reuse=[ordered]@{canonical_sequence=$canonical;canonical_sha256=[string]$d.sha256;model_inference_reused=$true;semantic_image_fetch=$false}
  $base.flags.image_generation_called=$false; $base.flags.tiny_snow_api_called=$false; $base.flags.paid_api_called=$false; $base.flags.vision_api_called=$false; $base.flags.local_model_only=$true
  $reuseRecords+=$base
}
$all=@($recordsBySeq.Values)+$reuseRecords; $all=@($all|Sort-Object {[int]$_.sequence}); $pendingAnalyzed=@($recordsBySeq.Keys|Where-Object{$queueSeq.ContainsKey([int]$_)})
$remaining=@(); foreach($q in $queue){if(-not $recordsBySeq.ContainsKey([int]$q.sequence)){$remaining+=$q}}
$pass=@($all|Where-Object{[string]$_.gate.status -eq 'PASS'}); $hold=@($all|Where-Object{[string]$_.gate.status -eq 'HOLD'}); $block=@($all|Where-Object{[string]$_.gate.status -eq 'BLOCK'}); $local=@($all|Where-Object{[string]$_.analysis_mode -eq 'LOCAL_SEMANTIC'}); $reuse=@($all|Where-Object{[string]$_.analysis_mode -eq 'SHA_REUSE'})
Write-Jsonl (Join-Path $OutputDir 'semantic_progress.jsonl') $all; Write-Jsonl (Join-Path $OutputDir 'semantic_evidence.jsonl') $all; Write-Jsonl (Join-Path $OutputDir 'semantic_pass.jsonl') $pass; Write-Jsonl (Join-Path $OutputDir 'semantic_hold.jsonl') $hold; Write-Jsonl (Join-Path $OutputDir 'semantic_block.jsonl') $block; Write-Jsonl (Join-Path $OutputDir 'remaining_semantic_queue.jsonl') $remaining
$progressPath=Join-Path $OutputDir 'semantic_progress.jsonl'; $progressHash=(Get-FileHash $progressPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checkpoint=[ordered]@{schema_version='v4c2.semantic-checkpoint.1';phase=$Phase;v4c1_baseline_head=$Baseline;pending_queue_count=$queue.Count;analyzed_pending_count=$pendingAnalyzed.Count;sha_reuse_count=$reuse.Count;remaining_count=$remaining.Count;progress_sha256=$progressHash;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;source_pipeline_redownload=$false}; $checkpoint|ConvertTo-Json -Depth 20|Set-Content (Join-Path $OutputDir 'semantic_checkpoint.json') -Encoding UTF8
$summary=[ordered]@{schema_version='v4c2.semantic-summary.1';phase=$Phase;v4c1_baseline_head=$Baseline;pending_queue_count=$queue.Count;local_semantic_count=$local.Count;sha_reuse_count=$reuse.Count;total_v4c2_records=$all.Count;gate_pass=$pass.Count;gate_hold=$hold.Count;gate_block=$block.Count;remaining_semantic=$remaining.Count;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;local_model_only=$true;source_pipeline_redownload=$false}; $summary|ConvertTo-Json -Depth 20|Set-Content (Join-Path $OutputDir 'semantic_summary.json') -Encoding UTF8
Write-Host "SEMANTIC_PHASE=$Phase"; Write-Host "SEMANTIC_LOCAL_COUNT=$($local.Count)"; Write-Host "SEMANTIC_SHA_REUSE=$($reuse.Count)"; Write-Host "SEMANTIC_PASS=$($pass.Count)"; Write-Host "SEMANTIC_HOLD=$($hold.Count)"; Write-Host "SEMANTIC_BLOCK=$($block.Count)"; Write-Host "SEMANTIC_REMAINING=$($remaining.Count)"; Write-Host 'IMAGE_GENERATION_CALLED=false'; Write-Host 'TINY_SNOW_API_CALLED=false'; Write-Host 'PAID_API_CALLED=false'; Write-Host 'VISION_API_CALLED=false'; Write-Host 'SOURCE_PIPELINE_REDOWNLOAD=false'
