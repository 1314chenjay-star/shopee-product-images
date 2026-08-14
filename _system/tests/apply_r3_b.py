from pathlib import Path
R=Path('.')
def rd(p): return p.read_text('utf-8-sig')
def bom(p,s): p.write_bytes(b'\xef\xbb\xbf'+s.encode('utf-8'))
def rep(s,a,b,n):
    if a not in s: raise SystemExit('missing '+n)
    return s.replace(a,b,1)

p=R/'_system/start/image_pipeline_v2.ps1'; s=rd(p)
old="""function Test-RetryableV2([string]$Message) {
    return ($Message -match '429|HTTP 5\\d\\d|timeout|timed out|network|connection|reset|暫時|連線|逾時|主圖適配檢查未通過')
}
"""
new=r'''function Get-CompactTransportPromptV2([string]$Slot, [string]$Name) {
    $common = '只依商品名稱與參考圖可確認內容；商品外觀、顏色、數量、結構與可見配件必須忠實。禁止捏造尺寸、材質、功能、品牌、型號、認證、保固、贈品或數據；資訊不明就省略。文字使用自然台灣繁體中文，不用中國大陸電商詞。'
    switch ($Slot) {
        'main' { $role = '製作1:1台灣蝦皮封面主圖。商品清楚完整約佔55%到75%，有一個醒目主標題與2到4個可驗證短賣點，背景有層次，手機縮圖可讀。' }
        'detail1' { $role = '製作1:1詳情圖，整理3到5個可確認核心賣點，不與主圖只換背景重複。' }
        'detail2' { $role = '製作1:1詳情圖，呈現可確認的結構、配件與可見細節。' }
        'detail3' { $role = '製作1:1詳情圖，呈現真實合理的使用方式與適用情境，不暗示未證實效果。' }
        'detail4' { $role = '製作1:1詳情圖，整理可確認的適用對象、注意事項或選購重點；尺寸不能確認就不要畫尺寸圖。' }
        default { $role = '製作1:1補充詳情圖，只呈現可確認內容。' }
    }
    return ('商品名稱僅供辨識：' + $Name + '。' + $role + $common)
}

function Save-ApiReferenceJpegV2([string]$Source, [string]$Target, [int]$MaxEdge) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw ('找不到 API 參考圖：' + $Source) }
    Add-Type -AssemblyName System.Drawing
    $stream=[IO.File]::OpenRead($Source); $sourceImage=$null; $bitmap=$null; $graphics=$null
    try {
        $sourceImage=[Drawing.Image]::FromStream($stream,$true,$true); $largest=[Math]::Max($sourceImage.Width,$sourceImage.Height)
        if ($largest -le 0) { throw 'API 參考圖尺寸異常。' }
        $scale=[Math]::Min(1.0,$MaxEdge/[double]$largest); $width=[Math]::Max(1,[int][Math]::Round($sourceImage.Width*$scale)); $height=[Math]::Max(1,[int][Math]::Round($sourceImage.Height*$scale))
        $bitmap=New-Object Drawing.Bitmap $width,$height; $graphics=[Drawing.Graphics]::FromImage($bitmap); $graphics.Clear([Drawing.Color]::White)
        $graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $graphics.DrawImage($sourceImage,0,0,$width,$height); $bitmap.Save($Target,[Drawing.Imaging.ImageFormat]::Jpeg)
    } finally { if($null-ne$graphics){$graphics.Dispose()}; if($null-ne$bitmap){$bitmap.Dispose()}; if($null-ne$sourceImage){$sourceImage.Dispose()}; $stream.Dispose() }
    $info=Get-ImageInfoV2 $Target; if($info.length -le 0){throw 'API 參考圖壓縮後為 0KB。'}; return $info
}
function Convert-ToApiReferenceV2([string]$Source,[string]$ProductId) {
    $dir=Join-Path (Get-V2Workspace) ('api_refs\'+$ProductId); New-Item -ItemType Directory -Path $dir -Force|Out-Null; $target=Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($Source)+'.jpg')
    foreach($edge in @(1280,1024,768)){ Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; $info=Save-ApiReferenceJpegV2 $Source $target $edge; if($info.length -le 1572864){return $target} }; return $target
}
function Get-PreparedApiReferencesV2([string]$ProductId,[string[]]$References) { $prepared=@(); foreach($reference in $References){$prepared+=(Convert-ToApiReferenceV2 ([string]$reference) $ProductId)}; return [string[]]$prepared }
function Test-TransportFailureV2([string]$Message) { if([string]::IsNullOrWhiteSpace($Message)){return $false}; return ($Message -match '发送请求时出错|發送請求時出錯|傳送要求時發生錯誤|HttpRequestException|TaskCanceledException|HTTP 408|HTTP 502|HTTP 503|HTTP 504|HTTP 520|HTTP 522|HTTP 524|timeout|timed out|connection.*(reset|closed|abort)|network|socket|EOF|連線.*(重設|中斷|關閉)|逾時') }
function Test-RetryableV2([string]$Message) { return ((Test-TransportFailureV2 $Message) -or ($Message -match '429|HTTP 5\d\d|暫時|主圖適配檢查未通過|生成圖片與本商品先前成品完全重複')) }
'''
s=rep(s,old,new,'retry block')
s=s.replace("    $maximum = [Math]::Min([Math]::Max(1,[int]$Config.max_reference_images), $refCount)","    $maximum = [Math]::Min(2, [Math]::Min([Math]::Max(1,[int]$Config.max_reference_images), $refCount))",1)
start=s.index("        $prompt = Get-PromptV2 $slot ([string]$product.product_name)\n"); end=s.index("\n        if (-not $success) {",start)
block=r'''        $prompt = Get-PromptV2 $slot ([string]$product.product_name)
        $sourceRefs = [string[]]@(Get-ReferencesForSlotV2 $analysis $slot $maximum)
        $refs = [string[]]@(Get-PreparedApiReferencesV2 $productId $sourceRefs)
        $success = $false; $transportDegraded = $false; $lowQualityRejected = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $temporary=$null; $attemptRefs=[string[]]@($refs); $attemptQuality='medium'
            if($transportDegraded){ if($attempt -ge 3){$attemptRefs=[string[]]@($refs|Select-Object -First 1)}; if(-not $lowQualityRejected){$attemptQuality='low'} }
            $attemptPrompt=$prompt; if($transportDegraded){$attemptPrompt=Get-CompactTransportPromptV2 $slot ([string]$product.product_name)}
            if($slot -eq 'main' -and $attempt -gt 1 -and -not $transportDegraded){$attemptPrompt+="`n前一次主圖適配檢查未通過。請加大商品主體、加強明確主標題與2到4個可確認的短賣點，避免大片空白，務必做成比詳情圖更鮮明的電商封面。"}
            $attemptStarted=Get-Date; Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("{0} 第 {1}/3 次｜{2}｜{3} 張壓縮參考圖" -f $slot,$attempt,$attemptQuality,@($attemptRefs).Count)
            try {
                $temporary=Invoke-ImageEditMultiV2 $Config $attemptRefs $attemptPrompt '1024x1024' $attemptQuality; $info=Convert-ToFinalJpegV2 $temporary $target; Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue; $temporary=$null
                if($hashes.ContainsKey($info.hash)){Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; throw '生成圖片與本商品先前成品完全重複。'}
                if($slot -eq 'main'){Test-MainImageFitnessV2 $target}; $hashes[$info.hash]=$true; $state.status='done'; $state.last_error=''; $generated++; $success=$true; Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("{0} 已生成完成" -f $slot); break
            } catch {
                if($null-ne$temporary -and (Test-Path -LiteralPath $temporary)){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}; Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                $elapsed=[int]((Get-Date)-$attemptStarted).TotalSeconds; $rawError=Protect-SecretTextV2 $_.Exception.Message ([string]$Config.api_key); $isTransport=Test-TransportFailureV2 $rawError; $timeoutHint=''
                if($isTransport -and $elapsed -ge 105 -and $elapsed -le 150){$timeoutHint='；疑似上游同步約120秒超時'}
                $state.retries=[int]$state.retries+1; $state.last_error=($rawError+"（耗時 ${elapsed} 秒${timeoutHint}）"); Save-CheckpointV2 $checkpoint
                if($isTransport){$transportDegraded=$true}; if($attemptQuality -eq 'low' -and $rawError -match 'HTTP 400' -and $rawError -match '(quality|low|invalid|unsupported|不支持|不支援)'){$lowQualityRejected=$true}
                $canRetry=Test-RetryableV2 $rawError; if($lowQualityRejected -and $attempt -lt 3){$canRetry=$true}
                if($attempt -lt 3 -and $canRetry){ if($isTransport){$nextMode=if($attempt -eq 1){'下一次改用 low 並維持最多2張壓縮參考圖'}else{'下一次降為1張壓縮參考圖'}; Set-CheckpointActivityV2 $checkpoint $labels[$slot] ("傳輸失敗，{0}。" -f $nextMode); Start-Sleep -Seconds 3}else{Start-Sleep -Seconds 5} } else {break}
            }
        }
'''
s=s[:start]+block+s[end:]; bom(p,s)

# Smoke assertions appended before flat-output test.
p=R/'_system/tests/windows_smoke.ps1'; s=rd(p); mark="    # 6) Final images must be flat in 已生成圖片 beside START.bat; no ZIP is created.\n"
extra=r'''    # 6) R3 transport safeguards.
    $defaultConfig=[pscustomobject](Get-DefaultTinySnowConfigV2); if([int]$defaultConfig.max_reference_images -ne 2){throw 'R3 default max_reference_images must be 2.'}; if([string]$defaultConfig.transport_profile -ne 'r3_120s_safe'){throw 'R3 transport profile missing.'}
    if(-not(Test-TransportFailureV2 '发送请求时出错。')){throw 'Send error must be transport retryable.'}; if(-not(Test-TransportFailureV2 'HTTP 524: timeout')){throw 'HTTP 524 must be transport retryable.'}
    $compactPrompt=Get-CompactTransportPromptV2 'main' '測試商品'; if([string]::IsNullOrWhiteSpace($compactPrompt) -or $compactPrompt.Length -gt $prompt.Length){throw 'Compact prompt invalid.'}
    $largePng=Join-Path $imageDir 'large_reference.png'; $largeBmp=New-Object Drawing.Bitmap 1800,1200; try{$largeBmp.SetPixel(0,0,[Drawing.Color]::Black);$largeBmp.SetPixel(1799,1199,[Drawing.Color]::Red);$largeBmp.Save($largePng,[Drawing.Imaging.ImageFormat]::Png)}finally{$largeBmp.Dispose()}
    $apiRef=Convert-ToApiReferenceV2 $largePng '48565764183'; $apiInfo=Get-ImageInfoV2 $apiRef; if($apiInfo.width -gt 1280 -or $apiInfo.height -gt 1280){throw 'API reference resize failed.'}; if([IO.Path]::GetExtension($apiRef).ToLowerInvariant() -ne '.jpg'){throw 'API reference must be JPEG.'}; if($apiInfo.length -gt 1572864){throw 'API reference too large.'}

    # 7) Final images must be flat in 已生成圖片 beside START.bat; no ZIP is created.
'''
s=rep(s,mark,extra,'smoke insert').replace("    # 7) Progress summary exposes six understandable steps and counters.\n","    # 8) Progress summary exposes six understandable steps and counters.\n",1); bom(p,s)
