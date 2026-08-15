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
    if ($text -notmatch '數量規格可選') { throw '529 prompt missing stable quantity wording.' }
    if ($text -match '多入數可選|多人數可選') { throw '529 prompt contains unstable/incorrect quantity wording.' }
    if ($text -notmatch '文字無法逐字正確|無法逐字清楚正確') { throw 'Text omission-on-error rule missing.' }
}
if ($prompt529 -notmatch '最多使用 3 個短文字區塊') { throw 'detail4 three-block text budget missing.' }

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

$prompt580 = Get-PromptV2 'detail4' $product580
if ($prompt580 -notmatch '2公尺' -or $prompt580 -notmatch '200公分') { throw '580 Taiwan units lost after text-stability layer.' }
if ($prompt580 -match '(?<!公)2米') { throw '580 mainland unit wording reappeared.' }

Write-Host '[PASS] V4-A.2.1 image text stability: unstable quantity wording removed, detail4 text density reduced, Taiwan units preserved, and omission-on-error rules applied.' -ForegroundColor Green
