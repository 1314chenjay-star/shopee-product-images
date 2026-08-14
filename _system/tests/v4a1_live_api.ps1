$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')
. (Join-Path $startRoot 'v4a1_visual_truth.ps1')

$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }

$outDir = Join-Path $systemRoot 'live_e2e_output'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$downloadHeaders = @{ 'User-Agent'='Mozilla/5.0' }

$config = [pscustomobject]@{
    api_key = $key
    base_url = 'https://tinysnow.one/v1'
    model = 'gpt-image-2'
    quality = 'medium'
    size = '1024x1024'
    safe_test_mode = $true
    max_reference_images = 2
    transport_profile = 'r3_120s_safe'
}

function Get-LiveReference([string]$Url, [string]$Name) {
    $path = Join-Path $outDir $Name
    Invoke-WebRequest -Uri $Url -OutFile $path -Headers $downloadHeaders -UseBasicParsing -TimeoutSec 60
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Shopee reference download failed: ' + $Name) }
    if ((Get-Item -LiteralPath $path).Length -lt 10000) { throw ('Shopee reference image too small: ' + $Name) }
    return $path
}

# ------------------------------------------------------------
# 57565745174: VZJ-004S is verified; material/accessory/performance claims are not.
# ------------------------------------------------------------
$u575a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259g-mrpfuzzrmcjo62'
$u575b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0x43n5t1a'
$r575a = Get-LiveReference $u575a '57565745174_cover.jpg'
$r575b = Get-LiveReference $u575b '57565745174_image1.jpg'
$rows575 = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='ps_item_image.1';6='et_title_variation_1';7='et_title_option_1_for_variation_1'},
    @{0='57565745174';1='';2='排球訓練器材 墊球阻力帶 排球控球輔助訓練器 傳球墊球練習用品 學生球隊訓練裝備';3='101856 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Volleyball/Others';4=$u575a;5=$u575b;6='款式';7='美璐捷排球訓練器材(VZJ-004S)'}
)
$p575 = @(Convert-ShopeeRowsToProducts $rows575)[0]
if (@($p575.verified_facts.verified_models) -notcontains 'VZJ-004S') { throw '575 verified model missing.' }
if (@($p575.verified_facts.verified_accessories) -contains '球') { throw '575 排球 accessory regression.' }
$prompt575 = Get-PromptV2 'detail1' $p575
if ($prompt575 -notmatch 'VZJ-004S') { throw '575 live prompt missing VZJ-004S.' }
$prompt575 | Set-Content -LiteralPath (Join-Path $outDir '575_prompt.txt') -Encoding UTF8
$p575 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir '575_verified_product.json') -Encoding UTF8
$result575 = Invoke-ImageEditMultiV2 $config ([string[]]@($r575a,$r575b)) $prompt575 '1024x1024' 'medium'
if (-not (Test-Path -LiteralPath $result575 -PathType Leaf) -or (Get-Item -LiteralPath $result575).Length -lt 10000) { throw '575 TinySnow live output invalid.' }
Copy-Item -LiteralPath $result575 -Destination (Join-Path $outDir '57565745174_detail1_live.png') -Force

# ------------------------------------------------------------
# 52915734564: 20 variants across colors and 10/20/40 pieces.
# No single color or quantity is common, so the image must stay neutral.
# ------------------------------------------------------------
$u529a = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc'
$u529b = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892'
$r529a = Get-LiveReference $u529a '52915734564_cover.jpg'
$r529b = Get-LiveReference $u529b '52915734564_image1.jpg'

$optionNames = @(
    '藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片',
    '膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片',
    '黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片',
    '粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片',
    '綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片'
)
$header529 = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='ps_item_image.1';6='et_title_variation_1'}
$data529 = @{0='52915734564';1='';2='運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4=$u529a;5=$u529b;6='顏色/款式'}
for ($i = 1; $i -le $optionNames.Count; $i++) {
    $column = 6 + $i
    $header529[$column] = "et_title_option_${i}_for_variation_1"
    $data529[$column] = $optionNames[$i - 1]
}
$p529 = @(Convert-ShopeeRowsToProducts @($header529,$data529))[0]
if ($null -eq $p529) { throw '529 live product construction failed.' }
if (@($p529.variants).Count -ne 20) { throw ('529 expected 20 variants, got ' + @($p529.variants).Count) }
if (-not [bool]$p529.multi_variant_flags.has_multiple_quantities) { throw '529 quantity guard not active.' }
if (-not [bool]$p529.multi_variant_flags.has_multiple_colors) { throw '529 color guard not active.' }
if (@($p529.verified_facts.verified_quantities).Count -ne 0) { throw '529 common quantity must be empty.' }
if (@($p529.verified_facts.verified_colors).Count -ne 0) { throw '529 common color must be empty.' }
$prompt529 = Get-PromptV2 'detail4' $p529
foreach ($unsafe in @('不傷膝','不傷肌膚','降低不適','高彈棉質','親膚黏膠','防汗防水')) {
    if ($prompt529 -match [regex]::Escape($unsafe)) { throw ('529 unsafe text leaked into prompt: ' + $unsafe) }
}
if ($prompt529 -notmatch '視覺數量限制') { throw '529 visual quantity guard missing.' }
$prompt529 | Set-Content -LiteralPath (Join-Path $outDir '529_prompt.txt') -Encoding UTF8
$p529 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir '529_verified_product.json') -Encoding UTF8
$result529 = Invoke-ImageEditMultiV2 $config ([string[]]@($r529a,$r529b)) $prompt529 '1024x1024' 'medium'
if (-not (Test-Path -LiteralPath $result529 -PathType Leaf) -or (Get-Item -LiteralPath $result529).Length -lt 10000) { throw '529 TinySnow live output invalid.' }
Copy-Item -LiteralPath $result529 -Destination (Join-Path $outDir '52915734564_detail4_live.png') -Force

Write-Host ('[PASS] Real Shopee live regressions passed transport: 575=' + (Get-Item -LiteralPath $result575).Length + ' bytes; 529=' + (Get-Item -LiteralPath $result529).Length + ' bytes') -ForegroundColor Green
