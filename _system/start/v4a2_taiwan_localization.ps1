$ErrorActionPreference = 'Stop'

function Get-V4A2TaiwanTerms {
    $systemRoot = Split-Path $PSScriptRoot -Parent
    $path = Join-Path $systemRoot 'config\taiwan_terms_v4a2.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw '缺少 taiwan_terms_v4a2.json' }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Convert-ToTaiwanUnitTextV4A2([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return [string]$Text }
    $result = [string]$Text
    $ignoreCase = [Text.RegularExpressions.RegexOptions]::IgnoreCase

    # Longest unit tokens first so mm/ml/kg are never partially consumed as m/l/g.
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:毫米|mm)(?![A-Za-z])', '公釐', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:厘米|cm)(?![A-Za-z])', '公分', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:千克|公斤|kg)(?![A-Za-z])', '公斤', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:毫升|ml)(?![A-Za-z])', '毫升', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:英寸|inch|in)(?![A-Za-z])', '吋', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:磅|lb)(?![A-Za-z])', '磅', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:米|m)(?![A-Za-z])', '公尺', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:克|g)(?![A-Za-z])', '公克', $ignoreCase)
    $result = [regex]::Replace($result, '(?<=\d)\s*(?:公升|升|l)(?![A-Za-z])', '公升', $ignoreCase)
    return $result
}

function Convert-ToTaiwanCommerceTextV4A2([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return [string]$Text }
    $result = Convert-ToTaiwanUnitTextV4A2 ([string]$Text)
    $rules = Get-V4A2TaiwanTerms
    foreach ($entry in @($rules.general_replacements | Sort-Object { ([string]$_.from).Length } -Descending)) {
        $from = [string]$entry.from
        $to = [string]$entry.to
        if ($from -and $result.Contains($from)) { $result = $result.Replace($from, $to) }
    }
    return $result
}

function Get-TaiwanProductLabelV4A2($Product) {
    if ($null -eq $Product) { return '' }
    $name = [string](Get-V4A1Property $Product 'product_name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { return '' }
    $rules = Get-V4A2TaiwanTerms
    foreach ($entry in @($rules.product_labels)) {
        $pattern = [string]$entry.pattern
        if ($pattern -and $name -match $pattern) { return [string]$entry.label }
    }
    return ''
}

function Get-V4A2TaiwanLengthAliases($Product, [string]$Slot) {
    if ($Slot -ne 'detail4' -or $null -eq $Product) { return [string[]]@() }
    $facts = Get-V4A1Property $Product 'verified_facts' $null
    if ($null -eq $facts) { return [string[]]@() }
    $aliases = @()
    foreach ($raw in @(Get-V4A1Property $facts 'verified_dimensions' @())) {
        $text = ([string]$raw).Trim()
        if ($text -match '^(\d+(?:\.\d+)?)\s*(?:米|m)$') {
            $meters = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            $centimeters = $meters * 100.0
            $rounded = [Math]::Round($centimeters)
            if ([Math]::Abs($centimeters - $rounded) -lt 0.000001) {
                $aliases += ('{0}公分' -f [int64]$rounded)
            }
        }
    }
    return [string[]]@($aliases | Select-Object -Unique)
}

# Localize the exact output allowlist, while leaving original structured facts unchanged on disk.
$script:V4A2TaiwanAllowedBase = (Get-Command Get-V4A2AllowedOutputText -ErrorAction Stop).ScriptBlock
function Get-V4A2AllowedOutputText($Product, [string]$Slot) {
    $raw = @(& $script:V4A2TaiwanAllowedBase $Product $Slot)
    $localized = @($raw | ForEach-Object { Convert-ToTaiwanCommerceTextV4A2 ([string]$_) } | Where-Object { $_ })
    $label = Get-TaiwanProductLabelV4A2 $Product
    if ($label) { $localized += $label }
    $localized += @(Get-V4A2TaiwanLengthAliases $Product $Slot)
    return [string[]]@($localized | Select-Object -Unique)
}

# The factual section is diagnostic/prompt text only: localize its rendered copy, not the stored source facts.
$script:V4A2TaiwanFactualBase = (Get-Command Get-FactualPromptSectionsV4A1 -ErrorAction Stop).ScriptBlock
function Get-FactualPromptSectionsV4A1($Product, [string]$Slot) {
    $base = & $script:V4A2TaiwanFactualBase $Product $Slot
    return [pscustomobject]@{
        facts = $base.facts
        allowed_factual_text = [string[]]@(@($base.allowed_factual_text) | ForEach-Object { Convert-ToTaiwanCommerceTextV4A2 ([string]$_) } | Select-Object -Unique)
        text = (Convert-ToTaiwanCommerceTextV4A2 ([string]$base.text))
    }
}

# Final wrapper: all text sent to TinySnow passes through Taiwan localization after factual/reference guards.
$script:V4A2TaiwanPromptBase = (Get-Command Get-PromptV2 -ErrorAction Stop).ScriptBlock
$script:V4A2TaiwanCompactBase = (Get-Command Get-CompactTransportPromptV2 -ErrorAction Stop).ScriptBlock

function Get-PromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A2TaiwanPromptBase $Slot $ProductOrName
    $localized = Convert-ToTaiwanCommerceTextV4A2 ([string]$base)
    return ($localized + "`n[台灣在地化硬限制]`n所有成品文字採台灣消費者自然常用說法與台灣商品名稱；單位只使用已轉換後的台灣顯示值。不得把來源資料重新翻回其他地區的用語。品牌、型號、SKU與數值事實本身不得因在地化而改義；沒有明確同義對應就保留白名單原意或少寫。")
}

function Get-CompactTransportPromptV2([string]$Slot, $ProductOrName) {
    $base = & $script:V4A2TaiwanCompactBase $Slot $ProductOrName
    $localized = Convert-ToTaiwanCommerceTextV4A2 ([string]$base)
    return ($localized + ' 所有成品文字使用台灣自然常用說法與台灣商品名稱；只使用已轉換後的台灣單位顯示值，不得改動品牌、型號、SKU或數值事實。')
}
