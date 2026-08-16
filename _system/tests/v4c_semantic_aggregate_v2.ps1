param(
  [ValidateSet('Smoke','Final')][string]$Phase='Smoke',
  [string]$QueuePath='_system/v4c/results/semantic_evidence_queue.jsonl',
  [string]$SourceEvidencePath='_system/v4c/results/source_evidence.jsonl',
  [string]$DuplicateMapPath='_system/v4c/results/duplicate_map.json',
  [string]$SeedProgressPath='',
  [string]$ShardResultRoot='',
  [string]$OutputDir='artifacts/semantic-aggregate'
)
$ErrorActionPreference='Stop'

# Do not inspect $LASTEXITCODE after invoking another PowerShell script.
# On Windows PowerShell 5.1 it may retain the exit code from an unrelated
# native command used inside the child script (for example Get-FileHash/git).
# With ErrorActionPreference=Stop, a real child-script failure already throws.
& .\_system\tests\v4c_semantic_aggregate.ps1 -Phase $Phase -QueuePath $QueuePath -SourceEvidencePath $SourceEvidencePath -DuplicateMapPath $DuplicateMapPath -SeedProgressPath $SeedProgressPath -ShardResultRoot $ShardResultRoot -OutputDir $OutputDir

$required = @(
  'semantic_progress.jsonl',
  'semantic_evidence.jsonl',
  'semantic_pass.jsonl',
  'semantic_hold.jsonl',
  'semantic_block.jsonl',
  'remaining_semantic_queue.jsonl',
  'semantic_checkpoint.json',
  'semantic_summary.json'
)
foreach($name in $required){
  $path = Join-Path $OutputDir $name
  if(-not(Test-Path $path)){ throw "Base semantic aggregate did not create required output: $path" }
}

function Patch-Jsonl([string]$Path){
  $items=@()
  Get-Content $Path -Encoding UTF8 | ForEach-Object {
    if(-not[string]::IsNullOrWhiteSpace($_)){
      $r=$_|ConvertFrom-Json
      if([string]($r.analysis_mode)-eq'SHA_REUSE'){
        $r.provenance.sha256_state='REUSED_CANONICAL'
        $r.provenance.semantic_image_fetch=$false
        $r.provenance.source_pipeline_redownload=$false
      }
      $items+=$r
    }
  }
  $enc=New-Object System.Text.UTF8Encoding($false)
  $lines=@();foreach($r in $items){$lines+=($r|ConvertTo-Json -Depth 40 -Compress)}
  [System.IO.File]::WriteAllLines($Path,$lines,$enc)
}
foreach($name in @('semantic_progress.jsonl','semantic_evidence.jsonl','semantic_pass.jsonl','semantic_hold.jsonl','semantic_block.jsonl')){
  Patch-Jsonl (Join-Path $OutputDir $name)
}
$progressPath=Join-Path $OutputDir 'semantic_progress.jsonl'
$checkpointPath=Join-Path $OutputDir 'semantic_checkpoint.json'
$cp=Get-Content $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json
$cp.progress_sha256=(Get-FileHash $progressPath -Algorithm SHA256).Hash.ToLowerInvariant()
$cp|ConvertTo-Json -Depth 20|Set-Content $checkpointPath -Encoding UTF8
Write-Host 'SHA_REUSE_PROVENANCE_NORMALIZED=true'
Write-Host 'SEMANTIC_AGGREGATE_V2_OUTPUTS_VERIFIED=true'
