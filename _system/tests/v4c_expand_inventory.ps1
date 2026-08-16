param(
    [Parameter(Mandatory=$false)][string]$InventoryPath = "_system/v4c/inventory/source_inventory.jsonl"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $InventoryPath)) { throw "Inventory marker not found: $InventoryPath" }
$first = Get-Content -LiteralPath $InventoryPath -TotalCount 1 -Encoding UTF8
try { $marker = $first | ConvertFrom-Json } catch { return }
if (-not ($marker.PSObject.Properties.Name -contains "bootstrap") -or -not [bool]$marker.bootstrap) { return }
if (-not ($marker.PSObject.Properties.Name -contains "bootstrap_format") -or [string]$marker.bootstrap_format -ne "V4C1C2") {
    throw "Unsupported inventory bootstrap format"
}

$inventoryDir = Split-Path -Parent $InventoryPath
$partsDir = Join-Path $inventoryDir ([string]$marker.bootstrap_parts_dir)
if (-not (Test-Path -LiteralPath $partsDir)) { throw "Bootstrap parts directory missing: $partsDir" }
$parts = @(Get-ChildItem -LiteralPath $partsDir -File | Sort-Object Name)
if ($parts.Count -ne [int]$marker.part_count) { throw "Bootstrap part count mismatch: $($parts.Count)/$($marker.part_count)" }

$encoded = ""
foreach ($part in $parts) { $encoded += ([System.IO.File]::ReadAllText($part.FullName, $Utf8NoBom)).Trim() }
if ($encoded.Length -ne [int]$marker.encoded_length) { throw "Bootstrap encoded length mismatch: $($encoded.Length)/$($marker.encoded_length)" }
$compressed = [Convert]::FromBase64String($encoded)
$input = New-Object System.IO.MemoryStream(,$compressed)
$gzip = New-Object System.IO.Compression.GZipStream($input, [System.IO.Compression.CompressionMode]::Decompress)
$output = New-Object System.IO.MemoryStream
try {
    $gzip.CopyTo($output)
    $compactBytes = $output.ToArray()
} finally {
    $output.Dispose(); $gzip.Dispose(); $input.Dispose()
}
$compactSha = Get-Sha256Hex $compactBytes
if ($compactSha -ne ([string]$marker.compact_raw_sha256).ToLowerInvariant()) { throw "Compact bootstrap SHA256 mismatch: $compactSha" }

$compactText = $Utf8NoBom.GetString($compactBytes)
$lines = @($compactText -split "\r?\n")
if ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count-1])) { $lines = @($lines | Select-Object -First ($lines.Count-1)) }
if ($lines.Count -lt 3 -or $lines[0] -ne "#V4C1C2") { throw "Compact bootstrap header mismatch" }
$filesIndex = -1
for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq "#FILES") { $filesIndex = $i; break } }
if ($filesIndex -lt 2) { throw "Compact bootstrap #FILES marker missing" }
$groupLines = @($lines[1..($filesIndex-1)])
$fileLines = @($lines[($filesIndex+1)..($lines.Count-1)])
if ($groupLines.Count -ne [int]$marker.product_count) { throw "Product group count mismatch: $($groupLines.Count)/$($marker.product_count)" }
if ($fileLines.Count -ne [int]$marker.expected_count) { throw "Source filename count mismatch: $($fileLines.Count)/$($marker.expected_count)" }

$baseUrl = [string]$marker.base_url
$seq = 0
$fileCursor = 0
$records = New-Object System.Collections.Generic.List[string]
foreach ($groupLine in $groupLines) {
    $pair = $groupLine -split ":", 2
    if ($pair.Count -ne 2) { throw "Invalid compact product group: $groupLine" }
    $productId = [string]$pair[0]
    $count = [int]$pair[1]
    for ($imageIndex = 0; $imageIndex -lt $count; $imageIndex++) {
        if ($fileCursor -ge $fileLines.Count) { throw "Compact source cursor overflow" }
        $token = [string]$fileLines[$fileCursor]
        $fileCursor++
        if ($token.StartsWith("!")) {
            $filename = $token.Substring(1)
        } else {
            $p = $token -split "\|", 2
            if ($p.Count -ne 2) { throw "Invalid compact filename token: $token" }
            if ($p[1].StartsWith("!")) {
                $filename = "sg-11134201-" + $p[0] + "-" + $p[1].Substring(1)
            } else {
                $filename = "sg-11134201-" + $p[0] + "-mr" + $p[1]
            }
        }
        $seq++
        $record = [ordered]@{
            sequence = $seq
            source_id = ("V4C-S{0:D6}" -f $seq)
            product_id = $productId
            image_index = $imageIndex
            image_type = $(if ($imageIndex -eq 0) { "主圖" } else { "商品圖$($imageIndex)" })
            url = $baseUrl + $filename
            source_action = "PRESERVE_WITH_CAUTION"
        }
        $records.Add(($record | ConvertTo-Json -Compress -Depth 6))
    }
}
if ($seq -ne [int]$marker.expected_count -or $fileCursor -ne $fileLines.Count) { throw "Expanded source count mismatch: $seq/$fileCursor" }
$inventoryText = ($records -join "`n") + "`n"
[System.IO.File]::WriteAllText($InventoryPath, $inventoryText, $Utf8NoBom)
$inventorySha = (Get-FileHash -Algorithm SHA256 -LiteralPath $InventoryPath).Hash.ToLowerInvariant()
if ($inventorySha -ne ([string]$marker.inventory_sha256).ToLowerInvariant()) { throw "Expanded inventory SHA256 mismatch: $inventorySha" }
Write-Host "INVENTORY_EXPANDED=true"
Write-Host "INVENTORY_COUNT=$seq"
Write-Host "INVENTORY_SHA256=$inventorySha"
Write-Host "IMAGE_GENERATION_CALLED=false"
Write-Host "TINY_SNOW_API_CALLED=false"
Write-Host "PAID_API_CALLED=false"
