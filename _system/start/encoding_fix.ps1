$ErrorActionPreference = 'Stop'

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$targets = @()
$targets += Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File
$testsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'tests'
if (Test-Path -LiteralPath $testsDir) {
    $targets += Get-ChildItem -LiteralPath $testsDir -Filter '*.ps1' -File
}

foreach ($file in $targets) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $text = $utf8NoBom.GetString($bytes)
        [IO.File]::WriteAllText($file.FullName, $text, $utf8Bom)
    }
}

exit 0
