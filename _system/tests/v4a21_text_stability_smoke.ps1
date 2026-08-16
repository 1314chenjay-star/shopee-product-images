$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

function New-TestProductV4A21([string]$Id, [string]$Name, [string[]]$Options) {
    $header = @{0='et_title_product_id';1='et_title_product_name';2='et_title_product_category';3='ps_item_cover_image';4='et_title_variation_1'}
    $data = @{0=$Id;1=$Name;2='Sports & Outdoors/Others';3='https://example.invalid/cover.jpg';4='規格'}
    for ($i=1; $i -le $Options.Count; $i++) {
        $column = 4 + $i
        $header[$column] = "et_title_option_${i}_for_variation_1"
        $data[$column] = $Options[$i - 1]
    }
    $product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
    if ($null -eq $product) { throw ('Fixture construction failed: ' + $Id) }
    return $product
}

$product529 = New-TestProductV4A21 '52915734564' '運動肌貼 肌肉貼布' @(
    '藍色-常規肌肉貼20片',
    '藍色-常規肌肉貼40片',
    '黑色-護膝貼10片',
    '黑色-護膝貼20片'
)
$allowed529 = @(Get-V4A2AllowedOutputText $product529 'detail4')
foreach ($required in @('運動肌貼','數量規格可選','規格請依選項為準')) {
    if ($allowed529 -notcontains $required) { throw ('529 stable allowlist missing: ' + $required) }
}
if ($allowed529 -contains '多入數可選') { throw 'Legacy 多入數可選 still present in 529 allowlist.' }
if ($allowed529.Count -gt 3) { throw ('529 detail4 text budget is too large: ' + $allowed529.Count) }

$mainAllowed529 = @(Get-V4A2AllowedOutputText $product529 'main')
if ($mainAllowed529 -contains '多入數可選') { throw 'Legacy 多入數可選 still present in main allowlist.' }
if ($mainAllowed529 -notcontains '數量規格可選') { throw 'Stable quantity wording missing from main allowlist.' }

$prompt529 = Get-PromptV2 'detail4' $product529
$compact529 = Get-CompactTransportPromptV2 'detail4' $product529
foreach ($text in @($prompt529,$compact529)) {
    if ($text -match '多入數可選|多人數可選') { throw '529 prompt contains unstable/incorrect quantity wording.' }
    if (($text -match '數量規格可選') -and ($text -match '多入數可選|多人數可選')) { throw '529 prompt mixed stable and unstable quantity wording.' }
    $legacyOmitRule = $text -match '文字無法逐字正確|無法逐字清楚正確'
    $v4bOmitRule = $text -match '看不清楚、被遮住、語意不確定或來源彼此衝突的文字不要猜|看不清就省略，不猜測'
    if (-not ($legacyOmitRule -or $v4bOmitRule)) { throw 'Text omission-on-error rule missing.' }
}
if ($prompt529 -match 'V4-B 原圖保真台灣化模式') {
    if ($prompt529 -notmatch '禁止自行新增或推測') { throw 'V4-B detail4 no-invention rule missing.' }
} elseif ($prompt529 -notmatch '最多使用 3 個短文字區塊') {
    throw 'Legacy detail4 three-block text budget missing.'
}

$product580 = New-TestProductV4A21 '58015741169' '籃球訓練阻力繩' @(
    '黑色2米30磅+腰帶一組',
    '黑色2米30磅+腰帶各5組'
)
$allowed580 = @(Get-V4A2AllowedOutputText $product580 'detail4')
foreach ($required in @('2公尺','200公分','30磅','腰帶','黑色','數量規格可選','規格請依選項為準')) {
    if ($allowed580 -notcontains $required) { throw ('580 verified/stable text missing: ' + $required) }
}
if ($allowed580 -contains '2米') { throw '580 source unit leaked into rendered allowlist.' }
if ($allowed580 -contains '多入數可選') { throw '580 legacy quantity wording leaked.' }

$detail1Allowed580 = @(Get-V4A2AllowedOutputText $product580 'detail1')
foreach ($forbidden in @('多規格可選','數量規格可選','請依實際選項為準','實際內容請依選項為準','不同規格內容可能不同','款式可選')) {
    if ($detail1Allowed580 -contains $forbidden) { throw ('detail1 redundant microcopy still allowed: ' + $forbidden) }
}
foreach ($required in @('籃球訓練阻力繩','2公尺','30磅','腰帶','黑色')) {
    if ($detail1Allowed580 -notcontains $required) { throw ('detail1 essential text missing: ' + $required) }
}

$detail2Allowed580 = @(Get-V4A2AllowedOutputText $product580 'detail2')
foreach ($required in @('商品結構與細節展示','2公尺','30磅','腰帶','黑色')) {
    if ($detail2Allowed580 -notcontains $required) { throw ('detail2 essential text missing: ' + $required) }
}
foreach ($forbidden in @('籃球訓練阻力繩','多規格可選','數量規格可選','彈力繩','連接扣')) {
    if ($detail2Allowed580 -contains $forbidden) { throw ('detail2 extra/structural label still allowed: ' + $forbidden) }
}

$detail2Prompt580 = Get-PromptV2 'detail2' $product580
if ($detail2Prompt580 -match 'V4-B 原圖保真台灣化模式') {
    if ($detail2Prompt580 -notmatch '保留來源圖既有的結構、局部、配件、包裝或其他可見內容') { throw 'V4-B detail2 source-structure preservation rule missing.' }
    if ($detail2Prompt580 -notmatch '沒有就不要補新的零件或功能') { throw 'V4-B detail2 no-invention structural rule missing.' }
} else {
    if ($detail2Prompt580 -notmatch '局部放大圖與圈選細節全部禁止加文字標籤') { throw 'Legacy detail2 no-caption hard rule missing.' }
    if ($detail2Prompt580 -notmatch '禁止自行為商品局部結構') { throw 'Legacy global structural naming ban missing.' }
}

$prompt580 = Get-PromptV2 'detail4' $product580
if ($prompt580 -notmatch '2公尺') { throw '580 Taiwan length unit lost after text-stability layer.' }
if ($prompt580 -match '(?<!公)2米') { throw '580 mainland unit wording reappeared.' }
if (($prompt580 -notmatch 'V4-B 原圖保真台灣化模式') -and ($prompt580 -notmatch '200公分')) { throw 'Legacy detail4 prompt lost exact 200公分 equivalent.' }

Write-Host '[PASS] Image text stability: unstable quantity wording stays removed, helper allowlists remain stable, V4-B may omit unnecessary microcopy, Taiwan units persist, and uncertain text is omitted instead of guessed.' -ForegroundColor Green
