$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

if ($null -eq (Get-Command Get-V4A2ImageSignal -ErrorAction SilentlyContinue)) { throw 'V4-A.2 runtime layer not loaded.' }
$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }

$outDir = Join-Path $systemRoot 'live_e2e_output'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

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

function New-LiveProductV4A2([string]$ProductId, [string]$Name, [string]$Category, [string[]]$Urls, [string]$VariationName, [string[]]$Options) {
    $header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image'}
    $data = @{0=$ProductId;1='';2=$Name;3=$Category;4=$Urls[0]}
    for ($i=1; $i -lt $Urls.Count; $i++) {
        $column = 4 + $i
        $header[$column] = "ps_item_image.$i"
        $data[$column] = $Urls[$i]
    }
    $variationColumn = 20
    $header[$variationColumn] = 'et_title_variation_1'
    $data[$variationColumn] = $VariationName
    for ($i=1; $i -le $Options.Count; $i++) {
        $column = 20 + $i
        $header[$column] = "et_title_option_${i}_for_variation_1"
        $data[$column] = $Options[$i - 1]
    }
    $product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
    if ($null -eq $product) { throw ('Product construction failed: ' + $ProductId) }
    return $product
}

function Save-LiveSelectionV4A2($Product) {
    $dir = Get-SelectionWorkspaceV2
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Product | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $dir 'selected_product.json') -Encoding UTF8
}

function Test-LivePromptV4A2([string]$ProductId, [string]$Prompt) {
    switch ($ProductId) {
        '58015741169' {
            foreach ($v in @('2米','30磅','腰帶','黑色')) { if ($Prompt -notmatch [regex]::Escape($v)) { throw ('580 prompt missing ' + $v) } }
            if ($Prompt -match '5組|五人聯動|32cm|60cm|9cm|尼龍|橡膠|金屬') { throw '580 unsafe fact leaked.' }
        }
        '57565745174' {
            if ($Prompt -notmatch 'VZJ-004S') { throw '575 model missing.' }
            if ($Prompt -match '尼龍|D-ring|D型環|附球|提升反應|提升球技') { throw '575 unsafe fact leaked.' }
        }
        '52915734564' {
            if ($Prompt -match '不傷膝|不傷肌膚|降低不適|高彈棉質|親膚黏膠|防汗防水|20片|40片|10片') { throw '529 unsafe or variant quantity leaked.' }
        }
        '53615734484' {
            if ($Prompt -match '夜光|發光|變色|真皮|柔韌手感|氣筒|收納袋|精美套裝') { throw '536 variant-specific/unsupported fact leaked.' }
        }
        '53215734553' {
            if ($Prompt -match '真皮|吸汗防滑|內外通用|耐磨耐打|氣筒|收納袋|OFFICIAL SIZE|INDOOR') { throw '532 variant-specific/unsupported fact leaked.' }
        }
    }
    if ($Prompt -notmatch 'Reference Safety') { throw ('Reference Safety prompt missing for ' + $ProductId) }
}

$cases = @(
    [pscustomobject]@{
        id='58015741169'; slot='main'; name='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品'; category='Sports & Outdoors/Basketball/Training'; variation='規格';
        urls=@('https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57','https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87','https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69','https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb');
        options=@('黑色2米30磅+腰帶一組','黑色2米30磅+腰帶各5組')
    },
    [pscustomobject]@{
        id='57565745174'; slot='detail1'; name='排球訓練器材 墊球阻力帶 排球控球輔助訓練器 傳球墊球練習用品 學生球隊訓練裝備'; category='Sports & Outdoors/Volleyball/Others'; variation='款式';
        urls=@('https://s-cf-tw.shopeesz.com/file/sg-11134201-8259g-mrpfuzzrmcjo62','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0x43n5t1a','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a3-mrpfv1r0chl227','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a6-mrpfv2cg1xjafd','https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv2vst24gdd');
        options=@('美璐捷排球訓練器材(VZJ-004S)')
    },
    [pscustomobject]@{
        id='52915734564'; slot='detail4'; name='運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品'; category='Sports & Outdoors/Basketball/Others'; variation='顏色/款式';
        urls=@('https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc','https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mrpfuwav3oxz61','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257t-mrpfuxgjpnuoca','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a9-mrpfuy40nm6g41','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257s-mrpfuyr5b56v5c','https://s-cf-tw.shopeesz.com/file/sg-11134201-82597-mrpfv03xg9a855','https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv1k8bpxd4a');
        options=@('藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片','膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片','黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片','粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片','綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片')
    },
    [pscustomobject]@{
        id='53615734484'; slot='main'; name='夜光排球 5號標準排球 馬卡龍配色學生訓練球 柔軟手感耐磨排球 室內外運動用品 夜間發光球'; category='Sports & Outdoors/Volleyball/Others'; variation='型號';
        urls=@('https://s-cf-tw.shopeesz.com/file/sg-11134201-825b4-mrpfuzn6rv29cc','https://s-cf-tw.shopeesz.com/file/sg-11134201-825ak-mrpfv0zc8tmpf9','https://s-cf-tw.shopeesz.com/file/sg-11134201-825bb-mrpfv1qg69zc3a','https://s-cf-tw.shopeesz.com/file/sg-11134201-8258p-mrpfv2iep15149','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259s-mrpfv3c34wea84','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259i-mrpfv45wc6iv1e','https://s-cf-tw.shopeesz.com/file/sg-11134201-825b3-mrpfv4wnuy9y15','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257y-mrpfv7egf6rs13','https://s-cf-tw.shopeesz.com/file/sg-11134201-8258u-mrpfv9jhnmrk93');
        options=@('馬卡龍夜光限定-淺粉','馬卡龍夜光限定-淺粉藍','馬卡龍夜光限定-淺蘭','馬卡龍夜光限定-清新紫','馬卡龍夜光限定-清新綠','幻彩變色科技-光照變色','幻彩變色科技-黑白感溫','非夜光基礎款-V8001淺粉','非夜光基礎款-V8001淺藍','非夜光基礎款-V8001淺紫','非夜光基礎款-V8001淺綠','數碼彩印排球-喵嗚藍','數碼彩印排球-呱呱綠','數碼彩印排球-小熊黃','LED夜光燈球-星空粉','LED夜光燈球-星空紫')
    },
    [pscustomobject]@{
        id='53215734553'; slot='detail2'; name='真皮籃球 7號成人標準比賽球 室內外籃球 耐磨防滑柔軟手感 專業訓練用球'; category='Sports & Outdoors/Basketball/Others'; variation='款式';
        urls=@('https://s-cf-tw.shopeesz.com/file/sg-11134201-8259r-mrpfuvd4m2v6a3','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259h-mrpfuw6vsbggb5','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a8-mrpfuwxdjytg41','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257x-mrpfuxgw9ypzc1','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfuy3hoy6cd6','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259u-mrpfuysth4w7bd','https://s-cf-tw.shopeesz.com/file/sg-11134201-825am-mrpfv1fa7fgicf','https://s-cf-tw.shopeesz.com/file/sg-11134201-825b7-mrpfv3l9jldx50','https://s-cf-tw.shopeesz.com/file/sg-11134201-825ba-mrpfv4hcg8p460');
        options=@('真皮加厚款','基礎款')
    }
)

$summary = @()
foreach ($case in $cases) {
    Write-Host ('[LIVE] ' + $case.id + '｜download all originals -> Reference Safety -> TinySnow') -ForegroundColor Cyan
    $product = New-LiveProductV4A2 $case.id $case.name $case.category ([string[]]$case.urls) $case.variation ([string[]]$case.options)
    Save-LiveSelectionV4A2 $product
    $download = Download-ProductImagesV2 $product
    $analysis = Analyze-ProductImagesV2 ([string]$case.id) ([string[]]$download.paths)
    if (@($analysis.images).Count -ne @($download.paths).Count) { throw ('Not all downloaded originals analyzed: ' + $case.id) }
    $selected = [string[]]@(Get-ReferencesForSlotV2 $analysis ([string]$case.slot) 2)
    if ($selected.Count -lt 1 -or $selected.Count -gt 2) { throw ('Invalid selected ref count: ' + $case.id) }
    $prepared = [string[]]@(Get-PreparedApiReferencesV2 ([string]$case.id) $selected)

    # Deliberately call with product_name string to match Start-SingleProductOptimizationV2 runtime behavior.
    $prompt = Get-PromptV2 ([string]$case.slot) ([string]$product.product_name)
    Test-LivePromptV4A2 ([string]$case.id) $prompt
    $compact = Get-CompactTransportPromptV2 ([string]$case.slot) ([string]$product.product_name)
    Test-LivePromptV4A2 ([string]$case.id) $compact
    $prompt | Set-Content -LiteralPath (Join-Path $outDir ($case.id + '_prompt.txt')) -Encoding UTF8
    $compact | Set-Content -LiteralPath (Join-Path $outDir ($case.id + '_compact_prompt.txt')) -Encoding UTF8
    $analysis | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outDir ($case.id + '_reference_safety.json')) -Encoding UTF8
    $product | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outDir ($case.id + '_verified_product.json')) -Encoding UTF8

    for ($i=0; $i -lt $selected.Count; $i++) {
        Copy-Item -LiteralPath $selected[$i] -Destination (Join-Path $outDir ($case.id + '_selected_ref' + ($i+1) + '.jpg')) -Force
    }
    $result = Invoke-ImageEditMultiV2 $config $prepared $prompt '1024x1024' 'medium'
    if (-not (Test-Path -LiteralPath $result -PathType Leaf) -or (Get-Item -LiteralPath $result).Length -lt 10000) { throw ('TinySnow output invalid: ' + $case.id) }
    $output = Join-Path $outDir ($case.id + '_' + $case.slot + '_live.png')
    Copy-Item -LiteralPath $result -Destination $output -Force
    $summary += [pscustomobject]@{
        product_id=$case.id; slot=$case.slot; original_count=@($analysis.images).Count; high_variant_conflict=[bool]$analysis.high_variant_conflict;
        selected_reference_count=$selected.Count; selected_references=@($selected | ForEach-Object { Split-Path $_ -Leaf }); output_bytes=(Get-Item -LiteralPath $output).Length
    }
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'v4a2_batch_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-A.2 five-product real Shopee batch completed: all originals analyzed, safe subsets selected, and five TinySnow images generated.' -ForegroundColor Green
