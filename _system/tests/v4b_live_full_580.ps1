$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key=[string]$env:TINYSNOW_API_KEY
if([string]::IsNullOrWhiteSpace($key)){throw'TINYSNOW_API_KEY repository secret is missing.'}
$round='R9'
$artifactName=if([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)){'TinySnow-V4-B-Full-580-R9'}else{([string]$env:V4B_ARTIFACT_NAME).Trim()}
$outDirName='live_e2e_output_v4b_full_580_r9'
$config=[pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}
function Assert-Full580([bool]$Condition,[string]$Message){if(-not$Condition){throw('V4-B full 580 failed: '+$Message)}}

$urls=[string[]]@(
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7',
'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb')
$h=@{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1';21='et_title_option_1_for_variation_1';22='et_title_option_2_for_variation_1'}
$d=@{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='Sports & Outdoors/Basketball/Training';4=$urls[0];20='規格';21='黑色2米30磅+腰帶一組';22='黑色2米30磅+腰帶各5組'}
for($i=1;$i-lt$urls.Count;$i++){$c=4+$i;$h[$c]="ps_item_image.$i";$d[$c]=$urls[$i]}
$product=@(Convert-ShopeeRowsToProducts @($h,$d))[0]
Assert-Full580 ($null-ne$product) 'product parse failed'
Assert-Full580 ([string]$product.product_id-eq'58015741169') 'product ID changed'
Assert-Full580 ([bool]$product.multi_variant_flags.has_multiple_quantities) 'quantity conflict not detected'

$workspace=Get-V2Workspace
foreach($relative in @('checkpoints\58015741169','raw_images\58015741169','safe_refs\58015741169','api_refs\58015741169')){$p=Join-Path $workspace $relative;if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Recurse -Force}}
$finalDir=Get-GeneratedImagesDirectoryV2
foreach($slot in @('main','detail1','detail2','detail3','detail4')){$p=Join-Path $finalDir ('58015741169_'+$slot+'.jpg');Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}
$selDir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $selDir -Force|Out-Null
$product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8

$started=Get-Date
$result=Start-SingleProductOptimizationV2 $config
$elapsed=[int]((Get-Date)-$started).TotalSeconds
Assert-Full580 ([bool]$result.complete) 'full optimization did not complete'
$checkpoint=Get-CheckpointV2 '58015741169'
foreach($slot in @('main','detail1','detail2','detail3','detail4')){
    Assert-Full580 ([string]$checkpoint.states.$slot.status-eq'done') ($slot+' checkpoint is not done')
    $path=Join-Path $finalDir ('58015741169_'+$slot+'.jpg')
    Assert-Full580 ((Test-Path -LiteralPath $path -PathType Leaf)-and(Get-Item -LiteralPath $path).Length-gt10000) ($slot+' final image missing/invalid')
}
Assert-Full580 ([bool]$checkpoint.finalization_complete) 'finalization checkpoint is false'
$progress=Get-ProgressSummaryV2 $product
Assert-Full580 ([int]$progress.generated-eq5) ('expected 5 generated slots, got '+[string]$progress.generated)

$outDir=Join-Path $systemRoot $outDirName
if(Test-Path -LiteralPath $outDir){Remove-Item -LiteralPath $outDir -Recurse -Force}
New-Item -ItemType Directory -Path $outDir -Force|Out-Null
foreach($slot in @('main','detail1','detail2','detail3','detail4')){Copy-Item -LiteralPath (Join-Path $finalDir ('58015741169_'+$slot+'.jpg')) -Destination (Join-Path $outDir ('58015741169_'+$slot+'.jpg')) -Force}
$rawDir=Join-Path $workspace 'raw_images\58015741169'
foreach($name in @('analysis.json','source_plan_v4b.json')){$p=Join-Path $rawDir $name;if(Test-Path -LiteralPath $p){Copy-Item -LiteralPath $p -Destination (Join-Path $outDir $name) -Force}}
$validationPath=Join-Path $workspace 'checkpoints\58015741169\source_validation_v4b.json';if(Test-Path -LiteralPath $validationPath){Copy-Item -LiteralPath $validationPath -Destination (Join-Path $outDir 'source_validation_v4b.json') -Force}
$checkpoint|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outDir 'checkpoint_v2.json') -Encoding UTF8

$hashes=@();$tests=@();foreach($slot in @('main','detail1','detail2','detail3','detail4')){$output=Join-Path $outDir ('58015741169_'+$slot+'.jpg');$hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant();$hashes+=$hash;$tests+=[pscustomobject]@{product_id='58015741169';slot=$slot;output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;sha256=$hash}}
Assert-Full580 (@($hashes|Select-Object -Unique).Count-eq5) 'full five-image output contains exact duplicate files'
[pscustomobject]@{
    schema_version=2;version='V4-B Full 580 R9';round=$round;head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT;workflow_name=[string]$env:GITHUB_WORKFLOW;repository=[string]$env:GITHUB_REPOSITORY;
    artifact_name=$artifactName;artifact_id=$null;artifact_id_status='assigned after payload upload; see v4b_full_580_r9_artifact_receipt.json and GitHub job summary';
    output_directory=$outDirName;product_id='58015741169';full_pipeline=$true;generated_image_count=5;elapsed_seconds=$elapsed;
    checkpoint_complete=[bool]$checkpoint.finalization_complete;unique_hashes=@($hashes|Select-Object -Unique).Count;api_transport='API-R3-120S';
    tests=[object[]]$tests;visual_review_required=$true
}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $outDir 'v4b_full_580_r9_summary.json') -Encoding UTF8
Write-Host ('[PASS] V4-B Full 580 '+$round+' end-to-end pipeline completed with 5 outputs in '+$elapsed+' seconds. Visual review required.') -ForegroundColor Green
