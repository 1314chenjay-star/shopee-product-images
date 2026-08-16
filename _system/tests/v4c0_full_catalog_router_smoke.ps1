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

# Ambiguity regressions discovered only after the complete 375-product pass.
# In Taiwan copy, billiards listings may contain "桌球桿"; Billiards category + cue nouns must beat table-tennis keyword matching.
Assert-Route '57365605625' '中式美式撞球杆 10.5mm公桿通杆 黑八桌球一體桿 球廳專用小頭桿' 'Sports & Outdoors/Billiards' 'sports' 'billiards' | Out-Null
Assert-Route '56115605586' '撞球桿 小頭中頭大頭 斯諾克黑八專用 手工製作桌球桿 10mm 11.5mm' 'Sports & Outdoors/Billiards' 'sports' 'billiards' | Out-Null
Assert-Route '52365599928' '撞球桿 開球衝桿 胡跳木衝跳一體桿 短小跳球專用杆 桌球配件' 'Sports & Outdoors/Billiards' 'sports' 'billiards' | Out-Null
Assert-Route '50565615202' '碳素中式黑八球杆 10.2MM小頭一體通桿 碳纖維斯諾克桌球杆' 'Sports & Outdoors/Billiards' 'sports' 'billiards' | Out-Null

# Incidental accessory/protection words must not override the primary product body.
Assert-Route '47465669144' '全碳素壁球拍 超輕一體壁球拍 成人專業訓練壁球拍 送壁球手膠護腕' 'Sports & Outdoors/Squash' 'sports' 'racket_sports' | Out-Null
Assert-Route '58065693152' '泰拳踢靶 小腿訓練靶 低掃腿靶 散打格鬥訓練護具 成人搏擊陪練用品' 'Sports & Outdoors/Boxing/Punching Bags & Paddings' 'sports' 'combat_martial_arts' | Out-Null
Assert-Route '50565689852' '跆拳道腳靶 成人踢腿訓練靶 散打泰拳格鬥練習靶 加厚防撞護具' 'Sports & Outdoors/Boxing/Punching Bags & Paddings' 'sports' 'combat_martial_arts' | Out-Null
Assert-Route '49215708682' '拳擊手靶 反應速度訓練靶 跆拳道踢靶 泰拳散打陪練靶 MMA格鬥訓練器材 成人運動護具' 'Sports & Outdoors/Boxing/Punching Bags & Paddings' 'sports' 'combat_martial_arts' | Out-Null
Assert-Route '41233382286' '專業棒球手套 加厚軟式手套 成人專用 十字檔工字檔 T網球擋' 'Sports & Outdoors/Baseball & Softball' 'sports' 'ball_sports' | Out-Null

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
