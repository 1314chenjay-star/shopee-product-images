$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

if ($null -eq (Get-Command Get-V4A21TextBudget -ErrorAction SilentlyContinue)) { throw 'V4-A.2.1 text stability runtime layer not loaded.' }
$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }

$outDir = Join-Path $systemRoot 'live_e2e_output_v4a21'
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

function New-LiveProductV4A21([string]$ProductId, [string]$Name, [string]$Category, [string[]]$Urls, [string]$VariationName, [string[]]$Options) {
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

function Save-LiveSelectionV4A21($Product) {
    $dir = Get-SelectionWorkspaceV2
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Product | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $dir 'selected_product.json') -Encoding UTF8
}

function Invoke-LiveSlotV4A21($Product, $Analysis, [string]$Slot) {
    $productId = [string]$Product.product_id
    $selected = [string[]]@(Get-ReferencesForSlotV2 $Analysis $Slot 2)
    if ($selected.Count -lt 1 -or $selected.Count -gt 2) { throw ('Invalid reference count: ' + $productId + '/' + $Slot) }
    $prepared = [string[]]@(Get-PreparedApiReferencesV2 $productId $selected)
    $prompt = Get-PromptV2 $Slot ([string]$Product.product_name)
    $compact = Get-CompactTransportPromptV2 $Slot ([string]$Product.product_name)

    if ($prompt -match '多入數可選|多人數可選' -or $compact -match '多入數可選|多人數可選') { throw ('Unstable quantity wording leaked: ' + $productId + '/' + $Slot) }
    if ($prompt -notmatch '圖片文字穩定硬限制 V4-A\.2\.1') { throw ('V4-A.2.1 full prompt rule missing: ' + $productId + '/' + $Slot) }
    if ($compact -notmatch '圖片文字穩定規則') { throw ('V4-A.2.1 compact rule missing: ' + $productId + '/' + $Slot) }

    if ($productId -eq '52915734564') {
        $allowed = @(Get-V4A2AllowedOutputText $Product $Slot)
        if ($Slot -ne 'detail4') { throw '529 live stability case must use detail4.' }
        if ($allowed.Count -gt 3) { throw ('529 detail4 allowlist too dense: ' + $allowed.Count) }
        foreach ($required in @('運動肌貼','數量規格可選','規格請依選項為準')) {
            if ($allowed -notcontains $required) { throw ('529 allowlist missing: ' + $required) }
        }
        if ($prompt -match '20片|40片|10片|防汗防水|親膚黏膠|不傷膝|不傷肌膚') { throw '529 unsafe fact leaked.' }
    }

    if ($productId -eq '58015741169') {
        foreach ($required in @('2公尺','30磅','腰帶','黑色','籃球訓練阻力繩')) {
            if ($prompt -notmatch [regex]::Escape($required)) { throw ('580 prompt missing: ' + $required + '/' + $Slot) }
        }
        if ($prompt -match '(?<!公)2米|5組|五人聯動|32cm|60cm|9cm|尼龍|橡膠|金屬') { throw ('580 unsafe fact leaked: ' + $Slot) }
    }

    $prompt | Set-Content -LiteralPath (Join-Path $outDir ($productId + '_' + $Slot + '_prompt.txt')) -Encoding UTF8
    $compact | Set-Content -LiteralPath (Join-Path $outDir ($productId + '_' + $Slot + '_compact_prompt.txt')) -Encoding UTF8
    for ($i=0; $i -lt $selected.Count; $i++) {
        Copy-Item -LiteralPath $selected[$i] -Destination (Join-Path $outDir ($productId + '_' + $Slot + '_selected_ref' + ($i+1) + '.jpg')) -Force
    }

    Write-Host ('[LIVE] ' + $productId + ' / ' + $Slot + ' -> TinySnow') -ForegroundColor Cyan
    $result = Invoke-ImageEditMultiV2 $config $prepared $prompt '1024x1024' 'medium'
    if (-not (Test-Path -LiteralPath $result -PathType Leaf) -or (Get-Item -LiteralPath $result).Length -lt 10000) { throw ('TinySnow output invalid: ' + $productId + '/' + $Slot) }
    $output = Join-Path $outDir ($productId + '_' + $Slot + '_live.png')
    Copy-Item -LiteralPath $result -Destination $output -Force
    return [pscustomobject]@{
        product_id=$productId
        slot=$Slot
        selected_reference_count=$selected.Count
        output_bytes=(Get-Item -LiteralPath $output).Length
        output_file=(Split-Path $output -Leaf)
    }
}

$product529 = New-LiveProductV4A21 '52915734564' '運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品' 'Sports & Outdoors/Basketball/Others' @(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mrpfuwav3oxz61',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257t-mrpfuxgjpnuoca',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a9-mrpfuy40nm6g41',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257s-mrpfuyr5b56v5c',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82597-mrpfv03xg9a855',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv1k8bpxd4a'
) '顏色/款式' @(
    '藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片',
    '膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片',
    '黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片',
    '粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片',
    '綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片'
)
Save-LiveSelectionV4A21 $product529
$download529 = Download-ProductImagesV2 $product529
$analysis529 = Analyze-ProductImagesV2 '52915734564' ([string[]]$download529.paths)
$result529 = Invoke-LiveSlotV4A21 $product529 $analysis529 'detail4'

$product580 = New-LiveProductV4A21 '58015741169' '籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品' 'Sports & Outdoors/Basketball/Training' @(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb'
) '規格' @('黑色2米30磅+腰帶一組','黑色2米30磅+腰帶各5組')
Save-LiveSelectionV4A21 $product580
$download580 = Download-ProductImagesV2 $product580
$analysis580 = Analyze-ProductImagesV2 '58015741169' ([string[]]$download580.paths)
$results580 = @()
foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
    $results580 += Invoke-LiveSlotV4A21 $product580 $analysis580 $slot
}

$summary = @($result529) + @($results580)
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'v4a21_live_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-A.2.1 focused live E2E completed: 529 detail4 + full five-slot 580 generated through real TinySnow.' -ForegroundColor Green
