$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_product_evidence.ps1')
. (Join-Path $root 'start\v4c_category_router.ps1')
. (Join-Path $root 'start\v4c_excel_adapter.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "V4-C0 Excel adapter smoke failed: $Message" }
}

function New-Row([object[]]$Values) {
    $row = @{}
    for ($i = 0; $i -lt $Values.Count; $i++) {
        if ($null -ne $Values[$i]) { $row[$i] = [string]$Values[$i] }
    }
    return $row
}

# Header is intentionally not row 1. V4-C0 must scan the first 30 rows.
$rows = @()
$rows += ,(New-Row @('media_info','meta','ignore'))
$rows += ,(New-Row @('說明','這不是標題列'))
$rows += ,(New-Row @('1','1','1','1','1'))
$rows += ,(New-Row @('請注意','請輸入圖片URL'))
$rows += ,(New-Row @('更多說明'))
$rows += ,(New-Row @('仍然不是標題'))
$rows += ,(New-Row @('商品ID','主商品貨號','商品名稱','商品分類','主商品圖片','商品圖片 1','商品圖片 2','新版尺寸表','圖片尺寸表','規格名稱 1','選項 1 的名稱','選項 1 的圖片','選項 2 的名稱','選項 2 的圖片','選項 3 的名稱','選項 3 的圖片'))
$rows += ,(New-Row @(
    '42833435408','SKU-428','籃球短褲 男款寬鬆五分褲 假兩件設計','101853 - Sports & Outdoors/Basketball/Others',
    'https://example.com/428-main.jpg','https://example.com/428-1.jpg','https://example.com/428-2.jpg','','','顏色分類',
    '黑色-2件裝','https://example.com/black.jpg','白色-3件裝','https://example.com/white.jpg','粉色-2件裝','https://example.com/pink.jpg'
))

$header = Find-V4CShopeeHeaderMap $rows 30
Assert-True ($header.header_row_index -eq 6) '必須找到第 7 列的真實標題列。'
Assert-True ($header.columns.product_id -eq 0) '商品 ID 欄位映射錯誤。'
Assert-True ($header.columns.product_name -eq 2) '商品名稱欄位映射錯誤。'
Assert-True ($header.columns.category -eq 3) '商品分類欄位映射錯誤。'
Assert-True (@($header.columns.image_columns).Count -eq 3) '應辨識主圖加兩張商品圖。'
Assert-True (@($header.columns.option_name_columns).Count -eq 3) '應辨識三個規格選項名稱欄。'

$products = @(Convert-V4CShopeeRowsToProducts $rows $header)
Assert-True ($products.Count -eq 1) '應轉出一件商品。'
$p = $products[0]
Assert-True ($p.product_id -eq '42833435408') '11 位商品 ID 必須保持字串完整。'
Assert-True ($p.category -like '*Basketball*') '商品分類必須保留。'
Assert-True ($p.image_urls.Count -eq 3) '商品圖片 URL 必須保留。'
Assert-True ($p.variation_options.Count -eq 3) '規格選項必須保留。'
Assert-True ($p.source_provenance.option_text_is_not_common_fact -eq $true) '規格文字不得自動升格為共同事實。'
Assert-True ($p.multi_variant_flags.has_multiple_colors -eq $true) '不同顏色選項應被標成變體風險。'
Assert-True ($p.multi_variant_flags.has_multiple_quantities -eq $true) '2 件 / 3 件規格差異應被標成數量衝突。'

$evidence = New-V4CProductEvidence $p $null
$route = Get-V4CCategoryRoute $p $evidence
Assert-True ($route.family -eq 'apparel') '籃球短褲從真實 Excel 物件進路由後仍必須是 apparel。'
Assert-True ($route.subfamily -eq 'sports_apparel') '籃球短褲應保留 sports_apparel 場景。'
Assert-True ($evidence.verified_fact_count -eq 0) '原始規格文字不得自動變成 verified facts。'
Assert-True ($evidence.variant_risk.high_conflict -eq $true) '數量差異必須形成高規格衝突。'

Write-Host 'V4-C0 Shopee Excel adapter smoke: PASS'
