[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('init', 'status', 'sync', 'pull-sync', 'capture', 'publish')]
    [string]$Command,

    [Parameter()]
    [string]$Message
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:ConfigRoot = Join-Path $script:RepoRoot 'config'
$script:TargetsFile = Join-Path $script:ConfigRoot 'targets.json'
$script:MachineLocalFile = Join-Path $script:ConfigRoot 'machine.local.json'
$script:MachineLocalExampleFile = Join-Path $script:ConfigRoot 'machine.local.json.example'
$script:Utf8Encoding = New-Object System.Text.UTF8Encoding($true)
$script:BackupStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:BackupRoot = Join-Path $script:RepoRoot (Join-Path '.backup' $script:BackupStamp)

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8Encoding)
}

function Read-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, $script:Utf8Encoding)
}

function New-Result {
    param(
        [string]$Name,
        [string]$Source,
        [string]$Target,
        [string]$Action,
        [string]$Result,
        [string]$Details
    )

    return [pscustomobject]@{
        Name    = $Name
        Source  = $Source
        Target  = $Target
        Action  = $Action
        Result  = $Result
        Details = $Details
    }
}

function Write-ResultSummary {
    param([Parameter(Mandatory = $true)][System.Collections.IEnumerable]$Results)

    $Results | Select-Object Name, Action, Result, Details | Format-Table -AutoSize
}

function Test-GitAvailable {
    try {
        $null = Get-Command git -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Ensure-GitAvailable {
    if (-not (Test-GitAvailable)) {
        throw '未找到 git 命令。'
    }
}

function Ensure-MachineLocalFile {
    if (-not (Test-Path $script:MachineLocalExampleFile)) {
        throw "缺少示例配置文件：$script:MachineLocalExampleFile"
    }

    if (-not (Test-Path $script:MachineLocalFile)) {
        Copy-Item -LiteralPath $script:MachineLocalExampleFile -Destination $script:MachineLocalFile -Force
        Write-Host "已生成本机配置：$script:MachineLocalFile"
    }
}

function Get-Variables {
    $variables = @{
        USERPROFILE       = $env:USERPROFILE
        JAVA_PROJECT_ROOT = 'C:\project\java-project'
    }

    if (Test-Path $script:MachineLocalFile) {
        $machineConfig = Get-Content -Path $script:MachineLocalFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($machineConfig.variables) {
            foreach ($property in $machineConfig.variables.PSObject.Properties) {
                $variables[$property.Name] = [string]$property.Value
            }
        }
    }

    return $variables
}

function Expand-Template {
    param(
        [Parameter(Mandatory = $true)][string]$Template,
        [Parameter(Mandatory = $true)][hashtable]$Variables
    )

    $expanded = $Template
    foreach ($key in $Variables.Keys) {
        $placeholder = '${' + $key + '}'
        $expanded = $expanded.Replace($placeholder, [string]$Variables[$key])
    }

    return $expanded
}

function Get-AgentTargets {
    if (-not (Test-Path $script:TargetsFile)) {
        throw "缺少目标配置文件：$script:TargetsFile"
    }

    $config = Get-Content -Path $script:TargetsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $variables = Get-Variables
    $targets = @()

    foreach ($target in $config.targets) {
        $resolvedSource = Join-Path $script:RepoRoot $target.source
        $resolvedTarget = Expand-Template -Template $target.target -Variables $variables
        $targets += [pscustomobject]@{
            Name     = [string]$target.name
            Source   = $resolvedSource
            Target   = $resolvedTarget
            Encoding = [string]$target.encoding
            Required = [bool]$target.required
        }
    }

    return $targets
}

function Get-FileHashSafe {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Ensure-ParentDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Backup-File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $backupDirectory = Join-Path $script:BackupRoot (Join-Path $Kind $Name)
    if (-not (Test-Path $backupDirectory)) {
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    }

    $destination = Join-Path $backupDirectory ([System.IO.Path]::GetFileName($Path))
    Copy-Item -LiteralPath $Path -Destination $destination -Force
    return $destination
}

function Sync-AgentTargets {
    param([Parameter(Mandatory = $true)][System.Collections.IEnumerable]$Targets)

    $results = @()
    $hasFailure = $false

    foreach ($target in $Targets) {
        try {
            if (-not (Test-Path $target.Source)) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'sync' -Result 'missing_source' -Details '源文件不存在'
                if ($target.Required) { $hasFailure = $true }
                continue
            }

            $sourceHash = Get-FileHashSafe -Path $target.Source
            $targetHash = Get-FileHashSafe -Path $target.Target

            if ($sourceHash -and $targetHash -and $sourceHash -eq $targetHash) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'sync' -Result 'in_sync' -Details '无需同步'
                continue
            }

            if (Test-Path $target.Target) {
                $backupPath = Backup-File -Path $target.Target -Name $target.Name -Kind 'target'
                $detail = "已更新，备份：$backupPath"
            }
            else {
                $detail = '已创建目标文件'
            }

            Ensure-ParentDirectory -Path $target.Target
            $content = Read-Utf8File -Path $target.Source
            Write-Utf8File -Path $target.Target -Content $content

            $verifiedHash = Get-FileHashSafe -Path $target.Target
            if ($verifiedHash -ne $sourceHash) {
                throw '写入后哈希校验失败'
            }

            $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'sync' -Result 'synced' -Details $detail
        }
        catch {
            $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'sync' -Result 'failed' -Details $_.Exception.Message
            $hasFailure = $true
        }
    }

    return [pscustomobject]@{
        Results    = $results
        HasFailure = $hasFailure
    }
}

function Get-StatusForTargets {
    param([Parameter(Mandatory = $true)][System.Collections.IEnumerable]$Targets)

    $results = @()
    $hasFailure = $false

    foreach ($target in $Targets) {
        try {
            if (-not (Test-Path $target.Source)) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'status' -Result 'missing_source' -Details '源文件不存在'
                if ($target.Required) { $hasFailure = $true }
                continue
            }

            if (-not (Test-Path $target.Target)) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'status' -Result 'missing_target' -Details '目标文件不存在'
                if ($target.Required) { $hasFailure = $true }
                continue
            }

            $sourceHash = Get-FileHashSafe -Path $target.Source
            $targetHash = Get-FileHashSafe -Path $target.Target

            if ($sourceHash -eq $targetHash) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'status' -Result 'in_sync' -Details '源文件与目标文件一致'
            }
            else {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'status' -Result 'drift' -Details '源文件与目标文件存在差异'
            }
        }
        catch {
            $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'status' -Result 'failed' -Details $_.Exception.Message
            $hasFailure = $true
        }
    }

    return [pscustomobject]@{
        Results    = $results
        HasFailure = $hasFailure
    }
}

function Capture-AgentTargets {
    param([Parameter(Mandatory = $true)][System.Collections.IEnumerable]$Targets)

    $results = @()
    $hasFailure = $false

    foreach ($target in $Targets) {
        try {
            if (-not (Test-Path $target.Source)) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'capture' -Result 'missing_source' -Details '源文件不存在'
                $hasFailure = $true
                continue
            }

            if (-not (Test-Path $target.Target)) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'capture' -Result 'missing_target' -Details '目标文件不存在'
                $hasFailure = $true
                continue
            }

            $sourceHash = Get-FileHashSafe -Path $target.Source
            $targetHash = Get-FileHashSafe -Path $target.Target

            if ($sourceHash -eq $targetHash) {
                $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'capture' -Result 'in_sync' -Details '无需回收'
                continue
            }

            $backupPath = Backup-File -Path $target.Source -Name $target.Name -Kind 'source'
            $content = Read-Utf8File -Path $target.Target
            Write-Utf8File -Path $target.Source -Content $content

            $verifiedHash = Get-FileHashSafe -Path $target.Source
            if ($verifiedHash -ne $targetHash) {
                throw '回收后哈希校验失败'
            }

            $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'capture' -Result 'captured' -Details "已回收目标改动，备份：$backupPath"
        }
        catch {
            $results += New-Result -Name $target.Name -Source $target.Source -Target $target.Target -Action 'capture' -Result 'failed' -Details $_.Exception.Message
            $hasFailure = $true
        }
    }

    return [pscustomobject]@{
        Results    = $results
        HasFailure = $hasFailure
    }
}

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Ensure-GitAvailable
    Push-Location $script:RepoRoot
    try {
        & git @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "git 命令执行失败：git $($Arguments -join ' ')"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-GitOutput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    Ensure-GitAvailable
    Push-Location $script:RepoRoot
    try {
        $output = & git @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "git 命令执行失败：git $($Arguments -join ' ')"
        }
        return $output
    }
    finally {
        Pop-Location
    }
}

function Get-GitChangedPaths {
    $lines = Get-GitOutput -Arguments @('status', '--porcelain', '--untracked-files=all')
    $paths = @()

    foreach ($line in $lines) {
        if (-not $line) { continue }
        $path = $line.Substring(3).Trim()
        if ($path -like '* -> *') {
            $parts = $path -split ' -> '
            $path = $parts[-1]
        }
        $paths += ($path -replace '\\', '/')
    }

    return $paths
}

function Ensure-PublishMessage {
    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw 'publish 命令必须显式提供 -Message。'
    }
}

function Ensure-AllowedPublishPaths {
    $allowedPaths = @(
        'source/',
        'docs/',
        'config/targets.json',
        'config/machine.local.json.example',
        'scripts/',
        '.gitignore',
        'README.md'
    )

    $changedPaths = Get-GitChangedPaths
    foreach ($path in $changedPaths) {
        $isAllowed = $false
        foreach ($allowedPath in $allowedPaths) {
            if ($path -eq $allowedPath -or $path.StartsWith($allowedPath)) {
                $isAllowed = $true
                break
            }
        }

        if (-not $isAllowed) {
            throw "publish 检测到不允许提交的路径：$path"
        }
    }

    return $changedPaths
}

function Invoke-Init {
    Ensure-MachineLocalFile
    $targets = Get-AgentTargets

    foreach ($target in $targets) {
        if (-not (Test-Path $target.Source)) {
            throw "init 失败，缺少源文件：$($target.Source)"
        }
        Ensure-ParentDirectory -Path $target.Target
    }

    $syncResult = Sync-AgentTargets -Targets $targets
    Write-ResultSummary -Results $syncResult.Results
    if ($syncResult.HasFailure) {
        throw 'init 过程中同步失败。'
    }

    $statusResult = Get-StatusForTargets -Targets $targets
    Write-ResultSummary -Results $statusResult.Results
    if ($statusResult.HasFailure) {
        throw 'init 完成后状态校验失败。'
    }
}

function Invoke-Status {
    $targets = Get-AgentTargets
    $statusResult = Get-StatusForTargets -Targets $targets
    Write-ResultSummary -Results $statusResult.Results
    if ($statusResult.HasFailure) {
        throw '状态检查失败。'
    }
}

function Invoke-Sync {
    $targets = Get-AgentTargets
    $syncResult = Sync-AgentTargets -Targets $targets
    Write-ResultSummary -Results $syncResult.Results
    if ($syncResult.HasFailure) {
        throw '同步失败。'
    }
}

function Invoke-PullSync {
    Invoke-Git -Arguments @('pull', '--ff-only')
    Invoke-Sync
    Invoke-Status
}

function Invoke-Capture {
    $targets = Get-AgentTargets
    $captureResult = Capture-AgentTargets -Targets $targets
    Write-ResultSummary -Results $captureResult.Results
    if ($captureResult.HasFailure) {
        throw '回收失败。'
    }
}

function Invoke-Publish {
    Ensure-PublishMessage
    $locationPath = (Get-Location).Path
    if ((Resolve-Path $locationPath).Path -ne $script:RepoRoot) {
        throw "publish 只允许在配置仓库根目录执行。当前目录：$locationPath"
    }

    $preStatus = Get-StatusForTargets -Targets (Get-AgentTargets)
    Write-ResultSummary -Results $preStatus.Results
    if ($preStatus.HasFailure) {
        throw 'publish 前状态检查失败。'
    }

    Invoke-Sync
    Invoke-Git -Arguments @('diff', '--check')
    $changedPaths = Ensure-AllowedPublishPaths

    if (-not $changedPaths -or $changedPaths.Count -eq 0) {
        Write-Host '没有需要发布的改动。'
        return
    }

    Invoke-Git -Arguments @('add', '--all')
    Invoke-Git -Arguments @('commit', '-m', $Message)
    Invoke-Git -Arguments @('push')
    Write-Host '发布完成。'
}

try {
    switch ($Command) {
        'init' { Invoke-Init }
        'status' { Invoke-Status }
        'sync' { Invoke-Sync }
        'pull-sync' { Invoke-PullSync }
        'capture' { Invoke-Capture }
        'publish' { Invoke-Publish }
        default { throw "不支持的命令：$Command" }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
