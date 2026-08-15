$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$rows = @(
    @{0='et_title_product_id';1='et_title_product_name';2='et_title_product_category';3='ps_item_cover_image';4='et_title_variation_1';5='et_title_option_1_for_variation_1';6='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='籃球訓練阻力繩';2='Sports & Outdoors/Basketball/Training';3='https://example.invalid/580.jpg';4='規格';5='黑色2米30磅+腰帶一組';6='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
if ($null -eq $product) { throw 'Menu loader fixture construction failed.' }
$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8

$before = Get-PromptV2 'main' ([string]$product.product_name)
if ($before -notmatch '2公尺' -or $before -match '(?<!公)2米' -or $before -notmatch '籃球訓練阻力繩') { throw 'Final runtime was not Taiwan-localized before legacy reload.' }
if ($before -notmatch '成品允許文字逐字白名單') { throw 'Exact-text hardening missing before legacy reload.' }

# Simulate the historical menu loader bug: v4a1_visual_truth.ps1 was sourced again after v4a1_guard.ps1.
. (Join-Path $startRoot 'v4a1_visual_truth.ps1')

$after = Get-PromptV2 'main' ([string]$product.product_name)
if ($after -notmatch '2公尺' -or $after -match '(?<!公)2米' -or $after -notmatch '籃球訓練阻力繩') { throw 'Legacy visual guard reload overwrote Taiwan localization.' }
if ($after -notmatch '成品允許文字逐字白名單') { throw 'Legacy visual guard reload overwrote exact-text hardening.' }
if ($after -notmatch 'Reference Safety') { throw 'Legacy visual guard reload overwrote Reference Safety.' }

Write-Host '[PASS] V4-A.2 menu loader regression: duplicate legacy visual-guard load cannot overwrite Reference Safety, exact-text hardening, or Taiwan localization.' -ForegroundColor Green
