$ErrorActionPreference = 'Stop'

function Get-V4BConfigJson([string]$Name) {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot ('config\' + $Name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('缺少 V4-B 設定檔：' + $Name) }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-V4BTaiwanTerms {
    return (Get-V4BConfigJson 'taiwan_terms_v4b.json')
}

function Convert-ToTaiwanCommerceTextV4B([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return [string]$Text }
    $result = [string]$Text
    $base = Get-Command Convert-ToTaiwanCommerceTextV4A2 -ErrorAction SilentlyContinue
    if ($null -ne $base) { $result = Convert-ToTaiwanCommerceTextV4A2 $result }
    $rules = Get-V4BTaiwanTerms
    foreach ($entry in @($rules.replacements | Sort-Object { ([string]$_.from).Length } -Descending)) {
        $from = [string]$entry.from
        $to = [string]$entry.to
        if (-not [string]::IsNullOrWhiteSpace($from) -and $result.Contains($from)) {
            $result = $result.Replace($from, $to)
        }
    }
    return $result
}

function Get-V4BMainlandCommerceTerms {
    $rules = Get-V4BTaiwanTerms
    return [string[]]@($rules.mainland_commerce_terms_to_avoid | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique)
}

function Test-V4BContainsMainlandCommerceTerm([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    foreach ($term in @(Get-V4BMainlandCommerceTerms)) {
        if ($Text.Contains($term)) { return $true }
    }
    return $false
}
