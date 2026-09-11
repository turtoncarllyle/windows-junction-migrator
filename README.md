# windows-junction-migrator

[English](README.en.md) | 简体中文

面向 Windows 10/11 的目录迁移技能。它把常用软件的大型缓存或用户数据从 C 盘移动到其他磁盘，并在原路径创建 NTFS Junction。软件继续使用原来的路径，实际数据存放在 E 盘或你指定的目标盘，从而释放 C 盘空间。

## 这个技能是做什么的

Windows 的系统盘容量较小时，浏览器用户数据、开发工具缓存和 AI 工具数据会持续占用 C 盘。Junction 是 Windows NTFS 的目录重解析点：例如把 `C:\Users\flze\.codex` 指向 `E:\codex\.codex` 后，程序访问 C 盘路径时实际读写 E 盘数据。

技能会先生成预览，检查源目录、目标目录、已有 Junction、权限和预计释放空间。只有用户明确确认，并且相关软件已经关闭后，才会执行移动和创建链接。

## 支持的场景

- 批量迁移内置常用软件目录。
- 只迁移指定软件，例如 Edge、Chrome 和 Codex。
- 迁移一个指定目录，或通过 UTF-8 JSON 批量提供自定义目录。
- 验证 Junction 是否指向正确目标。
- 只删除 Junction 并保留目标盘数据。
- 在目标盘有足够空间时，把数据恢复到 C 盘。

内置软件 ID 包括：`codex`、`cc-switch`、`nuget`、`workbuddy`、`claude`、`gemini`、`codebuddy`、`codebuddycn`、`trae-cn`、`zcode`、`vscode`、`antigravity-ide`、`cache`、`copilot`、`edge` 和 `chrome`。

## 安装

在支持技能安装的 Codex 环境中执行：

```text
请从 https://github.com/turtoncarllyle/windows-junction-migrator/tree/main/windows-junction-migrator 安装 windows-junction-migrator 技能。
```

安装后重启 Codex 或新建任务，使技能被重新发现。

## 使用技能

可以直接向 Codex 提问：

```text
使用 $windows-junction-migrator 预览所有常用软件迁移，计算可以释放多少 C 盘空间。
```

```text
使用 $windows-junction-migrator，只迁移 Edge、Chrome 和 Codex。先预览，确认没有冲突后再等待我的确认。
```

```text
使用 $windows-junction-migrator，把 C:\Users\flze\SomeApp\Data 迁移到 E:\SomeApp\Data，先生成预览。
```

脚本也可以在 PowerShell 中直接运行。默认源根目录是 `$env:USERPROFILE`，默认目标根目录是 `E:\`：

```powershell
$skill = "E:\github\awesome-develop-skills\windows-junction-migrator\windows-junction-migrator"

# 预览全部内置映射（不会修改文件）
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Preset common -TargetRoot "E:\"

# 只预览或执行指定软件
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Software edge,chrome,codex -TargetRoot "E:\"

pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Apply -Software edge,chrome,codex -TargetRoot "E:\" -ConfirmApply

# 指定目录迁移
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Source "C:\Users\flze\SomeApp\Data" -Target "E:\SomeApp\Data"
```

`Apply`、`RemoveLink` 和 `Restore` 都必须带 `-ConfirmApply`。执行前关闭对应软件及后台进程；脚本不会替你结束进程。

## 自定义批量映射

创建 UTF-8 文件 `my-mappings.json`：

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

相对目标路径会拼接到 `-TargetRoot`；绝对目标路径会直接使用。使用以下命令预览或执行：

```powershell
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -MappingFile ".\my-mappings.json" -TargetRoot "E:\"
```

## IntelliJ IDEA 缓存迁移

IDEA 目录包含版本号，不在内置清单中猜测版本。关闭 IDEA 后查找最近使用的版本：

```powershell
$idea = Get-ChildItem "$env:LOCALAPPDATA\JetBrains" -Directory |
  Where-Object { $_.Name -match '^(IntelliJIdea|IdeaIC)' } |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
$source = Join-Path $idea.FullName "caches"
$target = "E:\intellij-idea\caches"

pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Preview -Source $source -Target $target
```

找到多个版本时先手动选择准确目录，再执行迁移。

## 验证、删除和恢复

```powershell
# 验证链接和目标
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Verify -Software edge,chrome

# 只删除 C 盘 Junction，保留 E 盘数据
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode RemoveLink -Software edge -ConfirmApply

# 将目标数据迁回 C 盘并恢复普通目录
pwsh -NoProfile -File "$skill\scripts\migrate-junctions.ps1" `
  -Mode Restore -Software edge -ConfirmApply
```

手动删除单个 Junction 前，先确认它是 Junction，再使用 `rmdir`：

```powershell
cmd /c rmdir "C:\Users\flze\.codex"
```

`rmdir` 删除的是链接本身，`E:\codex\.codex` 中的数据会保留。不要对未知普通目录使用递归删除。

## 安全规则和限制

- 源目录为普通目录且目标已存在时停止，不自动合并或覆盖。
- 已正确指向目标的 Junction 会被识别为已完成，不重复移动。
- 错误 Junction、断裂目标、文件路径、权限不足、程序占用或目标盘不可用时停止。
- Junction 不是备份，迁移前请确保目标盘可靠。
- 本技能仅支持 Windows NTFS Junction，不处理 macOS/Linux 符号链接。

## 参考资料

Junction 概念和 IntelliJ IDEA 缓存迁移场景参考：[Win10系统Junction连接使用技巧及解决C盘空间不足的方法](https://blog.csdn.net/qq_45351273/article/details/149415259)（兔子蟹子，CC BY-SA 4.0）。本仓库使用原创说明和脚本实现。

## 许可证

[MIT License](LICENSE)
