$ErrorActionPreference = 'Stop'

function Join-Chars([int[]]$Codes, [string]$Suffix = '') {
    $builder = New-Object System.Text.StringBuilder
    foreach ($code in $Codes) {
        [void]$builder.Append([char]$code)
    }
    if (-not [string]::IsNullOrEmpty($Suffix)) {
        [void]$builder.Append($Suffix)
    }
    return $builder.ToString()
}

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

function Get-ShopeeHeaderAliases {
    $product = Join-Chars @(0x5546, 0x54C1)
    $name = Join-Chars @(0x540D, 0x7A31)
    $main = Join-Chars @(0x4E3B)
    $image = Join-Chars @(0x5716, 0x7247)
    $number = Join-Chars @(0x7DE8, 0x865F)

    $aliases = @{}
    $aliases.id = @($product + 'ID', $product + ' ID', $product + $number)
    $aliases.name = @($product + $name, $product + (Join-Chars @(0x540D)))
    $aliases.main = @($main + $product + $image, $product + $main + (Join-Chars @(0x5716)))

    for ($i = 1; $i -le 8; $i++) {
        $key = 'image' + $i
        $aliases[$key] = @($product + $image + $i, $product + $image + ' ' + $i)
    }

    return $aliases
}

function Import-ShopeeExcelV2([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Excel file not found.'
    }
    if ([IO.Path]::GetExtension($Path) -ne '.xlsx') {
        throw 'Please select an .xlsx Shopee media file.'
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
        $archive = [IO.Compression.ZipFile]::OpenRead($resolvedPath)

        $entries = @{}
        foreach ($entry in $archive.Entries) {
            $entries[$entry.FullName] = $entry
        }

        $sheet = $null
        if ($entries.ContainsKey('xl/worksheets/sheet1.xml')) {
            $sheet = $entries['xl/worksheets/sheet1.xml']
        }
        if ($null -eq $sheet) {
            $sheet = @($archive.Entries | Where-Object { $_.FullName -like 'xl/worksheets/sheet*.xml' }) | Select-Object -First 1
        }
        if ($null -eq $sheet) {
            throw 'No worksheet XML was found in the XLSX file.'
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

        $reader = New-Object IO.StreamReader($sheet.Open())
        try {
            [xml]$sheetXml = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        $rows = New-Object Collections.Generic.List[object]
        foreach ($row in $sheetXml.SelectNodes('//*[local-name()="sheetData"]/*[local-name()="row"]')) {
            $values = @{}
            foreach ($cell in $row.SelectNodes('./*[local-name()="c"]')) {
                $parsed = Get-XlsxCellValue $cell $sharedStrings
                if ($parsed.Column -ge 0) {
                    $values[[int]$parsed.Column] = [string]$parsed.Value
                }
            }
            [void]$rows.Add($values)
        }

        if ($rows.Count -lt 2) {
            throw 'The XLSX file does not contain enough readable rows.'
        }

        $aliases = Get-ShopeeHeaderAliases
        $headerRowIndex = -1
        $header = $null
        $scanLimit = [Math]::Min($rows.Count, 30)

        for ($scanIndex = 0; $scanIndex -lt $scanLimit; $scanIndex++) {
            $candidate = $rows[$scanIndex]
            $foundId = $false
            $foundName = $false
            $foundMain = $false

            foreach ($candidateColumn in $candidate.Keys) {
                $candidateText = ([string]$candidate[$candidateColumn]).Trim()
                if ($aliases.id -contains $candidateText) { $foundId = $true }
                if ($aliases.name -contains $candidateText) { $foundName = $true }
                if ($aliases.main -contains $candidateText) { $foundMain = $true }
            }

            if ($foundId -and $foundName -and $foundMain) {
                $headerRowIndex = $scanIndex
                $header = $candidate
                break
            }
        }

        if ($headerRowIndex -lt 0 -or $null -eq $header) {
            throw 'Required Shopee columns were not found in the first 30 rows.'
        }

        $columns = @{}
        foreach ($key in $aliases.Keys) {
            foreach ($column in $header.Keys) {
                $headerText = ([string]$header[$column]).Trim()
                if ($aliases[$key] -contains $headerText) {
                    $columns[$key] = [int]$column
                    break
                }
            }
        }

        if (-not $columns.ContainsKey('id') -or -not $columns.ContainsKey('name') -or -not $columns.ContainsKey('main')) {
            throw 'Shopee header row was found, but required column mapping failed.'
        }

        $products = New-Object Collections.Generic.List[object]
        for ($rowIndex = $headerRowIndex + 1; $rowIndex -lt $rows.Count; $rowIndex++) {
            $data = $rows[$rowIndex]

            $productId = ''
            if ($data.ContainsKey($columns.id)) {
                $productId = ([string]$data[$columns.id]).Trim()
            }
            if ($productId -notmatch '^\d{5,30}$') {
                continue
            }

            $productName = ''
            if ($data.ContainsKey($columns.name)) {
                $productName = ([string]$data[$columns.name]).Trim()
            }

            $urls = New-Object Collections.Generic.List[string]
            foreach ($key in @('main', 'image1', 'image2', 'image3', 'image4', 'image5', 'image6', 'image7', 'image8')) {
                if ($columns.ContainsKey($key) -and $data.ContainsKey($columns[$key])) {
                    $url = ([string]$data[$columns[$key]]).Trim()
                    if ($url -match '^https?://') {
                        [void]$urls.Add($url)
                    }
                }
            }

            if ($urls.Count -eq 0) {
                continue
            }

            [void]$products.Add([pscustomobject]@{
                product_id   = $productId
                product_name = $productName
                image_urls   = @($urls)
            })
        }

        if ($products.Count -eq 0) {
            throw 'Shopee headers were found, but no valid product rows with image URLs were read.'
        }

        return @($products)
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
        imported_at  = (Get-Date).ToString('o')
        products     = $products
    }

    $catalog | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $workspace 'catalog.json') -Encoding UTF8
    return @($products)
}
