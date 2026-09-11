---
name: windows-junction-migrator
description: "Windows-only workflow for moving large application data directories off C: and creating NTFS Junctions so software keeps using its original path. Supports common presets, selected software, custom mappings, verification, safe link removal, and restore operations."
---

# Windows Junction Migrator / Windows 目录迁移

在 Windows 10/11 上，使用本技能把常用软件的大型缓存或用户数据从 C: 迁移到其他磁盘（默认 E:），再在原路径创建 NTFS Junction。软件仍访问原来的 C: 路径，实际数据存放在目标盘，从而释放 C 盘空间。

On Windows 10/11, move large application caches or user data from C: to another drive (E: by default), then create an NTFS directory Junction at the original path. Applications keep using the original C: path while the data lives on the target drive.

## 工作方式 / Workflow

1. 先确认 Windows、PowerShell、源目录和目标盘；路径使用反斜杠并按 UTF-8 读取文本。
2. 先运行 `Preview`。预览只读取目录、解析环境变量、识别现有 Junction、估算可释放空间并列出 blockers，不移动或删除数据。
3. 要执行 `Apply`、`RemoveLink` 或 `Restore`，先要求用户关闭相关软件及其后台进程，然后要求用户明确确认。不要自动结束进程、覆盖已有目标目录或合并两个非空目录。
4. 执行后运行 `Verify`，报告每项的源路径、目标路径、链接类型、数据可访问性和实际结果。
5. 已正确指向目标的 Junction 是幂等成功；错误目标、断裂链接、源路径为文件或目标冲突必须停止并说明原因。

## 脚本入口 / Script entry point

从技能目录运行 `scripts/migrate-junctions.ps1`。`-UserRoot` 默认是 `$env:USERPROFILE`，`-TargetRoot` 默认是 `E:\`。目标映射以 `-TargetRoot` 为根，绝对目标路径也可用于自定义映射。

```powershell
# 预览全部常用软件
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Preview -Preset common -TargetRoot "E:\"

# 只迁移指定软件（执行前必须确认并关闭软件）
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Apply `
  -Software edge,chrome,codex -TargetRoot "E:\" -ConfirmApply

# 指定一个目录；先预览，再把同一参数改为 Apply
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Preview `
  -Source "C:\Users\flze\SomeApp\Data" -Target "E:\SomeApp\Data"

# 用自定义 JSON 批量迁移
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Preview `
  -MappingFile ".\my-mappings.json" -TargetRoot "E:\"

# 验证、删除链接（保留目标数据）或恢复
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Verify -Software edge,chrome
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode RemoveLink -Software edge -ConfirmApply
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Restore -Software edge -ConfirmApply
```

支持的参数：

- `-Mode Preview|Apply|Verify|RemoveLink|Restore`，默认为 `Preview`。
- `-Preset common` 选择内置映射；`-Software` 接受逗号分隔的软件 ID。
- `-Source` 与 `-Target` 用于单个自定义目录；两者必须同时提供。
- `-MappingFile` 指向 UTF-8 JSON 数组，可用于任意软件的批量迁移。
- `-ConfirmApply` 是所有写操作的显式确认开关；没有它时脚本拒绝修改。

## 内置映射 / Built-in mappings

详细列表见 [`references/common-mappings.json`](references/common-mappings.json)。点号目录使用 `%USERPROFILE%`，Edge 和 Chrome 使用 `%LOCALAPPDATA%`。IntelliJ IDEA 的目录带版本号，因此见下方动态路径示例，不在清单中硬编码版本。

## IntelliJ IDEA 示例 / IntelliJ IDEA example

关闭 IDEA 后查找缓存目录，再把得到的真实路径作为自定义目录：

```powershell
$idea = Get-ChildItem "$env:LOCALAPPDATA\JetBrains" -Directory |
  Where-Object { $_.Name -match '^(IntelliJIdea|IdeaIC)' } |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
$source = Join-Path $idea.FullName "caches"
$target = "E:\intellij-idea\caches"
pwsh -NoProfile -File .\scripts\migrate-junctions.ps1 -Mode Preview -Source $source -Target $target
```

如果找到多个版本，应先明确选择一个目录；不要让脚本猜测要迁移的版本。

## 删除和恢复 Junction / Removing and restoring a Junction

`RemoveLink` 只删除 C: 上的 Junction，目标盘数据保留。手动删除时确认该路径确实是 Junction，并使用 `rmdir` 删除链接本身：

```powershell
cmd /c rmdir "C:\Users\flze\.codex"
```

不要对未知普通目录使用递归删除。需要把数据迁回 C: 时使用 `Restore`，先确认 C: 有足够空间且软件已关闭。

`RemoveLink` removes only the Junction on C: and keeps the target data. For a manual removal, verify that the path is a Junction and use `rmdir` so the link itself is removed. Use `Restore` only when there is enough C: space and the application is closed.

## 能力边界 / Limits

- 本技能只针对 Windows NTFS Junction，不处理 macOS/Linux 符号链接。
- Junction 不是备份；迁移前应确保目标盘可靠并保留必要备份。
- 没有本机文件和 PowerShell 权限时，只能生成命令和说明，不能声称迁移已完成。
- 目标冲突、权限不足、文件占用或目标盘不可用时停止，修复后对相同映射重新预览。
