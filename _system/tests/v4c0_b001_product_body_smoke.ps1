$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_catalog_analyzer.ps1')

function Assert-Route([string]$Id, [string]$Name, [string]$Category, [string]$Family, [string]$Subfamily) {
    $p = [pscustomobject]@{
        product_id = $Id
        name = $Name
        category = $Category
        image_urls = @('https://example.test/1.jpg','https://example.test/2.jpg')
        variation_options = @()
        multi_variant_flags = [pscustomobject]@{}
        verified_facts = [pscustomobject]@{}
    }
    $r = Invoke-V4C0CatalogAnalysis @($p)
    $actual = @($r.products)[0].route
    if ($actual.family -ne $Family -or $actual.subfamily -ne $Subfamily) {
        throw ("B001 product-body route failed: {0}, expected {1}/{2}, got {3}/{4}" -f $Id,$Family,$Subfamily,$actual.family,$actual.subfamily)
    }
}

# Vehicle wording is a secondary use case; the primary product is a camping water container.
Assert-Route '51515651767' '戶外折疊水桶 伸縮儲水桶 露營車載水桶 帶龍頭水壺 15L大容量 加厚耐用提手 旅行便攜水桶' 'Sports & Outdoors/Camping & Hiking/Others' 'sports' 'outdoor_camping'

# Vehicle-seat use is secondary; the primary product is a sports towel.
Assert-Route '47515735339' '運動吸汗毛巾 健身跑步擦汗巾 柔軟加厚多用途毛巾 車用座椅鋪巾' 'Sports & Outdoors/Badminton/Others' 'sports' 'sports_towel'

# Table-tennis wording is context; the primary product body is a glue roller maintenance tool.
Assert-Route '28195530371' '桌球拍貼膠工具 滾膠棒 壓膠棍 球拍膠皮黏貼工具 加厚款 桌球用品維修保養配件' 'Sports & Outdoors/Table Tennis/Others' 'tools' 'sports_maintenance_tool'

# Table-tennis wording is context; the primary product body is a ball-storage container/bag.
Assert-Route '28845515575' '桌球收納盒 乒乓球桶 多球訓練球罐 大容量桌球整理盒 防摔耐磨 運動訓練用品 球館教練專用' 'Sports & Outdoors/Table Tennis/Others' 'bags' 'sports_bag'

# Basketball is design context; the primary product body is a necklace/jewelry item.
Assert-Route '49865764122' '籃球項鍊 運動風吊墜 籃球迷紀念飾品 男生生日禮物 球類愛好者收藏小禮品' 'Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others' 'jewelry' 'jewelry'

# A kicking target is combat training equipment, not wearable protective gear.
Assert-Route '50565689852' '跆拳道腳靶 成人踢腿訓練靶 散打泰拳格鬥練習靶 加厚防撞護具 拳擊訓練器材 家庭運動用品' 'Sports & Outdoors/Sports & Outdoor Recreation Equipments/Boxing & Martial Arts/Punching Bags & Paddings' 'sports' 'combat_martial_arts'

# Negative control: a product whose actual body is explicitly a vehicle purifier must remain auto.
Assert-Route '42383385337' '太陽能車載淨化器 免插電自動運行 臭氧除味消毒機 車內除臭除菌裝置' 'Sports & Outdoors/Camping & Hiking/Others' 'auto' 'auto_accessory'

Write-Host 'V4-C0 B001 product-body routing smoke: PASS'
