$ErrorActionPreference = 'Stop'

function Get-V2Workspace {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'workspace'
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Get-ImageInfoV2([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $stream = [IO.File]::OpenRead($Path)
    $image = $null
    try {
        $image = [Drawing.Image]::FromStream($stream, $true, $true)
        return [pscustomobject]@{
            width = [int]$image.Width
            height = [int]$image.Height
            length = [long](Get-Item -LiteralPath $Path).Length
            hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
}

function Convert-ToPngV2([string]$Source, [string]$Target) {
    Add-Type -AssemblyName System.Drawing
    $stream = [IO.File]::OpenRead($Source)
    $image = $null
    try {
        $image = [Drawing.Image]::FromStream($stream, $true, $true)
        $image.Save($Target, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($null -ne $image) { $image.Dispose() }
        $stream.Dispose()
    }
    $info = Get-ImageInfoV2 $Target
    if ($info.length -le 0) { throw '下載圖片轉存後為 0KB。' }
    return $info
}

function Download-ProductImagesV2($Product) {
    $productId = [string]$Product.product_id
    if ($productId -notmatch '^\d{5,30}$') { throw '商品ID格式錯誤。' }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $rawDir = Join-Path (Get-V2Workspace) ("raw_images\" + $productId)
    New-Item -ItemType Directory -Path $rawDir -Force | Out-Null

    $downloaded = @()
    $failures = @()
    $urls = @($Product.image_urls)

    for ($index = 0; $index -lt $urls.Count; $index++) {
        $url = ([string]$urls[$index]).Trim()
        if ($url -notmatch '^https?://') { continue }

        $name = if ($index -eq 0) { '00_main_original.png' } else { ('{0:D2}_detail_original.png' -f $index) }
        $target = Join-Path $rawDir $name

        if (Test-Path -LiteralPath $target) {
            try {
                Get-ImageInfoV2 $target | Out-Null
                $downloaded += $target
                continue
            }
            catch {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            }
        }

        $ok = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $temp = $target + '.download'
            try {
                Invoke-WebRequest -Uri $url -OutFile $temp -UseBasicParsing -TimeoutSec 90
                Convert-ToPngV2 $temp $target | Out-Null
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                $downloaded += $target
                $ok = $true
                break
            }
            catch {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                if ($attempt -lt 3) { Start-Sleep -Seconds @(2,5)[$attempt - 1] }
            }
        }

        if (-not $ok) {
            $failures += $url
            Write-TinySnowLog '原圖下載' $url ("product_id=" + $productId) $false '下載或圖片驗證失敗'
        }
    }

    if ($downloaded.Count -eq 0) { throw '所有原始圖片都下載失敗，已停止；不會呼叫生圖 API。' }

    return [pscustomobject]@{
        paths = @($downloaded)
        failed_urls = @($failures)
        folder = $rawDir
    }
}

function Analyze-ProductImagesV2([string]$ProductId, [string[]]$Paths) {
    if ($ProductId -notmatch '^\d{5,30}$') { throw '商品ID格式錯誤。' }
    if ($null -eq $Paths -or $Paths.Count -eq 0) { throw '沒有可分析的原圖。' }

    $seen = @{}
    $items = @()
    $references = @()

    for ($position = 0; $position -lt $Paths.Count; $position++) {
        $imagePath = [string]$Paths[$position]
        $info = Get-ImageInfoV2 $imagePath
        $duplicate = $seen.ContainsKey($info.hash)
        if (-not $duplicate) { $seen[$info.hash] = $true }
        $ratio = if ($info.height -gt 0) { $info.width / [double]$info.height } else { 0 }
        $squareDelta = [Math]::Abs($ratio - 1.0)
        $items += [pscustomobject]@{
            path = $imagePath
            file = Split-Path $imagePath -Leaf
            position = $position
            width = $info.width
            height = $info.height
            bytes = $info.length
            sha256 = $info.hash
            duplicate = $duplicate
            near_square = ($squareDelta -le 0.15)
        }
        if (-not $duplicate) { $references += $imagePath }
    }

    $analysis = [ordered]@{
        product_id = $ProductId
        analyzed_at = (Get-Date).ToString('o')
        semantic_check = 'not_available_in_local_preflight'
        images = @($items)
        reference_order = @($references)
        failed = $false
    }

    $folder = Split-Path $Paths[0] -Parent
    $analysis | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $folder 'analysis.json') -Encoding UTF8

    $lines = @()
    $lines += "商品ID：$ProductId"
    $lines += "可用原圖：$($items.Count) 張"
    $lines += "去重後參考圖：$($references.Count) 張"
    $lines += '本地預檢內容：能否開啟、尺寸、檔案大小、SHA256重複、接近1:1。'
    $lines += '注意：本地預檢不能可靠判斷簡體文字、品牌/尺寸/規格語意衝突；生成時仍使用保守提示詞，最終成品需要人工看圖確認。'
    $lines += ''
    foreach ($item in $items) {
        $dupText = if ($item.duplicate) { '重複' } else { '正常' }
        $lines += ("{0}｜{1}x{2}｜{3} bytes｜{4}" -f $item.file, $item.width, $item.height, $item.bytes, $dupText)
    }
    $lines | Set-Content -LiteralPath (Join-Path $folder 'analysis_summary.txt') -Encoding UTF8

    return [pscustomobject]$analysis
}

function Test-SelectedProductImagesV2 {
    $product = Get-SelectedProduct
    $download = Download-ProductImagesV2 $product
    $analysis = Analyze-ProductImagesV2 ([string]$product.product_id) ([string[]]@($download.paths))
    return [pscustomobject]@{
        product = $product
        downloaded = @($download.paths)
        failed_urls = @($download.failed_urls)
        analysis = $analysis
        folder = $download.folder
    }
}

function Get-CheckpointPathV2([string]$ProductId) {
    $dir = Join-Path (Get-V2Workspace) ("checkpoints\" + $ProductId)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return (Join-Path $dir 'checkpoint_v2.json')
}

function Get-CheckpointV2([string]$ProductId) {
    $path = Get-CheckpointPathV2 $ProductId
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    $states = [ordered]@{}
    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
        $states[$slot] = [ordered]@{ status='pending'; retries=0; last_error='' }
    }
    $checkpoint = [ordered]@{ product_id=$ProductId; states=$states; updated_at=(Get-Date).ToString('o') }
    $checkpoint | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-CheckpointV2($Checkpoint) {
    $Checkpoint.updated_at = (Get-Date).ToString('o')
    $Checkpoint | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-CheckpointPathV2 ([string]$Checkpoint.product_id)) -Encoding UTF8
}

function Get-PromptV2([string]$Slot, [string]$Name) {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $templates = Get-Content -LiteralPath (Join-Path $systemRoot 'config\prompt_templates.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $key = switch ($Slot) {
        'main' { 'main_image' }
        'detail1' { 'detail_overview' }
        'detail2' { 'detail_structure' }
        'detail3' { 'detail_scene' }
        'detail4' { 'detail_spec' }
        default { 'detail_general' }
    }
    return "商品名稱僅供辨識：$Name。`n$($templates.$key)`n共同硬規則：$($templates.common_rules)"
}

function Get-ReferencesForSlotV2($Analysis, [string]$Slot, [int]$Maximum) {
    $order = @($Analysis.reference_order)
    if ($order.Count -eq 0) { throw '沒有可用參考圖。' }
    $maximum = [Math]::Min([Math]::Max(1,$Maximum), $order.Count)
    if ($order.Count -eq 1 -or $maximum -eq 1) { return @([string]$order[0]) }

    $details = @($order | Select-Object -Skip 1)
    $refs = @([string]$order[0])
    $offset = switch ($Slot) { 'detail1'{0} 'detail2'{1} 'detail3'{2} 'detail4'{3} default{0} }

    if ($Slot -eq 'main') {
        for ($i=0; $i -lt $details.Count -and $refs.Count -lt $maximum; $i++) { $refs += [string]$details[$i] }
    }
    else {
        for ($i=0; $i -lt $details.Count -and $refs.Count -lt $maximum; $i++) {
            $idx = ($offset + $i) % $details.Count
            $candidate = [string]$details[$idx]
            if ($refs -notcontains $candidate) { $refs += $candidate }
        }
    }
    return @($refs)
}

function Convert-ToFinalJpegV2([string]$Source, [string]$Target) {
    $info = Get-ImageInfoV2 $Source
    if ($info.width -lt 100 -or $info.height -lt 100) { throw '生成圖片尺寸異常。' }
    $ratio = $info.width / [double]$info.height
    if ($ratio -lt 0.9 -or $ratio -gt 1.1) { throw "生成圖片不是接近1:1：$($info.width)x$($info.height)" }
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Image]::FromFile($Source)
    try { $image.Save($Target, [Drawing.Imaging.ImageFormat]::Jpeg) }
    finally { $image.Dispose() }
    return (Get-ImageInfoV2 $Target)
}

function New-ProductZipV2([string]$ProductId) {
    $folder = Join-Path (Get-V2Workspace) ("final_images\" + $ProductId)
    $names = @("${ProductId}_main.jpg","${ProductId}_detail1.jpg","${ProductId}_detail2.jpg","${ProductId}_detail3.jpg","${ProductId}_detail4.jpg")
    foreach ($name in $names) { if (-not (Test-Path -LiteralPath (Join-Path $folder $name))) { throw "尚未完成5張圖片，缺少：$name" } }
    $zip = Join-Path (Get-V2Workspace) ("${ProductId}_圖片優化完成.zip")
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tempDir = Join-Path (Get-V2Workspace) ("zip_" + $ProductId)
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    foreach ($name in $names) { Copy-Item -LiteralPath (Join-Path $folder $name) -Destination $tempDir }
    [IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zip)
    Remove-Item -LiteralPath $tempDir -Recurse -Force
    return $zip
}

function Start-SingleProductOptimizationV2($Config) {
    if (-not [bool]$Config.safe_test_mode) { throw 'SAFE TEST MODE 必須保持開啟。' }
    $product = Get-SelectedProduct
    $preflight = Test-SelectedProductImagesV2
    $analysis = $preflight.analysis
    $productId = [string]$product.product_id
    $maximum = [Math]::Min([Math]::Max(1,[int]$Config.max_reference_images), @($analysis.reference_order).Count)

    $finalDir = Join-Path (Get-V2Workspace) ("final_images\" + $productId)
    New-Item -ItemType Directory -Path $finalDir -Force | Out-Null
    $checkpoint = Get-CheckpointV2 $productId
    $errors = @()
    $generated = 0
    $hashes = @{}

    foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
        $target = Join-Path $finalDir ("${productId}_${slot}.jpg")
        $state = $checkpoint.states.$slot
        if ($state.status -eq 'done' -and (Test-Path -LiteralPath $target)) {
            try { $existing = Get-ImageInfoV2 $target; $hashes[$existing.hash] = $true; continue } catch { $state.status = 'pending' }
        }

        $state.status = 'generating'
        Save-CheckpointV2 $checkpoint
        $prompt = Get-PromptV2 $slot ([string]$product.product_name)
        $refs = @(Get-ReferencesForSlotV2 $analysis $slot $maximum)
        $success = $false

        for ($attempt=1; $attempt -le 3; $attempt++) {
            try {
                $temporary = Invoke-ImageEditMulti $Config ([string[]]$refs) $prompt '1024x1024' 'medium'
                $info = Convert-ToFinalJpegV2 $temporary $target
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                if ($hashes.ContainsKey($info.hash)) { Remove-Item -LiteralPath $target -Force; throw '生成圖片與本商品之前成品完全重複。' }
                $hashes[$info.hash] = $true
                $state.status = 'done'
                $state.last_error = ''
                $generated++
                $success = $true
                Save-CheckpointV2 $checkpoint
                break
            }
            catch {
                $state.retries = [int]$state.retries + 1
                $state.last_error = Protect-SecretText $_.Exception.Message ([string]$Config.api_key)
                Save-CheckpointV2 $checkpoint
                if ($attempt -lt 3 -and $state.last_error -match '429|HTTP 5\d\d|timed? out|timeout|network|connection|連線') { Start-Sleep -Seconds @(15,30)[$attempt-1] }
                else { break }
            }
        }

        if (-not $success) {
            $state.status = 'failed'
            $errors += ("$slot：" + $state.last_error)
            Save-CheckpointV2 $checkpoint
            break
        }
    }

    $allDone = @($checkpoint.states.PSObject.Properties | Where-Object { $_.Value.status -ne 'done' }).Count -eq 0
    $zip = ''
    if ($allDone) { $zip = New-ProductZipV2 $productId }

    return [pscustomobject]@{
        product_id = $productId
        generated_this_run = $generated
        complete = $allDone
        zip = $zip
        failed_urls = @($preflight.failed_urls)
        errors = @($errors)
    }
}
