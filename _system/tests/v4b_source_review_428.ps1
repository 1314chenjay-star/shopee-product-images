$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$outDir = Join-Path $systemRoot 'source_review_v4b_428'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$urls = [string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ap-mrpfutt4ncp41f',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825au-mrpfuuls51qgc0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259z-mrpfuvcqstttff',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825az-mrpfuvy05b7s56',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82587-mrpfux6j2cqqff',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258l-mrpfuxtu721481',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82595-mrpfuyp7gsncb8',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0wxe32cf0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257w-mrpfv1qfv1fo7f'
)
$options = [string[]]@(
    '粉標黑色','粉標白色','白標黑色','黑標白色','黑內光板','白內光板',
    '粉標火焰黑','白標火焰黑','粉標火焰白','黑標火焰白','BRRO【粉标】黑色【速干透气】'
)

$h = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1'}
$d = @{0='42833435408';1='';2='籃球短褲 男款寬鬆五分褲 假兩件設計 速乾透氣運動短褲 夏季籃球訓練休閒褲';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4=$urls[0];20='款式'}
for ($i=1; $i -lt $urls.Count; $i++) {
    $c=4+$i; $h[$c]="ps_item_image.$i"; $d[$c]=$urls[$i]
}
for ($i=1; $i -le $options.Count; $i++) {
    $c=20+$i; $h[$c]="et_title_option_${i}_for_variation_1"; $d[$c]=$options[$i-1]
}

$product = @(Convert-ShopeeRowsToProducts @($h,$d))[0]
if ($null -eq $product) { throw '428 source-review product parse failed.' }
if ([string]$product.product_id -ne '42833435408') { throw '428 product ID changed during parse.' }
if (@($product.image_urls).Count -ne 9) { throw ('Expected 9 source URLs, got ' + @($product.image_urls).Count + '.') }

$selDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selDir -Force | Out-Null
$product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8

$download = Download-ProductImagesV2 $product
$paths = [string[]]@($download.paths)
if ($paths.Count -ne 9) { throw ('Expected 9 downloaded source images, got ' + $paths.Count + '.') }
$analysis = Analyze-ProductImagesV2 '42833435408' $paths
$plan = Get-V4BCurrentSourcePlan
if ($null -eq $plan) { throw '428 V4-B source plan missing.' }
if (-not [bool](Test-V4BSourcePlan $plan $true).passed) { throw '428 V4-B source plan validation failed.' }

$manifest = @()
for ($i=0; $i -lt $paths.Count; $i++) {
    $sourcePath = $paths[$i]
    $targetName = ('source_{0:D2}.png' -f $i)
    $targetPath = Join-Path $outDir $targetName
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    $info = Get-ImageInfoV2 $targetPath
    $manifest += [pscustomobject]@{
        index = $i
        source_url = $urls[$i]
        file = $targetName
        width = [int]$info.width
        height = [int]$info.height
        bytes = (Get-Item -LiteralPath $targetPath).Length
        sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir 'product_428.json') -Encoding UTF8
$analysis | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir 'analysis.json') -Encoding UTF8
$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir 'source_plan_v4b.json') -Encoding UTF8
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'source_manifest.json') -Encoding UTF8

[pscustomobject]@{
    product_id = '42833435408'
    source = 'Shopee CDN URLs recovered from mass_update_media_info_1708743129_20260813140028.xlsx'
    expected_count = 9
    downloaded_count = $paths.Count
    tiny_snow_api_called = $false
    visual_review_required = $true
    note = 'Source-only review. No image generation and no claim that CDN text/visual content is verified until human review.'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'source_review_summary.json') -Encoding UTF8

Write-Host '[PASS] Downloaded all 9 real 428 Shopee source images for no-API visual review.' -ForegroundColor Green
