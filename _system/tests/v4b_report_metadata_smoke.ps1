$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
function Assert-V4BMetadata([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('V4-B report metadata smoke failed: ' + $Message) }
}

$cases = @(
    [pscustomobject]@{file='v4b-live-safety-r2.yml';round='R2';slug='r2';artifact='TinySnow-V4-B-Safety-R2'},
    [pscustomobject]@{file='v4b-live-safety-r3.yml';round='R3';slug='r3';artifact='TinySnow-V4-B-Safety-R3'},
    [pscustomobject]@{file='v4b-live-safety-r4.yml';round='R4';slug='r4';artifact='TinySnow-V4-B-Safety-R4'},
    [pscustomobject]@{file='v4b-live-overlay-r6.yml';round='R6';slug='r6';artifact='TinySnow-V4-B-Verified-Overlay-R6'}
)
foreach ($case in $cases) {
    $path = Join-Path $root ('.github\workflows\' + $case.file)
    Assert-V4BMetadata (Test-Path -LiteralPath $path -PathType Leaf) ('missing workflow: ' + $case.file)
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    Assert-V4BMetadata ($text -match ('V4B_SAFETY_ROUND:\s*' + [regex]::Escape($case.round))) ($case.file + ' round metadata mismatch')
    Assert-V4BMetadata ($text -match ('V4B_SAFETY_SLUG:\s*' + [regex]::Escape($case.slug))) ($case.file + ' slug metadata mismatch')
    Assert-V4BMetadata ($text -match ('V4B_ARTIFACT_NAME:\s*' + [regex]::Escape($case.artifact))) ($case.file + ' artifact name mismatch')
    Assert-V4BMetadata ($text -match ('live_e2e_output_v4b_safety_' + [regex]::Escape($case.slug))) ($case.file + ' upload path mismatch')
}

$runner = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'v4b_live_safety_r2.ps1') -Raw -Encoding UTF8
foreach ($field in @('schema_version','round=$round','head_sha','run_id','run_attempt','workflow_name','artifact_name','artifact_id_status','summaryName')) {
    Assert-V4BMetadata ($runner -match [regex]::Escape($field)) ('dynamic safety summary missing field: ' + $field)
}
Assert-V4BMetadata ($runner -notmatch "version='V4-B safety R2'") 'legacy fixed R2 version remains in safety runner'
Assert-V4BMetadata ($runner -notmatch "'v4b_safety_r2_summary.json'") 'legacy fixed R2 summary filename remains in safety runner'

$closureWorkflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\v4b-live-closure-r7.yml') -Raw -Encoding UTF8
foreach ($required in @('id: payload','steps.payload.outputs.artifact-id','v4b_closure_r7_artifact_receipt.json','artifact_id = $env:PAYLOAD_ARTIFACT_ID','head_sha = $env:GITHUB_SHA','run_id = $env:GITHUB_RUN_ID')) {
    Assert-V4BMetadata ($closureWorkflow -match [regex]::Escape($required)) ('R7 artifact receipt missing: ' + $required)
}

$detail3Workflow = Get-Content -LiteralPath (Join-Path $root '.github\workflows\v4b-live-detail3-r8.yml') -Raw -Encoding UTF8
foreach ($required in @('RUN-V4B-DETAIL3-R8','id: payload','steps.payload.outputs.artifact-id','v4b_detail3_r8_artifact_receipt.json','artifact_id = $env:PAYLOAD_ARTIFACT_ID','head_sha = $env:GITHUB_SHA','run_id = $env:GITHUB_RUN_ID')) {
    Assert-V4BMetadata ($detail3Workflow -match [regex]::Escape($required)) ('R8 artifact receipt missing: ' + $required)
}

Write-Host 'V4-B round/head/run/artifact metadata smoke: PASS' -ForegroundColor Green
