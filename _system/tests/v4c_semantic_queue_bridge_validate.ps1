param(
  [string]$IntegrationResultPath='artifacts/integration/preservation-semantic-integration.json',
  [string]$GateLockPath='_system/v4c/preservation/PRESERVATION_GATE_LOCK.json',
  [string]$QueuePath='_system/v4c/preservation/results/preservation_semantic_queue.jsonl',
  [string]$ProgressPath='artifacts/preservation-semantic-final/semantic_progress.jsonl',
  [string]$PlanSummaryPath='artifacts/preservation-semantic-plan/plan_summary.json',
  [string]$SummaryPath='artifacts/preservation-semantic-final/semantic_summary.json',
  [string]$OutputPath='artifacts/preservation-semantic-final/validation.json',
  [string]$ExpectedStableHead='5d49f061e140813b3d229520e9e530f86b27b640',
  [string]$V4C1BaselineHead='a7447b792e65780bc95aa248b9e3a2fd0466f142'
)
$ErrorActionPreference='Stop'
function Read-Jsonl([string]$Path){$items=@();if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"};Get-Content $Path -Encoding UTF8|ForEach-Object{if(-not[string]::IsNullOrWhiteSpace($_)){$items+=($_|ConvertFrom-Json)}};return $items}
foreach($p in @($IntegrationResultPath,$GateLockPath,$PlanSummaryPath,$SummaryPath)){if(-not(Test-Path $p)){throw "Missing validation input: $p"}}
$integration=Get-Content $IntegrationResultPath -Raw -Encoding UTF8|ConvertFrom-Json
$lock=Get-Content $GateLockPath -Raw -Encoding UTF8|ConvertFrom-Json
$plan=Get-Content $PlanSummaryPath -Raw -Encoding UTF8|ConvertFrom-Json
$summary=Get-Content $SummaryPath -Raw -Encoding UTF8|ConvertFrom-Json
if(-not[bool]$integration.passed){throw 'Preservation -> Semantic interface did not PASS'}
if(-not[bool]$lock.smoke_passed){throw 'Preservation Gate lock is not PASS'}
$queue=@(Read-Jsonl $QueuePath);$progress=@(Read-Jsonl $ProgressPath)
$expected=[int]$lock.semantic_required_count
if($queue.Count-ne$expected){throw "Filtered queue count mismatch: $($queue.Count) != $expected"}
if($progress.Count-ne$queue.Count){throw "Semantic terminal coverage mismatch: $($progress.Count) != $($queue.Count)"}
if([int]$plan.filtered_queue_count-ne$queue.Count){throw 'Bridge plan queue count mismatch'}
if([int]$summary.terminal_count-ne$queue.Count -or [int]$summary.remaining_semantic-ne 0){throw 'Bridge semantic summary did not reach terminal coverage'}
$queueSeq=@{};foreach($q in $queue){$seq=[int]$q.sequence;$queueSeq[$seq]=$q;if([string]$q.preservation_decision-ne'SEMANTIC_REQUIRED'){throw "Non-semantic-required queue sequence: $seq"}}
$seen=@{};foreach($r in $progress){
  $seq=[int]$r.sequence;if($seen.ContainsKey($seq)){throw "Duplicate semantic result: $seq"};$seen[$seq]=$true
  if(-not$queueSeq.ContainsKey($seq)){throw "Semantic result leaked outside filtered queue: $seq"}
  if([string]$r.gate.status -notin @('PASS','HOLD','BLOCK')){throw "Invalid gate status at $seq"}
  if([bool]$r.flags.image_generation_called -or [bool]$r.flags.tiny_snow_api_called -or [bool]$r.flags.paid_api_called -or [bool]$r.flags.vision_api_called){throw "Forbidden API flag at $seq"}
  if([bool]$r.provenance.source_pipeline_redownload){throw "Source pipeline redownload flag at $seq"}
}
foreach($seq in $queueSeq.Keys){if(-not$seen.ContainsKey([int]$seq)){throw "Filtered queue sequence missing terminal semantic result: $seq"}}
if($queueSeq.ContainsKey(13) -and $queueSeq.ContainsKey(7)){
  $r13=@($progress|Where-Object{[int]$_.sequence-eq13})[0]
  if([string]$r13.analysis_mode-ne'SHA_REUSE' -or [int]$r13.canonical_sequence-ne7){throw 'Required SHA reuse 13 -> 7 was not preserved across integration'}
  if([bool]$r13.provenance.semantic_image_fetch){throw 'SHA reuse sequence 13 performed semantic image fetch'}
}
if([bool]$summary.image_generation_called -or [bool]$summary.tiny_snow_api_called -or [bool]$summary.paid_api_called -or [bool]$summary.vision_api_called -or [bool]$summary.source_pipeline_redownload){throw 'Forbidden summary flag detected'}
$stableLine=git ls-remote origin refs/heads/tinysnow-tool-only;$stableHead=($stableLine -split '\s+')[0]
if($stableHead-ne$ExpectedStableHead){throw "Stable HEAD changed: $stableHead"}
git merge-base --is-ancestor $V4C1BaselineHead HEAD;if($LASTEXITCODE-ne0){throw 'Current HEAD is not descended from frozen V4-C1 baseline'}
$protected=@('_system/v4c/inventory/source_inventory.jsonl','_system/v4c/progress/v4c_source_progress.jsonl','_system/v4c/results/source_evidence.jsonl','_system/v4c/results/duplicate_map.json','_system/v4c/results/failed_sources.json','_system/v4c/results/semantic_evidence_queue.jsonl','_system/v4c/results/aggregate_summary.json','_system/v4c/results/validation.json','_system/start/api_v2.ps1')
git diff --quiet $V4C1BaselineHead -- $protected;if($LASTEXITCODE-ne0){throw 'Frozen V4-C1 protected evidence changed'}
$out=[ordered]@{phase='PreservationGateToSemanticQueue';passed=$true;preservation_smoke_retested=$false;v4c1_retested=$false;v4b_retested=$false;filtered_queue_count=$queue.Count;semantic_terminal_count=$progress.Count;local_semantic_count=[int]$summary.local_semantic_count;sha_reuse_count=[int]$summary.sha_reuse_count;gate_pass=[int]$summary.gate_pass;gate_hold=[int]$summary.gate_hold;gate_block=[int]$summary.gate_block;remaining_semantic=[int]$summary.remaining_semantic;sha_reuse_13_to_7=($queueSeq.ContainsKey(13)-and$queueSeq.ContainsKey(7));stable_head=$stableHead;stable_head_unchanged=$true;v4c1_protected_files_unchanged=$true;source_pipeline_redownload=$false;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false}
$dir=Split-Path -Parent $OutputPath;if($dir){New-Item -ItemType Directory -Force $dir|Out-Null};$out|ConvertTo-Json -Depth 30|Set-Content $OutputPath -Encoding UTF8
Write-Host 'PRESERVATION_TO_SEMANTIC_QUEUE_PASS=true';Write-Host "FILTERED_QUEUE_COUNT=$($queue.Count)";Write-Host "SEMANTIC_TERMINAL_COUNT=$($progress.Count)";Write-Host "SHA_REUSE_COUNT=$([int]$summary.sha_reuse_count)";Write-Host "HOLD=$([int]$summary.gate_hold)";Write-Host "BLOCK=$([int]$summary.gate_block)";Write-Host 'PRESERVATION_SMOKE_RETESTED=false';Write-Host 'V4C1_RETESTED=false';Write-Host 'V4B_RETESTED=false';Write-Host 'SOURCE_PIPELINE_REDOWNLOAD=false';Write-Host 'IMAGE_GENERATION_CALLED=false';Write-Host 'PAID_API_CALLED=false'
