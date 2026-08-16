$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

if ($null -eq (Get-Command Get-V4A2ImageSignal -ErrorAction SilentlyContinue)) { throw 'V4-A.2 runtime layer was not loaded by v4a1_guard.ps1.' }

$rows = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1';7='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='TEST-580';2='危險標題 夜光 真皮 送氣筒 五人聯動';3='Sports & Outdoors/Basketball/Training';4='https://example.invalid/cover.jpg';5='規格';6='黑色2米30磅+腰帶一組';7='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
if ($null -eq $product) { throw 'V4-A.2 fixture product construction failed.' }

$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8

Add-Type -AssemblyName System.Drawing
$tmp = Join-Path $systemRoot 'v4a2_smoke_images'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

function New-SmokeImage([string]$Path, [bool]$Promo, [int]$Variant) {
    $bmp = New-Object Drawing.Bitmap 600,600
    $g = [Drawing.Graphics]::FromImage($bmp)
    $pen = $null; $brush = $null
    try {
        $g.Clear([Drawing.Color]::White)
        $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::Black)
        if ($Promo) {
            for ($i=0; $i -lt 12; $i++) {
                $y = 10 + ($i * 20)
                $g.FillRectangle($brush, 10, $y, 560, 7)
            }
            for ($i=0; $i -lt 10; $i++) {
                $x = 15 + ($i * 55)
                $g.FillRectangle($brush, $x, 500, 30, 55)
            }
        }
        else {
            if ($Variant -eq 1) { $g.FillEllipse($brush, 185, 185, 230, 230) }
            else { $g.FillRectangle($brush, 205, 160, 190, 280) }
        }
        $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally {
        if ($null -ne $brush) { $brush.Dispose() }
        if ($null -ne $pen) { $pen.Dispose() }
        $g.Dispose(); $bmp.Dispose()
    }
}

$p0 = Join-Path $tmp '00_main_original.jpg'
$p1 = Join-Path $tmp '01_detail_original.jpg'
$p2 = Join-Path $tmp '02_detail_original.jpg'
New-SmokeImage $p0 $true 0
New-SmokeImage $p1 $false 1
New-SmokeImage $p2 $false 2

$analysis = Analyze-ProductImagesV2 '58015741169' ([string[]]@($p0,$p1,$p2))
if (-not [bool]$analysis.all_originals_participated) { throw 'All-original participation flag missing.' }
if (@($analysis.images).Count -ne 3) { throw 'Not all original images participated in Reference Safety analysis.' }
if (-not [bool]$analysis.high_variant_conflict) { throw 'Variant conflict was not detected.' }
$refs = @(Get-ReferencesForSlotV2 $analysis 'main' 2)
if ($refs.Count -ne 1) { throw ('High-conflict product must use one safe reference; got ' + $refs.Count) }
if ((Split-Path $refs[0] -Leaf) -match '^00_main_original') { throw 'Promotional cover should not outrank cleaner gallery references in this fixture.' }

$prompt = Get-PromptV2 'main' '危險標題 夜光 真皮 送氣筒 五人聯動'
foreach ($required in @('2公尺','30磅','腰帶','黑色','Reference Safety')) {
    if ($prompt -notmatch [regex]::Escape($required)) { throw ('Runtime prompt missing: ' + $required) }
}
if ($prompt -match '(?<!公)2米') { throw 'Runtime prompt leaked Mainland length unit 2米.' }
foreach ($unsafe in @('危險標題','夜光','真皮','送氣筒','五人聯動','各5組')) {
    if ($prompt -match [regex]::Escape($unsafe)) { throw ('Runtime prompt leaked title/variant-specific text: ' + $unsafe) }
}
$compact = Get-CompactTransportPromptV2 'main' '危險標題 夜光 真皮 送氣筒 五人聯動'
foreach ($required in @('2公尺','30磅','腰帶','黑色')) {
    if ($compact -notmatch [regex]::Escape($required)) { throw ('Compact runtime prompt missing: ' + $required) }
}
if ($compact -match '(?<!公)2米') { throw 'Compact retry leaked Mainland length unit 2米.' }
if ($compact -match '夜光|真皮|送氣筒|五人聯動|各5組') { throw 'Compact retry leaked unsafe title/variant-specific text.' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '[PASS] V4-A.2 Reference Safety: runtime loader, all-original analysis, safe subset selection, Taiwan-localized factual output, prompt title isolation, and compact retry facts passed.' -ForegroundColor Green
