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
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Create a deterministic local reference image so the live test does not publish user product data.
Add-Type -AssemblyName System.Drawing
$refPath = Join-Path $outDir 'reference.jpg'
$bmp = New-Object Drawing.Bitmap 1024,1024
$g = [Drawing.Graphics]::FromImage($bmp)
try {
    $g.Clear([Drawing.Color]::White)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::Black), 24
    $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::Black)
    $g.DrawEllipse($pen, 220, 380, 580, 220)
    $g.FillRectangle($brush, 455, 220, 115, 185)
    $g.FillRectangle($brush, 455, 590, 115, 185)
    $font = New-Object Drawing.Font 'Arial', 28
    $g.DrawString('REFERENCE PRODUCT', $font, $brush, 330, 80)
    $bmp.Save($refPath, [Drawing.Imaging.ImageFormat]::Jpeg)
}
finally {
    if ($null -ne $pen) { $pen.Dispose() }
    if ($null -ne $brush) { $brush.Dispose() }
    if ($null -ne $font) { $font.Dispose() }
    $g.Dispose(); $bmp.Dispose()
}

$rows = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1';7='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='LIVE-580';2='籃球訓練阻力繩';3='Sports & Outdoors/Basketball/Training';4='https://example.invalid/reference.jpg';5='規格';6='黑色2米30磅+腰帶一組';7='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
if ($null -eq $product) { throw 'Live factual product construction failed.' }
foreach ($v in @('2米','30磅','腰帶','黑色')) {
    if ((Get-PromptV2 'main' $product) -notmatch [regex]::Escape($v)) { throw ('Live prompt missing verified fact: ' + $v) }
}
if (@($product.verified_facts.verified_quantities).Count -ne 0) { throw 'Variant-specific quantity leaked before live API call.' }

$config = [pscustomobject]@{
    api_key = $key
    base_url = 'https://tinysnow.one/v1'
    model = 'gpt-image-2'
    quality = 'medium'
    size = '1024x1024'
    safe_test_mode = $true
    max_reference_images = 1
    transport_profile = 'r3_120s_safe'
}

$prompt = Get-PromptV2 'main' $product
$prompt | Set-Content -LiteralPath (Join-Path $outDir 'prompt.txt') -Encoding UTF8
$result = Invoke-ImageEditMultiV2 $config ([string[]]@($refPath)) $prompt '1024x1024' 'medium'
if (-not (Test-Path -LiteralPath $result -PathType Leaf)) { throw 'TinySnow live API returned no image file.' }
if ((Get-Item -LiteralPath $result).Length -lt 10000) { throw 'TinySnow live API output image is unexpectedly small.' }
Copy-Item -LiteralPath $result -Destination (Join-Path $outDir 'tinysnow_live_result.png') -Force
Write-Host ('[PASS] TinySnow live API image generated: ' + (Get-Item -LiteralPath $result).Length + ' bytes') -ForegroundColor Green
