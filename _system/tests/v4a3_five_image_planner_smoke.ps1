$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$start = Join-Path $root '_system\start'

. (Join-Path $start 'api_v2.ps1')
. (Join-Path $start 'excel_reader.ps1')
. (Join-Path $start 'selection_v2.ps1')
. (Join-Path $start 'image_pipeline_v2.ps1')
. (Join-Path $start 'v4a1_guard.ps1')

function Assert-V4A3([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('V4-A.3 smoke failed: ' + $Message) }
}

$synthetic = @()
for ($i = 0; $i -lt 6; $i++) {
    $risk = 0.16 + 0.035 * $i
    $synthetic += [pscustomobject]@{
        path = ('C:\refs\ref' + $i + '.png')
        position = $i
        local_risk_score = $risk
        local_safe_score = (1.0 - $risk)
        edge_density = (0.045 + 0.012 * $i)
        outer_edge_density = (0.035 + 0.008 * $i)
        near_square = $true
    }
}
$analysis = [pscustomobject]@{
    product_id = '90000000001'
    high_variant_conflict = $false
    reference_safety = [object[]]$synthetic
    images = [object[]]$synthetic
}
$product = [pscustomobject]@{ product_id='90000000001'; product_name='測試商品' }
$plan = New-FiveImagePlanV4A3 $product $analysis 2
Assert-V4A3 (@($plan.slots).Count -eq 5) 'planner must create exactly five slots'
$families = @($plan.slots | ForEach-Object { [string]$_.preferred_layout_family })
Assert-V4A3 (@($families | Select-Object -Unique).Count -eq 5) 'five slot layout families must be distinct'
foreach ($slotPlan in @($plan.slots)) {
    Assert-V4A3 (@($slotPlan.selected_reference_paths).Count -ge 1) ([string]$slotPlan.slot + ' must have a reference')
    Assert-V4A3 (@($slotPlan.selected_reference_paths).Count -le 2) ([string]$slotPlan.slot + ' must keep max two references')
}
$mainRef = [string](Get-V4A3PlanSlot $plan 'main').primary_reference_source
$detail1Ref = [string](Get-V4A3PlanSlot $plan 'detail1').primary_reference_source
$detail4Ref = [string](Get-V4A3PlanSlot $plan 'detail4').primary_reference_source
Assert-V4A3 (-not ($mainRef -eq $detail1Ref -and $detail1Ref -eq $detail4Ref)) 'main/detail1/detail4 must not all default to one primary reference when safe alternatives exist'

$highConflict = [pscustomobject]@{
    product_id = '90000000002'
    high_variant_conflict = $true
    reference_safety = [object[]]$synthetic
    images = [object[]]$synthetic
}
$conflictPlan = New-FiveImagePlanV4A3 $product $highConflict 2
foreach ($slotPlan in @($conflictPlan.slots)) {
    Assert-V4A3 (@($slotPlan.selected_reference_paths).Count -eq 1) 'high-conflict products must default to one reference per slot'
}
$conflictPrimary = @($conflictPlan.slots | ForEach-Object { [string]$_.primary_reference_source } | Select-Object -Unique)
Assert-V4A3 ($conflictPrimary.Count -eq 1) 'high-conflict products must keep one safest primary reference across slots rather than chase diversity through variant images'

# Production modules must be product-agnostic. Known regression fixture IDs may appear in tests/docs only.
foreach ($module in @('reference_classifier_v3.ps1','five_image_planner_v3.ps1','layout_memory_v3.ps1','group_validation_v3.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $start $module) -Raw -Encoding UTF8
    foreach ($fixtureId in @('52915734564','58015741169','53615734484','53215734553','57565745174')) {
        Assert-V4A3 (-not $text.Contains($fixtureId)) ($module + ' contains product-ID hardcoding: ' + $fixtureId)
    }
}

# Build five local images without TinySnow. Make detail1 identical to main so group validator must flag detail1 only as the later duplicate.
Add-Type -AssemblyName System.Drawing
$tempDir = Join-Path $env:TEMP ('v4a3_smoke_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
try {
    $slots = @('main','detail1','detail2','detail3','detail4')
    foreach ($index in 0..4) {
        $slot = $slots[$index]
        $path = Join-Path $tempDir ('90000000001_' + $slot + '.jpg')
        if ($slot -eq 'detail1') {
            Copy-Item -LiteralPath (Join-Path $tempDir '90000000001_main.jpg') -Destination $path -Force
            continue
        }
        $bmp = New-Object Drawing.Bitmap 240,240
        $g = [Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([Drawing.Color]::White)
            $x = 15 + $index * 35
            $y = 20 + (($index * 47) % 120)
            $size = 45 + $index * 16
            $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(40 + $index * 35, 80 + $index * 20, 120 + $index * 15))
            try { $g.FillRectangle($brush,$x,$y,$size,$size) } finally { $brush.Dispose() }
            $bmp.Save($path,[Drawing.Imaging.ImageFormat]::Jpeg)
        }
        finally { $g.Dispose(); $bmp.Dispose() }
    }

    $validation = Test-FiveImageGroupV4A3 '90000000001' $tempDir $plan
    Assert-V4A3 (@($validation.failed_slots) -contains 'detail1') 'group validator must flag the later identical detail1 image'

    $checkpoint = Get-CheckpointV2 '90000000001'
    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) { $checkpoint.states.$slot.status = 'done' }
    $checkpoint.finalization_complete = $true
    Save-CheckpointV2 $checkpoint
    Set-V4A3SlotsForRetry '90000000001' @('detail1') 'smoke retry'
    $after = Get-CheckpointV2 '90000000001'
    Assert-V4A3 ($after.states.detail1.status -eq 'pending') 'failed slot must become pending for focused retry'
    Assert-V4A3 ($after.states.main.status -eq 'done') 'passed main slot must remain done'
    Assert-V4A3 ($after.states.detail2.status -eq 'done') 'passed detail2 slot must remain done'
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Compare exact Git bytes to the tested V4-A.2.1 api_v2.ps1 blob. The distribution step separately
# keeps the official API-R3-120S SHA-256 lock after packaging normalization.
$apiBlob = (& git -C $root hash-object -- '_system/start/api_v2.ps1').Trim().ToLowerInvariant()
Assert-V4A3 ($apiBlob -eq '9e81a9c4a0769d5e41b4c1e7dba4b92266c49187') ('API-R3 transport Git blob changed: ' + $apiBlob)

Write-Host 'V4-A.3 Five-Image Planner focused smoke: PASS' -ForegroundColor Green
