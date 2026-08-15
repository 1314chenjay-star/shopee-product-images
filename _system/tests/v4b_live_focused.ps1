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
if ($null -eq (Get-Command New-V4BSourceImagePlan -ErrorAction SilentlyContinue)) { throw 'V4-B runtime layer not loaded.' }

$outDir = Join-Path $systemRoot 'live_e2e_output_v4b'
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

function Assert-V4BLive([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('V4-B live failed: ' + $Message) }
}

function New-V4BLiveProduct([string]$ProductId, [string]$Name, [string]$Category, [string[]]$Urls, [string]$VariationName, [string[]]$Options) {
    $header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image'}
    $data = @{0=$ProductId;1='';2=$Name;3=$Category;4=$Urls[0]}
    for ($i=1; $i -lt $Urls.Count; $i++) {
        $column = 4 + $i
        $header[$column] = "ps_item_image.$i"
        $data[$column] = $Urls[$i]
    }
    if (-not [string]::IsNullOrWhiteSpace($VariationName)) {
        $variationColumn = 20
        $header[$variationColumn] = 'et_title_variation_1'
        $data[$variationColumn] = $VariationName
        for ($i=1; $i -le $Options.Count; $i++) {
            $column = 20 + $i
            $header[$column] = "et_title_option_${i}_for_variation_1"
            $data[$column] = $Options[$i - 1]
        }
    }
    $product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
    if ($null -eq $product) { throw ('Product construction failed: ' + $ProductId) }
    return $product
}

function Save-V4BLiveSelection($Product) {
    $dir = Get-SelectionWorkspaceV2
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $dir 'selected_product.json') -Encoding UTF8
}

function Prepare-V4BLiveProduct($Product) {
    Save-V4BLiveSelection $Product
    $download = Download-ProductImagesV2 $Product
    $analysis = Analyze-ProductImagesV2 ([string]$Product.product_id) ([string[]]$download.paths)
    $plan = Get-V4BCurrentSourcePlan
    Assert-V4BLive ($null -ne $plan) ('source plan missing: ' + [string]$Product.product_id)
    Assert-V4BLive (@($plan.slots).Count -eq 5) ('source plan is not five slots: ' + [string]$Product.product_id)
    Assert-V4BLive ([bool](Test-V4BSourcePlan $plan $true).passed) ('source plan validation failed: ' + [string]$Product.product_id)
    $plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir ([string]$Product.product_id + '_source_plan_v4b.json')) -Encoding UTF8
    return [pscustomobject]@{ product=$Product; download=$download; analysis=$analysis; plan=$plan }
}

function Invoke-V4BLiveSlot($Prepared, [string]$Slot) {
    $product = $Prepared.product
    $analysis = $Prepared.analysis
    $plan = $Prepared.plan
    $productId = [string]$product.product_id
    Save-V4BLiveSelection $product

    $slotPlan = Get-V4BPlanSlot $plan $Slot
    if ($null -eq $slotPlan) { throw ('Missing V4-B slot plan: ' + $productId + '/' + $Slot) }

    $refs = [string[]]@(Get-ReferencesForSlotV2 $analysis $Slot 2)
    Assert-V4BLive ($refs.Count -ge 1 -and $refs.Count -le 2) ('invalid source count: ' + $productId + '/' + $Slot)
    Assert-V4BLive (@($slotPlan.source_paths).Count -eq $refs.Count) ('runtime refs do not match source plan: ' + $productId + '/' + $Slot)

    $prompt = Get-PromptV2 $Slot $product
    Assert-V4BLive ($prompt -match 'EDIT / PRESERVE / LOCALIZE') ('preservation mode missing: ' + $productId + '/' + $Slot)
    Assert-V4BLive ($prompt -match '不要假裝 OCR') ('no-OCR rule missing: ' + $productId + '/' + $Slot)
    Assert-V4BLive ($prompt -match '原圖沒有的人物') ('no-new-content rule missing: ' + $productId + '/' + $Slot)

    if ([string]$slotPlan.source_mode -eq 'generic_fill') {
        foreach ($copy in @($slotPlan.allowed_generic_copy)) {
            Assert-V4BLive (Test-V4BGenericCopyAllowed ([string]$copy)) ('non-whitelist generic copy: ' + [string]$copy)
        }
    }

    $prompt | Set-Content -LiteralPath (Join-Path $outDir ($productId + '_' + $Slot + '_prompt.txt')) -Encoding UTF8
    $slotPlan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outDir ($productId + '_' + $Slot + '_slot_plan.json')) -Encoding UTF8
    for ($i=0; $i -lt $refs.Count; $i++) {
        Copy-Item -LiteralPath $refs[$i] -Destination (Join-Path $outDir ($productId + '_' + $Slot + '_selected_ref' + ($i+1) + '.png')) -Force
    }

    $preparedRefs = [string[]]@(Get-PreparedApiReferencesV2 $productId $refs)
    Write-Host ('[LIVE V4-B] ' + $productId + ' / ' + $Slot + ' / ' + [string]$slotPlan.source_mode + ' -> TinySnow') -ForegroundColor Cyan
    $temporary = Invoke-ImageEditMultiV2 $config $preparedRefs $prompt '1024x1024' 'medium'
    Assert-V4BLive ((Test-Path -LiteralPath $temporary -PathType Leaf) -and (Get-Item -LiteralPath $temporary).Length -gt 10000) ('TinySnow output invalid: ' + $productId + '/' + $Slot)
    $output = Join-Path $outDir ($productId + '_' + $Slot + '_live.jpg')
    Convert-ToFinalJpegV2 $temporary $output | Out-Null
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        product_id = $productId
        slot = $Slot
        source_mode = [string]$slotPlan.source_mode
        source_count = $refs.Count
        source_indices = [int[]]@($slotPlan.source_indices)
        allowed_generic_copy = [string[]]@($slotPlan.allowed_generic_copy)
        output_file = Split-Path $output -Leaf
        output_bytes = (Get-Item -LiteralPath $output).Length
        sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$urls580 = [string[]]@(
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
$product580 = New-V4BLiveProduct '58015741169' '籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品' 'Sports & Outdoors/Basketball/Training' $urls580 '規格' ([string[]]@('黑色2米30磅+腰帶一組','黑色2米30磅+腰帶各5組'))
$prepared580 = Prepare-V4BLiveProduct $product580
$prompt580 = Get-PromptV2 'detail4' $product580
foreach ($required in @('2公尺','30磅','腰帶','黑色')) { Assert-V4BLive ($prompt580 -match [regex]::Escape($required)) ('580 verified common fact missing: ' + $required) }
Assert-V4BLive ($prompt580 -notmatch '5組|各5組') '580 variant-only bundle count leaked into prompt'

$urls529 = [string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mrpfuwav3oxz61',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257t-mrpfuxgjpnuoca',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a9-mrpfuy40nm6g41',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257s-mrpfuyr5b56v5c',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82597-mrpfv03xg9a855',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv1k8bpxd4a'
)
$options529 = [string[]]@(
    '藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片',
    '膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片',
    '黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片',
    '粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片',
    '綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片'
)
$product529 = New-V4BLiveProduct '52915734564' '運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品' 'Sports & Outdoors/Basketball/Others' $urls529 '顏色/款式' $options529
$prepared529 = Prepare-V4BLiveProduct $product529
Assert-V4BLive ([bool]$prepared529.plan.high_variant_conflict) '529 must remain high variant conflict'
Assert-V4BLive (@($prepared529.plan.slots | Where-Object { $_.source_mode -eq 'recomposed_originals' }).Count -eq 0) '529 with enough originals should not need cross-variant recomposition'
$prompt529 = Get-PromptV2 'detail4' $product529
Assert-V4BLive ($prompt529 -notmatch '10片|20片|40片') '529 variant-only quantities leaked into prompt'

# Synthetic 3-source fill test uses only three real source images. Production code remains product-agnostic.
$productFill = New-V4BLiveProduct '90000020003' '運動肌貼' 'Sports & Outdoors/Training' ([string[]]@($urls529[0],$urls529[1],$urls529[2])) '' ([string[]]@())
$preparedFill = Prepare-V4BLiveProduct $productFill
$fillD3 = Get-V4BPlanSlot $preparedFill.plan 'detail3'
$fillD4 = Get-V4BPlanSlot $preparedFill.plan 'detail4'
Assert-V4BLive ([string]$fillD3.source_mode -eq 'recomposed_originals') '3-source detail3 must be recomposed_originals'
Assert-V4BLive ([string]$fillD4.source_mode -eq 'generic_fill') '3-source detail4 must be generic_fill'
Assert-V4BLive (@($fillD3.source_paths).Count -eq 2) '3-source recomposed detail3 should use two existing originals'
Assert-V4BLive (@($fillD4.source_paths).Count -eq 1) 'generic fill must keep one real source'

$results = @()
$results += Invoke-V4BLiveSlot $prepared580 'detail4'
$results += Invoke-V4BLiveSlot $prepared529 'detail4'
$results += Invoke-V4BLiveSlot $preparedFill 'detail3'
$results += Invoke-V4BLiveSlot $preparedFill 'detail4'

$uniqueHashes = @($results | ForEach-Object { $_.sha256 } | Select-Object -Unique)
Assert-V4BLive ($uniqueHashes.Count -eq 4) 'live outputs contain exact duplicate images'

[pscustomobject]@{
    version = 'V4-B'
    generated_image_count = 4
    tests = [object[]]$results
    technical_gate = 'passed'
    visual_review_required = $true
    api_transport = 'API-R3-120S'
} | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir 'v4b_live_summary.json') -Encoding UTF8

Write-Host '[PASS] V4-B focused live technical gate: 580 detail4 + 529 detail4 + 3-source detail3/detail4 generated. Visual review required.' -ForegroundColor Green
