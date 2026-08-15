$ErrorActionPreference = 'Stop'

$script:V4A3PromptBase = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A3CompactPromptBase = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A3LayoutRetryBase = (Get-Command Get-LayoutRetryPromptV2 -ErrorAction Stop).ScriptBlock

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

function Get-V4A3LayoutMemoryFromPlan($Plan) {
    $memory = @()
    if ($null -eq $Plan) { return [object[]]$memory }
    foreach ($slotPlan in @($Plan.slots)) {
        $hasPerson = 'slot_dependent'
        if ([string]$slotPlan.slot -eq 'detail3') { $hasPerson = 'preferred_if_safe' }
        elseif ([string]$slotPlan.slot -eq 'main') { $hasPerson = 'not_primary' }

        $handHeld = 'avoid_repetition'
        if ([string]$slotPlan.slot -eq 'detail4') { $handHeld = 'blocked_as_primary' }

        $memory += [pscustomobject]@{
            slot = [string]$slotPlan.slot
            main_subject_type = [string]$slotPlan.role
            has_person = $hasPerson
            dominant_layout_family = [string]$slotPlan.preferred_layout_family
            product_angle_type = 'must_differ_from_prior_slots'
            product_position = 'planner_assigned_dynamic'
            visual_theme = [string]$slotPlan.content_goal
            hand_held_style = $handHeld
            primary_reference_source = [string]$slotPlan.primary_reference_source
            reference_class = [string](@($slotPlan.preferred_reference_classes) -join ',')
        }
    }
    return [object[]]$memory
}

function Save-V4A3LayoutMemoryFromPlan($Plan) {
    if ($null -eq $Plan) { return }
    try {
        $productId = [string]$Plan.product_id
        if ([string]::IsNullOrWhiteSpace($productId)) { return }
        $dir = Join-Path (Get-V2Workspace) ('checkpoints\' + $productId)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $payload = [pscustomobject]@{
            version = 'V4-A.3'
            product_id = $productId
            updated_at = (Get-Date).ToString('o')
            fingerprints = [object[]](Get-V4A3LayoutMemoryFromPlan $Plan)
        }
        $payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $dir 'layout_memory_v4a3.json') -Encoding UTF8
    }
    catch {}
}
