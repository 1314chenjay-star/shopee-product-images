param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'fixtures\v4c_source_batch_manifest.json'),
    [string]$OutRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'source_review_v4c')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Net.Http

if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Source batch manifest not found: $ManifestPath" }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$batchId = [string]$manifest.batch_id
$rows = @($manifest.rows)
$expected = [int]$manifest.expected_count
if ([string]::IsNullOrWhiteSpace($batchId)) { throw 'Source batch manifest missing batch_id.' }
if ($rows.Count -ne $expected) { throw ("Source batch expected_count mismatch: {0} vs {1}" -f $expected,$rows.Count) }

$outDir = Join-Path $OutRoot $batchId
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function Get-ImageExtension([byte[]]$Bytes, [string]$ContentType) {
    if ($Bytes.Length -ge 12) {
        if ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8) { return '.jpg' }
        if ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47) { return '.png' }
        $riff = [Text.Encoding]::ASCII.GetString($Bytes,0,4)
        $webp = [Text.Encoding]::ASCII.GetString($Bytes,8,4)
        if ($riff -eq 'RIFF' -and $webp -eq 'WEBP') { return '.webp' }
    }
    if ($ContentType -match 'png') { return '.png' }
    if ($ContentType -match 'webp') { return '.webp' }
    return '.jpg'
}

$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(60)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 TinySnow-V4C0-SourceReview/1.0')
$client.DefaultRequestHeaders.Accept.ParseAdd('image/jpeg')
$client.DefaultRequestHeaders.Accept.ParseAdd('image/png')
$client.DefaultRequestHeaders.Accept.ParseAdd('image/webp')
$client.DefaultRequestHeaders.Accept.ParseAdd('*/*')

$downloadRows = @()
$successCount = 0
$failureCount = 0
try {
    foreach ($row in $rows) {
        $seq = [int]$row.sequence
        $pid = [string]$row.product_id
        $pos = [int]$row.source_position
        $url = [string]$row.source_url
        $bytes = $null
        $contentType = ''
        $lastError = ''

        for ($attempt = 1; $attempt -le 4; $attempt++) {
            try {
                $response = $client.GetAsync($url).GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) { throw ("HTTP {0}" -f [int]$response.StatusCode) }
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                $contentType = [string]$response.Content.Headers.ContentType.MediaType
                if ($null -eq $bytes -or $bytes.Length -lt 128) { throw 'Downloaded image payload is empty or too small.' }
                break
            }
            catch {
                $lastError = $_.Exception.Message
                if ($attempt -lt 4) { Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 6)) }
            }
        }

        if ($null -eq $bytes) {
            $failureCount++
            $downloadRows += [pscustomobject]@{
                sequence=$seq; product_id=$pid; source_position=$pos; source_url=$url; status='FAILED';
                file=''; bytes=0; content_type=$contentType; sha256=''; error=$lastError
            }
            continue
        }

        $ext = Get-ImageExtension $bytes $contentType
        $fileName = $seq.ToString('0000') + '_' + $pid + '_p' + $pos.ToString('00') + $ext
        $target = Join-Path $outDir $fileName
        [IO.File]::WriteAllBytes($target, $bytes)
        $sha = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        $successCount++
        $downloadRows += [pscustomobject]@{
            sequence=$seq; product_id=$pid; source_position=$pos; source_url=$url; status='OK';
            file=$fileName; bytes=$bytes.Length; content_type=$contentType; sha256=$sha; error=''
        }
    }
}
finally {
    $client.Dispose()
    $handler.Dispose()
}

$downloadRows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'download_manifest.json') -Encoding UTF8
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outDir 'requested_manifest.json') -Encoding UTF8

$summary = [pscustomobject]@{
    schema_version='v4c0-source-review-1'
    batch_id=$batchId
    expected_count=$expected
    downloaded_count=$successCount
    failed_count=$failureCount
    tiny_snow_api_called=$false
    image_generation_called=$false
    pixel_semantic_review_completed=$false
    visual_review_required=$true
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'source_review_summary.json') -Encoding UTF8

Write-Host ("V4-C0 source review {0}: {1}/{2} downloaded, {3} failed." -f $batchId,$successCount,$expected,$failureCount)
if ($successCount -ne $expected -or $failureCount -ne 0) { throw ("Source batch download incomplete: {0}/{1}" -f $successCount,$expected) }
Write-Host '[PASS] Source-only batch download completed. No image generation API was called.' -ForegroundColor Green
