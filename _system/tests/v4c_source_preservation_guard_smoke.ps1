$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'guards\source_preservation_guard.ps1')

$root = Join-Path $env:RUNNER_TEMP 'TinySnow-Source-Preservation-Guard-Smoke'
if ([string]::IsNullOrWhiteSpace([string]$env:RUNNER_TEMP)) { $root = Join-Path $env:TEMP 'TinySnow-Source-Preservation-Guard-Smoke' }
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $root -Force | Out-Null
$sourcePath = Join-Path $root 'source.png'
$candidatePath = Join-Path $root 'candidate.png'
$restoredPath = Join-Path $root 'restored.png'

function New-SourceFixture([string]$Path) {
    $bmp = New-Object System.Drawing.Bitmap(80,80,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::White)
            $g.FillRectangle([System.Drawing.Brushes]::Gold,0,0,40,20)
            $g.FillRectangle([System.Drawing.Brushes]::Black,4,4,26,4)
            $g.FillRectangle([System.Drawing.Brushes]::Black,4,11,20,4)
            $g.FillEllipse([System.Drawing.Brushes]::Red,22,28,36,36)
            $g.DrawRectangle([System.Drawing.Pens]::DarkRed,22,28,36,36)
        } finally { $g.Dispose() }
        $bmp.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bmp.Dispose() }
}

function New-CorruptedCandidate([string]$Source,[string]$Path) {
    $src = [System.Drawing.Image]::FromFile($Source)
    $bmp = New-Object System.Drawing.Bitmap(160,160,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::White)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($src,0,0,160,160)
            # Simulate the real canary regression: remove/change the protected badge/text area.
            $g.FillRectangle([System.Drawing.Brushes]::LightBlue,0,0,80,40)
        } finally { $g.Dispose() }
        $bmp.Save($Path,[System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bmp.Dispose(); $src.Dispose() }
}

New-SourceFixture $sourcePath
New-CorruptedCandidate $sourcePath $candidatePath
$regions = @([pscustomobject]@{name='source_badge_text';x=0.0;y=0.0;width=0.5;height=0.25})

$routePreserve = Get-TinySnowSourcePreservationRoute -Action 'PRESERVE' -ProtectedRegions @()
if ($routePreserve.route -ne 'DETERMINISTIC_ONLY' -or $routePreserve.paid_generation_allowed) { throw 'PRESERVE routing guard failed.' }
$routeCleanup = Get-TinySnowSourcePreservationRoute -Action 'CLEANUP' -ProtectedRegions @()
if ($routeCleanup.route -ne 'DETERMINISTIC_ONLY' -or $routeCleanup.paid_generation_allowed) { throw 'CLEANUP routing guard failed.' }
$routeBlocked = Get-TinySnowSourcePreservationRoute -Action 'PROCESS_LOCALIZE' -ProtectedRegions @()
if ($routeBlocked.route -ne 'BLOCKED_NO_PROTECTED_REGION' -or $routeBlocked.paid_generation_allowed) { throw 'Unprotected generative routing guard failed.' }
$routeProtected = Get-TinySnowSourcePreservationRoute -Action 'PROCESS_LOCALIZE' -ProtectedRegions $regions
if ($routeProtected.route -ne 'GENERATIVE_WITH_PROTECTED_REGION_RESTORE' -or -not $routeProtected.paid_generation_allowed) { throw 'Protected generative routing guard failed.' }

$before = Test-TinySnowProtectedRegions -SourcePath $sourcePath -CandidatePath $candidatePath -ProtectedRegions $regions
if ($before.passed) { throw 'Corrupted protected region was not rejected.' }
Restore-TinySnowProtectedRegions -SourcePath $sourcePath -CandidatePath $candidatePath -OutputPath $restoredPath -ProtectedRegions $regions | Out-Null
$after = Test-TinySnowProtectedRegions -SourcePath $sourcePath -CandidatePath $restoredPath -ProtectedRegions $regions
if (-not $after.passed) { throw ('Restored protected region did not pass deterministic QA: ' + ($after | ConvertTo-Json -Depth 8 -Compress)) }

$validation = [ordered]@{
    schema_version = 'tinysnow.source-preservation-guard-validation.1'
    status = 'PASS'
    zero_paid = $true
    image_generation_called = $false
    stable_mutation = $false
    c5_3_rerun = $false
    routing = [ordered]@{
        preserve = $routePreserve.route
        cleanup = $routeCleanup.route
        unprotected_generative = $routeBlocked.route
        protected_generative = $routeProtected.route
    }
    negative_control_rejected = (-not $before.passed)
    restored_control_passed = $after.passed
    protected_region_before = $before
    protected_region_after = $after
    required_execution_contract = @(
        'PRESERVE/CLEANUP must use deterministic-only path',
        'Generative edit without protected regions is blocked',
        'Generative edit with protected regions requires deterministic source-region restore',
        'Post-generation protected-region difference must pass before promotion'
    )
}
$validationPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'control\source_preservation_guard_validation.json'
$validation | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $validationPath -Encoding UTF8
Write-Host ($validation | ConvertTo-Json -Depth 12)
