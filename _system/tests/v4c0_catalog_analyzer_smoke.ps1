$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_catalog_analyzer.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "V4-C0 catalog analyzer smoke failed: $Message" }
}

function New-Urls([string]$Prefix, [int]$Count = 5) {
    $urls = @()
    for ($i=1; $i -le $Count; $i++) { $urls += ('https://example.test/' + $Prefix + '-' + $i + '.jpg') }
    return [string[]]$urls
}

$products = @(
    [pscustomobject]@{
        product_id='P1'; name='籃球 7號訓練球'; category='Sports & Outdoors/Basket Balls';
        image_urls=(New-Urls 'p1' 5); variation_options=@('7號'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='P2'; name='中式撞球杆 黑八桌球一體桿'; category='Sports & Outdoors/Billiards';
        image_urls=(New-Urls 'p2' 4); variation_options=@('10mm','11.5mm'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='P3'; name='太陽能戶外庭院燈 花園草坪燈'; category='Sports & Outdoors/Camping & Hiking/Others';
        image_urls=(New-Urls 'p3' 4); variation_options=@('暖光'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='P4'; name='成人救生衣 大浮力背心'; category='Sports & Outdoors/Boating';
        image_urls=(New-Urls 'p4' 4);
        variation_options=@('S','M','L','XL','2XL','3XL','4XL','5XL','紅色','藍色','黑色','黃色','橘色','綠色','成人款','兒童款','A','B','C','D');
        multi_variant_flags=[pscustomobject]@{ has_multiple_colors=$true; has_multiple_sizes=$true; has_multiple_materials=$false; has_multiple_quantities=$false; has_multiple_bundle_counts=$false; has_multiple_patterns=$false; option_count=20 };
        verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='49265607225'; name='健身瑜伽無痕內褲 女士冰絲三角褲 運動塑型打底'; category='Sports & Outdoors/Yoga & Pilates/Others';
        image_urls=(New-Urls 'p5' 4); variation_options=@('M','L','XL'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='56215585979'; name='全棉五指瑜伽襪 專業防滑運動襪 普拉提襪'; category='Sports & Outdoors/Yoga & Pilates/Others';
        image_urls=(New-Urls 'p6' 4); variation_options=@('黑','白','灰'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='26795530384'; name='桌球拍保護套 防撞保護夾板 亞克力硬殼防護套 球拍收納保護用品'; category='Sports & Outdoors/Table Tennis/Others';
        image_urls=(New-Urls 'p7' 5); variation_options=@('透明'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{
        product_id='52915734524'; name='籃球護腿套 加長運動護腿褲 小腿大腿壓縮防護套'; category='Sports & Outdoors/Basketball/Others';
        image_urls=(New-Urls 'p8' 5); variation_options=@('M','L'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{}
    }
)

$r = Invoke-V4C0CatalogAnalysis $products
Assert-True ($r.product_count -eq 8) 'must analyze all products.'
Assert-True ($r.image_api_called -eq $false) 'must remain free-analysis only.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P2' }).route.subfamily -eq 'billiards') 'billiards ambiguity must resolve.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P3' }).route.family -eq 'home_garden') 'wrong historical camping category must not override garden product body.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P4' }).review_gate.risk_tier -eq 'HIGH') 'high-risk life-safety multi-variant item must be priority review.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '49265607225' }).route.subfamily -eq 'sports_apparel') 'yoga underwear must route as apparel, not fitness equipment.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '56215585979' }).route.subfamily -eq 'sports_apparel') 'yoga socks must route as apparel, not fitness equipment.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '26795530384' }).route.family -eq 'bags') 'racket protective cover must route as case/bag product body.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '52915734524' }).route.subfamily -eq 'protective_gear') 'basketball leg sleeve must route as protective gear.'
Assert-True ($r.structural_guard_change_count -ge 4) 'structural guard must actually correct context-word routes.'
Assert-True (@($r.products | Where-Object { $_.final_paid_generation_permission -ne 'HOLD' }).Count -eq 0) 'catalog analyzer may not auto-approve paid generation.'

Write-Host 'V4-C0 catalog analyzer smoke: PASS'
