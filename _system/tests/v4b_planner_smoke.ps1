$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$start = Join-Path $root '_system\start'

. (Join-Path $start 'api_v2.ps1')
. (Join-Path $start 'excel_reader.ps1')
. (Join-Path $start 'selection_v2.ps1')
. (Join-Path $start 'image_pipeline_v2.ps1')
. (Join-Path $start 'v4a1_guard.ps1')

function Assert-V4B([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('V4-B smoke failed: ' + $Message) }
}

function New-V4BSyntheticAnalysis([string]$ProductId, [int]$Count, [bool]$HighConflict) {
    $items = @()
    for ($i=0; $i -lt $Count; $i++) {
        $risk = 0.12 + (0.035 * $i)
        $items += [pscustomobject]@{
            path = ('C:\refs\source_' + $ProductId + '_' + $i + '.png')
            position = $i
            duplicate = $false
            local_risk_score = $risk
            local_safe_score = (1.0 - $risk)
        }
    }
    return [pscustomobject]@{
        product_id = $ProductId
        high_variant_conflict = $HighConflict
        reference_safety = [object[]]$items
        images = [object[]]$items
    }
}

$product = [pscustomobject]@{
    product_id = '90000010001'
    product_name = '測試商品'
    variation_name = '顏色'
    variants = @()
    verified_facts = [pscustomobject]@{
        verified_numbers=[string[]]@('2米')
        verified_dimensions=[string[]]@('2米')
        verified_materials=[string[]]@()
        verified_accessories=[string[]]@()
        verified_gifts=[string[]]@()
        verified_bundle_contents=[string[]]@()
        verified_colors=[string[]]@()
        verified_sizes=[string[]]@()
        verified_models=[string[]]@()
        verified_quantities=[string[]]@()
        verified_features=[string[]]@()
        verified_use_cases=[string[]]@()
        verified_certifications=[string[]]@()
        verified_origin=[string[]]@()
    }
    multi_variant_flags = [pscustomobject]@{
        variant_count=2
        has_multiple_variants=$true
        has_multiple_sizes=$false
        has_multiple_colors=$true
        has_multiple_quantities=$false
        has_multiple_bundle_counts=$false
        has_multiple_models=$false
        has_multiple_resistance_levels=$false
    }
}

# 8 originals: choose exactly five truthful source images; no fill needed.
$analysis8 = New-V4BSyntheticAnalysis '90000010008' 8 $false
$plan8 = New-V4BSourceImagePlan $product $analysis8
Assert-V4B (@($plan8.slots).Count -eq 5) '8 originals must still output five slots'
Assert-V4B (@($plan8.slots | Where-Object { $_.source_mode -ne 'single_original' }).Count -eq 0) '8 originals should not need fill modes'
Assert-V4B (@($plan8.slots | ForEach-Object { $_.source_paths[0] } | Select-Object -Unique).Count -eq 5) '8 originals should select five distinct sources'
Assert-V4B ([bool](Test-V4BSourcePlan $plan8 $false).passed) '8-original source plan validation failed'

# 5 originals: one-to-one source preservation.
$analysis5 = New-V4BSyntheticAnalysis '90000010005' 5 $false
$plan5 = New-V4BSourceImagePlan $product $analysis5
Assert-V4B (@($plan5.slots).Count -eq 5) '5 originals must map one-to-one to five slots'
Assert-V4B (@($plan5.slots | Where-Object { $_.source_mode -eq 'single_original' }).Count -eq 5) '5 originals should all be single_original'
Assert-V4B ([bool](Test-V4BSourcePlan $plan5 $false).passed) '5-original source plan validation failed'

# 3 originals: preserve three directly, recompose only real sources, then safe generic fill.
$analysis3 = New-V4BSyntheticAnalysis '90000010003' 3 $false
$plan3 = New-V4BSourceImagePlan $product $analysis3
$modes3 = @($plan3.slots | ForEach-Object { [string]$_.source_mode })
Assert-V4B ($modes3 -contains 'single_original') '3 originals must keep direct sources'
Assert-V4B ($modes3 -contains 'recomposed_originals') '3 originals must use existing-content recomposition before generic fill'
Assert-V4B ($modes3 -contains 'generic_fill') '3 originals must safely fill to five'
Assert-V4B ([bool](Test-V4BSourcePlan $plan3 $false).passed) '3-original source plan validation failed'
$fill3 = Get-V4BPlanSlot $plan3 'detail4'
foreach ($copy in @($fill3.allowed_generic_copy)) { Assert-V4B (Test-V4BGenericCopyAllowed ([string]$copy)) ('generic fill contains non-whitelist copy: ' + [string]$copy) }

# 1 original: never invent another product visual. All slots trace back to the same real source.
$analysis1 = New-V4BSyntheticAnalysis '90000010000' 1 $false
$plan1 = New-V4BSourceImagePlan $product $analysis1
Assert-V4B (@($plan1.slots).Count -eq 5) '1 original must still fill to five'
Assert-V4B (@($plan1.slots | Where-Object { $_.source_mode -eq 'recomposed_originals' }).Count -eq 0) '1 original cannot claim multi-source recomposition'
$onePaths = @($plan1.slots | ForEach-Object { @($_.source_paths) } | Select-Object -Unique)
Assert-V4B ($onePaths.Count -eq 1) '1-original plan must retain one real visual source across all slots'
Assert-V4B (@($plan1.slots | Where-Object { $_.source_mode -eq 'generic_fill' }).Count -ge 1) '1 original needs at least one safe generic fill slot'
Assert-V4B ([bool](Test-V4BSourcePlan $plan1 $false).passed) '1-original source plan validation failed'

# High-conflict products must never mix two different variants just to fill image count.
$analysisConflict = New-V4BSyntheticAnalysis '90000010009' 3 $true
$planConflict = New-V4BSourceImagePlan $product $analysisConflict
Assert-V4B (@($planConflict.slots | Where-Object { @($_.source_paths).Count -gt 1 }).Count -eq 0) 'high-conflict fill must not mix multiple source variants'
Assert-V4B (@($planConflict.slots | Where-Object { $_.source_mode -eq 'recomposed_originals' }).Count -eq 0) 'high-conflict fill must not recompose across variants'

# Taiwan localization is not simple character conversion: commerce wording and units are localized.
$localized = Convert-ToTaiwanCommerceTextV4B '产品参数 2米 尺码 发货 使用说明 颜色分类'
Assert-V4B ($localized -match '規格資訊') '产品参数 must localize to 規格資訊'
Assert-V4B ($localized -match '2公尺') '2米 must localize to 2公尺 without changing numeric meaning'
Assert-V4B ($localized -match '尺寸') '尺码 must localize to 尺寸'
Assert-V4B ($localized -match '出貨') '发货 must localize to 出貨'
Assert-V4B ($localized -match '使用方式') '使用说明 must localize to 使用方式'
Assert-V4B ($localized -match '顏色／款式') '颜色分类 must localize to 顏色／款式'

$conditional = @(Get-V4BConditionalGenericCopy $product)
Assert-V4B ($conditional -contains '多色可選') 'multi-color product should allow 多色可選'
Assert-V4B ($conditional -notcontains '多尺寸可選') 'product without multi-size evidence must not allow 多尺寸可選'

$prompt = Get-PromptV2 'detail2' $product
Assert-V4B ($prompt -match 'EDIT / PRESERVE / LOCALIZE') 'V4-B edit/preserve/localize mode missing'
Assert-V4B ($prompt -match '原圖沒有的人物') 'no-new-person/source-fidelity rule missing'
Assert-V4B ($prompt -match '不要假裝 OCR') 'no fake OCR claim missing'
Assert-V4B ($prompt -match '功能、材質、尺寸、數量') 'hallucination ban missing'
Assert-V4B ($prompt -notmatch '測試商品') 'full product title/name must not seed the prompt as factual content'
$compact = Get-CompactTransportPromptV2 'detail4' $product
Assert-V4B ($compact -match 'EDIT/PRESERVE/LOCALIZE') 'compact V4-B prompt missing preservation mode'

# V4-B deliberately disables visual-novelty regeneration; source fidelity is the gate.
$layout = Test-LayoutDiversityV2 'not-used.jpg' ([string[]]@('also-not-used.jpg'))
Assert-V4B (-not [bool]$layout.high_similarity) 'V4-B must not regenerate solely for layout similarity'
Assert-V4B ((Get-LayoutRetryPromptV2 'detail2' 1) -match '相同真實來源') 'V4-B retry must preserve the same source'

# Production modules must remain generic; fixture IDs belong only in tests/docs.
foreach ($module in @('v4b_localization.ps1','v4b_fill_to_five.ps1','v4b_source_image_planner.ps1','v4b_original_image_guard.ps1','v4b_output_validator.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $start $module) -Raw -Encoding UTF8
    foreach ($fixtureId in @('52915734564','58015741169','53615734484','53215734553','57565745174')) {
        Assert-V4B (-not $text.Contains($fixtureId)) ($module + ' contains product-specific hardcoding: ' + $fixtureId)
    }
}

$apiBlob = (& git -C $root hash-object -- '_system/start/api_v2.ps1').Trim().ToLowerInvariant()
Assert-V4B ($apiBlob -eq '9e81a9c4a0769d5e41b4c1e7dba4b92266c49187') ('API-R3 transport Git blob changed: ' + $apiBlob)

Write-Host 'V4-B original-image preservation/localization/fill-to-five smoke: PASS' -ForegroundColor Green
