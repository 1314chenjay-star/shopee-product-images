$ErrorActionPreference = 'Stop'

# Compatibility UX layer for the existing beginner menu.
# Only the legacy "press Enter to return" prompt is auto-answered.
# Every other Read-Host call is delegated to the built-in cmdlet unchanged.
function Read-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string]$Prompt,
        [switch]$AsSecureString
    )

    if ([string]$Prompt -eq '按 Enter 回主選單') {
        Start-Sleep -Milliseconds 1100
        return ''
    }

    if ($AsSecureString) {
        if ([string]::IsNullOrWhiteSpace([string]$Prompt)) {
            return Microsoft.PowerShell.Utility\Read-Host -AsSecureString
        }
        return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt -AsSecureString
    }

    if ([string]::IsNullOrWhiteSpace([string]$Prompt)) {
        return Microsoft.PowerShell.Utility\Read-Host
    }
    return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt
}

try {
    if ($null -ne $host -and $null -ne $host.UI -and $null -ne $host.UI.RawUI) {
        $host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2 | V4-A.2 Taiwan Reference Safety | API-R3-120S'
    }
}
catch {}
