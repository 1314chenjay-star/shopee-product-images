Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-TinySnowSourcePreservationRoute {
    param(
        [Parameter(Mandatory=$true)][string]$Action,
        [object[]]$ProtectedRegions = @()
    )
    $normalized = $Action.Trim().ToUpperInvariant()
    $deterministicOnly = @('PRESERVE','CLEANUP','DETERMINISTIC_CLEANUP','SAFE_CROP','SAFE_RESIZE','SAFE_PAD')
    if ($deterministicOnly -contains $normalized) {
        return [pscustomobject]@{
            action = $normalized
            route = 'DETERMINISTIC_ONLY'
            paid_generation_allowed = $false
            requires_protected_regions = $false
            reason = 'Source-preserving cleanup must not use full-frame generative redraw.'
        }
    }
    if (@($ProtectedRegions).Count -lt 1) {
        return [pscustomobject]@{
            action = $normalized
            route = 'BLOCKED_NO_PROTECTED_REGION'
            paid_generation_allowed = $false
            requires_protected_regions = $true
            reason = 'Generative edit is blocked until explicit protected regions are supplied.'
        }
    }
    return [pscustomobject]@{
        action = $normalized
        route = 'GENERATIVE_WITH_PROTECTED_REGION_RESTORE'
        paid_generation_allowed = $true
        requires_protected_regions = $true
        reason = 'Generative edit may run only with deterministic protected-region restore and post-generation QA.'
    }
}

function ConvertTo-TinySnowPixelRect {
    param(
        [Parameter(Mandatory=$true)]$Region,
        [Parameter(Mandatory=$true)][int]$Width,
        [Parameter(Mandatory=$true)][int]$Height
    )
    foreach ($name in @('x','y','width','height')) {
        if (-not ($Region.PSObject.Properties.Name -contains $name)) { throw "Protected region missing property: $name" }
    }
    $x = [double]$Region.x; $y = [double]$Region.y; $w = [double]$Region.width; $h = [double]$Region.height
    if ($x -lt 0 -or $y -lt 0 -or $w -le 0 -or $h -le 0 -or ($x + $w) -gt 1.000001 -or ($y + $h) -gt 1.000001) {
        throw 'Protected region must use normalized coordinates inside [0,1].'
    }
    $px = [Math]::Max(0, [int][Math]::Round($x * $Width))
    $py = [Math]::Max(0, [int][Math]::Round($y * $Height))
    $pw = [Math]::Max(1, [int][Math]::Round($w * $Width))
    $ph = [Math]::Max(1, [int][Math]::Round($h * $Height))
    if (($px + $pw) -gt $Width) { $pw = $Width - $px }
    if (($py + $ph) -gt $Height) { $ph = $Height - $py }
    return New-Object System.Drawing.Rectangle($px,$py,$pw,$ph)
}

function Restore-TinySnowProtectedRegions {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$CandidatePath,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [Parameter(Mandatory=$true)][object[]]$ProtectedRegions
    )
    if (@($ProtectedRegions).Count -lt 1) { throw 'At least one protected region is required.' }
    $source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $SourcePath).Path)
    $candidate = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $CandidatePath).Path)
    $target = New-Object System.Drawing.Bitmap($candidate.Width,$candidate.Height,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $g = [System.Drawing.Graphics]::FromImage($target)
        try {
            $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($candidate,0,0,$candidate.Width,$candidate.Height)
            foreach ($region in @($ProtectedRegions)) {
                $srcRect = ConvertTo-TinySnowPixelRect $region $source.Width $source.Height
                $dstRect = ConvertTo-TinySnowPixelRect $region $candidate.Width $candidate.Height
                $g.DrawImage($source,$dstRect,$srcRect,[System.Drawing.GraphicsUnit]::Pixel)
            }
        }
        finally { $g.Dispose() }
        $dir = Split-Path -Parent $OutputPath
        if (-not [string]::IsNullOrWhiteSpace($dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $target.Save($OutputPath,[System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $target.Dispose(); $candidate.Dispose(); $source.Dispose()
    }
    return (Resolve-Path -LiteralPath $OutputPath).Path
}

function Test-TinySnowProtectedRegions {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$CandidatePath,
        [Parameter(Mandatory=$true)][object[]]$ProtectedRegions,
        [double]$MaxMeanAbsoluteError = 0.50,
        [double]$MaxChangedPixelRatio = 0.001,
        [int]$ChangedPixelThreshold = 2
    )
    if (@($ProtectedRegions).Count -lt 1) { throw 'At least one protected region is required.' }
    $source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $SourcePath).Path)
    $candidate = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $CandidatePath).Path)
    $results = @(); $allPass = $true
    try {
        foreach ($region in @($ProtectedRegions)) {
            $srcRect = ConvertTo-TinySnowPixelRect $region $source.Width $source.Height
            $dstRect = ConvertTo-TinySnowPixelRect $region $candidate.Width $candidate.Height
            $expected = New-Object System.Drawing.Bitmap($dstRect.Width,$dstRect.Height,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $actual = New-Object System.Drawing.Bitmap($dstRect.Width,$dstRect.Height,[System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try {
                $ge = [System.Drawing.Graphics]::FromImage($expected)
                try {
                    $ge.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                    $ge.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $ge.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $ge.DrawImage($source,(New-Object System.Drawing.Rectangle(0,0,$dstRect.Width,$dstRect.Height)),$srcRect,[System.Drawing.GraphicsUnit]::Pixel)
                } finally { $ge.Dispose() }
                $ga = [System.Drawing.Graphics]::FromImage($actual)
                try {
                    $ga.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
                    $ga.DrawImage($candidate,(New-Object System.Drawing.Rectangle(0,0,$dstRect.Width,$dstRect.Height)),$dstRect,[System.Drawing.GraphicsUnit]::Pixel)
                } finally { $ga.Dispose() }
                [double]$sum = 0; [long]$changed = 0; [long]$pixels = [long]$dstRect.Width * [long]$dstRect.Height
                for ($yy=0; $yy -lt $dstRect.Height; $yy++) {
                    for ($xx=0; $xx -lt $dstRect.Width; $xx++) {
                        $e = $expected.GetPixel($xx,$yy); $a = $actual.GetPixel($xx,$yy)
                        $d = ([Math]::Abs([int]$e.R-[int]$a.R)+[Math]::Abs([int]$e.G-[int]$a.G)+[Math]::Abs([int]$e.B-[int]$a.B))/3.0
                        $sum += $d
                        if ($d -gt $ChangedPixelThreshold) { $changed++ }
                    }
                }
                $mae = if ($pixels -gt 0) { $sum / $pixels } else { 255.0 }
                $ratio = if ($pixels -gt 0) { [double]$changed / [double]$pixels } else { 1.0 }
                $pass = ($mae -le $MaxMeanAbsoluteError -and $ratio -le $MaxChangedPixelRatio)
                if (-not $pass) { $allPass = $false }
                $name = if ($region.PSObject.Properties.Name -contains 'name') { [string]$region.name } else { 'protected_region' }
                $results += [pscustomobject]@{name=$name;mean_absolute_error=[Math]::Round($mae,6);changed_pixel_ratio=[Math]::Round($ratio,6);passed=$pass}
            }
            finally { $actual.Dispose(); $expected.Dispose() }
        }
    }
    finally { $candidate.Dispose(); $source.Dispose() }
    return [pscustomobject]@{passed=$allPass;regions=$results;max_mean_absolute_error=$MaxMeanAbsoluteError;max_changed_pixel_ratio=$MaxChangedPixelRatio}
}
