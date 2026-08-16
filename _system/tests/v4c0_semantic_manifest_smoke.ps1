$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_review_manifest.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "V4-C0 semantic manifest smoke failed: $Message" }
}

function New-Product([string]$Id, [string]$Tier, [int]$Score, [int]$ImageCount) {
    $sources = @()
    for ($i=0; $i -lt $ImageCount; $i++) {
        $sources += [pscustomobject]@{ position=$i; path=('https://example.test/' + $Id + '-' + $i + '.jpg') }
    }
    return [pscustomobject]@{
        product_id=$Id
        title=('Product ' + $Id)
        route=[pscustomobject]@{ family='sports'; subfamily='ball_sports'; risk_fields=@('size','material','bundle_count') }
        review_gate=[pscustomobject]@{ risk_tier=$Tier; risk_score=$Score; review_queue=($Tier + '_QUEUE') }
        excel_only_image_actions=[object[]]$sources
    }
}

$catalog = [pscustomobject]@{
    products=@(
        (New-Product 'LOW1' 'LOW' 0 2),
        (New-Product 'HIGH1' 'HIGH' 7 3),
        (New-Product 'MED1' 'MEDIUM' 3 2),
        (New-Product 'LOCK1' 'HIGH' 9 2)
    )
}
$checkpoints = @{ 'LOCK1' = 'LOCKED_ACCEPTED' }
$m = New-V4CSemanticReviewManifest $catalog $checkpoints 3

Assert-True ($m.image_api_called -eq $false) 'manifest must never call image API.'
Assert-True ($m.image_count -eq 9) 'must include every source image exactly once.'
Assert-True ($m.pending_image_count -eq 7) 'non-locked images must remain NOT_RUN.'
Assert-True ($m.locked_image_count -eq 2) 'locked product images must be checkpoint accepted.'
Assert-True ($m.rows[0].product_id -eq 'HIGH1') 'HIGH priority must appear first.'
Assert-True ($m.rows[3].product_id -eq 'MED1') 'MEDIUM must follow HIGH.'
Assert-True ($m.rows[5].product_id -eq 'LOW1') 'LOW must follow MEDIUM.'
Assert-True ($m.rows[7].product_id -eq 'LOCK1') 'locked checkpoint must sort last and be skipped.'
Assert-True ($m.rows[0].semantic_review_state -eq 'NOT_RUN') 'manifest must not pretend pixels were reviewed.'
Assert-True ($m.rows[0].semantic_action -eq 'UNDECIDED') 'action must remain undecided before semantic review.'
Assert-True ($m.rows[0].final_paid_generation_permission -eq 'HOLD') 'pending source image may not enter paid generation.'
Assert-True ($m.rows[7].final_paid_generation_permission -eq 'NO_RERUN_LOCKED') 'locked accepted output may not rerun.'
Assert-True ($m.rows[0].batch_id -eq 'B001' -and $m.rows[3].batch_id -eq 'B002') 'batch IDs must be deterministic.'
Assert-True (@($m.rows[0].required_checks | Where-Object { $_ -eq 'product_identity' }).Count -eq 1) 'universal identity check must be present.'
Assert-True (@($m.rows[0].required_checks | Where-Object { $_ -eq 'bundle_count' }).Count -eq 1) 'route-specific risk checks must be included.'

Write-Host 'V4-C0 semantic review manifest smoke: PASS'
