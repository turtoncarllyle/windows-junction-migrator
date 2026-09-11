# windows-junction-migrator

**English** | [简体中文](README.md)

A Windows 10/11 skill for moving large application caches or user data away from the C: drive and creating NTFS directory Junctions at the original paths. Applications continue to use their existing paths while the data is stored on E: or another selected drive, freeing system-disk space.

## Purpose

On a small system drive, browser profiles, development-tool caches, and AI-tool data can consume C: quickly. A Junction is a Windows NTFS directory reparse point. For example, a Junction from `C:\Users\flze\.codex` to `E:\codex\.codex` makes applications keep using the C: path while reads and writes go to E:.

The skill always starts with a preview. It checks source and target directories, existing Junctions, conflicts, permissions, and estimated space that can be freed. It performs a move only after the user explicitly confirms and the related applications are closed.

## Supported scenarios

- Batch migration of the built-in common-software mappings.
- Selecting individual software such as Edge, Chrome, or Codex.
- Migrating one directory or a batch of custom directories from a UTF-8 JSON file.
- Verifying that Junctions point to the expected targets.
- Removing only a Junction while keeping the target data.
- Restoring data to C: when there is enough free space.

Built-in IDs are `codex`, `cc-switch`, `nuget`, `workbuddy`, `claude`, `gemini`, `codebuddy`, `codebuddycn`, `trae-cn`, `zcode`, `vscode`, `antigravity-ide`, `cache`, `copilot`, `edge`, and `chrome`.

## Installation

In a Codex environment that supports skill installation:

```text
Install the windows-junction-migrator skill from https://github.com/turtoncarllyle/windows-junction-migrator/tree/main/windows-junction-migrator.
```

Restart Codex or open a new task so the skill can be discovered.

## Using the skill

Example prompts:

```text
Use $windows-junction-migrator to preview all common-software migrations and estimate the C: space they can free.
```

```text
Use $windows-junction-migrator to migrate only Edge, Chrome, and Codex. Preview first and wait for my confirmation before applying.
```

```text
Use $windows-junction-migrator to move C:\Users\flze\SomeApp\Data to E:\SomeApp\Data and show a preview first.
```

The script can also be run directly from PowerShell. The default source root is `$env:USERPROFILE`; the default target root is `E:\`:

```powershell
$skill = "E:\github\awesome-develop-skills\windows-junction-migrator\windows-junction-migrator"

# Preview all built-in mappings (read-only)
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Preset common -TargetRoot "E:\"

# Preview or apply selected software
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Software edge,chrome,codex -TargetRoot "E:\"

pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Apply -Software edge,chrome,codex -TargetRoot "E:\" -ConfirmApply

# Migrate a custom directory
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Source "C:\Users\flze\SomeApp\Data" -Target "E:\SomeApp\Data"
```

`Apply`, `RemoveLink`, and `Restore` require `-ConfirmApply`. Close the selected applications and their background processes first; the script never terminates them for you.

## Custom batch mappings

Create a UTF-8 file named `my-mappings.json`:

```json
[
  {
    "id": "my-app",
    "nameZh": "我的应用",
    "nameEn": "My app",
    "source": "%LOCALAPPDATA%\\MyApp\\Data",
    "target": "my-app\\Data"
  }
]
```

Relative targets are joined to `-TargetRoot`; absolute targets are used as written.

```powershell
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -MappingFile ".\my-mappings.json" -TargetRoot "E:\"
```

## IntelliJ IDEA cache example

IDEA directories contain a version number, so the skill does not guess one in the built-in list. Close IDEA and find the most recently used version:

```powershell
$idea = Get-ChildItem "$env:LOCALAPPDATA\JetBrains" -Directory |
  Where-Object { $_.Name -match '^(IntelliJIdea|IdeaIC)' } |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
$source = Join-Path $idea.FullName "caches"
$target = "E:\intellij-idea\caches"

pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Source $source -Target $target
```

If multiple versions are found, choose the exact directory manually before applying.

## Verify, remove, and restore

```powershell
# Verify the Junction and target
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Verify -Software edge,chrome

# Remove only the C: Junction and keep E: data
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode RemoveLink -Software edge -ConfirmApply

# Move data back to C: and restore a normal directory
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Restore -Software edge -ConfirmApply
```

Before manually removing a Junction, verify its type and use `rmdir`:

```powershell
cmd /c rmdir "C:\Users\flze\.codex"
```

`rmdir` removes the link itself and keeps the data in `E:\codex\.codex`. Do not recursively delete an unknown ordinary directory.

## Safety and limits

- If the source is an ordinary directory and the target already exists, the script stops instead of merging or overwriting.
- A Junction already pointing to the expected target is reported as complete and is not moved again.
- Unexpected or broken Junctions, file sources, insufficient permissions, open files, and unavailable target drives stop the operation.
- A Junction is not a backup; make sure the target drive is reliable.
- This skill supports Windows NTFS Junctions only; it does not handle macOS/Linux symbolic links.

## Reference

The Junction concept and IntelliJ IDEA cache scenario were informed by [Win10系统Junction连接使用技巧及解决C盘空间不足的方法](https://blog.csdn.net/qq_45351273/article/details/149415259) by 兔子蟹子 under CC BY-SA 4.0. This repository contains original instructions and implementation.

## License

[MIT License](LICENSE)
