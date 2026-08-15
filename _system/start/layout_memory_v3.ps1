$ErrorActionPreference = 'Stop'

$script:V4A3PromptBase = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A3CompactPromptBase = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock
$layoutRetryCommand = Get-Command Get-LayoutRetryPromptV2 -ErrorAction SilentlyContinue
$script:V4A3LayoutRetryBase = $null
if ($null -ne $layoutRetryCommand) { $script:V4A3LayoutRetryBase = $layoutRetryCommand.ScriptBlock }
$script:V4A3MainFitnessBase = (Get-Command Test-MainImageFitnessV2 -ErrorAction Stop).ScriptBlock
$script:V4A3DiversityBase = (Get-Command Test-LayoutDiversityV2 -ErrorAction Stop).ScriptBlock

function Get-V4A3PlannerPromptText([string]$Slot) {
    $plan = Get-V4A3CurrentPlan
    $slotPlan = $null
    if ($null -ne $plan) { $slotPlan = Get-V4A3PlanSlot $plan $Slot }
    if ($null -eq $slotPlan) {
        $definition = @(Get-V4A3SlotDefinitions | Where-Object { [string]$_.slot -eq $Slot } | Select-Object -First 1)
        if ($definition.Count -gt 0) { $slotPlan = $definition[0] }
    }
    if ($null -eq $slotPlan) { return '' }

    $blocked = @($slotPlan.blocked_visual_patterns)
    $blockedText = if ($blocked.Count -gt 0) { $blocked -join '；' } else { '避免重複前一張的主要構圖。' }
    $different = @($slotPlan.must_differ_from_slots)
    $differentText = if ($different.Count -gt 0) { $different -join '、' } else { '無' }

    return ("`n[V4-A.3 五圖整體規劃] 本張角色：{0}。內容目標：{1}。指定版型家族：{2}。必須與 {3} 在至少兩個視覺維度上明顯不同（商品位置／人物有無／主視角／資訊區位置／場景／版面骨架擇二以上），但不得為了差異度選擇風險更高或與共同已驗證事實衝突的內容。禁止：{4}。同商品五張圖屬於同一商品頁素材，不可只換背景反覆複製同一個手持商品或英雄式主視覺。" -f [string]$slotPlan.role,[string]$slotPlan.content_goal,[string]$slotPlan.preferred_layout_family,$differentText,$blockedText)
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A3PromptBase $Slot $ProductOrName
    return ($base + (Get-V4A3PlannerPromptText $Slot))
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A3CompactPromptBase $Slot $ProductOrName
    return ($base + (Get-V4A3PlannerPromptText $Slot))
}

if ($null -ne $script:V4A3LayoutRetryBase) {
    function Get-LayoutRetryPromptV2([string]$Slot, [int]$LayoutAttempt) {
        $base = & $script:V4A3LayoutRetryBase $Slot $LayoutAttempt
        $plan = Get-V4A3CurrentPlan
        $slotPlan = $null
        if ($null -ne $plan) { $slotPlan = Get-V4A3PlanSlot $plan $Slot }
        if ($null -eq $slotPlan) { return $base }

        $mustDiffer = @($slotPlan.must_differ_from_slots)
        $fromText = if ($mustDiffer.Count -gt 0) { $mustDiffer -join '、' } else { '前面已完成圖片' }
        return ($base + ("`nV4-A.3 去重記憶：此 slot 的固定角色仍是「{0}」，不得改成其他 slot 的任務。重生時優先改變與 {1} 相同的商品位置、主視角、人物／手持方式、資訊區位置與版面骨架；至少改兩項。Reference Safety 與 VerifiedFacts 永遠優先於去重。" -f [string]$slotPlan.role,$fromText))
    }
}

function Get-V4A3LayoutMemoryPath([string]$ProductId) {
    $dir = Join-Path (Get-V2Workspace) ('checkpoints\' + $ProductId)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Join-Path $dir 'layout_memory_v4a3.json')
}

function Get-V4A3LayoutMemoryFromPlan($Plan) {
    $memory = @()
    if ($null -eq $Plan) { return [object[]]$memory }
    foreach ($slotPlan in @($Plan.slots)) {
        $memory += [pscustomobject]@{
            slot = [string]$slotPlan.slot
            main_subject_type = [string](Get-V4A1Property $slotPlan 'main_subject_type' $slotPlan.role)
            has_person = [string](Get-V4A1Property $slotPlan 'has_person' 'slot_dependent')
            dominant_layout_family = [string]$slotPlan.preferred_layout_family
            product_angle_type = [string](Get-V4A1Property $slotPlan 'product_angle_type' 'must_differ_from_prior_slots')
            product_position = [string](Get-V4A1Property $slotPlan 'product_position' 'planner_assigned_dynamic')
            visual_theme = [string]$slotPlan.content_goal
            hand_held_style = [string](Get-V4A1Property $slotPlan 'hand_held_style' 'avoid_repetition')
            primary_reference_source = [string]$slotPlan.primary_reference_source
            reference_class = [string](@($slotPlan.preferred_reference_classes) -join ',')
            actual_sha256 = ''
            recorded_at = ''
        }
    }
    return [object[]]$memory
}

function Save-V4A3LayoutMemoryFromPlan($Plan) {
    if ($null -eq $Plan) { return }
    try {
        $productId = [string]$Plan.product_id
        if ([string]::IsNullOrWhiteSpace($productId)) { return }
        $path = Get-V4A3LayoutMemoryPath $productId
        $existing = @{}
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($item in @($old.fingerprints)) { $existing[[string]$item.slot] = $item }
            }
            catch {}
        }

        $fingerprints = @()
        foreach ($item in @(Get-V4A3LayoutMemoryFromPlan $Plan)) {
            $slot = [string]$item.slot
            if ($existing.ContainsKey($slot)) {
                $oldItem = $existing[$slot]
                $item.actual_sha256 = [string](Get-V4A1Property $oldItem 'actual_sha256' '')
                $item.recorded_at = [string](Get-V4A1Property $oldItem 'recorded_at' '')
            }
            $fingerprints += $item
        }
        $payload = [pscustomobject]@{
            version = 'V4-A.3'
            product_id = $productId
            updated_at = (Get-Date).ToString('o')
            fingerprints = [object[]]$fingerprints
        }
        $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    }
    catch {}
}

function Register-V4A3AcceptedSlotMemory([string]$Slot, [string]$CandidatePath) {
    try {
        if (@('main','detail1','detail2','detail3','detail4') -notcontains $Slot) { return }
        if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) { return }
        $plan = Get-V4A3CurrentPlan
        if ($null -eq $plan) { return }
        $slotPlan = Get-V4A3PlanSlot $plan $Slot
        if ($null -eq $slotPlan) { return }

        $path = Get-V4A3LayoutMemoryPath ([string]$plan.product_id)
        Save-V4A3LayoutMemoryFromPlan $plan
        $payload = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $updated = @()
        foreach ($item in @($payload.fingerprints)) {
            if ([string]$item.slot -eq $Slot) {
                $item.actual_sha256 = (Get-FileHash -LiteralPath $CandidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
                $item.recorded_at = (Get-Date).ToString('o')
            }
            $updated += $item
        }
        $payload.fingerprints = [object[]]$updated
        $payload.updated_at = (Get-Date).ToString('o')
        $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    }
    catch {}
}

function Get-V4A3SlotFromCandidatePath([string]$Path) {
    $leaf = Split-Path $Path -Leaf
    if ($leaf -match '_(main|detail1|detail2|detail3|detail4)\.jpg(?:\.candidate)?$') { return [string]$matches[1] }
    return ''
}

function Test-MainImageFitnessV2([string]$Path) {
    & $script:V4A3MainFitnessBase $Path
    Register-V4A3AcceptedSlotMemory 'main' $Path
}

function Test-LayoutDiversityV2([string]$CandidatePath, [string[]]$ExistingPaths) {
    $result = & $script:V4A3DiversityBase $CandidatePath $ExistingPaths
    if (-not [bool]$result.high_similarity) {
        $slot = Get-V4A3SlotFromCandidatePath $CandidatePath
        if (-not [string]::IsNullOrWhiteSpace($slot)) { Register-V4A3AcceptedSlotMemory $slot $CandidatePath }
    }
    return $result
}
