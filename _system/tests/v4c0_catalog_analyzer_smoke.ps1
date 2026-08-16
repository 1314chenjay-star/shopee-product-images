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
    [pscustomobject]@{ product_id='P1'; name='籃球 7號訓練球'; category='Sports & Outdoors/Basket Balls'; image_urls=(New-Urls 'p1' 5); variation_options=@('7號'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='P2'; name='中式撞球杆 黑八桌球一體桿'; category='Sports & Outdoors/Billiards'; image_urls=(New-Urls 'p2' 4); variation_options=@('10mm','11.5mm'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='P3'; name='太陽能戶外庭院燈 花園草坪燈'; category='Sports & Outdoors/Camping & Hiking/Others'; image_urls=(New-Urls 'p3' 4); variation_options=@('暖光'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{
        product_id='P4'; name='成人救生衣 大浮力背心'; category='Sports & Outdoors/Boating'; image_urls=(New-Urls 'p4' 4);
        variation_options=@('S','M','L','XL','2XL','3XL','4XL','5XL','紅色','藍色','黑色','黃色','橘色','綠色','成人款','兒童款','A','B','C','D');
        multi_variant_flags=[pscustomobject]@{ has_multiple_colors=$true; has_multiple_sizes=$true; has_multiple_materials=$false; has_multiple_quantities=$false; has_multiple_bundle_counts=$false; has_multiple_patterns=$false; option_count=20 }; verified_facts=[pscustomobject]@{}
    },
    [pscustomobject]@{ product_id='49265607225'; name='健身瑜伽無痕內褲 女士冰絲三角褲 運動塑型打底'; category='Sports & Outdoors/Yoga & Pilates/Others'; image_urls=(New-Urls 'p5' 4); variation_options=@('M','L','XL'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='56215585979'; name='全棉五指瑜伽襪 專業防滑運動襪 普拉提襪'; category='Sports & Outdoors/Yoga & Pilates/Others'; image_urls=(New-Urls 'p6' 4); variation_options=@('黑','白','灰'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='26795530384'; name='桌球拍保護套 防撞保護夾板 亞克力硬殼防護套 球拍收納保護用品'; category='Sports & Outdoors/Table Tennis/Others'; image_urls=(New-Urls 'p7' 5); variation_options=@('透明'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='52915734524'; name='籃球護腿套 加長運動護腿褲 小腿大腿壓縮防護套'; category='Sports & Outdoors/Basketball/Others'; image_urls=(New-Urls 'p8' 5); variation_options=@('M','L'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },

    # Real-catalog negative controls: incidental accessory words must NOT change the primary product route.
    [pscustomobject]@{ product_id='51365698925'; name='桌球拍 七星入門訓練拍 小學生成人初學橫拍直拍套組 室內運動用品'; category='Sports & Outdoors/Table Tennis/Table Tennis Bats'; image_urls=(New-Urls 'p9' 5); variation_options=@(); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='25348397564'; name='網球拍入門套組 成人初學訓練球拍 超輕耐用 附球拍包 單人練習運動用品'; category='Sports & Outdoors/Tennis/Tennis Rackets'; image_urls=(New-Urls 'p10' 5); variation_options=@(); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='54365715350'; name='匹克球拍 Pickleball球拍 入門超輕球拍套組 含4顆球與收納袋'; category='Sports & Outdoors/Tennis/Tennis Rackets'; image_urls=(New-Urls 'p11' 5); variation_options=@(); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='43933411549'; name='泰拳腰靶 格鬥訓練護腰靶 散打陪練靶 拳擊踢擊訓練器 加厚防撞護具'; category='Sports & Outdoors/Boxing & Martial Arts/Punching Bags & Paddings'; image_urls=(New-Urls 'p12' 5); variation_options=@(); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },

    # Real B001 regressions: secondary car-use wording must not override the product body.
    [pscustomobject]@{ product_id='47515735339'; name='運動吸汗毛巾 健身跑步擦汗巾 柔軟加厚多用途毛巾 車用座椅鋪巾'; category='Sports & Outdoors/Sports Accessories/Others'; image_urls=(New-Urls 'p13' 9); variation_options=@('紅','藍','灰'); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='51515651767'; name='戶外折疊水桶 伸縮儲水桶 露營車載水桶 帶龍頭水壺 15L大容量 加厚耐用提手 旅行便攜水桶'; category='Sports & Outdoors/Camping & Hiking/Others'; image_urls=(New-Urls 'p14' 4); variation_options=@(); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} },
    [pscustomobject]@{ product_id='42383385337'; name='太陽能車載淨化器 免插電自動運行 臭氧除味消毒機 無風扇靜音設計 停車自啟淨化空氣 車內除臭除菌裝置'; category='Automobiles/Car Accessories'; image_urls=(New-Urls 'p15' 4); variation_options=@(); multi_variant_flags=[pscustomobject]@{}; verified_facts=[pscustomobject]@{} }
)

$r = Invoke-V4C0CatalogAnalysis $products
Assert-True ($r.product_count -eq 15) 'must analyze all products.'
Assert-True ($r.image_api_called -eq $false) 'must remain free-analysis only.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P2' }).route.subfamily -eq 'billiards') 'billiards ambiguity must resolve.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P3' }).route.family -eq 'home_garden') 'wrong historical camping category must not override garden product body.'
Assert-True (($r.products | Where-Object { $_.product_id -eq 'P4' }).review_gate.risk_tier -eq 'HIGH') 'high-risk life-safety multi-variant item must be priority review.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '49265607225' }).route.subfamily -eq 'sports_apparel') 'yoga underwear must route as apparel, not fitness equipment.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '56215585979' }).route.subfamily -eq 'sports_apparel') 'yoga socks must route as apparel, not fitness equipment.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '26795530384' }).route.family -eq 'bags') 'racket protective cover must route as case/bag product body.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '52915734524' }).route.subfamily -eq 'protective_gear') 'basketball leg sleeve must route as protective gear.'

Assert-True (($r.products | Where-Object { $_.product_id -eq '51365698925' }).route.subfamily -eq 'racket_sports') 'table-tennis racket set must not become a bag.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '25348397564' }).route.subfamily -eq 'racket_sports') 'tennis racket with included bag must stay racket_sports.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '54365715350' }).route.subfamily -eq 'racket_sports') 'pickleball racket set must stay racket_sports.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '43933411549' }).route.subfamily -eq 'combat_martial_arts') 'boxing waist target must not become wearable protective gear.'

Assert-True (($r.products | Where-Object { $_.product_id -eq '47515735339' }).route.subfamily -eq 'sports_towel') 'sports towel must not become auto accessory because of secondary seat-cover use.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '51515651767' }).route.subfamily -eq 'outdoor_camping') 'camping folding water bucket must not become auto accessory because of 車載 wording.'
Assert-True (($r.products | Where-Object { $_.product_id -eq '42383385337' }).route.family -eq 'auto') 'true car purifier must remain auto.'

Assert-True ($r.structural_guard_change_count -ge 6) 'structural guard must actually correct context-word routes.'
Assert-True (@($r.products | Where-Object { $_.final_paid_generation_permission -ne 'HOLD' }).Count -eq 0) 'catalog analyzer may not auto-approve paid generation.'

Write-Host 'V4-C0 catalog analyzer smoke: PASS'
