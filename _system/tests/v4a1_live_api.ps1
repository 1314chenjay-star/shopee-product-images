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

# Real Shopee product 58015741169 references from the user's current media Excel.
$coverUrl = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83'
$detailUrl = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57'
$coverPath = Join-Path $outDir '58015741169_cover.jpg'
$detailPath = Join-Path $outDir '58015741169_detail1.jpg'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$headers = @{ 'User-Agent'='Mozilla/5.0' }
Invoke-WebRequest -Uri $coverUrl -OutFile $coverPath -Headers $headers -UseBasicParsing -TimeoutSec 60
Invoke-WebRequest -Uri $detailUrl -OutFile $detailPath -Headers $headers -UseBasicParsing -TimeoutSec 60
foreach ($path in @($coverPath,$detailPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Shopee reference download failed: ' + $path) }
    if ((Get-Item -LiteralPath $path).Length -lt 10000) { throw ('Shopee reference image too small: ' + $path) }
}

$rows = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='ps_item_image.1';6='et_title_variation_1';7='et_title_option_1_for_variation_1';8='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4=$coverUrl;5=$detailUrl;6='規格';7='黑色2米30磅+腰帶一組';8='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
if ($null -eq $product) { throw 'Live factual product construction failed.' }
foreach ($v in @('2米','30磅','腰帶','黑色')) {
    if ((Get-PromptV2 'main' $product) -notmatch [regex]::Escape($v)) { throw ('Live prompt missing verified fact: ' + $v) }
}
if (@($product.verified_facts.verified_quantities).Count -ne 0) { throw 'Variant-specific quantity leaked before live API call.' }
if (@($product.image_urls).Count -ne 2) { throw 'Real Shopee image URL ordering failed.' }
if ([string]$product.image_urls[0] -ne $coverUrl -or [string]$product.image_urls[1] -ne $detailUrl) { throw 'Real Shopee image order must be cover then image.1.' }

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

$prompt = Get-PromptV2 'main' $product
$prompt | Set-Content -LiteralPath (Join-Path $outDir 'prompt.txt') -Encoding UTF8
$product | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'verified_product.json') -Encoding UTF8

$result = Invoke-ImageEditMultiV2 $config ([string[]]@($coverPath,$detailPath)) $prompt '1024x1024' 'medium'
if (-not (Test-Path -LiteralPath $result -PathType Leaf)) { throw 'TinySnow live API returned no image file.' }
if ((Get-Item -LiteralPath $result).Length -lt 10000) { throw 'TinySnow live API output image is unexpectedly small.' }
Copy-Item -LiteralPath $result -Destination (Join-Path $outDir '58015741169_tinysnow_main.png') -Force

$guard = Test-FactualContentV4A1 '2米 30磅 腰帶 黑色' $product
if ([bool]$guard.factual_risk) { throw ('Expected verified facts were rejected: ' + (@($guard.risk_terms) -join ',')) }
$risk = Test-FactualContentV4A1 '32cm 尼龍 五人聯動 腰帶x5 不傷膝 提升爆發力 SGS' $product
if (-not [bool]$risk.factual_risk) { throw 'Known hallucination regression guard failed.' }

Write-Host ('[PASS] Real Shopee 580 TinySnow live API image generated from 2 references: ' + (Get-Item -LiteralPath $result).Length + ' bytes') -ForegroundColor Green
