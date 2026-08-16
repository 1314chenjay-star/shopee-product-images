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
foreach ($required in @('2公尺','30磅','腰帶','黑色')) {
    if ($prompt -notmatch [regex]::Escape($required)) { throw ('Runtime prompt missing verified/common fact: ' + $required) }
}
$legacyReferenceMarker = $prompt -match 'Reference Safety'
$v4bReferenceContract = ($prompt -match 'V4-B 原圖保真台灣化模式') -and
    ($prompt -match '只編修現有原圖|只允許原圖保真編修|以這張真實原圖為唯一視覺來源') -and
    ($prompt -match '原圖沒有的人物、手、使用場景、商品零件、配件、贈品、顏色、材質、尺寸、數量、功能、認證、功效或安全承諾，一律不得新增')
if (-not ($legacyReferenceMarker -or $v4bReferenceContract)) { throw 'Runtime prompt source/reference safety contract missing.' }
if ($prompt -match '(?<!公)2米') { throw 'Runtime prompt leaked Mainland length unit 2米.' }
foreach ($unsafe in @('危險標題','夜光','真皮','送氣筒','五人聯動','各5組')) {
    if ($prompt -match [regex]::Escape($unsafe)) { throw ('Runtime prompt leaked title/variant-specific text: ' + $unsafe) }
}

$compact = Get-CompactTransportPromptV2 'main' '危險標題 夜光 真皮 送氣筒 五人聯動'
$legacyCompactFacts = ($compact -match '2公尺') -and ($compact -match '30磅') -and ($compact -match '腰帶') -and ($compact -match '黑色')
$v4bCompactContract = ($compact -match 'V4-B EDIT/PRESERVE/LOCALIZE') -and
    ($compact -match '只編修提供的真實原圖') -and
    ($compact -match '看不清就省略，不猜測') -and
    ($compact -match '原圖沒有的人物、場景、零件、功能、材質、尺寸、數量、配件、贈品、認證、功效與安全承諾都禁止新增') -and
    ($compact -match '品牌、型號、SKU與數值不得改義')
if (-not ($legacyCompactFacts -or $v4bCompactContract)) { throw 'Compact runtime source/reference safety contract missing.' }
if ($compact -match '(?<!公)2米') { throw 'Compact retry leaked Mainland length unit 2米.' }
if ($compact -match '夜光|真皮|送氣筒|五人聯動|各5組') { throw 'Compact retry leaked unsafe title/variant-specific text.' }

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '[PASS] Reference Safety: all-original analysis, safe subset selection, title isolation, and V4-B source-preservation contracts passed.' -ForegroundColor Green
