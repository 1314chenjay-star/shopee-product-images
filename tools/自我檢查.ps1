$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'core\TinySnow.psm1') -Force
Import-Module (Join-Path $root 'core\ShopeeWorkflow.psm1') -Force
$config=Get-DefaultConfig
if($config.base_url-ne'https://tinysnow.one/v1'){throw'預設 Base URL 錯誤'}
if($config.model-ne'gpt-image-2'){throw'預設模型錯誤'}
if($config.quality-ne'medium'-or$config.size-ne'1024x1024'-or-not$config.safe_test_mode){throw'SAFE TEST MODE 預設值錯誤'}
if((Get-Endpoint $config 'images/generations')-ne'https://tinysnow.one/v1/images/generations'){throw'文生圖接口錯誤'}
if((Get-Endpoint $config 'images/edits')-ne'https://tinysnow.one/v1/images/edits'){throw'圖生圖接口錯誤'}
if((Mask-ApiKey '1234567890')-ne'1234**7890'){throw'金鑰遮罩錯誤'}
if(-not(Test-ProductId '123456789')-or(Test-ProductId '../bad')){throw'商品ID驗證錯誤'}
$reserved='\$(PID|args)\b'
foreach($scriptPath in Get-ChildItem $root -Recurse -Include *.ps1,*.psm1){$content=Get-Content $scriptPath.FullName -Raw;if($content-match$reserved){throw"發現 PowerShell 保留變數：$($scriptPath.FullName)"}}
$template=Get-Content (Join-Path $root 'config\prompt_templates.json') -Raw|ConvertFrom-Json
foreach($name in @('main_image','detail_overview','detail_structure','detail_scene','detail_spec','detail_general')){if(-not$template.$name){throw"缺少提示詞模板：$name"}}
Write-Host'自我檢查通過：設定、接口、商品ID、模板及保留變數均正常。' -ForegroundColor Green
