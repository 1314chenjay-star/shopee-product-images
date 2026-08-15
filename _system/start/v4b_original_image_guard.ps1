$ErrorActionPreference = 'Stop'

function Get-V4BResolvedProduct($ProductOrName) {
    if ($null -ne $ProductOrName -and -not ($ProductOrName -is [string])) { return $ProductOrName }
    try { return (Get-V4A2ResolvedProduct $ProductOrName) } catch {}
    return [pscustomobject]@{ product_id=''; product_name=''; verified_facts=$null; multi_variant_flags=$null; variants=@() }
}

function Get-V4BSafeProductLabel($Product) {
    if ($null -eq $Product) { return '商品' }
    $labelCommand = Get-Command Get-TaiwanProductLabelV4A2 -ErrorAction SilentlyContinue
    if ($null -ne $labelCommand) {
        $label = [string](Get-TaiwanProductLabelV4A2 $Product)
        if (-not [string]::IsNullOrWhiteSpace($label)) { return $label }
    }
    return '商品'
}

function Get-V4BStructuredFactText($Product) {
    if ($null -eq $Product) { return '無額外結構化共同規格；只依原圖清楚內容編修，不猜測。' }
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    if ($null -eq $facts) { return '無額外結構化共同規格；只依原圖清楚內容編修，不猜測。' }
    $values = @(Get-V4A1AllFactValues $facts | ForEach-Object { Convert-ToTaiwanCommerceTextV4B ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
    if ($values.Count -eq 0) { return '無額外結構化共同規格；只依原圖清楚內容編修，不猜測。' }
    return ($values -join '、')
}

function Get-V4BVariantConflictPrompt($Product) {
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $parts = @()
    if (Test-IsMultiVariantV4A1 $flags) {
        $parts += '本商品有多規格。可以保留來源圖本身清楚可見的款式外觀，但不得把單一規格內容改寫成所有規格共同具備。'
    }
    if ([bool](Get-V4A1Property $flags 'has_multiple_quantities' $false) -or [bool](Get-V4A1Property $flags 'has_multiple_bundle_counts' $false)) {
        $parts += '結構化規格顯示數量／套組數有差異：來源圖中的具體件數、片數、入數、組數、套數、條數等數量文字（例如 N片、N入、N組、N套、N條）不要翻譯、重建或改寫成通用賣點。若畫面需要保留該結構，改成不含數量的中性說法；共同已驗證的長度、重量、阻力等非件數規格仍可正常顯示。'
    }
    if ($parts.Count -eq 0) { return '仍不得從商品名稱或常識補出原圖沒有的具體規格。' }
    return ($parts -join ' ')
}

function Get-V4BSourceSellerPolicyPrompt {
    return '來源圖中的原賣家促銷與交易承諾不是商品屬性。價格、折扣、滿減、包郵／免郵、包退、退貨承諾、七天無理由、運費險、限時、銷量、廠家直銷、售後承諾、正品賠付等文字，即使看得清楚也必須把「整個文字標籤／整個承諾詞組」刪除，不翻譯、不重建、不保留其中一半。尤其看到含「包退／退換／售後」的詞組時，禁止把它改寫成「低敏、溫和、親膚、安全、安心、品質保證」等替代商品賣點。刪除後寧可留白、延續背景或使用純圖形，不補任何替代宣稱。除非未來有本賣場獨立驗證的交易政策資料，否則不得沿用其他賣家的承諾。'
}

function Get-V4BIconTextPrompt {
    return '純裝飾圖示可以保留或重新整理，但圖示／徽章內不要自行加入可辨識的拉丁字母、數字或單位縮寫，例如 KG、LB、CM、MM、IN。已驗證的尺寸或阻力若要顯示，直接在一般文字區使用完整台灣顯示值（例如 2公尺、30磅），不要再配一個帶不同單位字母的 icon，以免產生錯誤單位或矛盾。'
}

function Get-V4BSlotRoleText([string]$Slot) {
    switch ($Slot) {
        'main' { return '主圖：以原商品主視覺為底做乾淨的台灣電商封面整理；不要改造成另一個商品或新場景。' }
        'detail1' { return '詳情圖1：保留來源圖既有的商品重點、功能說明或細節資訊，重新整理文字與版面即可。' }
        'detail2' { return '詳情圖2：保留來源圖既有的結構、局部、配件、包裝或其他可見內容；沒有就不要補新的零件或功能。' }
        'detail3' { return '詳情圖3：若來源圖已有使用方式或情境就保留並在地化；若沒有，只整理來源圖既有內容，不自行新增人物、手或使用場景。' }
        'detail4' { return '詳情圖4：優先整理來源圖既有的尺寸、規格、款式或選購資訊；沒有可靠規格時只能使用安全白名單提醒。' }
        default { return '補充圖：只整理來源圖既有內容。' }
    }
}

function Get-V4BSourceModePrompt($SlotPlan) {
    if ($null -eq $SlotPlan) { return '來源模式：single_original。只編修現有原圖。' }
    $mode = [string](Get-V4A1Property $SlotPlan 'source_mode' 'single_original')
    $base = switch ($mode) {
        'single_original' { '來源模式：single_original。以這張真實原圖為唯一視覺來源，保留商品、人物、場景、零件與現有商品資訊；只做翻譯、排版、裁切、清理與畫質優化。' }
        'recomposed_originals' { '來源模式：recomposed_originals。只能把提供的真實原圖內容重新裁切、整理、組合；不得在兩張原圖之外創造新商品、新人物、新場景、新零件或新屬性。' }
        'generic_fill' { '來源模式：generic_fill。仍以提供的真實原圖商品為視覺基礎；若既有內容不足，只能加入下方安全白名單通用文字，不得新增任何具體商品事實。' }
        default { '來源模式：' + $mode + '。只允許原圖保真編修。' }
    }
    if ([bool](Get-V4A1Property $SlotPlan 'text_shield_required' $false)) {
        $shieldReason = [string](Get-V4A1Property $SlotPlan 'text_shield_reason' 'unspecified_source_text_risk')
        $base += (' [來源文字遮蔽｜' + $shieldReason + '] 本 slot 的來源文字或規格具有高風險，參考圖已被低解析處理以保留商品／人物／場景輪廓但阻止直接抄來源文字。不要猜測、還原、補全或模仿模糊的來源字樣；本張所有新可讀文字只能使用「結構化共同已驗證資訊」或「本 slot 安全通用文字」。來源圖中原本的功能句、件數、尺寸、材質、促銷字、售後字在此 slot 都不要重建。')
        if ($shieldReason -eq 'sparse_verified_facts_source_text_risk') {
            $base += ' [商品表面文字閉鎖] 此規則優先於保留原有印字：商品本體、織帶、標籤、包裝與背景都不得生成任何可辨識中文、英文、字母、數字、品牌、Logo 或標章。模糊來源印字必須改成與商品表面同色的無字中性紋理；禁止替換成新的英文詞、地名、品牌樣式或仿 Logo。'
        }
    }
    return $base
}

function Get-V4BGenericPromptText($SlotPlan) {
    if ($null -eq $SlotPlan) { return '（無）' }
    $copy = @($SlotPlan.allowed_generic_copy | ForEach-Object { Convert-ToTaiwanCommerceTextV4B ([string]$_) } | Where-Object { $_ } | Select-Object -Unique)
    if ($copy.Count -eq 0) { return '（無）' }
    return ($copy -join '｜')
}

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $product = Get-V4BResolvedProduct $ProductOrName
    $plan = Get-V4BCurrentSourcePlan
    $slotPlan = Get-V4BPlanSlot $plan $Slot
    $label = Get-V4BSafeProductLabel $product
    $facts = Get-V4BStructuredFactText $product
    $role = Get-V4BSlotRoleText $Slot
    $sourceMode = Get-V4BSourceModePrompt $slotPlan
    $generic = Get-V4BGenericPromptText $slotPlan
    $variantGuard = Get-V4BVariantConflictPrompt $product

    $prompt = @(
        '[V4-B 原圖保真台灣化模式｜EDIT / PRESERVE / LOCALIZE]',
        '這是「編修既有商品圖」任務，不是自由生圖，也不是重新設計商品。',
        $role,
        $sourceMode,
        ('安全商品類型標籤僅供辨識，不可當作新增規格事實：' + $label),
        ('結構化共同已驗證資訊僅供交叉確認：' + $facts),
        '[原圖內容保留硬規則]',
        '盡量保留原圖中已存在且清楚可辨識的商品外觀、顏色、結構、功能文字、材質文字、尺寸規格、名稱、型號、配件、使用說明與其他商品屬性。不要因為舊版白名單較少就把原圖清楚存在的有效商品資訊全部刪掉。',
        '原圖沒有的人物、手、使用場景、商品零件、配件、贈品、顏色、材質、尺寸、數量、功能、認證、功效或安全承諾，一律不得新增。原圖已有的人物或場景可以保留，但不得自行換成另一個新場景。',
        '[文字翻譯與台灣在地化硬規則]',
        '只翻譯你在參考圖中能清楚辨識的文字。簡體中文改成自然台灣繁體中文，規格名稱、尺寸名稱、功能標題與說明盡量改成台灣賣家常用說法，避免中國大陸電商語氣。',
        '品牌、Logo、型號、SKU、數字、數量與規格數值不得擅自改義。2米這類來源值顯示成台灣常用的2公尺；必要時尺寸圖可使用等值200公分，但不可改變數值意義。',
        '看不清楚、被遮住、語意不確定或來源彼此衝突的文字不要猜；可保留成不可辨識視覺、減少文字或省略。不要假裝 OCR 已驗證成功，本地流程沒有 OCR 真值保證。',
        '[來源賣家促銷／承諾清理]',
        (Get-V4BSourceSellerPolicyPrompt),
        '[圖示與單位文字硬限制]',
        (Get-V4BIconTextPrompt),
        '[禁止虛構]',
        '禁止自行新增或推測：功能、材質、尺寸、數量、規格、型號、配件、贈品、套組內容、認證、醫療／防護／安全承諾，以及防水、防汗、透氣、親膚、耐磨、減震、支撐、矯正等效果。只有來源原圖清楚存在或結構化共同已驗證資訊支持時才可保留。',
        ('[多規格／衝突規則] ' + $variantGuard),
        ('[本 slot 可用安全通用文字] ' + $generic),
        '安全通用文字只是「可以使用」，不是必須全部塞進圖片；版面資訊足夠就少寫。',
        '輸出維持1:1電商圖片，可做背景清潔、留白、裁切、對齊、字級與資訊層級整理，但商品本體與來源事實必須忠實。'
    ) -join "`n"
    return (Convert-ToTaiwanCommerceTextV4B $prompt)
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $product = Get-V4BResolvedProduct $ProductOrName
    $plan = Get-V4BCurrentSourcePlan
    $slotPlan = Get-V4BPlanSlot $plan $Slot
    $label = Get-V4BSafeProductLabel $product
    $generic = Get-V4BGenericPromptText $slotPlan
    $variantGuard = Get-V4BVariantConflictPrompt $product
    $shield = if ([bool](Get-V4A1Property $slotPlan 'text_shield_required' $false)) { ' 本張使用來源文字遮蔽參考；禁止還原或猜測模糊來源文字，新可讀文字只准共同已驗證資訊或安全通用文字。' } else { '' }
    if ([string](Get-V4A1Property $slotPlan 'text_shield_reason' '') -eq 'sparse_verified_facts_source_text_risk') { $shield += ' 商品本體、織帶、標籤、包裝與背景一律不得出現可辨識中文、英文、字母、數字、品牌、Logo 或標章；來源印字改成同色無字中性紋理，禁止創造新英文詞、地名或仿品牌字樣。' }
    $text = "V4-B EDIT/PRESERVE/LOCALIZE：商品類型僅辨識為「$label」。只編修提供的真實原圖，不重新設計商品。保留原圖清楚存在的商品與商品屬性並翻成自然台灣繁體；看不清就省略，不猜測，不假裝OCR成功。原圖沒有的人物、場景、零件、功能、材質、尺寸、數量、配件、贈品、認證、功效與安全承諾都禁止新增。品牌、型號、SKU與數值不得改義。來源圖的價格、折扣、包郵、包退、售後承諾、限時與原賣家促銷文字必須整個刪除，禁止改寫成低敏、親膚、安全、安心等替代賣點。規格圖示不要自行放 KG、LB、CM、MM、IN 或其他單位字母。$shield $variantGuard 安全通用文字僅可用：$generic。資訊不足就少寫。"
    return (Convert-ToTaiwanCommerceTextV4B $text)
}

function Get-LayoutRetryPromptV2([string]$Slot, [int]$LayoutAttempt) {
    if ($LayoutAttempt -le 0) {
        return "`n[V4-B 構圖規則] 以來源原圖構圖為基礎，只做必要的1:1裁切、留白與資訊整理；不要為了和其他五圖不同而創造新商品畫面。"
    }
    return "`n[V4-B 重試規則] 若需重試，仍必須使用相同真實來源與相同商品事實；只修正可讀性、排版或技術問題，不得用『換場景／換人物／換商品角度』方式追求新奇。"
}
