[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply', 'Verify', 'RemoveLink', 'Restore')]
    [string]$Mode = 'Preview',

    [ValidateSet('common')]
    [string]$Preset = 'common',

    [string[]]$Software,
    [string]$Source,
    [string]$Target,
    [string]$MappingFile,
    [string]$UserRoot = $env:USERPROFILE,
    [string]$TargetRoot = 'E:\',
    [switch]$ConfirmApply
)

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'windows-junction-migrator only supports Windows.'
}

if ($Mode -in @('Apply', 'RemoveLink', 'Restore') -and -not $ConfirmApply) {
    throw "$Mode changes the filesystem. Re-run with -ConfirmApply after reviewing Preview output."
}

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3) {
        return $full.TrimEnd('\')
    }
    return $full
}

function Expand-ConfiguredPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = $Path.Replace('%USERPROFILE%', $UserRoot)
    if ($env:LOCALAPPDATA) {
        $expanded = $expanded.Replace('%LOCALAPPDATA%', $env:LOCALAPPDATA)
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($expanded)
    return Normalize-Path -Path $expanded
}

function Resolve-TargetPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return Normalize-Path -Path $expanded
    }
    return Normalize-Path -Path (Join-Path -Path $TargetRoot -ChildPath $expanded)
}

function Test-SamePath {
    param([string]$Left, [string]$Right)

    return [string]::Equals(
        (Normalize-Path -Path $Left),
        (Normalize-Path -Path $Right),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Get-ItemSafe {
    param([string]$Path)

    return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Test-IsJunction {
    param([Parameter(Mandatory = $true)]$Item)

    return ($Item.PSIsContainer -and
        ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and
        [string]::Equals([string]$Item.LinkType, 'Junction', [StringComparison]::OrdinalIgnoreCase))
}

function Get-JunctionTarget {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-ItemSafe -Path $Path
    if ($null -eq $item -or -not $item.PSIsContainer) {
        return $null
    }
    if (-not (Test-IsJunction -Item $item)) {
        return $null
    }

    $targetValues = @($item.Target)
    if ($targetValues.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$targetValues[0])) {
        return $null
    }
    return Normalize-Path -Path ([string]$targetValues[0])
}

function Get-DirectorySize {
    param([string]$Path)

    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Force -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 } |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return [int64]0 }
        return [int64]$sum
    }
    catch {
        return [int64]0
    }
}

function Format-Size {
    param([int64]$Bytes)

    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Read-Mappings {
    $skillRoot = Split-Path -Parent $PSScriptRoot
    if ($MappingFile) {
        $path = [System.IO.Path]::GetFullPath($MappingFile)
    }
    else {
        $path = Join-Path $skillRoot 'references\common-mappings.json'
    }

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Mapping file not found: $path"
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $json = [System.IO.File]::ReadAllText($path, $utf8)
    $parsed = @(ConvertFrom-Json -InputObject $json)
    if ($parsed.Count -eq 0) {
        throw "Mapping file is empty: $path"
    }
    return $parsed
}

function Select-Mappings {
    if ($Source -or $Target) {
        if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Target)) {
            throw '-Source and -Target must be provided together.'
        }
        if ($Software -or $MappingFile) {
            throw '-Source/-Target cannot be combined with -Software or -MappingFile.'
        }
        return @([pscustomobject]@{
                id = 'custom'
                nameZh = '自定义目录'
                nameEn = 'Custom directory'
                source = $Source
                target = $Target
            })
    }

    $all = @(Read-Mappings)
    if ($Software) {
        $requested = @($Software | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
        $known = @($all | ForEach-Object { [string]$_.id })
        $unknown = @($requested | Where-Object { $_ -notin $known })
        if ($unknown.Count -gt 0) {
            throw "Unknown software id(s): $($unknown -join ', '). Available: $($known -join ', ')"
        }
        return @($all | Where-Object { $requested -contains ([string]$_.id).ToLowerInvariant() })
    }
    return $all
}

function New-PlanItem {
    param([Parameter(Mandatory = $true)]$Mapping)

    $sourcePath = Expand-ConfiguredPath -Path ([string]$Mapping.source)
    $targetPath = Resolve-TargetPath -Path ([string]$Mapping.target)
    $sourceItem = Get-ItemSafe -Path $sourcePath
    $targetItem = Get-ItemSafe -Path $targetPath
    $status = 'Ready'
    $detail = ''
    $bytes = [int64]0

    if ($sourcePath.Length -le 3) {
        $status = 'Blocked'
        $detail = '源路径不能是磁盘根目录。'
    }
    elseif (Test-SamePath -Left $sourcePath -Right $targetPath -or $targetPath.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $status = 'Blocked'
        $detail = '目标路径不能与源路径相同或位于源路径内部。'
    }
    elseif ($null -eq $sourceItem) {
        $status = 'MissingSource'
        $detail = '源目录不存在，已跳过。'
    }
    elseif (-not $sourceItem.PSIsContainer) {
        $status = 'Blocked'
        $detail = '源路径是文件，不是目录。'
    }
    elseif (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $linkTarget = Get-JunctionTarget -Path $sourcePath
        if ($null -eq $linkTarget) {
            $status = 'Blocked'
            $detail = '源目录是无法解析的重解析点。'
        }
        elseif (Test-SamePath -Left $linkTarget -Right $targetPath) {
            if ($null -eq $targetItem) {
                $status = 'Blocked'
                $detail = "Junction 指向的目标不存在：$targetPath"
            }
            else {
                $status = 'AlreadyMigrated'
                $detail = "已正确指向 $targetPath"
            }
        }
        else {
            $status = 'Blocked'
            $detail = "源路径已指向其他目标：$linkTarget"
        }
    }
    elseif ($null -ne $targetItem) {
        if (-not $targetItem.PSIsContainer) {
            $status = 'Blocked'
            $detail = '目标路径已存在且是文件。'
        }
        elseif (($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $status = 'Blocked'
            $detail = '目标路径已是重解析点，禁止嵌套链接。'
        }
        else {
            $status = 'Blocked'
            $detail = '目标目录已存在；为避免合并或覆盖，脚本不会自动处理。'
        }
    }

    if ($status -eq 'Ready') {
        $bytes = Get-DirectorySize -Path $sourcePath
        $detail = "预计释放 $(Format-Size -Bytes $bytes)"
    }

    return [pscustomobject]@{
        Id = [string]$Mapping.id
        NameZh = [string]$Mapping.nameZh
        NameEn = [string]$Mapping.nameEn
        Source = $sourcePath
        Target = $targetPath
        Status = $status
        Detail = $detail
        Bytes = $bytes
    }
}

function Show-Plan {
    param([Parameter(Mandatory = $true)][array]$Items)

    Write-Output "Mode: $Mode"
    Write-Output "Source root: $UserRoot"
    Write-Output "Target root: $TargetRoot"
    $Items | Select-Object Id, NameZh, Status, Source, Target, Detail | Format-Table -Wrap -AutoSize | Out-String | Write-Output

    $readyBytes = ($Items | Where-Object { $_.Status -eq 'Ready' } | Measure-Object -Property Bytes -Sum).Sum
    if ($null -eq $readyBytes) { $readyBytes = 0 }
    Write-Output ("Ready data: {0}" -f (Format-Size -Bytes ([int64]$readyBytes)))
}

function Assert-Applyable {
    param([array]$Items)

    $blockers = @($Items | Where-Object { $_.Status -eq 'Blocked' })
    if ($blockers.Count -gt 0) {
        $names = $blockers | ForEach-Object { $_.Id }
        throw "Preflight blocked: $($names -join ', '). Resolve blockers and preview again."
    }
}

function Ensure-ParentDirectory {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Invoke-Apply {
    param([array]$Items)

    Assert-Applyable -Items $Items
    foreach ($item in $Items) {
        if ($item.Status -ne 'Ready') {
            Write-Output "$($item.Id): $($item.Status) - skipped"
            continue
        }
        Ensure-ParentDirectory -Path $item.Target
        Move-Item -LiteralPath $item.Source -Destination $item.Target
        New-Item -ItemType Junction -Path $item.Source -Target $item.Target | Out-Null
        Write-Output "$($item.Id): moved data and created Junction"
    }
}

function Remove-JunctionOnly {
    param([string]$Path)

    $item = Get-ItemSafe -Path $Path
    if ($null -eq $item) { return 'missing' }
    if (-not (Test-IsJunction -Item $item)) {
        throw "Refusing to remove a non-Junction path: $Path"
    }
    [System.IO.Directory]::Delete($Path, $false)
    return 'removed'
}

function Invoke-RemoveLink {
    param([array]$Items)

    $invalid = @($Items | Where-Object {
            $sourceItem = Get-ItemSafe -Path $_.Source
            if ($null -eq $sourceItem) { return $false }
            if (-not (Test-IsJunction -Item $sourceItem)) { return $true }
            $linkTarget = Get-JunctionTarget -Path $_.Source
            return ($null -eq $linkTarget -or -not (Test-SamePath -Left $linkTarget -Right $_.Target))
        })
    if ($invalid.Count -gt 0) {
        throw "RemoveLink requires Junction source paths: $(($invalid | ForEach-Object { $_.Id }) -join ', ')"
    }

    foreach ($item in $Items) {
        $result = Remove-JunctionOnly -Path $item.Source
        Write-Output "$($item.Id): $result; target data kept at $($item.Target)"
    }
}

function Invoke-Restore {
    param([array]$Items)

    $invalid = @($Items | Where-Object {
            $sourceItem = Get-ItemSafe -Path $_.Source
            $targetItem = Get-ItemSafe -Path $_.Target
            $null -eq $sourceItem -or $null -eq $targetItem -or
            -not (Test-IsJunction -Item $sourceItem) -or
            $null -eq (Get-JunctionTarget -Path $_.Source) -or
            -not (Test-SamePath -Left (Get-JunctionTarget -Path $_.Source) -Right $_.Target)
        })
    if ($invalid.Count -gt 0) {
        throw "Restore requires an existing Junction and target directory: $(($invalid | ForEach-Object { $_.Id }) -join ', ')"
    }

    foreach ($item in $Items) {
        Remove-JunctionOnly -Path $item.Source | Out-Null
        Move-Item -LiteralPath $item.Target -Destination $item.Source
        Write-Output "$($item.Id): restored data to $($item.Source)"
    }
}

$mappings = @(Select-Mappings)
if ($mappings.Count -eq 0) {
    throw 'No mappings selected.'
}
$items = @($mappings | ForEach-Object { New-PlanItem -Mapping $_ })
Show-Plan -Items $items

switch ($Mode) {
    'Preview' { return }
    'Verify' {
        $failed = @($items | Where-Object { $_.Status -notin @('AlreadyMigrated', 'MissingSource') })
        if ($failed.Count -gt 0) {
            throw "Verification failed for: $(($failed | ForEach-Object { $_.Id }) -join ', ')"
        }
        Write-Output 'Verification passed.'
    }
    'Apply' { Invoke-Apply -Items $items }
    'RemoveLink' { Invoke-RemoveLink -Items $items }
    'Restore' { Invoke-Restore -Items $items }
}
