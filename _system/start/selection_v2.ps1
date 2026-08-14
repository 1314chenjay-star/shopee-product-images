$ErrorActionPreference = 'Stop'

function Get-SelectionWorkspaceV2 {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'workspace'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-Catalog {
    $path = Join-Path (Get-SelectionWorkspaceV2) 'catalog.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw '尚未匯入蝦皮 Excel，請先選主選單 3。'
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Select-ShopeeProduct([string]$ProductId) {
    if ([string]::IsNullOrWhiteSpace($ProductId) -or $ProductId -notmatch '^\d{5,30}$') {
        throw '商品ID格式錯誤。'
    }

    $catalog = Get-Catalog
    $matches = @($catalog.products | Where-Object { [string]$_.product_id -eq $ProductId })
    if ($matches.Count -ne 1) {
        throw '找不到該商品，或 Excel 中有重複商品ID。'
    }

    $selection = [ordered]@{
        product_id = [string]$matches[0].product_id
        product_name = [string]$matches[0].product_name
        image_urls = @($matches[0].image_urls | ForEach-Object { [string]$_ })
        selected_at = (Get-Date).ToString('o')
    }

    $path = Join-Path (Get-SelectionWorkspaceV2) 'selected_product.json'
    $selection | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return [pscustomobject]$selection
}

function Get-SelectedProduct {
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
