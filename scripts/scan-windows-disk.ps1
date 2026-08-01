[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')][string]$Drive = 'C',
    [Parameter(Mandatory)][string]$RunDirectory,
    [ValidatePattern('^[A-Za-z]$')][string]$TargetDrive,
    [ValidateSet('zh-CN', 'en-US')][string]$Language = 'zh-CN',
    [string]$TestRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Windows PowerShell 7 or later is required.'
}
if (-not $IsWindows) {
    throw 'This skill supports Windows only.'
}

function Get-NormalPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "Path must be absolute: $Path"
    }
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Get-VolumeInfo {
    param([Parameter(Mandatory)][string]$Letter)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Letter.ToUpper()):'"
    if (-not $disk) { throw "Drive does not exist: $Letter`:" }
    if ([int]$disk.DriveType -ne 3) { throw "Drive is not a local fixed disk: $Letter`:" }
    if ($disk.FileSystem -ne 'NTFS') { throw "Drive is not NTFS: $Letter`:" }
    [pscustomobject]@{
        drive       = $Letter.ToUpper()
        drive_type  = 'Fixed'
        file_system = [string]$disk.FileSystem
        size_bytes  = [long]$disk.Size
        free_bytes  = [long]$disk.FreeSpace
    }
}

function Add-Spec {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$List,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Risk,
        [Parameter(Mandatory)][string]$Recommendation,
        [string[]]$Evidence = @(),
        [string[]]$SideEffects = @(),
        [string[]]$Processes = @()
    )
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (@($List | Where-Object { $_.path -eq $full }).Count -gt 0) { return }
    $List.Add([pscustomobject]@{
        category = $Category; path = $full; risk = $Risk
        recommendation = $Recommendation; evidence = @($Evidence)
        side_effects = @($SideEffects); required_processes_stopped = @($Processes)
        file_count = 0L; size_bytes = 0L; latest_write_utc = $null
    })
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    ([Convert]::ToHexString($hash)).ToLowerInvariant()
}

function Get-InstalledApplications {
    if ($script:TestMode) { return @() }
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @($roots | ForEach-Object {
        Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue
    } | Where-Object DisplayName | Select-Object @{n='name';e={$_.DisplayName}},
        @{n='version';e={$_.DisplayVersion}}, @{n='publisher';e={$_.Publisher}},
        @{n='install_location';e={$_.InstallLocation}} | Sort-Object name, version -Unique)
}

function Get-UpdateState {
    if ($script:TestMode) {
        return [pscustomobject]@{ reboot_pending = $false; winre_agent_present = $false; evidence = @('Synthetic test mode') }
    }
    $evidence = [Collections.Generic.List[string]]::new()
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) { $evidence.Add($key) }
    }
    $rename = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($rename) { $evidence.Add('PendingFileRenameOperations') }
    $winre = Test-Path -LiteralPath (Join-Path $script:RootPath '$WinREAgent')
    if ($winre) { $evidence.Add('$WinREAgent exists') }
    [pscustomobject]@{ reboot_pending = ($evidence.Count -gt 0); winre_agent_present = $winre; evidence = @($evidence) }
}

function Get-RelevantProcesses {
    if ($script:TestMode) { return @() }
    $names = @('msedge','chrome','Code','Cursor','LM Studio','Kimi','Obsidian','Notion','node','npm','python','uv')
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $names -contains $_.ProcessName } |
        Select-Object @{n='name';e={$_.ProcessName}}, @{n='id';e={$_.Id}}, @{n='path';e={try {$_.Path} catch {$null}}} |
        Sort-Object name, id)
}

$Drive = $Drive.ToUpper()
$script:TestMode = -not [string]::IsNullOrWhiteSpace($TestRoot)
$runPath = Get-NormalPath $RunDirectory

if ($script:TestMode) {
    $script:RootPath = Get-NormalPath $TestRoot
    $syntheticParent = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'windows-disk-steward-tests')).TrimEnd('\')
    if (-not $script:RootPath.StartsWith($syntheticParent + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "TestRoot must be a child of the dedicated synthetic-test directory: $syntheticParent"
    }
    if ($runPath.Equals($script:RootPath, [StringComparison]::OrdinalIgnoreCase) -or $runPath.StartsWith($script:RootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RunDirectory must be outside TestRoot so scan-only integrity can be verified.'
    }
    if (-not (Test-Path -LiteralPath $script:RootPath -PathType Container)) {
        throw "Synthetic test root does not exist: $script:RootPath"
    }
    $volume = [pscustomobject]@{ drive = $Drive; drive_type = 'Synthetic'; file_system = 'NTFS'; size_bytes = 0L; free_bytes = 0L }
    $profileRoot = Join-Path $script:RootPath 'Users\TestUser'
    $programDataRoot = Join-Path $script:RootPath 'ProgramData'
    $windowsRoot = Join-Path $script:RootPath 'Windows'
} else {
    $script:RootPath = "$Drive`:\"
    $volume = Get-VolumeInfo $Drive
    $profileRoot = if ($Drive -eq $env:SystemDrive.TrimEnd(':')) { $env:USERPROFILE } else { Join-Path $script:RootPath "Users\$env:USERNAME" }
    $programDataRoot = Join-Path $script:RootPath 'ProgramData'
    $windowsRoot = Join-Path $script:RootPath 'Windows'
}

$targetVolume = $null
if ($TargetDrive) {
    if ($script:TestMode) {
        $targetVolume = [pscustomobject]@{ drive = $TargetDrive.ToUpper(); drive_type = 'Synthetic'; file_system = 'NTFS'; size_bytes = 0L; free_bytes = 0L }
    } else {
        $targetVolume = Get-VolumeInfo $TargetDrive
    }
}

$specs = [Collections.Generic.List[object]]::new()
Add-Spec $specs delete (Join-Path $profileRoot 'AppData\Local\CrashDumps') low delete @('Windows crash dump staging') @('Crash diagnostics will no longer be available')
Add-Spec $specs delete (Join-Path $profileRoot 'AppData\Local\SquirrelTemp') low delete @('Application installer staging') @('A future update may recreate it')
Add-Spec $specs migrate (Join-Path $profileRoot 'AppData\Local\npm-cache') medium migrate @('Continuously growing reproducible development cache') @('Use npm configuration or a compatibility Junction') @('node','npm')
Add-Spec $specs migrate (Join-Path $profileRoot 'AppData\Local\pip\Cache') medium migrate @('Continuously growing reproducible development cache') @('Use pip cache configuration or a compatibility Junction') @('python')
Add-Spec $specs migrate (Join-Path $profileRoot 'AppData\Local\uv\cache') medium migrate @('Continuously growing reproducible development cache') @('Use UV_CACHE_DIR or a compatibility Junction') @('uv')
Add-Spec $specs migrate (Join-Path $profileRoot 'AppData\Local\electron\Cache') medium migrate @('Continuously growing Electron download cache') @('Use ELECTRON_CACHE or a compatibility Junction')
Add-Spec $specs migrate (Join-Path $profileRoot '.lmstudio\extensions') medium migrate @('Large application runtime and extension store') @('LM Studio must be closed') @('LM Studio')
Add-Spec $specs migrate (Join-Path $profileRoot '.vscode\extensions') medium migrate @('Large editor extension store') @('VS Code must be closed') @('Code')
Add-Spec $specs migrate (Join-Path $profileRoot 'AppData\Roaming\npm') medium migrate @('Installed global tools, not disposable cache') @('Preserve PATH compatibility') @('node','npm')
Add-Spec $specs migrate (Join-Path $profileRoot '.paseo\models') medium migrate @('Large local model store') @('Paseo must be closed') @('paseo')

foreach ($browser in @(
    @{ Base = 'AppData\Local\Google\Chrome\User Data\Default'; Process = 'chrome' },
    @{ Base = 'AppData\Local\Microsoft\Edge\User Data\Default'; Process = 'msedge' }
)) {
    foreach ($suffix in @('Cache','Code Cache','GPUCache','Service Worker\CacheStorage')) {
        Add-Spec $specs caution (Join-Path $profileRoot (Join-Path $browser.Base $suffix)) high review @('Browser-managed cache or site storage') @('May sign out sites, remove offline data, or be recreated') @($browser.Process)
    }
}
Add-Spec $specs caution (Join-Path $profileRoot 'AppData\Local\Temp') high review @('Shared user temporary directory') @('May contain active installer or update files')
Add-Spec $specs caution (Join-Path $profileRoot 'AppData\Local\ms-playwright') medium review @('Automation browser runtime') @('Tools may need to download it again')
Add-Spec $specs caution (Join-Path $windowsRoot 'Temp') high review @('Windows-managed temporary directory') @('Requires update and process checks')
Add-Spec $specs caution (Join-Path $windowsRoot 'SoftwareDistribution\Download') high review @('Windows Update working directory') @('Do not touch during an update or pending reboot')
Add-Spec $specs caution (Join-Path $script:RootPath '$WinREAgent') high review @('Windows recovery/update working directory') @('Can be required for update rollback')

if (Test-Path -LiteralPath (Join-Path $profileRoot 'AppData\Local')) {
    Get-ChildItem -LiteralPath (Join-Path $profileRoot 'AppData\Local') -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object Name -Like '*-updater' | ForEach-Object {
            Add-Spec $specs caution $_.FullName medium review @('Application updater directory') @('Confirm the installed version works before removal')
        }
}

Add-Spec $specs keep $windowsRoot critical keep @('Protected Windows system directory') @('Manual deletion can make Windows unbootable')
Add-Spec $specs keep (Join-Path $script:RootPath 'Users') critical keep @('Broad user-data root') @('Contains personal and application data')
Add-Spec $specs keep $profileRoot critical keep @('User-profile root') @('Contains personal and application data')
Add-Spec $specs keep (Join-Path $profileRoot 'AppData') critical keep @('Broad application-data root') @('Never delete or migrate as a whole')
Add-Spec $specs keep $programDataRoot critical keep @('Shared application-data root') @('Never delete as a whole')
foreach ($name in @('pagefile.sys','hiberfil.sys','swapfile.sys')) {
    Add-Spec $specs keep (Join-Path $script:RootPath $name) critical keep @('Windows-managed system file') @('Never delete manually')
}

$top = @{}
$largest = [Collections.Generic.List[object]]::new()
$skipped = [Collections.Generic.List[object]]::new()
$stack = [Collections.Generic.Stack[string]]::new()
$stack.Push($script:RootPath)
$attempted = 0L; $scannedDirs = 0L; $filesScanned = 0L; $bytesScanned = 0L

while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    $attempted++
    if ($script:TestMode -and [IO.Path]::GetFileName($dir) -eq '.simulated-access-denied') {
        $skipped.Add([pscustomobject]@{ path = $dir; entry_type = 'Directory'; reason = 'SimulatedAccessDenied' })
        continue
    }
    try {
        $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        $scannedDirs++
    } catch {
        $skipped.Add([pscustomobject]@{ path = $dir; entry_type = 'Directory'; reason = $_.Exception.GetType().Name })
        continue
    }

    foreach ($item in $items) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $entryType = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
            if ($item.PSIsContainer) { $attempted++ }
            $skipped.Add([pscustomobject]@{ path = $item.FullName; entry_type = $entryType; reason = 'ReparsePoint' })
            continue
        }
        if ($item.PSIsContainer) {
            if ($item.FullName.TrimEnd('\') -ne $runPath) { $stack.Push($item.FullName) }
            continue
        }

        $filesScanned++; $length = [long]$item.Length; $bytesScanned += $length
        $relative = [IO.Path]::GetRelativePath($script:RootPath, $item.FullName)
        $first = $relative.Split([IO.Path]::DirectorySeparatorChar)[0]
        $topPath = if ($relative -eq $first) { Join-Path $script:RootPath '[root files]' } else { Join-Path $script:RootPath $first }
        if (-not $top.ContainsKey($topPath)) { $top[$topPath] = [pscustomobject]@{ path=$topPath; file_count=0L; size_bytes=0L; latest_write_utc=$null } }
        $bucket = $top[$topPath]; $bucket.file_count++; $bucket.size_bytes += $length
        if (-not $bucket.latest_write_utc -or $item.LastWriteTimeUtc -gt [datetime]$bucket.latest_write_utc) { $bucket.latest_write_utc = $item.LastWriteTimeUtc.ToString('o') }

        $largest.Add([pscustomobject]@{ path=$item.FullName; size_bytes=$length; modified_utc=$item.LastWriteTimeUtc.ToString('o') })
        if ($largest.Count -gt 60) {
            $trimmed = @($largest | Sort-Object size_bytes -Descending | Select-Object -First 50)
            $largest.Clear(); foreach ($row in $trimmed) { $largest.Add($row) }
        }

        foreach ($spec in $specs) {
            $prefix = $spec.path.TrimEnd('\') + '\'
            if ($item.FullName.Equals($spec.path, [StringComparison]::OrdinalIgnoreCase) -or $item.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $spec.file_count++; $spec.size_bytes += $length
                if (-not $spec.latest_write_utc -or $item.LastWriteTimeUtc -gt [datetime]$spec.latest_write_utc) { $spec.latest_write_utc = $item.LastWriteTimeUtc.ToString('o') }
            }
        }
    }
}

$existing = [Collections.Generic.List[object]]::new()
foreach ($spec in $specs) {
    if (-not (Test-Path -LiteralPath $spec.path)) { continue }
    $item = Get-Item -LiteralPath $spec.path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $entryType = if ($item.PSIsContainer) { 'Directory' } else { 'File' }
    if (-not $spec.latest_write_utc -or $item.LastWriteTimeUtc -gt [datetime]$spec.latest_write_utc) {
        $spec.latest_write_utc = $item.LastWriteTimeUtc.ToString('o')
    }
    $existing.Add([pscustomobject]@{
        id = $null; category = $spec.category; path = $spec.path; resolved_path = $spec.path
        entry_type = $entryType; is_reparse_point = $false; file_count = [long]$spec.file_count
        size_bytes = [long]$spec.size_bytes; latest_write_utc = $spec.latest_write_utc
        risk = $spec.risk; recommendation = $spec.recommendation; evidence = @($spec.evidence)
        side_effects = @($spec.side_effects); required_processes_stopped = @($spec.required_processes_stopped)
        fingerprint = $null
    })
}

$prefixes = @{ delete='D'; caution='C'; keep='K'; migrate='M' }
$orderedCandidates = [Collections.Generic.List[object]]::new()
foreach ($category in @('delete','caution','keep','migrate')) {
    $number = 0
    foreach ($candidate in @($existing | Where-Object category -eq $category | Sort-Object path)) {
        $number++
        $candidate.id = '{0}{1:D2}' -f $prefixes[$category], $number
        $material = @($candidate.id,$candidate.category,$candidate.path,$candidate.entry_type,$candidate.file_count,$candidate.size_bytes,$candidate.latest_write_utc) -join '|'
        $candidate.fingerprint = Get-Sha256 $material
        $orderedCandidates.Add($candidate)
    }
}

$coveragePercent = if ($attempted -eq 0) { 100.0 } else { [math]::Round(($scannedDirs * 100.0) / $attempted, 2) }
$skippedDirectories = @($skipped | Where-Object entry_type -eq 'Directory').Count
$runId = '{0}-{1}' -f ([datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')), ([guid]::NewGuid().ToString('N').Substring(0,8))
$result = [ordered]@{
    schema_version = 1
    run_id = $runId
    scanned_at_utc = [datetime]::UtcNow.ToString('o')
    drive = $Drive
    root_path = $script:RootPath
    test_mode = $script:TestMode
    language = $Language
    volume = $volume
    target_volume = $targetVolume
    coverage = [ordered]@{
        directories_attempted = $attempted; directories_scanned = $scannedDirs
        directories_skipped = $skippedDirectories; coverage_percent = $coveragePercent
        files_scanned = $filesScanned; bytes_scanned = $bytesScanned
    }
    skipped_paths = @($skipped)
    update_state = Get-UpdateState
    processes = @(Get-RelevantProcesses)
    installed_applications = @(Get-InstalledApplications)
    top_level = @($top.Values | Sort-Object size_bytes -Descending)
    largest_files = @($largest | Sort-Object size_bytes -Descending | Select-Object -First 50)
    candidates = @($orderedCandidates)
}

New-Item -ItemType Directory -Path $runPath -Force | Out-Null
$scanFile = Join-Path $runPath 'scan.json'
$reportFile = Join-Path $runPath 'report.md'
$result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $scanFile -Encoding utf8

function Get-ReportText {
    param([string]$Text)
    if ($Language -ne 'zh-CN') { return $Text }
    $translations = @{
        low='低'; medium='中'; high='高'; critical='严重'
        'Windows crash dump staging'='Windows 崩溃转储暂存'
        'Crash diagnostics will no longer be available'='将无法再使用这些崩溃诊断文件'
        'Application installer staging'='应用安装器暂存目录'
        'A future update may recreate it'='后续更新可能重新生成'
        'Continuously growing reproducible development cache'='持续增长且可重新生成的开发缓存'
        'Use npm configuration or a compatibility Junction'='应使用 npm 配置或兼容 Junction'
        'Use pip cache configuration or a compatibility Junction'='应使用 pip 缓存配置或兼容 Junction'
        'Use UV_CACHE_DIR or a compatibility Junction'='应使用 UV_CACHE_DIR 或兼容 Junction'
        'Continuously growing Electron download cache'='持续增长的 Electron 下载缓存'
        'Use ELECTRON_CACHE or a compatibility Junction'='应使用 ELECTRON_CACHE 或兼容 Junction'
        'Large application runtime and extension store'='大型应用运行时和扩展目录'
        'LM Studio must be closed'='必须关闭 LM Studio'
        'Large editor extension store'='大型编辑器扩展目录'
        'VS Code must be closed'='必须关闭 VS Code'
        'Installed global tools, not disposable cache'='已安装的全局工具，不是可随意删除的缓存'
        'Preserve PATH compatibility'='必须保持 PATH 兼容性'
        'Large local model store'='大型本地模型目录'
        'Paseo must be closed'='必须关闭 Paseo'
        'Browser-managed cache or site storage'='浏览器管理的缓存或网站存储'
        'May sign out sites, remove offline data, or be recreated'='可能导致网站退出登录、离线数据丢失或重新下载'
        'Shared user temporary directory'='用户共享临时目录'
        'May contain active installer or update files'='可能包含正在使用的安装或更新文件'
        'Automation browser runtime'='自动化浏览器运行时'
        'Tools may need to download it again'='相关工具以后可能需要重新下载'
        'Windows-managed temporary directory'='Windows 管理的临时目录'
        'Requires update and process checks'='必须先检查更新和活动进程'
        'Windows Update working directory'='Windows 更新工作目录'
        'Do not touch during an update or pending reboot'='更新进行中或等待重启时不得处理'
        'Windows recovery/update working directory'='Windows 恢复或更新工作目录'
        'Can be required for update rollback'='更新回滚可能仍需要这些数据'
        'Application updater directory'='应用更新器目录'
        'Confirm the installed version works before removal'='删除前必须确认已安装版本工作正常'
        'Protected Windows system directory'='受保护的 Windows 系统目录'
        'Manual deletion can make Windows unbootable'='手动删除可能导致 Windows 无法启动'
        'Broad user-data root'='范围过大的用户数据根目录'
        'Contains personal and application data'='包含个人数据和应用数据'
        'User-profile root'='用户配置文件根目录'
        'Broad application-data root'='范围过大的应用数据根目录'
        'Never delete or migrate as a whole'='绝不能整体删除或迁移'
        'Shared application-data root'='共享应用数据根目录'
        'Never delete as a whole'='绝不能整体删除'
        'Windows-managed system file'='Windows 管理的系统文件'
        'Never delete manually'='绝不能手动删除'
    }
    if ($translations.ContainsKey($Text)) { return $translations[$Text] }
    $Text
}

$labels = if ($Language -eq 'zh-CN') {
    @{ title='Windows 磁盘扫描报告'; nochange='本轮未在运行目录之外进行任何修改。'; coverage='目录扫描覆盖'; skipped='跳过的路径（目录/链接）'; estimate='大小为扫描时观测值，不代表保证可释放的空间。'; side='副作用'; processes='需关闭进程'; fingerprint='指纹'; destination='迁移目标'; notselected='批准前必须选择精确目标路径'; none='无'; categories=@{delete='建议删除';caution='谨慎处理';keep='不建议删除';migrate='建议迁移'}; empty='无' }
} else {
    @{ title='Windows disk scan report'; nochange='No changes were made outside the run directory.'; coverage='Directory scan coverage'; skipped='Skipped paths (directories/links)'; estimate='Sizes are observations at scan time, not guaranteed reclaimable space.'; side='Side effects'; processes='Processes to close'; fingerprint='Fingerprint'; destination='Migration destination'; notselected='Exact destination required before approval'; none='None'; categories=@{delete='Suggested deletion';caution='Caution';keep='Keep / forbidden';migrate='Suggested migration'}; empty='None' }
}
$lines = [Collections.Generic.List[string]]::new()
$lines.Add("# $($labels.title)")
$lines.Add('')
$lines.Add("- Run ID: $runId")
$lines.Add("- Root: $($script:RootPath)")
$lines.Add("- $($labels.coverage): $coveragePercent% ($scannedDirs/$attempted)")
$lines.Add("- $($labels.skipped): $($skipped.Count); directories skipped: $skippedDirectories")
$lines.Add("- $($labels.nochange)")
$lines.Add("- $($labels.estimate)")
foreach ($category in @('delete','caution','keep','migrate')) {
    $lines.Add(''); $lines.Add("## $($labels.categories[$category])"); $lines.Add('')
    $rows = @($orderedCandidates | Where-Object category -eq $category)
    if ($rows.Count -eq 0) { $lines.Add($labels.empty); continue }
    $lines.Add("| ID | Path | Size (bytes) | Risk | Evidence | $($labels.side) | $($labels.processes) | $($labels.fingerprint) | $($labels.destination) |")
    $lines.Add('|---|---|---:|---|---|---|---|---|---|')
    foreach ($row in $rows) {
        $escaped = $row.path.Replace('|','\|')
        $evidence = (@($row.evidence | ForEach-Object { Get-ReportText $_ }) -join '; ').Replace('|','\|')
        $effects = (@($row.side_effects | ForEach-Object { Get-ReportText $_ }) -join '; ').Replace('|','\|')
        if (-not $effects) { $effects = $labels.none }
        $processes = @($row.required_processes_stopped) -join ', '
        if (-not $processes) { $processes = $labels.none }
        $destination = if ($category -eq 'migrate') { $labels.notselected } else { '—' }
        $lines.Add("| $($row.id) | ``$escaped`` | $($row.size_bytes) | $(Get-ReportText $row.risk) | $evidence | $effects | $processes | $($row.fingerprint) | $destination |")
    }
}
$lines | Set-Content -LiteralPath $reportFile -Encoding utf8

[pscustomobject]@{ run_id = $runId; scan_file = $scanFile; report_file = $reportFile; candidate_count = $orderedCandidates.Count }
