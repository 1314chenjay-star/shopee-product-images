$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }

$outDir = Join-Path $systemRoot 'live_e2e_output'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$urls = @(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb'
)

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$headers = @{ 'User-Agent'='Mozilla/5.0' }
for ($i = 0; $i -lt $urls.Count; $i++) {
    $name = if ($i -eq 0) { '58015741169_cover.jpg' } else { '58015741169_image' + $i + '.jpg' }
    $path = Join-Path $outDir $name
    Invoke-WebRequest -Uri $urls[$i] -OutFile $path -Headers $headers -UseBasicParsing -TimeoutSec 60
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Shopee reference download failed: ' + $name) }
    if ((Get-Item -LiteralPath $path).Length -lt 10000) { throw ('Shopee reference image too small: ' + $name) }
}

$rows = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='ps_item_image.1';6='ps_item_image.2';7='ps_item_image.3';8='ps_item_image.4';9='ps_item_image.5';10='ps_item_image.6';11='ps_item_image.7';12='ps_item_image.8';13='et_title_variation_1';14='et_title_option_1_for_variation_1';15='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4=$urls[0];5=$urls[1];6=$urls[2];7=$urls[3];8=$urls[4];9=$urls[5];10=$urls[6];11=$urls[7];12=$urls[8];13='規格';14='黑色2米30磅+腰帶一組';15='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
if ($null -eq $product) { throw 'Real 580 factual construction failed.' }
if (@($product.image_urls).Count -ne 9) { throw ('Expected 9 ordered Shopee images, got ' + @($product.image_urls).Count) }
foreach ($v in @('2米','30磅','腰帶','黑色')) {
    if ((Get-PromptV2 'main' $product) -notmatch [regex]::Escape($v)) { throw ('Prompt missing verified fact: ' + $v) }
}
if (@($product.verified_facts.verified_quantities).Count -ne 0) { throw 'Variant-specific quantity leaked.' }
$product | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'verified_product.json') -Encoding UTF8
(Get-PromptV2 'main' $product) | Set-Content -LiteralPath (Join-Path $outDir 'prompt.txt') -Encoding UTF8
Write-Host '[PASS] Downloaded all 9 real Shopee references for visual safety selection. No TinySnow image call was made in this collection pass.' -ForegroundColor Green
