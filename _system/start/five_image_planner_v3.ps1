$ErrorActionPreference = 'Stop'

$script:V4A3ReferenceSelectorBase = (Get-Command Get-ReferencesForSlotV2 -ErrorAction Stop).ScriptBlock
$script:V4A3AnalyzeBase = (Get-Command Analyze-ProductImagesV2 -ErrorAction Stop).ScriptBlock
$script:V4A3PlanCache = @{}

function Get-V4A3SlotDefinitions {
    return @(
        [pscustomobject]@{
            slot='main'; role='主成交圖'; content_goal='商品外觀與最重要的共同已驗證資訊';
            preferred_reference_classes=@('pure_product','detail_structure'); blocked_reference_classes=@('promo_risky','single_variant_risky');
            preferred_layout_family='hero_asymmetric'; blocked_visual_patterns=@('不可把多規格選項排成一次收到的整套','不可使用資訊卡塞滿整張主圖');
            must_differ_from_slots=@(); text_priority='商品標籤＋最精簡共同規格'; verified_fact_priority='common_only';
            main_subject_type='single_product_hero'; has_person='avoid'; product_angle_type='full_product'; product_position='center_or_right'; hand_held_style='avoid_if_alternative'
        },
        [pscustomobject]@{
            slot='detail1'; role='賣點／細節總覽'; content_goal='提供主圖沒有的新細節與不同視角';
            preferred_reference_classes=@('detail_structure','pure_product'); blocked_reference_classes=@('promo_risky','single_variant_risky');
            preferred_layout_family='detail_overview_grid'; blocked_visual_patterns=@('不得沿用 main 的同一手持商品主構圖','不得只換背景複製主圖');
            must_differ_from_slots=@('main'); text_priority='一個主標題＋一行已驗證規格'; verified_fact_priority='common_only';
            main_subject_type='detail_or_alternate_angle'; has_person='avoid'; product_angle_type='alternate_or_macro'; product_position='left_or_split'; hand_held_style='blocked_as_primary'
        },
        [pscustomobject]@{
            slot='detail2'; role='結構與細節'; content_goal='局部結構、可確認配件或包裝細節；沒有就只做無字細節';
            preferred_reference_classes=@('detail_structure','accessory','packaging'); blocked_reference_classes=@('promo_risky','single_variant_risky');
            preferred_layout_family='macro_breakdown'; blocked_visual_patterns=@('局部放大不得自行命名零件','不得重複 main/detail1 的英雄式大商品構圖');
            must_differ_from_slots=@('main','detail1'); text_priority='集中單一規格區，局部放大無字'; verified_fact_priority='common_only';
            main_subject_type='macro_detail_panels'; has_person='avoid'; product_angle_type='macro_or_structure'; product_position='distributed_panels'; hand_held_style='blocked_as_primary'
        },
        [pscustomobject]@{
            slot='detail3'; role='使用方式／情境'; content_goal='呈現合理使用方式，並保持多規格中立';
            preferred_reference_classes=@('usage_scene','pure_product'); blocked_reference_classes=@('promo_risky','single_variant_risky');
            preferred_layout_family='usage_scene'; blocked_visual_patterns=@('不得做成另一張靜態商品封面','多規格商品不得讓單一規格情境代表全部選項');
            must_differ_from_slots=@('main','detail1','detail2'); text_priority='商品標籤＋使用方式參考'; verified_fact_priority='common_only';
            main_subject_type='usage_context'; has_person='preferred_if_safe'; product_angle_type='usage_dependent'; product_position='scene_dependent'; hand_held_style='allowed_only_if_natural_use'
        },
        [pscustomobject]@{
            slot='detail4'; role='規格／選購補充'; content_goal='共同規格、尺寸、型號或保守選購提醒';
            preferred_reference_classes=@('spec_info','size_info','detail_structure','pure_product'); blocked_reference_classes=@('promo_risky','single_variant_risky');
            preferred_layout_family='information_card'; blocked_visual_patterns=@('不得再次使用 main 的手持商品英雄式主構圖','沒有共同規格時不得自行補尺寸或材質');
            must_differ_from_slots=@('main','detail1','detail2','detail3'); text_priority='規格／選購資訊卡'; verified_fact_priority='common_only';
            main_subject_type='supporting_product_with_info_cards'; has_person='avoid'; product_angle_type='supporting_product'; product_position='secondary_small'; hand_held_style='blocked_as_primary'
        }
    )
}

function Get-V4A3CandidateScore($Candidate, $Definition, [string[]]$UsedPrimaryPaths) {
    $risk = [double](Get-V4A1Property $Candidate 'local_risk_score' 0.50)
    $safe = [double](Get-V4A1Property $Candidate 'local_safe_score' (1.0 - $risk))
    $scores = Get-V4A1Property $Candidate 'class_scores' $null

    # Safety is the largest term by design. Diversity may never win by selecting a clearly riskier reference.
    $score = 120.0 * $safe - 80.0 * $risk
    foreach ($className in @($Definition.preferred_reference_classes)) {
        if ($null -ne $scores) { $score += 28.0 * [double](Get-V4A1Property $scores $className 0.0) }
    }
    foreach ($className in @($Definition.blocked_reference_classes)) {
        if ($null -ne $scores) { $score -= 32.0 * [double](Get-V4A1Property $scores $className 0.0) }
    }

    $path = [string](Get-V4A1Property $Candidate 'path' '')
    if (@($UsedPrimaryPaths) -contains $path) { $score -= 42.0 }
    return [Math]::Round($score,4)
}

function New-FiveImagePlanV4A3($Product, $Analysis, [int]$MaximumReferences) {
    if ($null -eq $Analysis) { throw 'V4-A.3：缺少 Analysis，無法建立五圖計畫。' }
    $maximum = [Math]::Min(2, [Math]::Max(1,$MaximumReferences))
    $highConflict = [bool](Get-V4A1Property $Analysis 'high_variant_conflict' $false)
    if ($highConflict) { $maximum = 1 }

    $classified = @(Get-V4A3ReferenceClassifications $Analysis)
    if ($classified.Count -eq 0) { throw 'V4-A.3：沒有可用參考圖分類結果。' }

    # High-conflict products cannot safely use diversity pressure to hop between references because
    # different originals may represent different variants. Lock all slots to the single safest source;
    # visual diversity must come from slot role/layout planning, never from a riskier variant reference.
    $highConflictSafest = $null
    if ($highConflict) {
        $safeRanked = @($classified | Sort-Object @{Expression='local_risk_score';Ascending=$true}, @{Expression='position';Ascending=$true})
        if ($safeRanked.Count -gt 0) { $highConflictSafest = $safeRanked[0] }
    }

    $usedPrimary = @()
    $slotPlans = @()
    foreach ($definition in @(Get-V4A3SlotDefinitions)) {
        $ranked = @()
        foreach ($candidate in $classified) {
            $candidateScore = 0.0
            if ($highConflict) {
                $risk = [double](Get-V4A1Property $candidate 'local_risk_score' 0.50)
                $candidateScore = [Math]::Round(100.0 * (1.0 - $risk),4)
            }
            else {
                $candidateScore = Get-V4A3CandidateScore $candidate $definition ([string[]]$usedPrimary)
            }
            $ranked += [pscustomobject]@{ candidate=$candidate; score=$candidateScore }
        }
        $ranked = @($ranked | Sort-Object @{Expression='score';Descending=$true}, @{Expression={ [double]$_.candidate.local_risk_score };Ascending=$true}, @{Expression={ [int]$_.candidate.position };Ascending=$true})

        $selected = @()
        if ($highConflict -and $null -ne $highConflictSafest) {
            $selected = @($highConflictSafest)
        }
        else {
            foreach ($entry in $ranked) {
                if ($selected.Count -ge $maximum) { break }
                $candidate = $entry.candidate
                $path = [string]$candidate.path
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                if (@($selected | ForEach-Object { [string]$_.path }) -contains $path) { continue }
                $selected += $candidate
            }
        }
        if ($selected.Count -eq 0) { throw ('V4-A.3：' + [string]$definition.slot + ' 無可用安全參考圖。') }
        $usedPrimary += [string]$selected[0].path

        $slotPlans += [pscustomobject]@{
            slot = [string]$definition.slot
            role = [string]$definition.role
            content_goal = [string]$definition.content_goal
            preferred_reference_classes = [string[]]@($definition.preferred_reference_classes)
            blocked_reference_classes = [string[]]@($definition.blocked_reference_classes)
            preferred_layout_family = [string]$definition.preferred_layout_family
            blocked_visual_patterns = [string[]]@($definition.blocked_visual_patterns)
            must_differ_from_slots = [string[]]@($definition.must_differ_from_slots)
            text_priority = [string]$definition.text_priority
            verified_fact_priority = [string]$definition.verified_fact_priority
            main_subject_type = [string]$definition.main_subject_type
            has_person = [string]$definition.has_person
            product_angle_type = [string]$definition.product_angle_type
            product_position = [string]$definition.product_position
            hand_held_style = [string]$definition.hand_held_style
            reference_candidates = [object[]]@($ranked | ForEach-Object { [pscustomobject]@{ path=[string]$_.candidate.path; score=$_.score; risk=[double]$_.candidate.local_risk_score; classes=[string[]]@($_.candidate.classes) } })
            selected_reference_ids = [string[]]@($selected | ForEach-Object { [string]$_.path })
            selected_reference_paths = [string[]]@($selected | ForEach-Object { [string]$_.path })
            primary_reference_source = [string]$selected[0].path
        }
    }

    $productId = [string](Get-V4A1Property $Analysis 'product_id' '')
    $plan = [pscustomobject]@{
        version = 'V4-A.3'
        product_id = $productId
        created_at = (Get-Date).ToString('o')
        safety_first = $true
        semantic_limit = 'proxy_only_no_ocr'
        high_variant_conflict = $highConflict
        high_conflict_reference_policy = if ($highConflict) { 'same_safest_reference_all_slots' } else { 'slot_aware_safe_diversity' }
        analyzed_reference_count = $classified.Count
        slots = [object[]]$slotPlans
    }

    if (-not [string]::IsNullOrWhiteSpace($productId)) { $script:V4A3PlanCache[$productId] = $plan }
    try {
        $firstImage = @($Analysis.images | Select-Object -First 1)
        if ($firstImage.Count -gt 0) {
            $folder = Split-Path ([string]$firstImage[0].path) -Parent
            $plan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $folder 'five_image_plan_v4a3.json') -Encoding UTF8
        }
    }
    catch {}
    return $plan
}

function Get-V4A3PlanSlot($Plan, [string]$Slot) {
    $matches = @($Plan.slots | Where-Object { [string]$_.slot -eq $Slot } | Select-Object -First 1)
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-V4A3CurrentPlan {
    try {
        $product = Get-V4A2ResolvedProduct $null
        $productId = [string](Get-V4A1Property $product 'product_id' '')
        if ($productId -and $script:V4A3PlanCache.ContainsKey($productId)) { return $script:V4A3PlanCache[$productId] }
    }
    catch {}
    return $null
}

function Analyze-ProductImagesV2([string]$ProductId, [string[]]$Paths) {
    $analysis = & $script:V4A3AnalyzeBase $ProductId $Paths
    $product = Get-V4A2ResolvedProduct $null
    $null = New-FiveImagePlanV4A3 $product $analysis 2
    return $analysis
}

function Get-ReferencesForSlotV2($Analysis, [string]$Slot, [int]$Maximum) {
    try {
        $productId = [string](Get-V4A1Property $Analysis 'product_id' '')
        $plan = $null
        if ($productId -and $script:V4A3PlanCache.ContainsKey($productId)) { $plan = $script:V4A3PlanCache[$productId] }
        if ($null -eq $plan) {
            $product = Get-V4A2ResolvedProduct $null
            $plan = New-FiveImagePlanV4A3 $product $Analysis $Maximum
        }
        $slotPlan = Get-V4A3PlanSlot $plan $Slot
        if ($null -eq $slotPlan) { throw '找不到 slot plan。' }

        $paths = @($slotPlan.selected_reference_paths)
        $limit = [Math]::Min([Math]::Max(1,$Maximum), $paths.Count)
        if ([bool]$plan.high_variant_conflict) { $limit = 1 }
        $paths = @($paths | Select-Object -First $limit)

        $classified = @(Get-V4A3ReferenceClassifications $Analysis)
        $final = @()
        foreach ($path in $paths) {
            $candidate = @($classified | Where-Object { [string]$_.path -eq [string]$path } | Select-Object -First 1)
            $risk = 0.50
            if ($candidate.Count -gt 0) { $risk = [double]$candidate[0].local_risk_score }
            $proxy = New-V4A2ReferenceProxy $productId ([string]$path) $risk ([bool]$plan.high_variant_conflict)
            if ($final -notcontains $proxy) { $final += $proxy }
        }
        if ($final.Count -gt 0) { return [string[]]$final }
    }
    catch {}

    return [string[]]@(& $script:V4A3ReferenceSelectorBase $Analysis $Slot $Maximum)
}
