$ErrorActionPreference = 'Stop'

$systemRoot = Split-Path $PSScriptRoot -Parent
$workflowPath = Join-Path $systemRoot 'core\ShopeeWorkflow.psm1'

if (-not (Test-Path -LiteralPath $workflowPath)) {
    throw "找不到 Excel 處理模組：$workflowPath"
}

$content = Get-Content -LiteralPath $workflowPath -Raw -Encoding UTF8

# 相容部分 XLSX 儲存格沒有 r / t 屬性的情況。
$oldCell = '$index=Get-ColumnNumber $cell.r;$type=[string]$cell.t;'
$newCell = '$cellRefAttr=$cell.Attributes.GetNamedItem(''r'');if($null-eq$cellRefAttr){continue};$index=Get-ColumnNumber ([string]$cellRefAttr.Value);$typeAttr=$cell.Attributes.GetNamedItem(''t'');$type=if($null-ne$typeAttr){[string]$typeAttr.Value}else{''''};'
if ($content.Contains($oldCell)) {
    $content = $content.Replace($oldCell, $newCell)
}

# 蝦皮媒體 Excel 前面通常有系統代碼與說明列，真正中文標題不一定在第 1 列。
$oldHeaderStart = '$header=$rows[0];$aliases='
$newHeaderStart = '$aliases='
if ($content.Contains($oldHeaderStart)) {
    $content = $content.Replace($oldHeaderStart, $newHeaderStart)
}

$oldColumnsStart = '};$columns=@{}'
$newColumnsStart = '};$headerRowIndex=-1;$header=$null;$scanLimit=[Math]::Min($rows.Count,30);for($scanIndex=0;$scanIndex-lt$scanLimit;$scanIndex++){$candidate=$rows[$scanIndex];$foundId=$false;$foundName=$false;$foundMain=$false;foreach($candidateColumn in $candidate.Keys){$candidateText=([string]$candidate[$candidateColumn]).Trim();if($aliases.id-contains$candidateText){$foundId=$true};if($aliases.name-contains$candidateText){$foundName=$true};if($aliases.main-contains$candidateText){$foundMain=$true}};if($foundId-and$foundName-and$foundMain){$headerRowIndex=$scanIndex;$header=$candidate;break}};if($headerRowIndex-lt0){throw ''找不到必要欄位：商品ID、商品名稱、主商品圖片。已搜尋前30列，請確認這是蝦皮媒體資訊 Excel。''};$columns=@{}'
if ($content.Contains($oldColumnsStart) -and -not $content.Contains('$headerRowIndex=-1')) {
    $content = $content.Replace($oldColumnsStart, $newColumnsStart)
}

$oldDataLoop = '$products=@();for($rowIndex=1;$rowIndex-lt$rows.Count;$rowIndex++)'
$newDataLoop = '$products=@();for($rowIndex=$headerRowIndex+1;$rowIndex-lt$rows.Count;$rowIndex++)'
if ($content.Contains($oldDataLoop)) {
    $content = $content.Replace($oldDataLoop, $newDataLoop)
}

Set-Content -LiteralPath $workflowPath -Value $content -Encoding UTF8
