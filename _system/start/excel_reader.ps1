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

function Get-XlsxCellValue($Cell, $SharedStrings) {
    $referenceAttr = $Cell.Attributes.GetNamedItem('r')
    if ($null -eq $referenceAttr) {
        return [pscustomobject]@{ Column = -1; Value = '' }
    }

    $column = Get-XlsxColumnNumber ([string]$referenceAttr.Value)
    if ($column -lt 0) {
        return [pscustomobject]@{ Column = -1; Value = '' }
    }

    $type = ''
    $typeAttr = $Cell.Attributes.GetNamedItem('t')
    if ($null -ne $typeAttr) {
        $type = [string]$typeAttr.Value
    }

    $value = ''
    if ($type -eq 'inlineStr') {
        $parts = @($Cell.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText })
        $value = ($parts -join '')
    }
    else {
        $valueNode = $Cell.SelectSingleNode('./*[local-name()="v"]')
        if ($null -ne $valueNode) {
            $value = [string]$valueNode.InnerText
            if ($type -eq 's' -and $value -match '^\d+$') {
                $idx = [int]$value
                if ($idx -ge 0 -and $idx -lt $SharedStrings.Count) {
                    $value = [string]$SharedStrings[$idx]
                }
            }
        }
    }

    return [pscustomobject]@{ Column = $column; Value = [string]$value }
}

function Read-XlsxRows($SheetEntry, $SharedStrings) {
    $reader = New-Object IO.StreamReader($SheetEntry.Open())
    try {
        [xml]$sheetXml = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }

    $rows = @()
    foreach ($row in $sheetXml.SelectNodes('//*[local-name()="sheetData"]/*[local-name()="row"]')) {
        $values = @{}
        foreach ($cell in $row.SelectNodes('./*[local-name()="c"]')) {
            $parsed = Get-XlsxCellValue $cell $SharedStrings
            if ($parsed.Column -ge 0) {
                $values[[int]$parsed.Column] = [string]$parsed.Value
            }
        }
        $rows += ,$values
    }
    return $rows
}

function Convert-ShopeeRowsToProducts($Rows) {
    $products = @()

    foreach ($data in $Rows) {
        $productId = ''
        if ($data.ContainsKey(0)) {
            $productId = ([string]$data[0]).Trim()
        }
        if ($productId -notmatch '^\d{5,30}$') {
            continue
        }

        $cover = ''
        if ($data.ContainsKey(4)) {
            $cover = ([string]$data[4]).Trim()
        }
        if ($cover -notmatch '^https?://') {
            continue
        }

        $productName = ''
        if ($data.ContainsKey(2)) {
            $productName = ([string]$data[2]).Trim()
        }

        $urls = @()
        for ($column = 4; $column -le 12; $column++) {
            if ($data.ContainsKey($column)) {
                $url = ([string]$data[$column]).Trim()
                if ($url -match '^https?://') {
                    $urls += $url
                }
            }
        }

        if ($urls.Count -eq 0) {
            continue
        }

        $products += ,[pscustomobject]@{
            product_id = $productId
            product_name = $productName
            image_urls = $urls
        }
    }

    return $products
}

function Import-ShopeeExcelV2([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Excel file not found.'
    }
    if ([IO.Path]::GetExtension($Path) -ne '.xlsx') {
        throw 'Please select an .xlsx file.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null

    try {
        $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path).Path)
        $entries = @{}
        foreach ($entry in $archive.Entries) {
            $normalizedName = ([string]$entry.FullName) -replace '\\', '/'
            $entries[$normalizedName] = $entry
        }

        $sharedStrings = @()
        if ($entries.ContainsKey('xl/sharedStrings.xml')) {
            $reader = New-Object IO.StreamReader($entries['xl/sharedStrings.xml'].Open())
            try {
                [xml]$sharedXml = $reader.ReadToEnd()
            }
            finally {
                $reader.Dispose()
            }

            foreach ($item in $sharedXml.SelectNodes('//*[local-name()="sst"]/*[local-name()="si"]')) {
                $parts = @($item.SelectNodes('.//*[local-name()="t"]') | ForEach-Object { $_.InnerText })
                $sharedStrings += ($parts -join '')
            }
        }

        $sheetEntries = @()
        foreach ($entry in $archive.Entries) {
            $normalizedName = ([string]$entry.FullName) -replace '\\', '/'
            if ($normalizedName -like 'xl/worksheets/sheet*.xml') {
                $sheetEntries += $entry
            }
        }
        $sheetEntries = @($sheetEntries | Sort-Object FullName)
        if ($sheetEntries.Count -eq 0) {
            throw 'No worksheet XML found.'
        }

        foreach ($sheet in $sheetEntries) {
            $rows = Read-XlsxRows $sheet $sharedStrings
            if ($null -eq $rows -or $rows.Count -eq 0) {
                continue
            }

            $products = Convert-ShopeeRowsToProducts $rows
            if ($null -ne $products -and $products.Count -gt 0) {
                return $products
            }
        }

        throw 'No Shopee product rows were found. Expected numeric product ID in column A and image URL in column E.'
    }
    catch {
        throw ('Excel import failed. Original file was not modified. ' + $_.Exception.Message)
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Save-ImportedCatalogV2([string]$ExcelPath) {
    $products = Import-ShopeeExcelV2 $ExcelPath
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
