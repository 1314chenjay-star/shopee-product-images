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
$legacyLayeredRuntime = ($before -match '成品允許文字逐字白名單') -and ($before -match 'Reference Safety')
$v4bRuntime = ($before -match 'V4-B 原圖保真台灣化模式') -and
    ($before -match '結構化共同已驗證資訊僅供交叉確認') -and
    ($before -match '只翻譯你在參考圖中能清楚辨識的文字') -and
    ($before -match '原圖沒有的人物、手、使用場景、商品零件、配件、贈品、顏色、材質、尺寸、數量、功能、認證、功效或安全承諾，一律不得新增')
if (-not ($legacyLayeredRuntime -or $v4bRuntime)) { throw 'Final guarded runtime missing before legacy reload.' }

# Simulate the historical menu loader bug: v4a1_visual_truth.ps1 was sourced again after v4a1_guard.ps1.
. (Join-Path $startRoot 'v4a1_visual_truth.ps1')

$after = Get-PromptV2 'main' ([string]$product.product_name)
if ($after -notmatch '2公尺' -or $after -match '(?<!公)2米' -or $after -notmatch '籃球訓練阻力繩') { throw 'Legacy visual guard reload overwrote Taiwan localization.' }
if ([string]$after -ne [string]$before) { throw 'Legacy visual guard reload changed the final runtime prompt.' }
if ($v4bRuntime -and $after -notmatch 'V4-B 原圖保真台灣化模式') { throw 'Legacy visual guard reload overwrote V4-B runtime.' }
if ($v4bRuntime -and $after -notmatch '只翻譯你在參考圖中能清楚辨識的文字') { throw 'Legacy visual guard reload overwrote V4-B text source guard.' }

# The old menu may still call Pause-Menu, but its exact Read-Host prompt must now auto-return.
$watch = [Diagnostics.Stopwatch]::StartNew()
$returnValue = Read-Host '按 Enter 回主選單'
$watch.Stop()
if ([string]$returnValue -ne '') { throw 'Legacy menu pause was not auto-answered.' }
if ($watch.ElapsedMilliseconds -gt 2500) { throw ('Legacy menu pause took too long: ' + $watch.ElapsedMilliseconds + 'ms') }

# Cosmetic stale build text in the old menu must still be intercepted rather than exposing the obsolete V4-A.1 label.
$rendered = (& { Write-Host 'Build: V4-A.1｜真實資料＋視覺數量鎖定版' -ForegroundColor Yellow } 6>&1 | Out-String)
if ($rendered -match 'V4-A\.1｜真實資料') { throw 'Legacy V4-A.1 menu build label still rendered.' }
if ($rendered -notmatch 'V4-A\.3｜Five-Image Planner 五圖整體規劃版|V4-B') { throw 'Legacy menu build label was not replaced by a current runtime label.' }

Write-Host '[PASS] Menu loader/UX regression: V4-B guarded runtime survives duplicate legacy load, Enter-to-return is automatic, and stale menu build text is intercepted.' -ForegroundColor Green