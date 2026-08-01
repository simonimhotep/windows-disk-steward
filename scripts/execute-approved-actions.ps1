[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanFile,
    [Parameter(Mandatory)][ValidateSet('Preflight','Execute','Rollback')][string]$Mode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows) {
    throw 'Windows PowerShell 7 or later is required.'
}

function Get-NormalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "Path must be absolute: $Path"
    }
    if ($Path.IndexOfAny([char[]]'*?[]') -ge 0 -or $Path -match '%[^%]+%' -or $Path -match '\$env:') {
        throw "Path contains a wildcard or unresolved variable: $Path"
    }
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-RequiredProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { throw "Missing required property: $Name" }
    $property.Value
}

function Get-VolumeInfoForPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$TestMode)
    $root = [IO.Path]::GetPathRoot($Path)
    if ($TestMode) {
        return [pscustomobject]@{ drive='Synthetic'; drive_type='Synthetic'; file_system='NTFS'; free_bytes=[long]::MaxValue }
    }
    $letter = $root.Substring(0,1).ToUpper()
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter`:'"
    if (-not $disk -or [int]$disk.DriveType -ne 3 -or $disk.FileSystem -ne 'NTFS') {
        throw "Path is not on a local NTFS fixed disk: $Path"
    }
    [pscustomobject]@{ drive=$letter; drive_type='Fixed'; file_system=[string]$disk.FileSystem; free_bytes=[long]$disk.FreeSpace }
}

function Get-TreeStats {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowRootReparse)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Path does not exist: $Path" }
    $rootItem = Get-Item -LiteralPath $Path -Force
    $rootIsReparse = [bool]($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($rootIsReparse -and -not $AllowRootReparse) { throw "Source is a reparse point: $Path" }
    if (-not $rootItem.PSIsContainer) {
        return [pscustomobject]@{
            entry_type='File'; is_reparse_point=$rootIsReparse; file_count=1L
            size_bytes=[long]$rootItem.Length; latest_write_utc=$rootItem.LastWriteTimeUtc.ToString('o')
            nested_reparse_points=@()
        }
    }

    $files = 0L; $bytes = 0L; $latest = $rootItem.LastWriteTimeUtc
    $links = [Collections.Generic.List[string]]::new()
    $stack = [Collections.Generic.Stack[string]]::new(); $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $links.Add($item.FullName); continue
            }
            if ($item.PSIsContainer) { $stack.Push($item.FullName); continue }
            $files++; $bytes += [long]$item.Length
            if ($item.LastWriteTimeUtc -gt $latest) { $latest = $item.LastWriteTimeUtc }
        }
    }
    [pscustomobject]@{
        entry_type='Directory'; is_reparse_point=$rootIsReparse; file_count=$files
        size_bytes=$bytes; latest_write_utc=$latest.ToString('o'); nested_reparse_points=@($links)
    }
}

function Assert-SafeScope {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Scan)
    $full = Get-NormalPath $Path
    $root = Get-NormalPath ([string]$Scan.root_path)
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or -not $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is a root or outside the scanned scope: $full"
    }

    if (-not [bool]$Scan.test_mode) {
        $driveRoot = [IO.Path]::GetPathRoot($full).TrimEnd('\')
        $profile = Get-NormalPath $env:USERPROFILE
        $protected = @(
            $driveRoot,
            (Join-Path $driveRoot 'Windows'),
            (Join-Path $driveRoot 'Users'),
            (Join-Path $driveRoot 'ProgramData'),
            $profile,
            (Join-Path $profile 'AppData'),
            (Join-Path $driveRoot 'Windows\System32'),
            (Join-Path $driveRoot 'Windows\WinSxS'),
            (Join-Path $driveRoot 'Windows\Installer'),
            (Join-Path $driveRoot '$WinREAgent'),
            (Join-Path $driveRoot 'pagefile.sys'),
            (Join-Path $driveRoot 'hiberfil.sys'),
            (Join-Path $driveRoot 'swapfile.sys')
        ) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
        if ($protected -contains $full) { throw "Protected path cannot be executed: $full" }
    }
    $full
}

function Copy-DirectoryExact {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($child in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to copy nested reparse point: $($child.FullName)"
        }
        Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force -ErrorAction Stop
    }
}

function Remove-ExactPath {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop }
    else { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    if (Test-Path -LiteralPath $Path) { throw "Removal verification failed: $Path" }
}

function Test-SameStats {
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual, [switch]$IgnoreReparse)
    $same = ([string]$Expected.entry_type -eq [string]$Actual.entry_type) -and
        ([long]$Expected.file_count -eq [long]$Actual.file_count) -and
        ([long]$Expected.size_bytes -eq [long]$Actual.size_bytes) -and
        (([datetime]$Expected.latest_write_utc).ToUniversalTime().Ticks -eq ([datetime]$Actual.latest_write_utc).ToUniversalTime().Ticks)
    if (-not $IgnoreReparse) { $same = $same -and ([bool]$Expected.is_reparse_point -eq [bool]$Actual.is_reparse_point) }
    $same
}

function Write-JsonFile {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
}

$planPath = Get-NormalPath $PlanFile
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw "Plan file does not exist: $planPath" }
$plan = Get-Content -Raw -LiteralPath $planPath | ConvertFrom-Json -Depth 20
if ([int](Get-RequiredProperty $plan 'schema_version') -ne 1) { throw 'Unsupported plan schema version.' }
$runId = [string](Get-RequiredProperty $plan 'run_id')
$scanPath = Get-NormalPath ([string](Get-RequiredProperty $plan 'scan_file'))
if (-not (Test-Path -LiteralPath $scanPath -PathType Leaf)) { throw "Referenced scan file does not exist: $scanPath" }
$scan = Get-Content -Raw -LiteralPath $scanPath | ConvertFrom-Json -Depth 20
if ([int]$scan.schema_version -ne 1 -or [string]$scan.run_id -ne $runId) { throw 'Plan and scan run_id/schema do not match.' }
if ([bool]$scan.test_mode) {
    $syntheticParent = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'windows-disk-steward-tests')).TrimEnd('\')
    $syntheticRoot = Get-NormalPath ([string]$scan.root_path)
    if (-not $syntheticRoot.StartsWith($syntheticParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Synthetic scan root is outside the dedicated test directory.'
    }
}
$actions = @((Get-RequiredProperty $plan 'actions'))
if ($actions.Count -eq 0) { throw 'The plan contains no explicitly approved actions.' }
$duplicateIds = @($actions | Group-Object id | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) { throw "The plan contains duplicate action IDs: $(@($duplicateIds.Name) -join ', ')" }

$runDirectory = Split-Path -Parent $planPath
$resultPath = Join-Path $runDirectory 'execution-result.json'
$manifestPath = Join-Path $runDirectory 'migration-manifest.json'
$result = [ordered]@{
    schema_version=1; run_id=$runId; mode=$Mode
    started_at_utc=[datetime]::UtcNow.ToString('o'); completed_at_utc=$null
    status='running'; actions=[Collections.Generic.List[object]]::new(); first_failure=$null
}
foreach ($action in $actions) {
    $result.actions.Add([pscustomobject]@{ id=[string]$action.id; type=[string]$action.type; state='not_started'; actual_bytes=0L; message=$null })
}

try {
    if ($Mode -eq 'Rollback') {
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'No migration manifest exists for rollback.' }
        $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 20
        foreach ($action in $actions) {
            $row = $result.actions | Where-Object id -eq ([string]$action.id) | Select-Object -First 1
            if ([string]$action.type -ne 'migrate') { continue }
            $record = @($manifest.migrations | Where-Object id -eq ([string]$action.id))[0]
            if (-not $record) { throw "No completed migration record for $($action.id)" }
            if ([string]$action.source_path -ne [string]$record.source_path -or [string]$action.destination_path -ne [string]$record.destination_path) {
                throw "Rollback plan and migration manifest do not match for $($action.id)"
            }
            $source = Get-NormalPath ([string]$record.source_path)
            $destination = Get-NormalPath ([string]$record.destination_path)
            $sourceItem = Get-Item -LiteralPath $source -Force
            if (-not ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Rollback source is not a Junction: $source" }
            $target = Get-NormalPath ([string]@($sourceItem.Target)[0])
            if (-not $target.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) { throw "Junction target drift for $source" }
            $destinationStats = Get-TreeStats $destination
            if ([long]$destinationStats.file_count -ne [long]$record.file_count -or [long]$destinationStats.size_bytes -ne [long]$record.size_bytes) { throw "Destination drift for $destination" }
            $stage = "$source.rollback-$runId"
            if (Test-Path -LiteralPath $stage) { throw "Rollback staging path already exists: $stage" }
            Copy-DirectoryExact $destination $stage
            $stageStats = Get-TreeStats $stage
            if ([long]$stageStats.file_count -ne [long]$record.file_count -or [long]$stageStats.size_bytes -ne [long]$record.size_bytes) { throw "Rollback copy verification failed for $source" }
            Remove-Item -LiteralPath $source -Force -ErrorAction Stop
            Move-Item -LiteralPath $stage -Destination $source -ErrorAction Stop
            $restored = Get-TreeStats $source
            if ([long]$restored.file_count -ne [long]$record.file_count -or [long]$restored.size_bytes -ne [long]$record.size_bytes) { throw "Rollback verification failed for $source" }
            $record.rollback_state = 'restored_destination_retained'
            $row.state='completed'; $row.actual_bytes=[long]$record.size_bytes; $row.message='Source restored; destination retained.'
            Write-JsonFile $manifest $manifestPath
        }
    } else {
        $validated = [Collections.Generic.List[object]]::new()
        foreach ($action in $actions) {
            $candidate = @($scan.candidates | Where-Object id -eq ([string]$action.id))[0]
            if (-not $candidate) { throw "Approved ID is absent from referenced scan: $($action.id)" }
            if ([string]$candidate.category -eq 'keep') { throw "Keep/forbidden candidate cannot execute: $($action.id)" }
            $expectedType = if ([string]$candidate.category -eq 'migrate') { 'migrate' } else { 'delete' }
            if ([string]$action.type -ne $expectedType) { throw "Action type does not match candidate: $($action.id)" }
            foreach ($field in @('fingerprint','source_path','resolved_source_path','entry_type','is_reparse_point','file_count','size_bytes','latest_write_utc')) {
                $actionValue = Get-RequiredProperty $action $field
                $candidateField = if ($field -eq 'source_path') { 'path' } elseif ($field -eq 'resolved_source_path') { 'resolved_path' } else { $field }
                if ([string]$actionValue -ne [string]$candidate.$candidateField) { throw "Action snapshot mismatch for $($action.id): $field" }
            }
            $source = Assert-SafeScope ([string]$action.source_path) $scan
            $sourceStats = Get-TreeStats $source
            if ($sourceStats.nested_reparse_points.Count -gt 0) { throw "Nested reparse point found under approved source: $source" }
            if (-not (Test-SameStats $action $sourceStats)) {
                $expectedLatest = ([datetime]$action.latest_write_utc).ToUniversalTime().ToString('o')
                $actualLatest = ([datetime]$sourceStats.latest_write_utc).ToUniversalTime().ToString('o')
                $expectedSummary = "type=$($action.entry_type),link=$($action.is_reparse_point),files=$($action.file_count),bytes=$($action.size_bytes),latest=$expectedLatest"
                $actualSummary = "type=$($sourceStats.entry_type),link=$($sourceStats.is_reparse_point),files=$($sourceStats.file_count),bytes=$($sourceStats.size_bytes),latest=$actualLatest"
                throw "Source snapshot drift: $source; expected {$expectedSummary}; actual {$actualSummary}"
            }
            $required = @((Get-RequiredProperty $action 'required_processes_stopped'))
            foreach ($processName in $required) {
                if (Get-Process -Name $processName -ErrorAction SilentlyContinue) { throw "Required process is running: $processName" }
            }
            Get-VolumeInfoForPath $source -TestMode:([bool]$scan.test_mode) | Out-Null

            $destination = $null
            if ([string]$action.type -eq 'migrate') {
                if ([string]$action.entry_type -ne 'Directory') { throw 'Migration supports directories only.' }
                $destination = Get-NormalPath ([string](Get-RequiredProperty $action 'destination_path'))
                $destinationRoot = Get-NormalPath ([string](Get-RequiredProperty $action 'destination_root'))
                if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) { throw "Destination root does not exist: $destinationRoot" }
                $destinationRootItem = Get-Item -LiteralPath $destinationRoot -Force
                if ($destinationRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Destination root cannot be a reparse point: $destinationRoot" }
                if (-not $destination.StartsWith($destinationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Destination escapes approved root: $destination" }
                if ($destination.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Destination cannot be inside source.' }
                if (Test-Path -LiteralPath $destination) { throw "Destination already exists: $destination" }
                $sourceVolume = Get-VolumeInfoForPath $source -TestMode:([bool]$scan.test_mode)
                $destinationVolume = Get-VolumeInfoForPath $destinationRoot -TestMode:([bool]$scan.test_mode)
                if (-not [bool]$scan.test_mode -and $sourceVolume.drive -eq $destinationVolume.drive) { throw 'Production migration must target another drive.' }
                if ([long]$destinationVolume.free_bytes -lt ([long]$action.size_bytes + 1GB)) { throw 'Destination lacks the required free space and 1 GiB safety margin.' }
            }
            $validated.Add([pscustomobject]@{ action=$action; source=$source; source_stats=$sourceStats; destination=$destination })
        }

        if ($Mode -eq 'Execute') {
            $manifest = if (Test-Path -LiteralPath $manifestPath) { Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 20 } else { [pscustomobject]@{ schema_version=1; run_id=$runId; migrations=[Collections.Generic.List[object]]::new() } }
            foreach ($validatedAction in $validated) {
                $action = $validatedAction.action
                $row = $result.actions | Where-Object id -eq ([string]$action.id) | Select-Object -First 1
                $row.state = 'running'
                if ([string]$action.type -eq 'delete') {
                    Remove-ExactPath $validatedAction.source
                    $row.state='completed'; $row.actual_bytes=[long]$action.size_bytes; $row.message='Exact approved path deleted.'
                    continue
                }

                $source = $validatedAction.source; $destination = $validatedAction.destination
                Copy-DirectoryExact $source $destination
                $copyStats = Get-TreeStats $destination
                if ([long]$copyStats.file_count -ne [long]$action.file_count -or [long]$copyStats.size_bytes -ne [long]$action.size_bytes) { throw "Migration copy verification failed: $source" }
                Remove-ExactPath $source
                try {
                    New-Item -ItemType Junction -Path $source -Target $destination -ErrorAction Stop | Out-Null
                    $junction = Get-Item -LiteralPath $source -Force
                    $target = Get-NormalPath ([string]@($junction.Target)[0])
                    if (-not $target.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) { throw 'Junction target verification failed.' }
                    $throughSource = Get-TreeStats $source -AllowRootReparse
                    if ([long]$throughSource.file_count -ne [long]$action.file_count -or [long]$throughSource.size_bytes -ne [long]$action.size_bytes) { throw 'Junction data verification failed.' }
                } catch {
                    if (Test-Path -LiteralPath $source) {
                        $sourceItem = Get-Item -LiteralPath $source -Force
                        if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue }
                    }
                    if (-not (Test-Path -LiteralPath $source)) { Copy-DirectoryExact $destination $source }
                    $restored = Get-TreeStats $source
                    if ([long]$restored.file_count -ne [long]$action.file_count -or [long]$restored.size_bytes -ne [long]$action.size_bytes) { throw "Junction failed and source restoration could not be verified: $source" }
                    throw "Junction failed; source was restored and destination retained: $($_.Exception.Message)"
                }
                $record = [pscustomobject]@{
                    id=[string]$action.id; source_path=$source; destination_path=$destination
                    junction_target=$destination; file_count=[long]$action.file_count; size_bytes=[long]$action.size_bytes
                    completed_at_utc=[datetime]::UtcNow.ToString('o'); rollback_state='not_requested'
                }
                $manifest.migrations.Add($record)
                Write-JsonFile $manifest $manifestPath
                $row.state='completed'; $row.actual_bytes=[long]$action.size_bytes; $row.message='Migrated and verified through Junction.'
            }
        } else {
            foreach ($row in $result.actions) { $row.state='completed'; $row.message='Preflight passed; no data changed.' }
        }
    }
    $result.status='completed'
} catch {
    $result.status='failed'; $result.first_failure=$_.Exception.Message
    $running = $result.actions | Where-Object state -eq 'running' | Select-Object -First 1
    if ($running) { $running.state='failed'; $running.message=$_.Exception.Message }
    throw
} finally {
    $result.completed_at_utc=[datetime]::UtcNow.ToString('o')
    Write-JsonFile $result $resultPath
}

$result
