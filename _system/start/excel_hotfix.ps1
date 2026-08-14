$ErrorActionPreference = 'Stop'

$systemRoot = Split-Path $PSScriptRoot -Parent
$workflowPath = Join-Path $systemRoot 'core\ShopeeWorkflow.psm1'

if (-not (Test-Path -LiteralPath $workflowPath)) {
    throw "找不到 Excel 處理模組：$workflowPath"
}

$content = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8
$old = '$index=Get-ColumnNumber $cell.r;$type=[string]$cell.t;'
$new = '$cellRefAttr=$cell.Attributes.GetNamedItem(''r'');if($null-eq$cellRefAttr){continue};$index=Get-ColumnNumber ([string]$cellRefAttr.Value);$typeAttr=$cell.Attributes.GetNamedItem(''t'');$type=if($null-ne$typeAttr){[string]$typeAttr.Value}else{''''};'

if ($content.Contains($old)) {
    $content = $content.Replace($old, $new)
    Set-Content -LiteralPath $workflowPath -Value $content -Encoding UTF8
}
