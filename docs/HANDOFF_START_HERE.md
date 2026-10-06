# 从这里开始（重装系统后的还原指南）

> 备份时间：**2026-10-06**
> 源码基线：`main` 分支，最后一次备份前的提交见 `04_snapshots/repo.bundle` 与备份根目录 `BACKUP_INFO.txt`
> 工程原名/路径：`C:\Users\zjh30\CodeBuddy\20260906184916`（**建议还原到同一路径**，见下"为什么"）

---

## 0. 这个备份里有什么

| 目录/文件 | 内容 | 还原到哪 |
|---|---|---|
| `01_project\` | **完整工程源码**（含 `.git` 全部 354+ 提交历史、`.codebuddy` 项目数据、`tools`、`test`、`core`、`ui`、`addons`、`assets`、`levels_lib` 等） | 覆盖回 `C:\Users\zjh30\CodeBuddy\20260906184916` |
| `02_godot_runtime\Godot.NET\` | **Godot 4.7.2 mono** 运行时（含 `*_console.exe`，门禁脚本按它调用） | **必须还原到 `D:\Godot.NET\`**（同名路径） |
| `03_user_data\app_userdata\` | Godot 的 `user://` 用户数据（本项目存档、`editor_bindings.cfg` 快捷键绑定、快照目录等） | `%APPDATA%\Godot\app_userdata\` |
| `03_user_data\*.tres` | Godot 编辑器设置（`editor_settings-4.7.tres`） | `%APPDATA%\Godot\` |
| `04_snapshots\repo.bundle` | **git 全历史单文件包**（可用 `git clone` 直接取出，或用 `git bundle verify` 校验完整性） | 任意位置，见下"方案 B" |
| `START_HERE.md` | 本文件 | — |
| `NEXT_STEPS.md` | **下一步要做什么**（含未完成清单、工作规则、踩坑记录） | — |

> 说明：**没有**备份 `.godot\`（724 MB 导入缓存，含 20 万个小文件）。它是**可重建**的，重装后第一次打开工程时 Godot 会自动重建（见 §3）。

---

## 1. 还原步骤（按顺序）

### 1.1 装基础环境

1. **.NET SDK 9.0.317**（原机版本；`dotnet build` 与 mono 版 Godot 都需要）
   - 装好后执行 `dotnet --version` 应输出 `9.0.317.x`（同主版本即可）
2. **Godot 4.7.2 mono**：把 `02_godot_runtime\Godot.NET\` 整个复制到 **`D:\Godot.NET\`**
   - 校验：`D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe` 存在

### 1.2 还原工程

**方案 A（直接复制，最省事）**：把 `01_project\` 整个复制到 `C:\Users\zjh30\CodeBuddy\20260906184916\`

**方案 B（从 bundle 取，最干净）**：
```powershell
git clone F:\WorldMinesweeper_backup_20261006\04_snapshots\repo.bundle C:\Users\zjh30\CodeBuddy\20260906184916
cd C:\Users\zjh30\CodeBuddy\20260906184916
git checkout main
```
> 方案 B 只带 **被提交的内容**；`01_project\` 里可能有少量未提交/被忽略的东西（本备份时工作区是干净的：`git status` = 0 项）。

### 1.3 还原用户数据（可选，但"无缝"建议做）

```powershell
Copy-Item -Recurse -Force "F:\WorldMinesweeper_backup_20261006\03_user_data\app_userdata\*" "$env:APPDATA\Godot\app_userdata\"
Copy-Item -Force "F:\WorldMinesweeper_backup_20261006\03_user_data\*.tres" "$env:APPDATA\Godot\"
```

### 1.4 **为什么必须还原到同一路径**

工程里有 **8 个脚本硬编码了 Godot 路径**（`D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\...`）：
`tools\ci_check.ps1:32`、`tools\ci_quick.ps1:22`、`tools\gut_shards.ps1:47`、`tools\batch_pipeline.ps1:19`、`tools\fill_level_lib.ps1:52`、`tools\run_batch.ps1:22/40/44`、`tools\verify_all.ps1:22`。

工程路径本身不硬编码，但**若改了工程路径**请一并 grep 一遍：
```powershell
Get-ChildItem tools,test,docs -Recurse -Include *.ps1,*.gd,*.md | Select-String -Pattern '20260906184916|D:\\Godot\.NET'
```

---

## 2. 还原后第一件事：跑门禁确认"和备份前一模一样"

```powershell
cd C:\Users\zjh30\CodeBuddy\20260906184916

# 全量门禁（约 160~250 秒，随机器负载浮动）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_check.ps1
```

**必须看到（与备份前一致）**：
- 末行 **`CI GREEN (build + GUT + preset health)`**
- unit：**201 个脚本 / 1473 个用例 / Failing 0**
- ui：**33 个脚本 / 212 个用例 / Failing 0**
- build：**0 个警告 0 个错误**

> 首次运行会更慢：Godot 要重建 `.godot` 导入缓存（几分钟，一次性）。

迭代期用增量门禁（快）：
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_quick.ps1            # 按工作区改动选测
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_quick.ps1 -Base HEAD~1
```

---

## 3. 如果门禁红了：先读这条（能省你几小时）

1. **先看是不是"缺摘要/并发假红"**：门禁脚本现在会
   - 对**没有摘要的分片自动定向重跑一次**；
   - 若重跑后仍缺摘要 ⇒ 判红并**打印可定位证据**（片号、分片日志绝对路径、字节数、有无 `[Failed]`）。
   ⇒ 看到 `[retry]` 说明发生过缺摘要；看到"仍缺 ⇒ 判红"时，按它打印的路径去翻那个分片日志。
2. **不要在红的时侯删 `tools\_shard_*.log`**（血的教训：我曾删掉失败证据，导致那条用例至今无名）。
3. **Godot 没有 `--user-data-dir`**：多个 Godot 进程会共用同一份 `user://`，有状态用例**并发时会假红**（单独跑就绿）。
   ⇒ 一切 Godot 运行都要拿跨进程锁 `tools/ci_lock.ps1`（`ci_check.ps1` 内部已自动拿）。用法：
   ```powershell
   . tools\ci_lock.ps1
   $lk = Enter-CiLock -Path tools\.ci_lock -TimeoutSeconds 900
   try { & $G --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/xxx.gd -gexit } finally { Exit-CiLock -Lock $lk }
   ```
4. **`--check-only --script` 不是有效的语法检查**：它不注册 autoload，会假报 `Identifier not found: ThemeManager`。要验脚本能不能用，**真跑**一个加载它的用例（如 `test_level_editor_smoke`）。
5. **PowerShell 5.1 的中文脚本坑**：给含中文的 `.ps1` 写文件必须带 **UTF-8 BOM**（否则按 GBK 读 ⇒ 乱码 + 解析失败）。改完自检头三字节应为 `239,187,191`。

---

## 4. 建议的机器设置（可选，能提速）

- **Windows Defender 排除**（GUT 要读上万个脚本文件，Windows 上常省 10~30%）：
  ```powershell
  # 管理员 PowerShell
  Add-MpPreference -ExclusionPath C:\Users\zjh30\CodeBuddy\20260906184916, D:\Godot.NET, "$env:APPDATA\Godot"
  ```
  撤销用 `Remove-MpPreference -ExclusionPath <同上>`。
  ⚠ 原机上这条**没成功**（权限不足，且 `Get-MpPreference` 报 `0x800106ba` ⇒ 当时 Defender 服务可能没在跑或已被第三方杀软接管），所以"能省多少"未知。

---

## 5. 备份完整性自检

```powershell
# git 包是否完好
git bundle verify F:\WorldMinesweeper_backup_20261006\04_snapshots\repo.bundle

# 复制的工程是否是一个健康的 git 仓库（HEAD 应与备份前一致）
git -C F:\WorldMinesweeper_backup_20261006\01_project log -1 --oneline
git -C F:\WorldMinesweeper_backup_20261006\01_project status --short   # 应为空
```

下一步要做什么，见 **`NEXT_STEPS.md`**。
