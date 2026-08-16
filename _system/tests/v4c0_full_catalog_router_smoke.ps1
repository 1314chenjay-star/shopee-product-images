$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_product_evidence.ps1')
. (Join-Path $root 'start\v4c_category_router.ps1')
. (Join-Path $root 'start\v4c_adaptive_five_planner.ps1')

function Assert-Route([string]$Id, [string]$Name, [string]$Category, [string]$Family, [string]$Subfamily) {
    $p = [pscustomobject]@{ product_id=$Id; name=$Name; category=$Category; verified_facts=[pscustomobject]@{} }
    $e = New-V4CProductEvidence $p $null
    $r = Get-V4CCategoryRoute $p $e
    if ($r.family -ne $Family -or $r.subfamily -ne $Subfamily) {
        throw ("V4-C0 full catalog route failed: {0} expected {1}/{2}, got {3}/{4}" -f $Id,$Family,$Subfamily,$r.family,$r.subfamily)
    }
    return [pscustomobject]@{ product=$p; evidence=$e; route=$r }
}

# Incidental bundled covers/bags must not override the actual racket/ball product.
Assert-Route '52565652509' '碳素複合壁球拍 一體成型專業壁球拍 超輕高彈性壁球拍 含拍套手膠' 'Sports & Outdoors/Squash' 'sports' 'racket_sports' | Out-Null
Assert-Route '53515745149' '籃球 7號成人比賽訓練球 室外耐磨籃球 附打氣筒球袋' 'Sports & Outdoors/Basketball' 'sports' 'ball_sports' | Out-Null
Assert-Route '54365715350' '匹克球拍 Pickleball球拍 入門超輕球拍套組 含4顆球與收納袋' 'Sports & Outdoors/Pickleball' 'sports' 'racket_sports' | Out-Null

# A true bag/container as the primary noun must still remain a bag.
Assert-Route '46615669138' '美式棒球裝備包 多功能運動雙肩包 戶外壘球訓練收納包' 'Sports & Outdoors/Baseball' 'bags' 'sports_bag' | Out-Null
Assert-Route '46115672530' '壁球收納小包 壁球專用收納盒 壁球高爾夫通用袋' 'Sports & Outdoors/Squash' 'bags' 'sports_bag' | Out-Null
Assert-Route '54665698453' '桌球拍套 硬殼球拍保護盒 防摔防撞收納包' 'Sports & Outdoors/Table Tennis' 'bags' 'sports_bag' | Out-Null

# Full-catalog gaps found from the real Shopee workbook.
Assert-Route '57665605617' '中式撞球杆 美式黑八球杆 職業專用通杆 10.3mm小頭' 'Sports & Outdoors/Billiards' 'sports' 'billiards' | Out-Null
Assert-Route '56265688661' '弧形拳擊手靶 成人拳擊訓練靶 散打泰拳陪練器材' 'Sports & Outdoors/Boxing' 'sports' 'combat_martial_arts' | Out-Null
Assert-Route '50815605686' 'SUP 衝浪板專用劃槳 充氣船橡皮艇划水槳' 'Sports & Outdoors/Water Sports' 'sports' 'water_sports' | Out-Null
Assert-Route '50915745061' '戶外沙灘球遊戲組 便攜式圓網運動遊戲 成人親子休閒活動' 'Sports & Outdoors/Outdoor Recreation' 'sports' 'outdoor_games' | Out-Null
Assert-Route 'WATER-SAFE' '大浮力磯釣救生衣 海釣釣魚浮力背心 船用作業救生衣' 'Sports & Outdoors/Water Sports' 'sports' 'water_safety_gear' | Out-Null

# Mixed catalog safety: generic outdoor wording still cannot turn home/garden into sports.
Assert-Route '53415651688' '太陽能戶外庭院燈 拐杖造型地埋景觀燈 花園草坪LED裝飾燈' 'Home & Living/Garden' 'home_garden' 'lighting' | Out-Null
Assert-Route '40983371866' '太陽能自動澆花器 免插電滴灌系統 陽台定時澆水器' 'Home & Living/Garden' 'home_garden' 'irrigation' | Out-Null

# Unknown products must remain generic; full-catalog hardening must not become a force-classifier.
Assert-Route 'UNKNOWN' '神秘商品XYZ' 'Misc' 'generic' 'unknown' | Out-Null

# Without structured verified facts, no slot role may advertise itself as verified content.
$racket = Assert-Route 'R-NOFACT' '桌球拍 初學入門訓練拍' 'Sports & Outdoors/Table Tennis' 'sports' 'racket_sports'
$roles = @(Get-V4CSlotRoles $racket.route $racket.evidence)
if (@($roles | Where-Object { $_ -match 'verified_' }).Count -gt 0) {
    throw 'V4-C0 full catalog planner failed: verified slot leaked without verified facts.'
}

Write-Host 'V4-C0 full catalog router regression smoke: PASS'
