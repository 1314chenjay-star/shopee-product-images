$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing

$systemRoot = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $systemRoot 'source_review_v4c_b001'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$urls = [string[]]@(
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257v-mrpfv01qftae87',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv189687667',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv20gcq9u13',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ab-mrpfv2pj318i67',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv3hzcv7k5a',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ah-mrpfv4am6olh77',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258p-mrpfv514qdqe3e',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259g-mrpfv681064o70',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a5-mrpfv6zz4vm02a',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258i-mrmk58q4nzlsb6',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259k-mrmk59xspwco7f',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrmk5ay8vcav9f',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258b-mrmk5c0mpiiue3',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259a-mrld4zmjvzese9',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aq-mrld5173wsnc26',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825bd-mrld52ewzv2845',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ar-mrld548dmr5yd0',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82589-mrld5h422mfbe0',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a2-mrld5lab4dfk7b',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a6-mrld5nnj9b7r7b',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259c-mrld5rkc9eyv80',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82581-mrlmz0jxodms4e',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257z-mrlmz57774zp49',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ab-mrlmz8wdwetc37',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257z-mrlmzdf1frwm2c',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259f-mrk7mccmv7ygca',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258e-mrk7mi3x9gcld9',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aa-mrk7mmjb2ux28e',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257w-mrk7msevh98g5c',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82592-mrmk55d3v7r5d6',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258w-mrmk56j2jmro41',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b4-mrmk57g31ngia6',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258m-mrmk58iaiwoxcb',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259i-mrlf15s6dnus45',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259x-mrlf1816xhc22b',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a6-mrlf1auswq2s97',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrlf1et4xeki2a',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a3-mroao82gjxfl3a',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259z-mroao92ds2de21',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257v-mroao9xigtmu82',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258h-mroaoautdz4873',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mroaobthz7yedb',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a7-mroaoclviolc21',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258r-mroaodm1dc7815',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258k-mroaoghpsoht91',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258e-mroaohod3e9t7c',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257y-mrpfuuln3uh312',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82594-mrpfuvovm1hiee',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b4-mrpfuweqmq6c9d',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259u-mrpfuxe3vpxjf8'
)

$manifest = @()
for ($i = 0; $i -lt $urls.Count; $i++) {
    $seq = $i + 1
    $rawPath = Join-Path $outDir ('raw_{0:D4}.bin' -f $seq)
    $pngName = ('source_{0:D4}.png' -f $seq)
    $pngPath = Join-Path $outDir $pngName
    $ok = $false
    $lastError = ''
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $urls[$i] -OutFile $rawPath -TimeoutSec 40 -Headers @{ 'User-Agent'='Mozilla/5.0 TinySnow-V4C0-SourceReview' }
            if (-not (Test-Path -LiteralPath $rawPath) -or (Get-Item -LiteralPath $rawPath).Length -le 0) { throw 'empty download' }
            $img = [System.Drawing.Image]::FromFile($rawPath)
            try { $img.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $img.Dispose() }
            $ok = $true
        } catch {
            $lastError = $_.Exception.Message
            if (Test-Path -LiteralPath $rawPath) { Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
        }
    }
    if (-not $ok) { throw ('B001 source download failed at sequence {0}: {1}' -f $seq, $lastError) }
    if (Test-Path -LiteralPath $rawPath) { Remove-Item -LiteralPath $rawPath -Force }
    $check = [System.Drawing.Image]::FromFile($pngPath)
    try { $width = [int]$check.Width; $height = [int]$check.Height }
    finally { $check.Dispose() }
    $manifest += [pscustomobject]@{
        sequence = $seq
        source_url = $urls[$i]
        file = $pngName
        width = $width
        height = $height
        bytes = (Get-Item -LiteralPath $pngPath).Length
        sha256 = (Get-FileHash -LiteralPath $pngPath -Algorithm SHA256).Hash.ToLowerInvariant()
        semantic_review_state = 'NOT_RUN'
        image_api_called = $false
    }
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'source_manifest.json') -Encoding UTF8
[pscustomobject]@{
    batch_id = 'B001'
    expected_count = 50
    downloaded_count = $manifest.Count
    source_only = $true
    image_api_called = $false
    semantic_review_required = $true
    note = 'Downloaded original Shopee CDN images only. No generation, no OCR claim, no semantic approval.'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'summary.json') -Encoding UTF8

if ($manifest.Count -ne 50) { throw ('B001 expected 50 images, got ' + $manifest.Count) }
Write-Host '[PASS] V4-C0 B001 downloaded 50 source images; no image generation API called.' -ForegroundColor Green
