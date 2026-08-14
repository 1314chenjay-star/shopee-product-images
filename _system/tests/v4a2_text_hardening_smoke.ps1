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
if ($prompt575 -notmatch '成品允許文字逐字白名單') { throw 'Exact output text allowlist section missing.' }
if ($prompt575 -notmatch 'VZJ-004S') { throw 'Verified model missing from hard allowlist.' }
foreach ($unsafe in @('危險商品標題','WORLD TOUR','穩定支撐｜','彈力調節｜','訓練輔助｜')) {
    if ($prompt575 -match [regex]::Escape($unsafe)) { throw ('Unsafe title text leaked into exact allowlist prompt: ' + $unsafe) }
}
if ($prompt575 -notmatch '商品表面本身有未驗證品牌字') { throw 'Surface marking suppression rule missing.' }
if ($prompt575 -notmatch '圖示與單位硬限制' -or $prompt575 -notmatch 'KG、LB、CM') { throw 'Unit-icon hardening rule missing.' }
if ($prompt575 -notmatch 'SUPER、MARBURY、OFFICIAL') { throw 'Final surface-text examples missing.' }

$rows532 = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1';7='et_title_option_2_for_variation_1'},
    @{0='53215734553';1='';2='真皮籃球 OFFICIAL SIZE INDOOR OUTDOOR MARBURY';3='Sports & Outdoors/Basketball/Others';4='https://example.invalid/b.jpg';5='款式';6='真皮加厚款';7='基礎款'}
)
$p532 = @(Convert-ShopeeRowsToProducts $rows532)[0]
$p532 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$prompt532 = Get-PromptV2 'detail2' ([string]$p532.product_name)
foreach ($unsafe in @('真皮籃球')) {
    if ($prompt532 -match [regex]::Escape($unsafe)) { throw ('532 title text leaked: ' + $unsafe) }
}
$allowed532 = @(Get-V4A2AllowedOutputText $p532 'detail2')
if ($allowed532 -contains '真皮') { throw 'Variant-specific material entered output allowlist.' }
if ($allowed532 -notcontains '商品結構與細節展示') { throw 'Safe slot title missing.' }

$compact532 = Get-CompactTransportPromptV2 'detail2' ([string]$p532.product_name)
if ($compact532 -match '真皮籃球') { throw 'Compact prompt leaked product title.' }
if ($compact532 -notmatch '商品表面印刷') { throw 'Compact surface marking suppression missing.' }
if ($compact532 -notmatch 'KG、LB、CM' -or $compact532 -notmatch 'SUPER、MARBURY、OFFICIAL') { throw 'Compact final hardening missing.' }

Write-Host '[PASS] V4-A.2 exact text allowlist, unit-icon suppression, and unverified surface-marking hardening passed.' -ForegroundColor Green
