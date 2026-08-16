param(
 [string]$PreservationPath='_system/v4c/preservation/results/image_preservation.jsonl',
 [string]$SemanticQueuePath='_system/v4c/preservation/results/preservation_semantic_queue.jsonl',
 [string]$ProductSummaryPath='_system/v4c/preservation/results/product_preservation_summary.jsonl',
 [string]$GateLockPath='_system/v4c/preservation/PRESERVATION_GATE_LOCK.json',
 [string]$OutputPath='artifacts/preservation-semantic-integration.json',
 [string]$V4C1BaselineHead='a7447b792e65780bc95aa248b9e3a2fd0466f142',
 [string]$ExpectedStableHead='5d49f061e140813b3d229520e9e530f86b27b640'
)
$ErrorActionPreference='Stop'
function Read-Jsonl([string]$Path){if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"};$a=@();Get-Content $Path -Encoding UTF8|ForEach-Object{if(-not[string]::IsNullOrWhiteSpace($_)){$a+=($_|ConvertFrom-Json)}};return $a}
if(-not(Test-Path $GateLockPath)){throw 'Preservation Gate has not been smoke-locked/merged'};$lock=Get-Content $GateLockPath -Raw -Encoding UTF8|ConvertFrom-Json;if(-not[bool]$lock.smoke_passed){throw 'Preservation Gate lock does not record smoke PASS'}
git merge-base --is-ancestor $V4C1BaselineHead HEAD;if($LASTEXITCODE-ne0){throw 'Integration HEAD not descended from frozen V4-C1 baseline'}
$stableLine=git ls-remote origin refs/heads/tinysnow-tool-only;$stableHead=($stableLine -split '\s+')[0];if($stableHead-ne$ExpectedStableHead){throw "Stable HEAD changed: $stableHead"}
$protected=@('_system/v4c/inventory/source_inventory.jsonl','_system/v4c/progress/v4c_source_progress.jsonl','_system/v4c/results/source_evidence.jsonl','_system/v4c/results/duplicate_map.json','_system/v4c/results/failed_sources.json','_system/v4c/results/semantic_evidence_queue.jsonl','_system/v4c/results/aggregate_summary.json','_system/v4c/results/validation.json','_system/start/api_v2.ps1')
git diff --quiet $V4C1BaselineHead -- $protected;if($LASTEXITCODE-ne0){throw 'Integration modified frozen V4-C1 evidence or api_v2.ps1'}
$all=@(Read-Jsonl $PreservationPath);$queue=@(Read-Jsonl $SemanticQueuePath);$products=@(Read-Jsonl $ProductSummaryPath);if($all.Count-lt100-or$all.Count-gt200){throw "Integration is expected to consume Preservation Smoke only; got $($all.Count)"}
$q=@{};foreach($r in $queue){$s=[int]$r.sequence;if($q.ContainsKey($s)){throw "Duplicate semantic queue sequence $s"};$q[$s]=$r;foreach($field in @('source_id','product_id','url','sha256')){if([string]::IsNullOrWhiteSpace([string]$r.$field)){throw "Semantic interface missing $field at sequence $s"}};if([string]$r.semantic_status-ne'PENDING'-or[string]$r.preservation_decision-ne'SEMANTIC_REQUIRED'){throw "Semantic interface state invalid at sequence $s"}}
$expected=0;foreach($r in $all){$s=[int]$r.sequence;$d=[string]$r.decision;if($d-eq'SEMANTIC_REQUIRED'){$expected++;if(-not$q.ContainsKey($s)){throw "Unfinished image not routed to semantic queue: $s"}}elseif($q.ContainsKey($s)){throw "Preserved/BLOCK image incorrectly routed to semantic queue: $s"}}
if($queue.Count-ne$expected){throw "Semantic interface reconciliation failed queue=$($queue.Count) expected=$expected"}
$mixed=@($products|Where-Object{[string]$_.product_state-eq'MIXED_PARTIAL'});if($mixed.Count-lt1){throw 'Integration has no mixed-state product evidence'}
foreach($p in $mixed){foreach($s in @($p.preserved_sequences)){if($q.ContainsKey([int]$s)){throw "Mixed product preserved image leaked downstream: product=$($p.product_id) sequence=$s"}};foreach($s in @($p.semantic_sequences)){if(-not$q.ContainsKey([int]$s)){throw "Mixed product unfinished image missing downstream: product=$($p.product_id) sequence=$s"}}}
$result=[ordered]@{phase='PreservationGate+SemanticQueueIntegration';passed=$true;preservation_image_count=$all.Count;semantic_queue_count=$queue.Count;mixed_partial_products=$mixed.Count;preserved_images_routed_to_semantic=0;blocked_images_routed_to_semantic=0;stable_head=$stableHead;stable_head_unchanged=$true;v4c1_baseline_head=$V4C1BaselineHead;v4c1_protected_files_unchanged=$true;v4c1_turbo_retested=$false;v4b_stable_retested=$false;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;source_pipeline_redownload=$false}
$d=Split-Path -Parent $OutputPath;if($d){New-Item -ItemType Directory -Force $d|Out-Null};$result|ConvertTo-Json -Depth 20|Set-Content $OutputPath -Encoding UTF8
Write-Host 'PRESERVATION_SEMANTIC_INTEGRATION_PASSED=true';Write-Host "SEMANTIC_QUEUE_COUNT=$($queue.Count)";Write-Host "MIXED_PARTIAL_PRODUCTS=$($mixed.Count)";Write-Host 'V4C1_TURBO_RETESTED=false';Write-Host 'V4B_STABLE_RETESTED=false';Write-Host 'IMAGE_GENERATION_CALLED=false';Write-Host 'TINY_SNOW_API_CALLED=false'
