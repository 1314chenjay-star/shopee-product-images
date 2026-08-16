$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$units = Convert-ToTaiwanCommerceTextV4A2 '2米 200厘米 5毫米 1千克 500克 750ml 2L 12英寸 30lb 米色'
Assert-True ($units -match '2公尺') '2米 should render as 2公尺.'
Assert-True ($units -match '200公分') '200厘米 should render as 200公分.'
Assert-True ($units -match '5公釐') '5毫米 should render as 5公釐.'
Assert-True ($units -match '1公斤') '1千克 should render as 1公斤.'
Assert-True ($units -match '500公克') '500克 should render as 500公克.'
Assert-True ($units -match '750毫升') '750ml should render as 750毫升.'
Assert-True ($units -match '2公升') '2L should render as 2公升.'
Assert-True ($units -match '12吋') '12英寸 should render as 12吋.'
Assert-True ($units -match '30磅') '30lb should render as 30磅.'
Assert-True ($units -match '米色') '米色 must never be converted as a length unit.'

$terms = Convert-ToTaiwanCommerceTextV4A2 '羽毛球拍 乒乓球 台球杆 雙肩包 斜挎包 魔術貼 氣筒 尺碼 俯臥撐支架'
foreach ($expected in @('羽球拍','桌球','撞球桿','後背包','斜背包','魔鬼氈','打氣筒','尺寸','伏地挺身架')) {
    Assert-True ($terms -match [regex]::Escape($expected)) ('Taiwan term missing: ' + $expected)
}

# 580: raw source fact stays untouched, but every prompt/output term is localized.
$rows580 = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1';7='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='';2='籃球訓練阻力繩';3='Sports & Outdoors/Basketball/Training';4='https://example.invalid/580.jpg';5='規格';6='黑色2米30磅+腰帶一組';7='黑色2米30磅+腰帶各5組'}
)
$p580 = @(Convert-ShopeeRowsToProducts $rows580)[0]
Assert-True ($null -ne $p580) '580 construction failed.'
Assert-True (@($p580.verified_facts.verified_dimensions) -contains '2米') 'Raw 580 fact must remain source-true as 2米.'
$allowed580Main = @(Get-V4A2AllowedOutputText $p580 'main')
Assert-True ($allowed580Main -contains '2公尺') '580 main allowlist must contain 2公尺.'
Assert-True ($allowed580Main -notcontains '2米') '580 main allowlist must not expose 2米.'
Assert-True ($allowed580Main -contains '籃球訓練阻力繩') '580 should use Taiwan-safe product label.'
$allowed580D4 = @(Get-V4A2AllowedOutputText $p580 'detail4')
Assert-True ($allowed580D4 -contains '200公分') '580 detail4 should allow exact equivalent 200公分.'
$prompt580 = Get-PromptV2 'main' $p580
Assert-True ($prompt580 -match '2公尺') '580 prompt must contain 2公尺.'
Assert-True ($prompt580 -notmatch '(?<!公)2米') '580 prompt must not expose 2米.'
Assert-True ($prompt580 -match '籃球訓練阻力繩') '580 prompt must expose Taiwan product label.'

# Product-label regression set: claims in source title must not become the product label.
$p575 = [pscustomobject]@{ product_name='排球訓練器材 墊球阻力帶 VZJ-004S' }
$p529 = [pscustomobject]@{ product_name='肌肉貼 運動貼布 護膝貼' }
$p536 = [pscustomobject]@{ product_name='夜光少女心排球 馬卡龍 發光' }
$p532 = [pscustomobject]@{ product_name='真皮籃球 耐磨 室內外' }
Assert-True ((Get-TaiwanProductLabelV4A2 $p575) -eq '排球訓練器') '575 Taiwan product label mismatch.'
Assert-True ((Get-TaiwanProductLabelV4A2 $p529) -eq '運動肌貼') '529 Taiwan product label mismatch.'
Assert-True ((Get-TaiwanProductLabelV4A2 $p536) -eq '排球') '536 label must be neutral 排球, not 夜光 claim.'
Assert-True ((Get-TaiwanProductLabelV4A2 $p532) -eq '籃球') '532 label must be neutral 籃球, not 真皮 claim.'

# Brand/model/SKU-shaped strings are never rewritten by localization.
$identity = Convert-ToTaiwanCommerceTextV4A2 'VZJ-004S SKU-A120 ABC-30'
Assert-True ($identity -eq 'VZJ-004S SKU-A120 ABC-30') 'Model/SKU identity must stay byte-for-byte equivalent.'

Write-Host '[PASS] V4-A.2 Taiwan localization smoke passed.' -ForegroundColor Green
