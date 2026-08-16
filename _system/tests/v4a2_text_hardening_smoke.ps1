$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

if ($null -eq (Get-Command Get-V4A2AllowedOutputText -ErrorAction SilentlyContinue)) { throw 'Reference hardening layer not loaded.' }

$rows575 = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1'},
    @{0='57565745174';1='';2='危險商品標題 穩定支撐 彈力調節 訓練輔助 WORLD TOUR';3='Sports & Outdoors/Volleyball/Others';4='https://example.invalid/a.jpg';5='款式';6='美璐捷排球訓練器材(VZJ-004S)'}
)
$p575 = @(Convert-ShopeeRowsToProducts $rows575)[0]
$selDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selDir -Force | Out-Null
$p575 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$prompt575 = Get-PromptV2 'detail1' ([string]$p575.product_name)
$legacyExactAllowlist = $prompt575 -match '成品允許文字逐字白名單'
$v4bTextContract = ($prompt575 -match 'V4-B 原圖保真台灣化模式') -and
    ($prompt575 -match '只翻譯你在參考圖中能清楚辨識的文字') -and
    ($prompt575 -match '看不清楚、被遮住、語意不確定或來源彼此衝突的文字不要猜') -and
    ($prompt575 -match '禁止自行新增或推測')
if (-not ($legacyExactAllowlist -or $v4bTextContract)) { throw 'Text hardening contract missing.' }
if ($prompt575 -notmatch 'VZJ-004S') { throw 'Verified model missing from factual prompt context.' }
foreach ($unsafe in @('危險商品標題','WORLD TOUR','穩定支撐｜','彈力調節｜','訓練輔助｜')) {
    if ($prompt575 -match [regex]::Escape($unsafe)) { throw ('Unsafe title text leaked into runtime prompt: ' + $unsafe) }
}
$legacySurfaceRule = ($prompt575 -match '商品表面本身有未驗證品牌字') -and ($prompt575 -match '禁止重建、猜測或補全任何可讀字樣')
$v4bUnitRule = ($prompt575 -match '圖示與單位文字硬限制') -and ($prompt575 -match '拉丁字母') -and ($prompt575 -match '單位縮寫')
if (-not ($legacySurfaceRule -or $v4bUnitRule)) { throw 'Unit/surface text hardening rule missing.' }

$rows532 = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1';7='et_title_option_2_for_variation_1'},
    @{0='53215734553';1='';2='真皮籃球 OFFICIAL SIZE INDOOR OUTDOOR MARBURY';3='Sports & Outdoors/Basketball/Others';4='https://example.invalid/b.jpg';5='款式';6='真皮加厚款';7='基礎款'}
)
$p532 = @(Convert-ShopeeRowsToProducts $rows532)[0]
$p532 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$prompt532 = Get-PromptV2 'detail2' ([string]$p532.product_name)
foreach ($unsafe in @('真皮籃球','MARBURY','OFFICIAL SIZE','INDOOR OUTDOOR')) {
    if ($prompt532 -match [regex]::Escape($unsafe)) { throw ('532 title/forbidden token leaked into prompt: ' + $unsafe) }
}
$allowed532 = @(Get-V4A2AllowedOutputText $p532 'detail2')
if ($allowed532 -contains '真皮') { throw 'Variant-specific material entered output allowlist.' }
if ($allowed532 -notcontains '商品結構與細節展示') { throw 'Safe slot title missing.' }

$compact532 = Get-CompactTransportPromptV2 'detail2' ([string]$p532.product_name)
foreach ($unsafe in @('真皮籃球','MARBURY','OFFICIAL SIZE','INDOOR OUTDOOR')) {
    if ($compact532 -match [regex]::Escape($unsafe)) { throw ('Compact prompt seeded forbidden token: ' + $unsafe) }
}
$legacyCompactHardening = ($compact532 -match '商品表面印刷') -and ($compact532 -match '拉丁字母') -and ($compact532 -match '單位縮寫') -and ($compact532 -match '禁止重建、猜測或補全可讀字樣')
$v4bCompactHardening = ($compact532 -match 'V4-B EDIT/PRESERVE/LOCALIZE') -and
    ($compact532 -match '只編修提供的真實原圖') -and
    ($compact532 -match '看不清就省略，不猜測') -and
    ($compact532 -match '原圖沒有的人物、場景、零件、功能、材質、尺寸、數量、配件、贈品、認證、功效與安全承諾都禁止新增') -and
    ($compact532 -match '品牌、型號、SKU與數值不得改義') -and
    ($compact532 -match 'KG、LB、CM、MM、IN')
if (-not ($legacyCompactHardening -or $v4bCompactHardening)) { throw 'Compact text hardening contract missing.' }

Write-Host '[PASS] Text hardening: unsafe title isolation, variant-material isolation, source-aware text rules, and unit-icon suppression passed.' -ForegroundColor Green
