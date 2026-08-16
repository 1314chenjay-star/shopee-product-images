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
if ($before -notmatch '圖片文字穩定硬限制 V4-A\.2\.1') { throw 'V4-A.2.1 text stability missing before legacy reload.' }
if ($before -notmatch 'V4-A\.3 五圖整體規劃') { throw 'V4-A.3 Five-Image Planner prompt layer missing before legacy reload.' }

# Simulate the historical menu loader bug: v4a1_visual_truth.ps1 was sourced again after v4a1_guard.ps1.
. (Join-Path $startRoot 'v4a1_visual_truth.ps1')

$after = Get-PromptV2 'main' ([string]$product.product_name)
if ($after -notmatch '2公尺' -or $after -match '(?<!公)2米' -or $after -notmatch '籃球訓練阻力繩') { throw 'Legacy visual guard reload overwrote Taiwan localization.' }
if ($after -notmatch '成品允許文字逐字白名單') { throw 'Legacy visual guard reload overwrote exact-text hardening.' }
if ($after -notmatch 'Reference Safety') { throw 'Legacy visual guard reload overwrote Reference Safety.' }
if ($after -notmatch '圖片文字穩定硬限制 V4-A\.2\.1') { throw 'Legacy visual guard reload overwrote V4-A.2.1 text stability.' }
if ($after -notmatch 'V4-A\.3 五圖整體規劃') { throw 'Legacy visual guard reload overwrote V4-A.3 planner layer.' }

# The old menu may still call Pause-Menu, but its exact Read-Host prompt must now auto-return.
$watch = [Diagnostics.Stopwatch]::StartNew()
$returnValue = Read-Host '按 Enter 回主選單'
$watch.Stop()
if ([string]$returnValue -ne '') { throw 'Legacy menu pause was not auto-answered.' }
if ($watch.ElapsedMilliseconds -gt 2500) { throw ('Legacy menu pause took too long: ' + $watch.ElapsedMilliseconds + 'ms') }

# Cosmetic stale build text in the old menu file must render as V4-A.3 without rewriting API-key input logic.
$rendered = (& { Write-Host 'Build: V4-A.1｜真實資料＋視覺數量鎖定版' -ForegroundColor Yellow } 6>&1 | Out-String)
if ($rendered -notmatch 'V4-A\.3｜Five-Image Planner 五圖整體規劃版') { throw 'Legacy V4-A.1 menu build label was not replaced with V4-A.3.' }
if ($rendered -match 'V4-A\.1｜真實資料') { throw 'Legacy V4-A.1 menu build label still rendered.' }

Write-Host '[PASS] V4-A.3 menu loader/UX regression: prior guards and planner survive duplicate legacy load, Enter-to-return is automatic, and stale menu build text renders as V4-A.3.' -ForegroundColor Green