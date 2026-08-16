param(
    [Parameter(Mandatory=$true)][string]$Base64Path,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$ExpectedSha256
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Base64Path)) { throw "Bootstrap not found: $Base64Path" }
$b64 = (Get-Content $Base64Path -Raw -Encoding ASCII).Trim()
$compressed = [Convert]::FromBase64String($b64)
$inStream = New-Object System.IO.MemoryStream(,$compressed)
$gzip = New-Object System.IO.Compression.GZipStream($inStream, [System.IO.Compression.CompressionMode]::Decompress)
$outStream = New-Object System.IO.MemoryStream
$gzip.CopyTo($outStream)
$gzip.Dispose(); $inStream.Dispose()
$bytes = $outStream.ToArray(); $outStream.Dispose()
$dir = Split-Path -Parent $OutputPath
if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
[System.IO.File]::WriteAllBytes($OutputPath, $bytes)
$actual = (Get-FileHash $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $ExpectedSha256.ToLowerInvariant()) { throw "Bootstrap SHA256 mismatch: $actual" }
Write-Host "SEMANTIC_BOOTSTRAP_EXPANDED=$OutputPath"
Write-Host "SEMANTIC_BOOTSTRAP_SHA256=$actual"
