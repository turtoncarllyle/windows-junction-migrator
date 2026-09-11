$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'These tests require Windows.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repoRoot 'windows-junction-migrator\scripts\migrate-junctions.ps1'
$shell = $env:WJM_TEST_SHELL
if (-not $shell) {
    $shell = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
}
if (-not $shell) {
    $shell = (Get-Command powershell -ErrorAction Stop).Source
}

$root = Join-Path $env:TEMP ('windows-junction-migrator-' + [guid]::NewGuid().ToString('N'))
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Migration {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $shell -NoProfile -File $scriptPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($exitCode -ne $ExpectedExitCode) {
        throw "Unexpected exit code $exitCode (expected $ExpectedExitCode): $($output -join [Environment]::NewLine)"
    }
    return @($output)
}

try {
    $source = Join-Path $root 'source\中文目录'
    $target = Join-Path $root 'target\数据目录'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $source 'data.txt'), '中文 Junction 数据', $utf8)

    Invoke-Migration -Arguments @('-Mode', 'Preview', '-Source', $source, '-Target', $target) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $source 'data.txt'))) { throw 'Preview changed the source.' }
    if (Test-Path -LiteralPath $target) { throw 'Preview created the target.' }
    Write-Output 'PASS preview is read-only'

    Invoke-Migration -Arguments @('-Mode', 'Apply', '-Source', $source, '-Target', $target, '-ConfirmApply') | Out-Null
    $sourceItem = Get-Item -LiteralPath $source -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Apply did not create a reparse point.' }
    if (-not (Test-Path -LiteralPath (Join-Path $source 'data.txt'))) { throw 'Junction does not expose target data.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'data.txt'))) { throw 'Target data is missing.' }
    Write-Output 'PASS apply moves data and creates Junction'

    Invoke-Migration -Arguments @('-Mode', 'Apply', '-Source', $source, '-Target', $target, '-ConfirmApply') | Out-Null
    Invoke-Migration -Arguments @('-Mode', 'Verify', '-Source', $source, '-Target', $target) | Out-Null
    Write-Output 'PASS apply is idempotent and verify succeeds'

    Invoke-Migration -Arguments @('-Mode', 'RemoveLink', '-Source', $source, '-Target', $target, '-ConfirmApply') | Out-Null
    if (Test-Path -LiteralPath $source) { throw 'RemoveLink left the source Junction.' }
    if (-not (Test-Path -LiteralPath (Join-Path $target 'data.txt'))) { throw 'RemoveLink deleted target data.' }
    Write-Output 'PASS RemoveLink keeps target data'

    $restoreSource = Join-Path $root 'restore-source'
    $restoreTarget = Join-Path $root 'restore-target'
    New-Item -ItemType Directory -Path $restoreSource -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $restoreSource 'restore.txt'), 'restore', $utf8)
    Invoke-Migration -Arguments @('-Mode', 'Apply', '-Source', $restoreSource, '-Target', $restoreTarget, '-ConfirmApply') | Out-Null
    Invoke-Migration -Arguments @('-Mode', 'Restore', '-Source', $restoreSource, '-Target', $restoreTarget, '-ConfirmApply') | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $restoreSource 'restore.txt'))) { throw 'Restore did not return data to the source.' }
    if (Test-Path -LiteralPath $restoreTarget) { throw 'Restore left the target directory.' }
    Write-Output 'PASS Restore returns data to C-side path'

    $conflictSource = Join-Path $root 'conflict-source'
    $conflictTarget = Join-Path $root 'conflict-target'
    New-Item -ItemType Directory -Path $conflictSource,$conflictTarget -Force | Out-Null
    Invoke-Migration -Arguments @('-Mode', 'Apply', '-Source', $conflictSource, '-Target', $conflictTarget, '-ConfirmApply') -ExpectedExitCode 1 | Out-Null
    if (-not (Test-Path -LiteralPath $conflictSource -PathType Container)) { throw 'Conflict handling changed the source.' }
    Write-Output 'PASS existing target blocks Apply'
}
finally {
    if (Test-Path -LiteralPath $root) {
        [System.IO.Directory]::Delete($root, $true)
    }
}
