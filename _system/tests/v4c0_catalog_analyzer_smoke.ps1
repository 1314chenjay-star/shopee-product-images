$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_catalog_analyzer.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "V4-C0 catalog analyzer smoke failed: $Message" }
}

$products = @(
    [pscustomobject]@{
        product_id='P1'; name='籃球 7號訓練球'; category='Sports & Outdoors/Basket Balls';
        image_urls=@('https://example.test/p1-1.jpg','https://example.test/p1-2.jpg','https://example.test/p1-3.jpg','https://example.test/p1-4.jpg','https://example.test/p1-5.jpg');
        variation_options=@('7號'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='P2'; name='中式撞球杆 黑八桌球一體桿'; category='Sports & Outdoors/Billiards';
        image_urls=@('https://example.test/p2-1.jpg','https://example.test/p2-2.jpg','https://example.test/p2-3.jpg','https://example.test/p2-4.jpg');
        variation_options=@('10mm','11.5mm'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='P3'; name='太陽能戶外庭院燈 花園草坪燈'; category='Sports & Outdoors/Camping & Hiking/Others';
        image_urls=@('https://example.test/p3-1.jpg','https://example.test/p3-2.jpg','https://example.test/p3-3.jpg','https://example.test/p3-4.jpg');
        variation_options=@('暖光'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='P4'; name='成人救生衣 大浮力背心'; category='Sports & Outdoors/Boating';
        image_urls=@('https://example.test/p4-1.jpg','https://example.test/p4-2.jpg','https://example.test/p4-3.jpg','https://example.test/p4-4.jpg');
        variation_options=@('S','M','L','XL','2XL','3XL','4XL','5XL','紅色','藍色','黑色','黃色','橘色','綠色','成人款','兒童款','A','B','C','D');
        multi_variant_flags=[pscustomobject]@{ has_multiple_colors=$true; has_multiple_sizes=$true; has_multiple_materials=$false; has_multiple_quantities=$false; has_multiple_bundle_counts=$false; has_multiple_patterns=$false; option_count=20 };
        verified_facts=[pscustomobject]@{}
    }
)

$r = Invoke-V4C0CatalogAnalysis $products
Assert-True ($r.product_count -eq 4) 'must analyze all products.'
Assert-True ($r.image_api_called -eq $false) 'must remain free-analysis only.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P2' }).route.subfamily -eq 'billiards') 'billiards ambiguity must resolve.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P3' }).route.family -eq 'home_garden') 'wrong historical camping category must not override garden product body.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P4' }).review_gate.risk_tier -eq 'HIGH') 'high-risk life-safety multi-variant item must be priority review.'
Assert-True (@($r.products | Where-Object { $_.final_paid_generation_permission -ne 'HOLD' }).Count -eq 0) 'catalog analyzer may not auto-approve paid generation.'

Write-Host 'V4-C0 catalog analyzer smoke: PASS'
