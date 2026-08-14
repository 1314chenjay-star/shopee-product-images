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

# Deliberately use the two riskiest real Shopee references for 58015741169.
# They visually contain multi-person / multi-unit bundle cues. The visual truth guard must neutralize those cues.
$coverUrl = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83'
$detailUrl = 'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57'
$coverPath = Join-Path $outDir '58015741169_cover_risky.jpg'
$detailPath = Join-Path $outDir '58015741169_detail1_risky.jpg'

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
if (-not [bool]$product.multi_variant_flags.has_multiple_bundle_counts) { throw 'Expected multiple bundle count protection.' }

$prompt = Get-PromptV2 'main' $product
$compact = Get-CompactTransportPromptV2 'main' $product
foreach ($needle in @('視覺數量限制','禁止用多個重複商品單位','以單一代表性商品外觀為主')) {
    if ($prompt -notmatch [regex]::Escape($needle)) { throw ('Live prompt visual guard missing: ' + $needle) }
}
if ($compact -notmatch '禁止用多個重複商品單位') { throw 'Compact live prompt visual guard missing.' }
if ($prompt -match '一組' -or $prompt -match '5組' -or $prompt -match '五套') { throw 'Variant-specific quantity leaked into live prompt.' }

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

$prompt | Set-Content -LiteralPath (Join-Path $outDir 'prompt.txt') -Encoding UTF8
$compact | Set-Content -LiteralPath (Join-Path $outDir 'compact_prompt.txt') -Encoding UTF8
$product | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'verified_product.json') -Encoding UTF8

$result = Invoke-ImageEditMultiV2 $config ([string[]]@($coverPath,$detailPath)) $prompt '1024x1024' 'medium'
if (-not (Test-Path -LiteralPath $result -PathType Leaf)) { throw 'TinySnow live API returned no image file.' }
if ((Get-Item -LiteralPath $result).Length -lt 10000) { throw 'TinySnow live API output image is unexpectedly small.' }
Copy-Item -LiteralPath $result -Destination (Join-Path $outDir '58015741169_visual_truth_main.png') -Force

Write-Host ('[PASS] Real Shopee 580 TinySnow live API completed with visual quantity guard: ' + (Get-Item -LiteralPath $result).Length + ' bytes') -ForegroundColor Green
