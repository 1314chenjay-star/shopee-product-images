# TinySnow V4-C0
# Sports-first universal category router.
# Product body wins over incidental accessory/context words.
# Generic words like "戶外" alone never imply sports/camping.

function Test-V4CAnyKeyword([string]$Text, [string[]]$Keywords) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($keyword in $Keywords) {
        if (-not [string]::IsNullOrWhiteSpace($keyword) -and $Text.IndexOf($keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function New-V4CRoute([string]$Family, [string]$Subfamily, [double]$Confidence, [string[]]$RiskFields, [string]$Priority = 'standard') {
    return [pscustomobject]@{
        family = $Family
        subfamily = $Subfamily
        confidence = [Math]::Round($Confidence,2)
        priority = $Priority
        risk_fields = [string[]]$RiskFields
        policy = if ($Priority -eq 'sports_deep') { 'sports_deep_rules' } else { 'universal_safe_fallback' }
    }
}

function Get-V4CTitleHead([string]$Title, [int]$Length = 24) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return '' }
    $clean = $Title.Trim()
    return $clean.Substring(0, [Math]::Min($Length, $clean.Length))
}

function Test-V4CPrimaryBagProduct([string]$Title) {
    $clean = if ($null -eq $Title) { '' } else { $Title.Trim() }
    $head = Get-V4CTitleHead $clean 24
    # 「桌球拍套裝」是 racket set，不是 racket cover。
    $head = $head.Replace('拍套裝','')
    if ($clean.StartsWith('桌球拍套 ') -or $clean.StartsWith('乒乓球拍套 ') -or $clean.StartsWith('球拍套 ') -or $clean.StartsWith('拍套 ')) { return $true }
    return Test-V4CAnyKeyword $head @(
        '包包','背包','後背包','后背包','雙肩包','双肩包','腰包','手提包','旅行袋',
        '球拍包','球拍袋','收納包','收纳包','收納袋','收纳袋','收納小包','收纳小包',
        '防水袋','運動包','运动包','裝備包','装备包','桌球包','羽球包','網球包','网球包',
        '游泳包','斜挎包','斜背包'
    )
}

function Test-V4CPrimaryProtectiveProduct([string]$Title) {
    $head = Get-V4CTitleHead $Title 20
    return Test-V4CAnyKeyword $head @(
        '護膝','护膝','護腕','护腕','護肘','护肘','護踝','护踝','護齒','护齿','牙套',
        '頭盔','头盔','拳擊手套','拳击手套','拳套','格鬥手套','格斗手套','搏擊手套','搏击手套',
        '纏手帶','缠手带','綁手帶','绑手带','護指','护指','護指套','护指套','運動肌貼','运动肌贴','肌內效貼','肌内效贴'
    )
}

function Get-V4CCategoryRoute($Product, $Evidence) {
    $title = [string](Get-V4CProperty $Evidence 'title' (Get-V4CProperty $Product 'name' ''))
    $category = [string](Get-V4CProperty $Evidence 'raw_category' (Get-V4CProperty $Product 'category' ''))
    $text = ($title + ' ' + $category)
    $sportContext = Test-V4CAnyKeyword $text @(
        '運動','运动','Sports','籃球','篮球','排球','足球','棒球','壘球','垒球','羽球','羽毛球','網球','网球','桌球','乒乓','匹克球','壁球',
        '跑步','健身','瑜伽','露營','露营','登山','游泳','自行車','自行车','騎行','骑行',
        '撞球','台球','斯諾克','斯诺克','拳擊','拳击','泰拳','散打','MMA','格鬥','格斗','跆拳道','武術','武术','太極','太极',
        '衝浪','冲浪','SUP','槳板','桨板','皮划艇','划槳','划桨','釣魚','钓鱼','路亞','路亚','海釣','海钓','磯釣','矶钓',
        '高爾夫','高尔夫','Golf','求生','野外生存','圓網','圆网'
    )
    $explicitCamping = Test-V4CAnyKeyword $title @('露營','露营','帳篷','帐篷','睡袋','野營','野营','天幕','露營燈','露营灯')

    # High-risk product-body routes.
    if (Test-V4CAnyKeyword $title @('救生衣','救生背心','浮力背心','助浮衣','救生馬甲','救生马甲','浮力衣')) {
        return New-V4CRoute 'sports' 'water_safety_gear' 0.98 @('size','buoyancy_rating','certification','material','closure','load_or_weight_range','safety_claims') 'sports_deep'
    }
    if (Test-V4CPrimaryProtectiveProduct $title) {
        return New-V4CRoute 'sports' 'protective_gear' 0.97 @('size','material','support_level','protection_claims','medical_claims','certification') 'sports_deep'
    }

    # Structural routes outrank sport context.
    if (Test-V4CAnyKeyword $title @('短褲','短裤','長褲','长裤','太極褲','太极裤','武術褲','武术裤','練功褲','练功裤','上衣','外套','背心','T恤','t恤','裙','泳衣','衣服','運動服','运动服','球衣','褲子','裤子','襪子','袜子','太極服','太极服','武術服','武术服','練功服','练功服','南拳服','拳擊短褲','拳击短裤')) {
        $sub = if ($sportContext) { 'sports_apparel' } else { 'apparel' }
        $priority = if ($sportContext) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'apparel' $sub 0.95 @('pockets','zipper','lining','fit','sleeve','hem','print','size','material','color_variant') $priority
    }
    if (Test-V4CAnyKeyword $title @('球鞋','跑鞋','運動鞋','运动鞋','登山鞋','太極鞋','太极鞋','武術鞋','武术鞋','拳擊鞋','拳击鞋','拖鞋','涼鞋','凉鞋','靴子','鞋子')) {
        $sub = if ($sportContext) { 'sports_footwear' } else { 'footwear' }
        $priority = if ($sportContext) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'shoes' $sub 0.94 @('size','material','sole','closure','compatibility','waterproof_claims') $priority
    }
    if (Test-V4CPrimaryBagProduct $title) {
        $sub = if ($sportContext) { 'sports_bag' } else { 'bags' }
        $priority = if ($sportContext) { 'sports_deep' } else { 'standard' }
        return New-V4CRoute 'bags' $sub 0.95 @('capacity','dimensions','material','pockets','compartments','zipper','strap','load_rating','waterproof_claims') $priority
    }

    # Explicit mixed-catalog non-sports bodies must override a historically wrong Shopee sports category.
    if (Test-V4CAnyKeyword $title @('澆花','浇花','滴灌','灌溉','澆水器','浇水器')) {
        return New-V4CRoute 'home_garden' 'irrigation' 0.95 @('power','battery','timer','flow_rate','capacity','dimensions','material','accessories','bundle_count','waterproof_rating')
    }
    if (Test-V4CAnyKeyword $title @('驅鳥','驱鸟','驅獸','驱兽','防獸','防兽','滅蚊燈','灭蚊灯','捕蟲燈','捕虫灯')) {
        return New-V4CRoute 'home_garden' 'garden_protection' 0.93 @('power','battery','sensor_claims','sound_claims','light_claims','range_claims','waterproof_rating','certification','accessories')
    }
    if (-not $explicitCamping -and (Test-V4CAnyKeyword $title @('庭院燈','庭院灯','花園燈','花园灯','草坪燈','草坪灯','地埋燈','地埋灯','路燈','路灯','洗牆燈','洗墙灯','景觀燈','景观灯','風鈴燈','风铃灯','太陽能燈','太阳能灯','壁燈','壁灯'))) {
        return New-V4CRoute 'home_garden' 'lighting' 0.95 @('power','battery','brightness','color_temperature','sensor_claims','waterproof_rating','ip_rating','dimensions','material','installation','bundle_count')
    }
    if (Test-V4CAnyKeyword $title @('汽車','汽车','機車','机车','車用','车用','車載','车载','雨刷','方向盤','方向盘')) {
        return New-V4CRoute 'auto' 'auto_accessory' 0.89 @('vehicle_compatibility','mounting','dimensions','material','power','certification')
    }

    # Trusted sports leaves are used only to disambiguate sports-vs-sports wording.
    # Product-body routes above still win, and historically wrong Camping/Others leaves are not trusted here.
    if ($category -match '(?i)/Billiards(?:$|/)') {
        return New-V4CRoute 'sports' 'billiards' 0.98 @('cue_type','tip_size','length','material','weight','accessories','bundle_count','surface_text') 'sports_deep'
    }
    if ($category -match '(?i)/(Baseball & Softball|Basket Balls|Volley Balls|Volley Nets|Rugby)(?:$|/)') {
        return New-V4CRoute 'sports' 'ball_sports' 0.97 @('size','material','ball_type','surface_pattern','bundle_count','accessories','certification') 'sports_deep'
    }
    if ($category -match '(?i)/(Table Tennis Bats|Table Tennis Balls|Table Tennis Nets|Tennis Rackets|Tennis Balls|Tennis Nets|Squash|Badminton Nets)(?:$|/)') {
        return New-V4CRoute 'sports' 'racket_sports' 0.97 @('racket_type','material','weight','grip','string','size','bundle_count','accessories') 'sports_deep'
    }
    if ($category -match '(?i)/(Yoga Blocks, Rings & Foam Rollers|Yoga Mats|Resistance Bands|Pull Up & Push Up Bars|Gears &Training Equipment|Stopwatches & Pedometers)(?:$|/)') {
        return New-V4CRoute 'sports' 'fitness_training' 0.96 @('weight','resistance','load_rating','material','dimensions','bundle_count','accessories','usage_claims') 'sports_deep'
    }
    if ($category -match '(?i)/(Punching Bags & Paddings)(?:$|/)') {
        return New-V4CRoute 'sports' 'combat_martial_arts' 0.97 @('size','material','weight','protection_claims','training_use','accessories','bundle_count','safety_claims') 'sports_deep'
    }
    if ($category -match '(?i)/(Mouthguards & Sport Tapes|Gym Protective Gears)(?:$|/)') {
        return New-V4CRoute 'sports' 'protective_gear' 0.97 @('size','material','support_level','protection_claims','medical_claims','certification') 'sports_deep'
    }
    if ($category -match '(?i)/(Gloves, Wraps & Helmets)(?:$|/)') {
        if (Test-V4CPrimaryProtectiveProduct $title) {
            return New-V4CRoute 'sports' 'protective_gear' 0.97 @('size','material','support_level','protection_claims','medical_claims','certification') 'sports_deep'
        }
        return New-V4CRoute 'sports' 'combat_martial_arts' 0.95 @('size','material','weight','protection_claims','training_use','accessories','bundle_count','safety_claims') 'sports_deep'
    }
    if ($category -match '(?i)/(Tents & Tent Accessories)(?:$|/)') {
        return New-V4CRoute 'sports' 'outdoor_camping' 0.97 @('dimensions','material','waterproof_rating','load_rating','capacity','battery','power','accessories','bundle_count') 'sports_deep'
    }

    # Explicit sports equipment routes. Specific ambiguous sports come before broad racket/ball words.
    if (Test-V4CAnyKeyword $text @('撞球','台球','斯諾克','斯诺克','黑八','球桿','球杆','巧克粉','巧粉','皮頭','皮头','架桿','架杆')) {
        return New-V4CRoute 'sports' 'billiards' 0.97 @('cue_type','tip_size','length','material','weight','accessories','bundle_count','surface_text') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('拳擊','拳击','泰拳','散打','MMA','格鬥','格斗','搏擊','搏击','跆拳道','武術','武术','太極','太极','三節棍','三节棍','手靶','腳靶','脚靶')) {
        return New-V4CRoute 'sports' 'combat_martial_arts' 0.96 @('size','material','weight','protection_claims','training_use','accessories','bundle_count','safety_claims') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('衝浪','冲浪','SUP','槳板','桨板','皮划艇','划槳','划桨','充氣船','充气船','橡皮艇','腳繩','脚绳','船槳','船桨')) {
        return New-V4CRoute 'sports' 'water_sports' 0.95 @('dimensions','material','load_rating','buoyancy_claims','compatibility','accessories','bundle_count','safety_claims') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('釣魚','钓鱼','路亞','路亚','海釣','海钓','磯釣','矶钓','垂釣','垂钓')) {
        return New-V4CRoute 'sports' 'fishing' 0.94 @('size','material','waterproof_claims','protection_claims','accessories','bundle_count') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('求生','生存裝備','生存装备','野外生存','傘繩','伞绳','打火石')) {
        return New-V4CRoute 'sports' 'outdoor_survival' 0.94 @('material','dimensions','tool_count','safety_claims','accessories','bundle_count') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('圓網','圆网','沙灘球遊戲','沙滩球游戏','roundnet','Spikeball')) {
        return New-V4CRoute 'sports' 'outdoor_games' 0.95 @('dimensions','material','bundle_contents','ball_count','accessories','age_claims') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('高爾夫','高尔夫','Golf','golf')) {
        return New-V4CRoute 'sports' 'golf' 0.95 @('club_or_training_type','dimensions','material','weight','compatibility','bundle_count','accessories') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('羽球','羽毛球','網球','网球','桌球','乒乓','匹克球','壁球','球拍')) {
        return New-V4CRoute 'sports' 'racket_sports' 0.95 @('racket_type','material','weight','grip','string','size','bundle_count','accessories') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('籃球','篮球','排球','足球','棒球','壘球','垒球','橄欖球','橄榄球','球類','球类')) {
        return New-V4CRoute 'sports' 'ball_sports' 0.96 @('size','material','ball_type','surface_pattern','bundle_count','accessories','certification') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('啞鈴','哑铃','壺鈴','壶铃','彈力帶','弹力带','瑜伽','健身','訓練器','训练器','拉力器','跳繩','跳绳','槓鈴','杠铃')) {
        return New-V4CRoute 'sports' 'fitness_training' 0.94 @('weight','resistance','load_rating','material','dimensions','bundle_count','accessories','usage_claims') 'sports_deep'
    }
    if ($explicitCamping -or (Test-V4CAnyKeyword $text @('登山','野餐墊','野餐垫','營釘','营钉'))) {
        return New-V4CRoute 'sports' 'outdoor_camping' 0.94 @('dimensions','material','waterproof_rating','load_rating','capacity','battery','power','accessories','bundle_count') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('泳鏡','泳镜','泳帽','游泳','浮板','蛙鞋','潛水','潜水')) {
        return New-V4CRoute 'sports' 'swimming' 0.93 @('size','material','waterproof_claims','lens_claims','certification','accessories') 'sports_deep'
    }
    if (Test-V4CAnyKeyword $text @('自行車','自行车','單車','单车','騎行','骑行','碼表','码表','自行車燈','自行车灯')) {
        return New-V4CRoute 'sports' 'cycling' 0.92 @('compatibility','mounting','dimensions','material','battery','power','waterproof_rating') 'sports_deep'
    }

    # Remaining universal safe fallback routes.
    if (Test-V4CAnyKeyword $title @('庭院擺飾','庭院摆饰','花園擺飾','花园摆饰','園藝','园艺')) {
        return New-V4CRoute 'home_garden' 'garden_decor' 0.88 @('dimensions','material','power','battery','waterproof_rating','bundle_count','accessories')
    }
    if (Test-V4CAnyKeyword $text @('充電','充电','充電器','充电器','充電線','充电线','耳機','耳机','藍牙','蓝牙','USB','Type-C','電源','电源','行動電源','移动电源')) {
        return New-V4CRoute 'electronics' 'electronics_accessory' 0.92 @('connector','voltage','power','capacity','compatibility','certification','battery','protocol')
    }
    if (Test-V4CAnyKeyword $text @('收納','收纳','置物','衣架','掛架','挂架','整理盒','收納盒','收纳盒')) {
        return New-V4CRoute 'home_storage' 'storage' 0.91 @('dimensions','material','layers','capacity','load_rating','installation','bundle_count')
    }
    if (Test-V4CAnyKeyword $text @('鍋','锅','杯','餐具','砧板','刀具','廚房','厨房','保鮮','保鲜')) {
        return New-V4CRoute 'kitchen' 'kitchenware' 0.89 @('material','capacity','dimensions','heat_rating','food_contact_claims','bundle_count')
    }
    if (Test-V4CAnyKeyword $text @('桌','椅','櫃','柜','家具','層架','层架','床','沙發','沙发')) {
        return New-V4CRoute 'furniture' 'furniture' 0.89 @('dimensions','material','load_rating','layers','installation','structure')
    }
    if (Test-V4CAnyKeyword $text @('寵物','宠物','貓','猫','狗','牽引','牵引','項圈','项圈','貓砂','猫砂')) {
        return New-V4CRoute 'pet' 'pet_supplies' 0.90 @('pet_type','size','material','capacity','safety_claims','medical_claims')
    }
    if (Test-V4CAnyKeyword $text @('扳手','螺絲','螺丝','鉗','钳','工具','鑽頭','钻头','套筒','五金')) {
        return New-V4CRoute 'tools' 'tools' 0.90 @('dimensions','material','interface','compatibility','load_rating','bundle_contents')
    }
    if (Test-V4CAnyKeyword $text @('玩具','積木','积木','拼圖','拼图','公仔','模型')) {
        return New-V4CRoute 'toys' 'toys' 0.87 @('piece_count','dimensions','material','age_claims','accessories','certification')
    }
    if (Test-V4CAnyKeyword $text @('美容','美妝','美妆','護膚','护肤','洗面','面膜','乳液','香水','個人護理','个人护理')) {
        return New-V4CRoute 'beauty' 'beauty_personal_care' 0.88 @('ingredients','capacity','medical_claims','efficacy_claims','certification','usage_claims')
    }
    if (Test-V4CAnyKeyword $text @('項鍊','项链','戒指','耳環','耳环','手鍊','手链','飾品','饰品')) {
        return New-V4CRoute 'jewelry' 'jewelry' 0.88 @('material','dimensions','plating','gem_claims','size','color_variant')
    }

    return New-V4CRoute 'generic' 'unknown' 0.35 @('dimensions','material','features','accessories','bundle_count','brand','certification')
}
