$ErrorActionPreference = 'Stop'

function Get-SelectionWorkspaceV2 {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'workspace'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-CatalogV2 {
    $path = Join-Path (Get-SelectionWorkspaceV2) 'catalog.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw '尚未匯入蝦皮 Excel，請先選主選單 3。'
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function New-SelectedProductSnapshotV2($Source) {
    if ($null -eq $Source) { throw '商品資料為空，無法建立選擇快照。' }

    # Preserve every catalog field so downstream factual/variant guards receive the same
    # structured product that was imported from Shopee. This is intentionally generic:
    # future catalog fields survive selection without needing product-specific patches.
    $values = [ordered]@{}
    foreach ($property in @($Source.PSObject.Properties)) {
        $values[[string]$property.Name] = $property.Value
    }

    $values['product_id'] = [string]$Source.product_id
    $values['product_name'] = [string]$Source.product_name
    $values['image_urls'] = [string[]]@($Source.image_urls | ForEach-Object { [string]$_ })
    $values['selected_at'] = (Get-Date).ToString('o')
    return [pscustomobject]$values
}

function Select-ShopeeProductV2([string]$ProductId) {
    if ([string]::IsNullOrWhiteSpace($ProductId) -or $ProductId -notmatch '^\d{5,30}$') {
        throw '商品ID格式錯誤。'
    }

    $catalog = Get-CatalogV2
    $matches = @($catalog.products | Where-Object { [string]$_.product_id -eq $ProductId })
    if ($matches.Count -ne 1) {
        throw '找不到該商品，或 Excel 中有重複商品ID。'
    }

    $selection = New-SelectedProductSnapshotV2 $matches[0]
    $path = Join-Path (Get-SelectionWorkspaceV2) 'selected_product.json'
    $selection | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding UTF8
    return $selection
}

function Get-SelectedProductV2 {
    $path = Join-Path (Get-SelectionWorkspaceV2) 'selected_product.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw '尚未選擇商品，請先選主選單 4。'
    }

    $product = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $productId = [string]$product.product_id
    if ($productId -notmatch '^\d{5,30}$') {
        throw '已選商品ID格式錯誤，請重新選擇商品。'
    }
    return $product
}
