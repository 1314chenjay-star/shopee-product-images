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
        $parts = @(
            $Cell.SelectNodes('.//*[local-name()="t"]') |
                ForEach-Object { $_.InnerText }
        )
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

function Import-ShopeeExcelV2([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw '找不到 Excel 檔案。'
    }
    if ([IO.Path]::GetExtension($Path) -ne '.xlsx') {
        throw '請選擇 .xlsx 格式的蝦皮媒體資訊 Excel。'
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
            throw 'Excel 中找不到工作表。'
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
                $parts = @(
                    $item.SelectNodes('.//*[local-name()="t"]') |
                        ForEach-Object { $_.InnerText }
                )
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
            $rows.Add($values)
        }

        if ($rows.Count -lt 2) {
            throw 'Excel 沒有可讀取的資料列。'
        }

        $aliases = @{
            id     = @('商品ID', '商品 ID', '商品編號')
            name   = @('商品名稱', '商品名')
            main   = @('主商品圖片', '商品主圖')
            image1 = @('商品圖片1', '商品圖片 1')
            image2 = @('商品圖片2', '商品圖片 2')
            image3 = @('商品圖片3', '商品圖片 3')
            image4 = @('商品圖片4', '商品圖片 4')
            image5 = @('商品圖片5', '商品圖片 5')
            image6 = @('商品圖片6', '商品圖片 6')
            image7 = @('商品圖片7', '商品圖片 7')
            image8 = @('商品圖片8', '商品圖片 8')
        }

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
            throw '找不到必要欄位：商品ID、商品名稱、主商品圖片。已搜尋前 30 列。'
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
            throw '標題列已找到，但必要欄位映射失敗。'
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
                        $urls.Add($url)
                    }
                }
            }

            if ($urls.Count -eq 0) {
                continue
            }

            $products.Add([pscustomobject]@{
                product_id   = $productId
                product_name = $productName
                image_urls   = @($urls)
            })
        }

        if ($products.Count -eq 0) {
            throw '已找到標題列，但沒有讀到有效商品資料。請確認商品列包含數字商品ID及 http/https 圖片網址。'
        }

        return @($products)
    }
    catch {
        throw "讀取 Excel 失敗（原檔未被修改）：$($_.Exception.Message)"
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
