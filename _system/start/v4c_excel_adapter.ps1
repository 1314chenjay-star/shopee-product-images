# TinySnow V4-C0
# Shopee Excel adapter for universal product analysis.
# This layer preserves raw product/category/variation evidence and never promotes option text into common facts.

function Get-V4CNormalizedHeader([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.Trim().ToLowerInvariant()) -replace '\s+', '' -replace '[：:（）()\[\]【】]', '')
}

function Test-V4CHeaderMatch([string]$Value, [string[]]$Candidates) {
    $normalized = Get-V4CNormalizedHeader $Value
    foreach ($candidate in $Candidates) {
        if ($normalized -eq (Get-V4CNormalizedHeader $candidate)) { return $true }
    }
    return $false
}

function Get-V4CRowValue($Row, [int]$Column) {
    if ($null -eq $Row -or $Column -lt 0) { return '' }
    if ($Row.ContainsKey($Column)) { return ([string]$Row[$Column]).Trim() }
    return ''
}

function Find-V4CShopeeHeaderMap($Rows, [int]$MaxScanRows = 30) {
    $scanCount = [Math]::Min(@($Rows).Count, $MaxScanRows)
    $best = $null
    $bestScore = -1

    for ($r = 0; $r -lt $scanCount; $r++) {
        $row = $Rows[$r]
        if ($null -eq $row) { continue }
        $map = [ordered]@{
            product_id = -1
            parent_sku = -1
            product_name = -1
            category = -1
            variation_name = -1
            image_columns = @()
            option_name_columns = @()
            option_image_columns = @()
        }

        foreach ($column in @($row.Keys | Sort-Object)) {
            $value = [string]$row[$column]
            if (Test-V4CHeaderMatch $value @('商品ID','et_title_product_id','productid')) { $map.product_id = [int]$column; continue }
            if (Test-V4CHeaderMatch $value @('主商品貨號','et_title_parent_sku','parentsku','商品SKU')) { $map.parent_sku = [int]$column; continue }
            if (Test-V4CHeaderMatch $value @('商品名稱','et_title_product_name','productname')) { $map.product_name = [int]$column; continue }
            if (Test-V4CHeaderMatch $value @('商品分類','et_title_product_category','productcategory')) { $map.category = [int]$column; continue }
            if (Test-V4CHeaderMatch $value @('規格名稱1','規格名稱 1','et_title_variation_1')) { $map.variation_name = [int]$column; continue }

            $normalized = Get-V4CNormalizedHeader $value
            if ($normalized -eq '主商品圖片' -or $normalized -eq 'ps_item_cover_image' -or $normalized -match '^商品圖片\d+$' -or $normalized -match '^ps_item_image\.\d+$') {
                $map.image_columns += [int]$column
                continue
            }
            if ($normalized -match '^選項\d+的名稱$' -or $normalized -match '^et_title_option_\d+_for_variation_1$') {
                $map.option_name_columns += [int]$column
                continue
            }
            if ($normalized -match '^選項\d+的圖片$' -or $normalized -match '^et_title_option_image_\d+_for_variation_1$') {
                $map.option_image_columns += [int]$column
                continue
            }
        }

        $score = 0
        if ($map.product_id -ge 0) { $score += 4 }
        if ($map.product_name -ge 0) { $score += 3 }
        if ($map.category -ge 0) { $score += 2 }
        if (@($map.image_columns).Count -gt 0) { $score += 3 }
        if ($map.variation_name -ge 0) { $score += 1 }
        if (@($map.option_name_columns).Count -gt 0) { $score += 1 }

        if ($score -gt $bestScore) {
            $bestScore = $score
            $best = [pscustomobject]@{
                header_row_index = $r
                score = $score
                columns = [pscustomobject]$map
            }
        }
    }

    if ($null -eq $best -or $best.score -lt 9 -or $best.columns.product_id -lt 0 -or $best.columns.product_name -lt 0 -or @($best.columns.image_columns).Count -eq 0) {
        throw 'V4-C0：前 30 列找不到可靠的 Shopee 商品標題列。'
    }
    return $best
}

function Get-V4CVariantFlagsFromOptions([string[]]$Options) {
    $options = @($Options | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $quantityTokens = @()
    $sizeTokens = @()
    $colorHits = @()
    $materialHits = @()

    foreach ($option in $options) {
        $text = [string]$option
        foreach ($m in [regex]::Matches($text, '(?i)(\d+)\s*(雙|双|入|個|个|件|隻|只|顆|颗|組|组|支|條|条|片|枚|套)')) { $quantityTokens += $m.Groups[1].Value + $m.Groups[2].Value }
        foreach ($m in [regex]::Matches($text, '(?i)(?:^|[^A-Z0-9])(XS|S|M|L|XL|2XL|3XL|4XL|5XL)(?:$|[^A-Z0-9])')) { $sizeTokens += $m.Groups[1].Value.ToUpperInvariant() }
        foreach ($color in @('黑','白','灰','紅','红','藍','蓝','綠','绿','粉','紫','黃','黄','橘','棕','咖啡','米色','銀','银','金色')) {
            if ($text -like ('*' + $color + '*')) { $colorHits += $color }
        }
        foreach ($material in @('棉','純棉','纯棉','尼龍','尼龙','聚酯','矽膠','硅胶','不鏽鋼','不锈钢','鋁合金','铝合金','皮革','牛皮','羊毛','木','塑膠','塑料')) {
            if ($text -like ('*' + $material + '*')) { $materialHits += $material }
        }
    }

    return [pscustomobject]@{
        has_multiple_colors = (@($colorHits | Select-Object -Unique).Count -ge 2)
        has_multiple_sizes = (@($sizeTokens | Select-Object -Unique).Count -ge 2)
        has_multiple_materials = (@($materialHits | Select-Object -Unique).Count -ge 2)
        has_multiple_quantities = (@($quantityTokens | Select-Object -Unique).Count -ge 2)
        has_multiple_bundle_counts = (@($quantityTokens | Select-Object -Unique).Count -ge 2)
        has_multiple_patterns = $false
        option_count = $options.Count
    }
}

function Convert-V4CShopeeRowsToProducts($Rows, $HeaderMap) {
    $products = @()
    $columns = $HeaderMap.columns
    for ($r = [int]$HeaderMap.header_row_index + 1; $r -lt @($Rows).Count; $r++) {
        $row = $Rows[$r]
        $productId = Get-V4CRowValue $row ([int]$columns.product_id)
        if ($productId -notmatch '^\d{5,30}$') { continue }

        $name = Get-V4CRowValue $row ([int]$columns.product_name)
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $urls = @()
        foreach ($column in @($columns.image_columns)) {
            $url = Get-V4CRowValue $row ([int]$column)
            if ($url -match '^https?://') { $urls += $url }
        }
        $urls = @($urls | Select-Object -Unique)
        if ($urls.Count -eq 0) { continue }

        $options = @()
        foreach ($column in @($columns.option_name_columns)) {
            $option = Get-V4CRowValue $row ([int]$column)
            if (-not [string]::IsNullOrWhiteSpace($option)) { $options += $option }
        }
        $options = @($options | Select-Object -Unique)

        $products += [pscustomobject]@{
            product_id = [string]$productId
            name = [string]$name
            title = [string]$name
            parent_sku = Get-V4CRowValue $row ([int]$columns.parent_sku)
            category = Get-V4CRowValue $row ([int]$columns.category)
            image_urls = [string[]]$urls
            variation_name = Get-V4CRowValue $row ([int]$columns.variation_name)
            variation_options = [string[]]$options
            multi_variant_flags = Get-V4CVariantFlagsFromOptions ([string[]]$options)
            verified_facts = [pscustomobject]@{}
            source_provenance = [pscustomobject]@{
                source_type = 'shopee_excel_raw'
                source_row_index = $r
                option_text_is_audit_only = $true
                option_text_is_not_common_fact = $true
            }
        }
    }
    return [object[]]$products
}

function Import-V4CShopeeExcel([string]$Path) {
    if (-not (Get-Command Read-XlsxRows -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'excel_reader.ps1')
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'V4-C0：找不到 Excel 檔案。' }
    if ([IO.Path]::GetExtension($Path) -ne '.xlsx') { throw 'V4-C0：只接受 .xlsx。' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
        $entries = @{}
        foreach ($entry in $archive.Entries) { $entries[(([string]$entry.FullName) -replace '\\','/')] = $entry }

        $sharedStrings = @()
        if ($entries.ContainsKey('xl/sharedStrings.xml')) {
            $reader = New-Object IO.StreamReader($entries['xl/sharedStrings.xml'].Open())
            try { [xml]$sharedXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
            foreach ($item in $sharedXml.SelectNodes('//*[local-name()="sst"]/*[local-name()="si"]')) {
                $parts = @($item.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText })
                $sharedStrings += ($parts -join '')
            }
        }

        foreach ($sheet in @($archive.Entries | Where-Object { (([string]$_.FullName) -replace '\\','/') -like 'xl/worksheets/sheet*.xml' } | Sort-Object FullName)) {
            $rows = Read-XlsxRows $sheet $sharedStrings
            if (@($rows).Count -eq 0) { continue }
            try {
                $header = Find-V4CShopeeHeaderMap $rows 30
                $products = @(Convert-V4CShopeeRowsToProducts $rows $header)
                if ($products.Count -gt 0) {
                    return [pscustomobject]@{
                        schema_version = 'v4c0-excel-1'
                        header_map = $header
                        products = [object[]]$products
                    }
                }
            }
            catch {
                # Continue to another worksheet; do not modify source workbook.
            }
        }
        throw 'V4-C0：沒有找到可用的 Shopee 商品資料列。'
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}
