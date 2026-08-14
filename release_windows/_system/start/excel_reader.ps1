$ErrorActionPreference = 'Stop'

function Get-XlsxColumnNumber([string]$Reference) {
    if ([string]::IsNullOrWhiteSpace($Reference)) { return -1 }
    $letters = ($Reference -replace '\d', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($letters)) { return -1 }
    $number = 0
    foreach ($letter in $letters.ToCharArray()) {
        $number = ($number * 26) + ([int]$letter - [int][char]'A' + 1)
    }
    return ($number - 1)
}

function Get-XlsxCellValue($Cell, [object[]]$SharedStrings) {
    $referenceAttr = $Cell.Attributes.GetNamedItem('r')
    if ($null -eq $referenceAttr) { return [pscustomobject]@{ Column = -1; Value = '' } }

    $column = Get-XlsxColumnNumber ([string]$referenceAttr.Value)
    if ($column -lt 0) { return [pscustomobject]@{ Column = -1; Value = '' } }

    $type = ''
    $typeAttr = $Cell.Attributes.GetNamedItem('t')
    if ($null -ne $typeAttr) { $type = [string]$typeAttr.Value }

    $value = ''
    if ($type -eq 'inlineStr') {
        $parts = @($Cell.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText })
        $value = ($parts -join '')
    }
    else {
        $valueNode = $Cell.SelectSingleNode('./*[local-name()="v"]')
        if ($null -ne $valueNode) {
            $value = [string]$valueNode.InnerText
            if ($type -eq 's' -and -not [string]::IsNullOrWhiteSpace($value)) {
                $sharedIndex = 0
                if ([int]::TryParse($value, [ref]$sharedIndex)) {
                    if ($sharedIndex -ge 0 -and $sharedIndex -lt $SharedStrings.Count) {
                        $value = [string]$SharedStrings[$sharedIndex]
                    }
                }
            }
        }
    }

    return [pscustomobject]@{ Column = $column; Value = [string]$value }
}

function Read-XlsxRows($SheetEntry, [object[]]$SharedStrings) {
    $reader = New-Object IO.StreamReader($SheetEntry.Open())
    try { [xml]$sheetXml = $reader.ReadToEnd() }
    finally { $reader.Dispose() }

    $rows = New-Object Collections.Generic.List[object]
    foreach ($row in $sheetXml.SelectNodes('//*[local-name()="sheetData"]/*[local-name()="row"]')) {
        $values = @{}
        foreach ($cell in $row.SelectNodes('./*[local-name()="c"]')) {
            $parsed = Get-XlsxCellValue $cell $SharedStrings
            if ($parsed.Column -ge 0) { $values[[int]$parsed.Column] = [string]$parsed.Value }
        }
        [void]$rows.Add($values)
    }
    return @($rows)
}

function Find-ShopeeLayout([object[]]$Rows) {
    $scanLimit = [Math]::Min($Rows.Count, 30)

    # Preferred: Shopee internal ASCII field names in the hidden first row.
    for ($i = 0; $i -lt $scanLimit; $i++) {
        $row = $Rows[$i]
        $map = @{}
        foreach ($col in $row.Keys) {
            $text = ([string]$row[$col]).Trim()
            if ($text -eq 'et_title_product_id') { $map.id = [int]$col }
            elseif ($text -eq 'et_title_product_name') { $map.name = [int]$col }
            elseif ($text -eq 'ps_item_cover_image') { $map.main = [int]$col }
            elseif ($text -match '^ps_item_image\.(\d+)$') {
                $n = [int]$Matches[1]
                if ($n -ge 1 -and $n -le 8) { $map['image' + $n] = [int]$col }
            }
        }
        if ($map.ContainsKey('id') -and $map.ContainsKey('name') -and $map.ContainsKey('main')) {
            return [pscustomobject]@{ Map = $map; DataStart = $i + 1; Mode = 'system-header' }
        }
    }

    # Structural fallback for Shopee media templates: A=id, C=name, E=cover, F:M=images.
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $row = $Rows[$i]
        $id = if ($row.ContainsKey(0)) { ([string]$row[0]).Trim() } else { '' }
        $cover = if ($row.ContainsKey(4)) { ([string]$row[4]).Trim() } else { '' }
        if ($id -match '^\d{5,30}$' -and $cover -match '^https?://') {
            $map = @{ id = 0; name = 2; main = 4 }
            for ($n = 1; $n -le 8; $n++) { $map['image' + $n] = 4 + $n }
            return [pscustomobject]@{ Map = $map; DataStart = $i; Mode = 'structural' }
        }
    }

    return $null
}

function Convert-RowsToProducts([object[]]$Rows, $Layout) {
    $columns = $Layout.Map
    $products = New-Object Collections.Generic.List[object]

    for ($rowIndex = [int]$Layout.DataStart; $rowIndex -lt $Rows.Count; $rowIndex++) {
        $data = $Rows[$rowIndex]
        $productId = ''
        if ($data.ContainsKey($columns.id)) { $productId = ([string]$data[$columns.id]).Trim() }
        if ($productId -notmatch '^\d{5,30}$') { continue }

        $productName = ''
        if ($data.ContainsKey($columns.name)) { $productName = ([string]$data[$columns.name]).Trim() }

        $urls = New-Object Collections.Generic.List[string]
        foreach ($key in @('main','image1','image2','image3','image4','image5','image6','image7','image8')) {
            if ($columns.ContainsKey($key) -and $data.ContainsKey($columns[$key])) {
                $url = ([string]$data[$columns[$key]]).Trim()
                if ($url -match '^https?://') { [void]$urls.Add($url) }
            }
        }
        if ($urls.Count -eq 0) { continue }

        [void]$products.Add([pscustomobject]@{
            product_id = $productId
            product_name = $productName
            image_urls = @($urls)
        })
    }

    return @($products)
}

function Import-ShopeeExcelV2([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Excel file not found.' }
    if ([IO.Path]::GetExtension($Path) -ne '.xlsx') { throw 'Please select an .xlsx file.' }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
        $entries = @{}
        foreach ($entry in $archive.Entries) { $entries[$entry.FullName] = $entry }

        $sharedStrings = @()
        if ($entries.ContainsKey('xl/sharedStrings.xml')) {
            $reader = New-Object IO.StreamReader($entries['xl/sharedStrings.xml'].Open())
            try { [xml]$sharedXml = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
            foreach ($item in $sharedXml.SelectNodes('//*[local-name()="sst"]/*[local-name()="si"]')) {
                $parts = @($item.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText })
                $sharedStrings += ($parts -join '')
            }
        }

        $sheetEntries = @($archive.Entries | Where-Object { $_.FullName -like 'xl/worksheets/sheet*.xml' } | Sort-Object FullName)
        if ($sheetEntries.Count -eq 0) { throw 'No worksheet XML found.' }

        foreach ($sheet in $sheetEntries) {
            $rows = @(Read-XlsxRows $sheet $sharedStrings)
            if ($rows.Count -eq 0) { continue }
            $layout = Find-ShopeeLayout $rows
            if ($null -eq $layout) { continue }
            $products = @(Convert-RowsToProducts $rows $layout)
            if ($products.Count -gt 0) { return $products }
        }

        throw 'Shopee media layout not detected. No product row with numeric ID and image URL was found.'
    }
    catch {
        throw ('Excel import failed. Original file was not modified. ' + $_.Exception.Message)
    }
    finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Save-ImportedCatalogV2([string]$ExcelPath) {
    $products = @(Import-ShopeeExcelV2 $ExcelPath)
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $workspace = Join-Path $systemRoot 'workspace'
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null

    $catalog = [ordered]@{
        source_excel = (Resolve-Path -LiteralPath $ExcelPath).Path
        imported_at = (Get-Date).ToString('o')
        products = $products
    }
    $catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $workspace 'catalog.json') -Encoding UTF8
    return $products
}
