[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scanner = Join-Path $PSScriptRoot 'scan-windows-disk.ps1'
$executor = Join-Path $PSScriptRoot 'execute-approved-actions.ps1'
$testParent = Join-Path ([IO.Path]::GetTempPath()) 'windows-disk-steward-tests'
$testBase = Join-Path $testParent ([guid]::NewGuid().ToString('N'))
$passed = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:passed.Add($Message)
}

function New-SyntheticRoot {
    param([Parameter(Mandatory)][string]$Path)
    $dirs = @(
        'Users\TestUser\AppData\Local\CrashDumps',
        'Users\TestUser\AppData\Local\npm-cache',
        'Users\TestUser\AppData\Local\Google\Chrome\User Data\Default\Service Worker\CacheStorage',
        'Users\TestUser\Documents',
        'Users\TestUser\AppData\Local\.simulated-access-denied',
        'Windows', 'ProgramData', 'link-target'
    )
    foreach ($dir in $dirs) { New-Item -ItemType Directory -Path (Join-Path $Path $dir) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $Path 'Users\TestUser\AppData\Local\CrashDumps\old.dmp') -Value 'crash-data' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'Users\TestUser\AppData\Local\npm-cache\package.bin') -Value ('n' * 200) -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'Users\TestUser\AppData\Local\Google\Chrome\User Data\Default\Service Worker\CacheStorage\offline.bin') -Value 'offline' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'Users\TestUser\Documents\keep.txt') -Value 'must remain' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'Users\TestUser\AppData\Local\.simulated-access-denied\secret.txt') -Value 'unreadable simulation' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'Windows\system.dat') -Value 'protected' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Path 'link-target\target.txt') -Value 'linked' -Encoding utf8
    New-Item -ItemType Junction -Path (Join-Path $Path 'Users\TestUser\linked-cache') -Target (Join-Path $Path 'link-target') | Out-Null
}

function Get-TreeDigest {
    param([Parameter(Mandatory)][string]$Path)
    $rows = [Collections.Generic.List[string]]::new()
    $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force)) {
            $relative = [IO.Path]::GetRelativePath($Path, $item.FullName)
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $rows.Add("L|$relative|$(@($item.Target) -join ',')"); continue
            }
            if ($item.PSIsContainer) { $rows.Add("D|$relative"); $stack.Push($item.FullName); continue }
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $rows.Add("F|$relative|$($item.Length)|$hash")
        }
    }
    $material = @($rows | Sort-Object) -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($material)
    ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Invoke-Scan {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Run)
    & pwsh -NoProfile -File $scanner -Drive C -RunDirectory $Run -Language zh-CN -TestRoot $Root | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Scanner exited with code $LASTEXITCODE" }
    Get-Content -Raw -LiteralPath (Join-Path $Run 'scan.json') | ConvertFrom-Json -Depth 20
}

function New-Action {
    param([Parameter(Mandatory)]$Candidate, [Parameter(Mandatory)][ValidateSet('delete','migrate')][string]$Type, [string]$Destination, [string]$DestinationRoot)
    $action = [ordered]@{
        id=[string]$Candidate.id; type=$Type; fingerprint=[string]$Candidate.fingerprint
        source_path=[string]$Candidate.path; resolved_source_path=[string]$Candidate.resolved_path
        entry_type=[string]$Candidate.entry_type; is_reparse_point=[bool]$Candidate.is_reparse_point
        file_count=[long]$Candidate.file_count; size_bytes=[long]$Candidate.size_bytes
        latest_write_utc=([datetime]$Candidate.latest_write_utc).ToUniversalTime().ToString('o'); required_processes_stopped=@()
    }
    if ($Type -eq 'migrate') { $action.destination_path=$Destination; $action.destination_root=$DestinationRoot }
    [pscustomobject]$action
}

function Write-Plan {
    param([Parameter(Mandatory)]$Scan, [Parameter(Mandatory)][string]$Run, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Actions, [string]$RunId)
    $id = if ($RunId) { $RunId } else { [string]$Scan.run_id }
    $plan = [ordered]@{
        schema_version=1; run_id=$id; scan_file=(Join-Path $Run 'scan.json')
        approved_at_utc=[datetime]::UtcNow.ToString('o'); actions=@($Actions)
    }
    $path = Join-Path $Run 'approved-actions.json'
    $plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8
    $path
}

function Invoke-ExecutorSuccess {
    param([Parameter(Mandatory)][string]$Plan, [Parameter(Mandatory)][string]$Mode)
    & pwsh -NoProfile -File $executor -PlanFile $Plan -Mode $Mode | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Executor $Mode exited with code $LASTEXITCODE" }
}

function Invoke-ExecutorFailure {
    param([Parameter(Mandatory)][string]$Plan, [Parameter(Mandatory)][string]$Mode)
    $output = & pwsh -NoProfile -File $executor -PlanFile $Plan -Mode $Mode 2>&1
    if ($LASTEXITCODE -eq 0) { throw "Executor $Mode unexpectedly succeeded: $output" }
}

try {
    New-Item -ItemType Directory -Path $testBase -Force | Out-Null

    $root1 = Join-Path $testBase 'disk-one'; $run1 = Join-Path $testBase 'run-one'
    New-SyntheticRoot $root1
    $before = Get-TreeDigest $root1
    $scan1 = Invoke-Scan $root1 $run1
    $after = Get-TreeDigest $root1
    Assert-True ($before -eq $after) 'Read-only scan leaves the synthetic disk unchanged'
    Assert-True (@($scan1.skipped_paths | Where-Object reason -eq 'ReparsePoint').Count -ge 1) 'Scanner records and skips reparse points'
    Assert-True (@($scan1.skipped_paths | Where-Object reason -eq 'SimulatedAccessDenied').Count -eq 1) 'Scanner records inaccessible-directory handling in test mode'
    Assert-True (($scan1.coverage.directories_attempted - $scan1.coverage.directories_scanned) -eq $scan1.coverage.directories_skipped) 'Directory coverage denominator and skipped-directory count are consistent'
    Assert-True (@($scan1.candidates | Where-Object category -eq 'delete').Count -ge 1) 'Scanner emits suggested-deletion candidates'
    Assert-True (@($scan1.candidates | Where-Object category -eq 'caution').Count -ge 1) 'Scanner emits caution candidates'
    Assert-True (@($scan1.candidates | Where-Object category -eq 'keep').Count -ge 1) 'Scanner emits keep candidates'
    Assert-True (@($scan1.candidates | Where-Object category -eq 'migrate').Count -ge 1) 'Scanner emits migration candidates'
    $reportText = Get-Content -Raw -LiteralPath (Join-Path $run1 'report.md')
    Assert-True ($reportText -match '副作用' -and $reportText -match '需关闭进程' -and $reportText -match '指纹') 'Chinese report includes approval-critical columns'
    Assert-True ($reportText -match '批准前必须选择精确目标路径' -and $reportText -match '\| 低 \|') 'Chinese report localizes risk and marks migration destination as unselected'

    $deleteCandidate = $scan1.candidates | Where-Object { $_.category -eq 'delete' -and $_.path -like '*CrashDumps' } | Select-Object -First 1
    $deleteAction = New-Action $deleteCandidate delete
    $deletePlan = Write-Plan $scan1 $run1 @($deleteAction)
    Invoke-ExecutorSuccess $deletePlan Preflight
    Assert-True (Test-Path -LiteralPath $deleteCandidate.path) 'Preflight makes no data change'
    Invoke-ExecutorSuccess $deletePlan Execute
    Assert-True (-not (Test-Path -LiteralPath $deleteCandidate.path)) 'Exact approved delete removes only its source'
    Assert-True (Test-Path -LiteralPath (Join-Path $root1 'Users\TestUser\Documents\keep.txt')) 'Unapproved personal file remains after deletion'
    Assert-True (Test-Path -LiteralPath (Join-Path $root1 'Users\TestUser\AppData\Local\npm-cache')) 'Unapproved migration source remains after deletion'

    $emptyPlan = Write-Plan $scan1 $run1 @()
    Invoke-ExecutorFailure $emptyPlan Preflight
    Assert-True $true 'Executor rejects a plan with no approved actions'

    $keepCandidate = $scan1.candidates | Where-Object category -eq 'keep' | Select-Object -First 1
    $keepAction = New-Action $keepCandidate delete
    $keepPlan = Write-Plan $scan1 $run1 @($keepAction)
    Invoke-ExecutorFailure $keepPlan Preflight
    Assert-True $true 'Executor rejects protected keep candidates and broad roots'

    $wildAction = New-Action ($scan1.candidates | Where-Object category -eq 'migrate' | Select-Object -First 1) migrate (Join-Path $testBase 'wild-dest\item') (Join-Path $testBase 'wild-dest')
    $wildAction.source_path = "$($wildAction.source_path)*"
    New-Item -ItemType Directory -Path (Join-Path $testBase 'wild-dest') -Force | Out-Null
    $wildPlan = Write-Plan $scan1 $run1 @($wildAction)
    Invoke-ExecutorFailure $wildPlan Preflight
    Assert-True $true 'Executor rejects wildcard or tampered paths'

    $staleAction = New-Action ($scan1.candidates | Where-Object category -eq 'migrate' | Select-Object -First 1) migrate (Join-Path $testBase 'stale-dest\item') (Join-Path $testBase 'stale-dest')
    New-Item -ItemType Directory -Path (Join-Path $testBase 'stale-dest') -Force | Out-Null
    $stalePlan = Write-Plan $scan1 $run1 @($staleAction) 'stale-run-id'
    Invoke-ExecutorFailure $stalePlan Preflight
    Assert-True $true 'Executor rejects a stale run_id'

    $root2 = Join-Path $testBase 'disk-two'; $run2 = Join-Path $testBase 'run-two'
    New-SyntheticRoot $root2
    $scan2 = Invoke-Scan $root2 $run2
    $driftCandidate = $scan2.candidates | Where-Object { $_.category -eq 'delete' -and $_.path -like '*CrashDumps' } | Select-Object -First 1
    $driftAction = New-Action $driftCandidate delete
    $driftPlan = Write-Plan $scan2 $run2 @($driftAction)
    Add-Content -LiteralPath (Join-Path $driftCandidate.path 'old.dmp') -Value 'changed-after-scan'
    Invoke-ExecutorFailure $driftPlan Preflight
    Assert-True (Test-Path -LiteralPath $driftCandidate.path) 'Snapshot drift stops before deletion and preserves source'

    $destinationRoot = Join-Path $testBase 'migration-destination'
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
    $migrationCandidate = $scan1.candidates | Where-Object { $_.category -eq 'migrate' -and $_.path -like '*npm-cache' } | Select-Object -First 1
    $destination = Join-Path $destinationRoot 'npm-cache'
    $migrationAction = New-Action $migrationCandidate migrate $destination $destinationRoot
    $migrationPlan = Write-Plan $scan1 $run1 @($migrationAction)
    Invoke-ExecutorSuccess $migrationPlan Preflight
    Invoke-ExecutorSuccess $migrationPlan Execute
    $junction = Get-Item -LiteralPath $migrationCandidate.path -Force
    Assert-True ([bool]($junction.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Migration replaces source with a Junction'
    Assert-True (([IO.Path]::GetFullPath([string]@($junction.Target)[0])).TrimEnd('\') -eq ([IO.Path]::GetFullPath($destination)).TrimEnd('\')) 'Junction targets the exact approved destination'
    Assert-True (Test-Path -LiteralPath (Join-Path $migrationCandidate.path 'package.bin')) 'Migrated data remains readable through the original path'
    Assert-True (Test-Path -LiteralPath (Join-Path $root1 'Users\TestUser\Documents\keep.txt')) 'Migration leaves unapproved paths unchanged'

    Invoke-ExecutorSuccess $migrationPlan Rollback
    $restored = Get-Item -LiteralPath $migrationCandidate.path -Force
    Assert-True (-not [bool]($restored.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Rollback restores a normal source directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $migrationCandidate.path 'package.bin')) 'Rollback restores source data'
    Assert-True (Test-Path -LiteralPath (Join-Path $destination 'package.bin')) 'Rollback retains the destination copy'

    $root3 = Join-Path $testBase 'disk-three'; $run3 = Join-Path $testBase 'run-three'
    New-SyntheticRoot $root3
    $scan3 = Invoke-Scan $root3 $run3
    $failureCandidate = $scan3.candidates | Where-Object { $_.category -eq 'migrate' -and $_.path -like '*npm-cache' } | Select-Object -First 1
    $failureRoot = Join-Path $testBase 'existing-destination'; $failureDestination = Join-Path $failureRoot 'npm-cache'
    New-Item -ItemType Directory -Path $failureDestination -Force | Out-Null
    $failureAction = New-Action $failureCandidate migrate $failureDestination $failureRoot
    $failurePlan = Write-Plan $scan3 $run3 @($failureAction)
    Invoke-ExecutorFailure $failurePlan Execute
    Assert-True (Test-Path -LiteralPath (Join-Path $failureCandidate.path 'package.bin')) 'Failed migration preserves all source data'

    [pscustomobject]@{ status='passed'; tests=$passed.Count; assertions=@($passed) }
} finally {
    $resolvedBase = [IO.Path]::GetFullPath($testBase).TrimEnd('\')
    $resolvedParent = [IO.Path]::GetFullPath($testParent).TrimEnd('\') + '\'
    if ($resolvedBase.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedBase)) {
        Remove-Item -LiteralPath $resolvedBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}
