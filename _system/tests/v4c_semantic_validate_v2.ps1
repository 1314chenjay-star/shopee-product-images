param(
  [ValidateSet('Smoke','Final')][string]$Phase='Smoke',
  [Parameter(Mandatory=$true)][string]$ProgressPath,
  [Parameter(Mandatory=$true)][string]$SummaryPath,
  [string]$QueuePath='_system/v4c/results/semantic_evidence_queue.jsonl',
  [string]$SmokeManifestPath='_system/v4c/semantic/smoke/semantic_smoke_manifest.jsonl',
  [string]$WorkerResumeSummaryPath='',
  [string]$OutputPath='artifacts/semantic-validation.json',
  [string]$ExpectedStableHead='5d49f061e140813b3d229520e9e530f86b27b640',
  [string]$V4C1BaselineHead='a7447b792e65780bc95aa248b9e3a2fd0466f142'
)
$ErrorActionPreference='Stop'
function Read-Jsonl([string]$Path){if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"};$a=@();Get-Content $Path -Encoding UTF8|ForEach-Object{if(-not[string]::IsNullOrWhiteSpace($_)){$a+=($_|ConvertFrom-Json)}};return $a}
function Has-Reason($Record,[string]$Reason){return (@($Record.gate.reasons)-contains$Reason)}

git merge-base --is-ancestor $V4C1BaselineHead HEAD
if($LASTEXITCODE-ne0){throw "HEAD is not descended from V4-C1 baseline $V4C1BaselineHead"}
$stableLine=git ls-remote origin refs/heads/tinysnow-tool-only;$stableHead=($stableLine -split '\s+')[0]
if($stableHead-ne$ExpectedStableHead){throw "Stable HEAD changed: $stableHead"}
$protected=@('_system/v4c/inventory/source_inventory.jsonl','_system/v4c/progress/v4c_source_progress.jsonl','_system/v4c/results/source_evidence.jsonl','_system/v4c/results/duplicate_map.json','_system/v4c/results/failed_sources.json','_system/v4c/results/semantic_evidence_queue.jsonl','_system/v4c/results/aggregate_summary.json','_system/v4c/results/validation.json','_system/start/api_v2.ps1')
git diff --quiet $V4C1BaselineHead -- $protected
if($LASTEXITCODE-ne0){throw 'Frozen V4-C1 evidence or api_v2.ps1 changed'}

$queue=@(Read-Jsonl $QueuePath);if($queue.Count-ne1544){throw "Frozen pending queue changed: $($queue.Count)"}
$queueSeq=@{};$queueMissingSha=@{}
foreach($q in $queue){$seq=[int]($q.sequence);$queueSeq[$seq]=$true;if([string]::IsNullOrWhiteSpace([string]($q.sha256))){$queueMissingSha[$seq]=$true}}
if($queueMissingSha.Count-ne50){throw "Expected 50 frozen V4-C1 SHA gaps; got $($queueMissingSha.Count)"}
$records=@(Read-Jsonl $ProgressPath);$seen=@{};$local=@();$reuse=@();$pass=@();$hold=@();$block=@();$legacyGapBlocks=@();$unexpectedTechnical=@()
$technicalReasons=@('FETCH_FAILED','SOURCE_SHA_MISMATCH','LOCAL_MODEL_UNAVAILABLE','LOCAL_MODEL_OR_DECODE_FAILURE','INVALID_SOURCE_URL','MISSING_PRODUCT_CONTEXT','MISSING_OR_INVALID_SHA256')
foreach($r in $records){
 $seq=[int]($r.sequence);if($seen.ContainsKey($seq)){throw "Duplicate semantic sequence: $seq"};$seen[$seq]=$true
 if([string]($r.schema_version)-ne'v4c2.semantic-evidence.1'){throw "Schema version mismatch: $seq"}
 if([bool]($r.flags.image_generation_called)-or[bool]($r.flags.tiny_snow_api_called)-or[bool]($r.flags.paid_api_called)-or[bool]($r.flags.vision_api_called)){throw "Forbidden API flag: $seq"}
 if(-not[bool]($r.flags.local_model_only)){throw "Not local-model-only: $seq"};if([bool]($r.provenance.source_pipeline_redownload)){throw "Source pipeline redownload flag true: $seq"}
 $mode=[string]($r.analysis_mode);$gate=[string]($r.gate.status);if($gate-notin@('PASS','HOLD','BLOCK')){throw "Invalid gate: $seq $gate"}
 if($mode-eq'LOCAL_SEMANTIC'){
   if(-not$queueSeq.ContainsKey($seq)){throw "LOCAL semantic record not from pending queue: $seq"};$local+=$r
   if(Has-Reason $r 'V4C1_SHA256_MISSING_NO_REDOWNLOAD'){
     if(-not$queueMissingSha.ContainsKey($seq)){throw "Unexpected missing-SHA BLOCK: $seq"};if($gate-ne'BLOCK'-or[string]($r.semantic_status)-ne'BLOCKED'){throw "Missing-SHA record not BLOCKED: $seq"};if([bool]($r.provenance.semantic_image_fetch)){throw "Missing-SHA record touched source URL: $seq"};if([string]($r.provenance.sha256_state)-ne'MISSING_V4C1'){throw "Missing-SHA state mismatch: $seq"};$legacyGapBlocks+=$r
   } else {
     if([string]($r.provenance.sha256_state)-ne'VERIFIED_V4C1'){throw "Analyzed record missing VERIFIED_V4C1 state: $seq"};if(([string]($r.sha256))-notmatch'^[a-f0-9]{64}$'){throw "Analyzed record invalid SHA: $seq"}
   }
 } elseif($mode-eq'SHA_REUSE'){
   $reuse+=$r;if([bool]($r.provenance.semantic_image_fetch)){throw "SHA reuse fetched bytes: $seq"};if(-not[bool]($r.reuse.model_inference_reused)){throw "SHA reuse did not reuse inference: $seq"};if([string]($r.provenance.sha256_state)-ne'REUSED_CANONICAL'){throw "SHA reuse state mismatch: $seq"}
 } else {throw "Unknown analysis_mode: $seq $mode"}
 foreach($reason in $technicalReasons){if(Has-Reason $r $reason){$unexpectedTechnical+=$r;break}}
 if($gate-eq'PASS'){$pass+=$r}elseif($gate-eq'HOLD'){$hold+=$r}else{$block+=$r}
}
if($unexpectedTechnical.Count-gt0){throw "Unexpected technical BLOCK/FAIL records: $($unexpectedTechnical.Count)"}
$summary=Get-Content $SummaryPath -Raw -Encoding UTF8|ConvertFrom-Json
if([bool]($summary.image_generation_called)-or[bool]($summary.tiny_snow_api_called)-or[bool]($summary.paid_api_called)-or[bool]($summary.vision_api_called)-or[bool]($summary.source_pipeline_redownload)){throw 'Forbidden summary flag'}
$checkpointResumeObserved=$false;$familyCount=$null;$subcategoryCount=$null;$uniqueProducts=$null
if($Phase-eq'Smoke'){
 $smoke=@(Read-Jsonl $SmokeManifestPath);if($smoke.Count-ne160){throw "Smoke manifest changed: $($smoke.Count)"};if($local.Count-ne160){throw "Smoke local semantic count must be 160; got $($local.Count)"};if($legacyGapBlocks.Count-ne9){throw "Smoke must prove 9 no-redownload legacy SHA BLOCKs; got $($legacyGapBlocks.Count)"};if($reuse.Count-ne1){throw "Smoke SHA reuse count must be 1; got $($reuse.Count)"}
 $probe=@($reuse|Where-Object{[int]($_.sequence)-eq13-and[int]($_.canonical_sequence)-eq7});if($probe.Count-ne1){throw 'Missing SHA reuse proof 13 -> 7'}
 $families=@{};$subs=@{};$products=@{};foreach($s in $smoke){$families[[string]($s.family)]=$true;$subs[([string]($s.family)+'/'+[string]($s.subcategory))]=$true;$products[[string]($s.product_id)]=$true};$familyCount=$families.Count;$subcategoryCount=$subs.Count;$uniqueProducts=$products.Count
 if($familyCount-ne4-or$subcategoryCount-ne13-or$uniqueProducts-ne127){throw "Cross-category smoke invariant failed families=$familyCount subcategories=$subcategoryCount products=$uniqueProducts"}
 if([string]::IsNullOrWhiteSpace($WorkerResumeSummaryPath)-or-not(Test-Path $WorkerResumeSummaryPath)){throw 'Missing resume summary'};$resume=Get-Content $WorkerResumeSummaryPath -Raw -Encoding UTF8|ConvertFrom-Json;if([int]($resume.checkpoint_skipped_this_run)-lt20){throw 'Checkpoint did not skip first 20 terminal records'};if([int]($resume.covered_after_run)-ne160){throw 'Checkpoint did not reconcile 160 smoke records'};$checkpointResumeObserved=$true
 if([int]($summary.remaining_semantic)-ne1384){throw "Smoke remaining must be 1384; got $($summary.remaining_semantic)"}
} else {
 if($local.Count-ne1544){throw "Final local semantic coverage must be 1544; got $($local.Count)"};if($legacyGapBlocks.Count-ne50){throw "Final no-redownload legacy SHA BLOCK count must be 50; got $($legacyGapBlocks.Count)"};if($reuse.Count-ne4){throw "Final SHA reuse must be 4; got $($reuse.Count)"}
 foreach($pair in @(@(13,7),@(1469,1468),@(1533,1532),@(2307,2304))){$dup=[int]$pair[0];$can=[int]$pair[1];$ok=@($reuse|Where-Object{[int]($_.sequence)-eq$dup-and[int]($_.canonical_sequence)-eq$can});if($ok.Count-ne1){throw "Missing SHA reuse $dup -> $can"}}
 if([int]($summary.remaining_semantic)-ne0){throw "Final remaining semantic must be 0; got $($summary.remaining_semantic)"};foreach($q in $queue){if(-not$seen.ContainsKey([int]($q.sequence))){throw "Final missing pending sequence $($q.sequence)"}}
}
$result=[ordered]@{phase=$Phase;passed=$true;v4c1_baseline_head=$V4C1BaselineHead;stable_head=$stableHead;stable_head_unchanged=$true;v4c1_protected_files_unchanged=$true;api_v2_unchanged=$true;pending_queue_count=1544;pending_with_v4c1_sha=1494;pending_missing_v4c1_sha=50;local_semantic_count=$local.Count;sha_reuse_count=$reuse.Count;gate_pass=$pass.Count;gate_hold=$hold.Count;gate_block=$block.Count;legacy_sha_gap_block=$legacyGapBlocks.Count;checkpoint_resume_observed=$checkpointResumeObserved;smoke_family_count=$familyCount;smoke_subcategory_count=$subcategoryCount;smoke_unique_products=$uniqueProducts;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;local_model_only=$true;source_pipeline_redownload=$false}
$dir=Split-Path -Parent $OutputPath;if(-not[string]::IsNullOrWhiteSpace($dir)){New-Item -ItemType Directory -Force $dir|Out-Null};$result|ConvertTo-Json -Depth 20|Set-Content $OutputPath -Encoding UTF8
Write-Host "SEMANTIC_VALIDATION_PHASE=$Phase";Write-Host 'SEMANTIC_VALIDATION_PASSED=true';Write-Host "SEMANTIC_LOCAL_COUNT=$($local.Count)";Write-Host "SEMANTIC_SHA_REUSE=$($reuse.Count)";Write-Host "SEMANTIC_HOLD=$($hold.Count)";Write-Host "SEMANTIC_BLOCK=$($block.Count)";Write-Host "LEGACY_SHA_GAP_BLOCK=$($legacyGapBlocks.Count)";Write-Host 'IMAGE_GENERATION_CALLED=false';Write-Host 'PAID_API_CALLED=false';Write-Host 'SOURCE_PIPELINE_REDOWNLOAD=false'
