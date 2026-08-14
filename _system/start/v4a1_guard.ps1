$ErrorActionPreference = 'Stop'

function Get-V4A1Rules {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'config\factual_rules_v4a1.json'
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-V4A1Property($Object, [string]$Name, $Default) {
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Convert-V4A1StringArray($Value) {
    if ($null -eq $Value) { return [string[]]@() }
    return [string[]]@($Value | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

function Get-V4A1CellByAliases($Data, $Headers, $Aliases, [int]$Fallback = -1) {
    foreach ($alias in @($Aliases)) {
        $key = [string]$alias
        if ($Headers.ContainsKey($key)) {
            $column = [int]$Headers[$key]
            if ($Data.ContainsKey($column)) { return ([string]$Data[$column]).Trim() }
        }
    }
    if ($Fallback -ge 0 -and $Data.ContainsKey($Fallback)) { return ([string]$Data[$Fallback]).Trim() }
    return ''
}

function Get-V4A1RegexValues([string]$Text, [string]$Pattern) {
    $values = @()
    foreach ($match in [regex]::Matches($Text, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $value = (([string]$match.Value) -replace '\s+', '').Trim()
        if ($value) { $values += $value }
    }
    return [string[]]@($values | Select-Object -Unique)
}

function Get-V4A1LongestDictionaryMatches([string]$Text, $Dictionary) {
    $result = @()
    foreach ($raw in @($Dictionary | Sort-Object { ([string]$_).Length } -Descending)) {
        $term = [string]$raw
        if (-not $Text.Contains($term)) { continue }
        $covered = $false
        foreach ($picked in $result) {
            if (([string]$picked).Contains($term)) { $covered = $true; break }
        }
        if (-not $covered) { $result += $term }
    }
    return [string[]]@($result | Select-Object -Unique)
}

function Get-V4A1AccessoryMatches([string]$Text, $Dictionary) {
    $result = @()
    foreach ($raw in @($Dictionary | Sort-Object { ([string]$_).Length } -Descending)) {
        $term = [string]$raw
        $escaped = [regex]::Escape($term)
        if ($Text -match ("(?:不含|不附|無|不送)\s*" + $escaped)) { continue }
        $positive = ("(?:\+|附|含|贈|送|配)\s*" + $escaped)
        if ($Text -match $positive) { $result += $term }
    }
    return [string[]]@($result | Select-Object -Unique)
}

function Parse-ShopeeVariantFactsV4A1($Variant) {
    $rules = Get-V4A1Rules
    $text = ([string](Get-V4A1Property $Variant 'option_name' '')).Trim()
    $dimensions = @(Get-V4A1RegexValues $text '(?<![A-Za-z0-9])\d+(?:\.\d+)?\s*(?:毫米|公分|公尺|mm|cm|米|吋|m)(?![A-Za-z])')
    $resistance = @(Get-V4A1RegexValues $text '(?<![A-Za-z0-9])\d+(?:\.\d+)?\s*(?:磅|lb)(?![A-Za-z])')
    $measurements = @(Get-V4A1RegexValues $text '(?<![A-Za-z0-9])\d+(?:\.\d+)?\s*(?:kg|ml|號|g|L)(?![A-Za-z])')
    $quantities = @(Get-V4A1RegexValues $text '(?<![A-Za-z0-9])(?:\d+|[一二兩三四五六七八九十百]+)\s*(?:片|件|入|雙|組|套|包)')
    $sizes = @(Get-V4A1RegexValues $text '(?<![A-Za-z0-9])(?:EU\s*\d{2}|US\s*\d{1,2}|UK\s*\d{1,2}|2XL|3XL|XL|S|M|L)(?![A-Za-z0-9])')
    $models = @(Get-V4A1RegexValues $text '(?<![A-Za-z0-9])[A-Z]{2,10}-\d{2,}[A-Z0-9-]*(?![A-Za-z0-9])')
    $materials = @(Get-V4A1LongestDictionaryMatches $text $rules.material_dictionary)
    $accessories = @(Get-V4A1AccessoryMatches $text $rules.accessory_dictionary)
    $colors = @(Get-V4A1LongestDictionaryMatches $text $rules.color_dictionary)
    $numbers = @($dimensions + $resistance + $measurements + $quantities + $sizes | Select-Object -Unique)
    return [pscustomobject]@{
        option_index = [int](Get-V4A1Property $Variant 'index' 0)
        raw_option_name = $text
        numbers = [string[]]$numbers
        dimensions = [string[]]$dimensions
        materials = [string[]]$materials
        accessories = [string[]]$accessories
        colors = [string[]]$colors
        sizes = [string[]]$sizes
        models = [string[]]$models
        quantities = [string[]]$quantities
        resistance_levels = [string[]]$resistance
        bundle_contents = [string[]]$accessories
    }
}

function Get-V4A1CommonValues($VariantFacts, [string]$PropertyName) {
    $items = @($VariantFacts)
    if ($items.Count -eq 0) { return [string[]]@() }
    $common = @($items[0].$PropertyName | ForEach-Object { [string]$_ })
    for ($index = 1; $index -lt $items.Count; $index++) {
        $current = @($items[$index].$PropertyName | ForEach-Object { [string]$_ })
        $common = @($common | Where-Object { $current -contains $_ })
    }
    return [string[]]@($common | Select-Object -Unique)
}

function Build-ProductVerifiedFactsV4A1($VariantFacts) {
    return [pscustomobject]@{
        verified_numbers = (Get-V4A1CommonValues $VariantFacts 'numbers')
        verified_dimensions = (Get-V4A1CommonValues $VariantFacts 'dimensions')
        verified_materials = (Get-V4A1CommonValues $VariantFacts 'materials')
        verified_accessories = (Get-V4A1CommonValues $VariantFacts 'accessories')
        verified_gifts = [string[]]@()
        verified_bundle_contents = (Get-V4A1CommonValues $VariantFacts 'bundle_contents')
        verified_colors = (Get-V4A1CommonValues $VariantFacts 'colors')
        verified_sizes = (Get-V4A1CommonValues $VariantFacts 'sizes')
        verified_models = (Get-V4A1CommonValues $VariantFacts 'models')
        verified_quantities = (Get-V4A1CommonValues $VariantFacts 'quantities')
        verified_features = [string[]]@()
        verified_use_cases = [string[]]@()
        verified_certifications = [string[]]@()
        verified_origin = [string[]]@()
    }
}

function Get-V4A1DistinctSignatures($VariantFacts, [string]$PropertyName) {
    return @($VariantFacts | ForEach-Object { (@($_.$PropertyName | Sort-Object) -join '|') } | Select-Object -Unique)
}

function Build-MultiVariantFlagsV4A1($VariantFacts) {
    $count = @($VariantFacts).Count
    return [pscustomobject]@{
        variant_count = $count
        has_multiple_variants = ($count -gt 1)
        has_multiple_sizes = (@(Get-V4A1DistinctSignatures $VariantFacts 'sizes').Count -gt 1)
        has_multiple_colors = (@(Get-V4A1DistinctSignatures $VariantFacts 'colors').Count -gt 1)
        has_multiple_quantities = (@(Get-V4A1DistinctSignatures $VariantFacts 'quantities').Count -gt 1)
        has_multiple_bundle_counts = (@(Get-V4A1DistinctSignatures $VariantFacts 'quantities').Count -gt 1)
        has_multiple_models = (@(Get-V4A1DistinctSignatures $VariantFacts 'models').Count -gt 1)
        has_multiple_resistance_levels = (@(Get-V4A1DistinctSignatures $VariantFacts 'resistance_levels').Count -gt 1)
        has_unique_sku = $false
    }
}

function Resolve-FactualCategoriesV4A1($Product) {
    $source = (([string](Get-V4A1Property $Product 'product_category' '')) + ' ' + ([string](Get-V4A1Property $Product 'product_name' ''))).ToLowerInvariant()
    $groups = @('universal')
    if ($source -match 'basketball|volleyball|football|soccer|badminton|tennis|baseball|softball|pickleball|racket|racquet|籃球|排球|足球|羽球|網球|棒球|壘球|匹克球|球拍') { $groups += 'balls_rackets' }
    if ($source -match 'training|trainer|resistance|agility|訓練|敏捷|阻力|練習器|訓練器材') { $groups += 'training_equipment' }
    if ($source -match 'tape|support|protective gear|肌貼|貼布|護膝|護腕|護肘|護踝|繃帶|支撐帶') { $groups += 'tape_support' }
    if ($source -match 'yoga|pilates|fitness|瑜伽|普拉提|健身') { $groups += 'pilates_yoga' }
    if ($source -match 'shoe|footwear|鞋') { $groups += 'footwear' }
    if ($source -match 'sportswear|clothing|apparel|服飾|上衣|t恤|球衣|背心|內衣|褲|外套|裙') { $groups += 'apparel' }
    if ($source -match 'outdoor|bag|戶外|運動包|腰包|收納') { $groups += 'outdoor' }
    return [string[]]@($groups | Select-Object -Unique)
}

function Initialize-ProductFactualDataV4A1($Product) {
    $variantFacts = @()
    foreach ($variant in @(Get-V4A1Property $Product 'variants' @())) { $variantFacts += ,(Parse-ShopeeVariantFactsV4A1 $variant) }
    $commonFacts = Build-ProductVerifiedFactsV4A1 $variantFacts
    Add-Member -InputObject $Product -NotePropertyName 'variant_facts' -NotePropertyValue ([object[]]$variantFacts) -Force
    Add-Member -InputObject $Product -NotePropertyName 'variant_specific_facts' -NotePropertyValue ([object[]]$variantFacts) -Force
    Add-Member -InputObject $Product -NotePropertyName 'verified_facts' -NotePropertyValue $commonFacts -Force
    Add-Member -InputObject $Product -NotePropertyName 'common_verified_facts' -NotePropertyValue $commonFacts -Force
    Add-Member -InputObject $Product -NotePropertyName 'multi_variant_flags' -NotePropertyValue (Build-MultiVariantFlagsV4A1 $variantFacts) -Force
    Add-Member -InputObject $Product -NotePropertyName 'factual_categories' -NotePropertyValue (Resolve-FactualCategoriesV4A1 $Product) -Force
    return $Product
}

function Convert-ShopeeRowsToProducts($Rows) {
    $products = @()
    $headers = @{}
    $headerRowIndex = -1
    $scanLimit = [Math]::Min(30, @($Rows).Count)
    for ($rowIndex = 0; $rowIndex -lt $scanLimit; $rowIndex++) {
        foreach ($column in $Rows[$rowIndex].Keys) {
            $value = ([string]$Rows[$rowIndex][$column]).Trim()
            if ($value -match '^(et_title_product_id|商品ID)$') { $headerRowIndex = $rowIndex; break }
        }
        if ($headerRowIndex -ge 0) { break }
    }
    if ($headerRowIndex -ge 0) {
        foreach ($column in $Rows[$headerRowIndex].Keys) {
            $header = ([string]$Rows[$headerRowIndex][$column]).Trim()
            if ($header) { $headers[$header] = [int]$column }
        }
    }

    for ($rowIndex = 0; $rowIndex -lt @($Rows).Count; $rowIndex++) {
        if ($rowIndex -eq $headerRowIndex) { continue }
        $data = $Rows[$rowIndex]
        $productId = Get-V4A1CellByAliases $data $headers @('et_title_product_id','商品ID') 0
        if ($productId -notmatch '^\d{5,30}$') { continue }
        $cover = Get-V4A1CellByAliases $data $headers @('ps_item_cover_image','et_title_main_image','主商品圖片') 4
        if ($cover -notmatch '^https?://') { continue }

        $urls = @($cover)
        for ($imageIndex = 1; $imageIndex -le 8; $imageIndex++) {
            $imageUrl = Get-V4A1CellByAliases $data $headers @("ps_item_image.$imageIndex", "et_title_product_image_$imageIndex", "商品圖片 $imageIndex", "商品圖片$imageIndex") -1
            if ($imageUrl -match '^https?://') { $urls += $imageUrl }
        }
        $urls = @($urls | Select-Object -Unique)

        $variants = @()
        for ($optionIndex = 1; $optionIndex -le 28; $optionIndex++) {
            $optionName = Get-V4A1CellByAliases $data $headers @("et_title_option_${optionIndex}_for_variation_1", "選項 ${optionIndex} 的名稱", "選項${optionIndex}的名稱") -1
            if ([string]::IsNullOrWhiteSpace($optionName)) { continue }
            $optionImage = Get-V4A1CellByAliases $data $headers @("et_title_option_image_${optionIndex}_for_variation_1", "選項 ${optionIndex} 的圖片", "選項${optionIndex}的圖片") -1
            $variants += ,[pscustomobject]@{ index=$optionIndex; option_name=$optionName; option_image=$optionImage }
        }

        $product = [pscustomobject]@{
            product_id = [string]$productId
            parent_sku = (Get-V4A1CellByAliases $data $headers @('et_title_parent_sku','主商品貨號') 1)
            product_name = (Get-V4A1CellByAliases $data $headers @('et_title_product_name','商品名稱') 2)
            product_category = (Get-V4A1CellByAliases $data $headers @('et_title_product_category','商品分類') 3)
            image_urls = [string[]]$urls
            variation_name = (Get-V4A1CellByAliases $data $headers @('et_title_variation_1','規格名稱 1','規格名稱1') -1)
            new_size_chart = (Get-V4A1CellByAliases $data $headers @('ps_new_size_chart','et_title_new_size_chart','新版尺寸表') -1)
            image_size_chart = (Get-V4A1CellByAliases $data $headers @('et_title_size_chart','et_title_image_size_chart','圖片尺寸表') -1)
            variants = [object[]]$variants
        }
        $products += ,(Initialize-ProductFactualDataV4A1 $product)
    }
    return $products
}

function Select-ShopeeProductV2([string]$ProductId) {
    if ([string]::IsNullOrWhiteSpace($ProductId) -or $ProductId -notmatch '^\d{5,30}$') { throw '商品ID格式錯誤。' }
    $catalog = Get-CatalogV2
    $matches = @($catalog.products | Where-Object { [string]$_.product_id -eq $ProductId })
    if ($matches.Count -ne 1) { throw '找不到該商品，或 Excel 中有重複商品ID。' }
    $product = Initialize-ProductFactualDataV4A1 $matches[0]
    $selection = [pscustomobject]@{
        product_id = [string]$product.product_id
        parent_sku = [string](Get-V4A1Property $product 'parent_sku' '')
        product_name = [string]$product.product_name
        product_category = [string](Get-V4A1Property $product 'product_category' '')
        image_urls = @($product.image_urls | ForEach-Object { [string]$_ })
        variation_name = [string](Get-V4A1Property $product 'variation_name' '')
        new_size_chart = [string](Get-V4A1Property $product 'new_size_chart' '')
        image_size_chart = [string](Get-V4A1Property $product 'image_size_chart' '')
        variants = @($product.variants)
        verified_facts = $product.verified_facts
        common_verified_facts = $product.common_verified_facts
        variant_facts = @($product.variant_facts)
        variant_specific_facts = @($product.variant_specific_facts)
        multi_variant_flags = $product.multi_variant_flags
        factual_categories = @($product.factual_categories)
        selected_at = (Get-Date).ToString('o')
    }
    $path = Join-Path (Get-SelectionWorkspaceV2) 'selected_product.json'
    $selection | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    return $selection
}

function Get-V4A1AllFactValues($Facts) {
    if ($null -eq $Facts) { return [string[]]@() }
    $values = @()
    foreach ($property in $Facts.PSObject.Properties) { $values += @(Convert-V4A1StringArray $property.Value) }
    return [string[]]@($values | Select-Object -Unique)
}

function Test-IsMultiVariantV4A1($Flags) {
    if ($null -eq $Flags) { return $false }
    if ([bool](Get-V4A1Property $Flags 'has_multiple_variants' $false)) { return $true }
    foreach ($name in @('has_multiple_sizes','has_multiple_colors','has_multiple_quantities','has_multiple_bundle_counts','has_multiple_models','has_multiple_resistance_levels')) {
        if ([bool](Get-V4A1Property $Flags $name $false)) { return $true }
    }
    return $false
}

function Get-V4A1BlacklistTerms($Product) {
    $rules = Get-V4A1Rules
    $groups = @('universal','medical_safety','performance_claims','materials_features') + @(Resolve-FactualCategoriesV4A1 $Product)
    $terms = @()
    foreach ($group in @($groups | Select-Object -Unique)) {
        if ($rules.blacklists.PSObject.Properties.Name -contains $group) { $terms += @($rules.blacklists.$group) }
    }
    return [string[]]@($terms | ForEach-Object { [string]$_ } | Select-Object -Unique)
}

function Test-FactualContentV4A1([string]$Content, $Product) {
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    $allowed = @(Get-V4A1AllFactValues $facts)
    $risks = @()
    foreach ($term in @(Get-V4A1BlacklistTerms $Product)) {
        if ($Content.Contains($term) -and $allowed -notcontains $term) { $risks += $term }
    }
    $rules = Get-V4A1Rules
    foreach ($term in @($rules.material_dictionary)) {
        if ($Content.Contains([string]$term) -and @($facts.verified_materials) -notcontains [string]$term) { $risks += [string]$term }
    }
    foreach ($match in [regex]::Matches($Content, '(?<![A-Za-z0-9])(?:\d+(?:\.\d+)?\s*(?:mm|cm|kg|ml|lb|米|m|g|磅|吋|號|片|件|入|雙|組|套)|[一二兩三四五六七八九十百]+\s*(?:片|件|入|雙|組|套)|[xX×]\s*\d+|\d+\s*%)', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $value = (([string]$match.Value) -replace '\s+','').Trim()
        if ($allowed -notcontains $value) { $risks += $value }
    }
    return [pscustomobject]@{ factual_risk=(@($risks | Select-Object -Unique).Count -gt 0); risk_terms=[string[]]@($risks | Select-Object -Unique); image_text_ocr_verified=$false }
}

function Get-FactualPromptSectionsV4A1($Product, [string]$Slot) {
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    $factValues = @(Get-V4A1AllFactValues $facts)
    $factText = if ($factValues.Count -gt 0) { $factValues -join '、' } else { '無已驗證具體規格；不要自行補數字、材質、配件或功效。' }
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $variantText = if (Test-IsMultiVariantV4A1 $flags) { '本商品有多規格：只能使用所有規格共同一致的已驗證事實；任何只屬於單一選項的數量、顏色、尺寸、型號、組合或阻力值都禁止寫死，可寫「多規格可選／請依實際選項為準」。' } else { '仍只能使用已驗證事實，不得從商品名稱或常識補規格。' }
    $slotTitle = switch ($Slot) { 'main' {'商品外觀一覽'} 'detail1' {'重點細節一覽'} 'detail2' {'商品細節展示'} 'detail3' {'使用方式參考'} 'detail4' {'選購前請確認規格'} default {'商品資訊'} }
    return [pscustomobject]@{
        facts = $facts
        allowed_factual_text = [string[]]@($factValues + @((Get-V4A1Rules).safe_copy) + @($slotTitle) | Select-Object -Unique)
        text = ("[已驗證可使用事實]`n" + $factText + "`n[硬性文字限制]`n所有文字型具體事實只能取自上方已驗證事實。參考圖只用來忠實保持商品外觀、結構、顏色與使用姿勢；不得因為模型自己看圖就新增未進白名單的尺寸、數字、材質、配件、贈品、內含物、功效、品牌承諾、認證或安全承諾。資訊不足就少寫，不得為填滿版面補內容。`n[多規格限制]`n" + $variantText)
    }
}

function Get-PromptV2([string]$Slot, $Product) {
    if ($Product -is [string]) { $Product = [pscustomobject]@{ product_name=[string]$Product } }
    $name = [string](Get-V4A1Property $Product 'product_name' '')
    $factual = Get-FactualPromptSectionsV4A1 $Product $Slot
    $role = switch ($Slot) {
        'main' { '製作1:1台灣蝦皮封面主圖。商品主體清楚完整、手機縮圖可讀；使用一個低風險主標題與少量已驗證資訊。' }
        'detail1' { 'detail1：核心資訊總覽。只整理白名單已驗證資訊與商品本體可見細節，版型不得複製主圖。' }
        'detail2' { 'detail2：商品結構與細節展示。只有白名單確認的配件或內含物才能標成隨附內容；否則只展示商品本體細節。' }
        'detail3' { 'detail3：使用方式或情境展示。可呈現姿勢與場景，但不得自行寫運動效果、醫療效果或性能提升。' }
        'detail4' { 'detail4：規格／選購補充。只有白名單已有數值才可做尺寸規格；沒有就做保守選購提醒，不填假數字。' }
        default { '製作1:1補充詳情圖，只呈現已驗證資訊。' }
    }
    return ("商品名稱僅供辨識核心商品：$name。商品名稱中的數字、材質、功能、配件與宣稱都不是已驗證事實。`n$role`n" + $factual.text + "`n文字使用自然台灣繁體中文，不用中國大陸電商浮誇詞。")
}

function Get-CompactTransportPromptV2([string]$Slot, $Product) {
    if ($Product -is [string]) { $Product = [pscustomobject]@{ product_name=[string]$Product } }
    $facts = @(Get-V4A1AllFactValues (Get-V4A1Property $Product 'verified_facts' $null))
    $factText = if ($facts.Count -gt 0) { $facts -join '、' } else { '無具體規格白名單' }
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    $variant = if (Test-IsMultiVariantV4A1 $flags) { '多規格，只能寫所有選項共同事實。' } else { '' }
    $role = switch ($Slot) { 'main' {'封面主圖'} 'detail1' {'重點總覽'} 'detail2' {'結構細節'} 'detail3' {'使用情境'} 'detail4' {'選購補充'} default {'補充詳情'} }
    return ("製作1:1台灣蝦皮$role。已驗證事實：$factText。$variant 所有具體數字、尺寸、材質、配件、贈品、內含物、功效、認證與安全承諾，未列入已驗證事實就禁止生成；資訊不足就少寫。忠實保持商品外觀與結構，使用自然台灣繁體中文。")
}
