# 从这里开始（重装系统后的还原指南）

> 备份时间：**2026-10-06** ｜ 备份盘：`F:\WorldMinesweeper_backup_20261006\`
> 源码基线：`main` 分支（完整提交号与文件校验见同目录 `BACKUP_INFO.txt`）
> 原工程路径：`C:\Users\zjh30\CodeBuddy\20260906184916`（**建议还原到同一路径**）

---

## 0. 备份里有什么（**归档形式**，不是散装文件夹）

| 文件 | 大小 | 内容 | 用途 |
|---|---|---|---|
| `project.tar` | ~1.6 GB | **完整工程**：源码（`core`/`ui`/`test`/`tools`/`addons`/`assets`/`levels_lib`…）+ **`.git` 全历史** + `.codebuddy` 项目数据 + `docs/`（含本文件与 `HANDOFF_NEXT_STEPS.md`） | 主体 |
| `godot_runtime.tar` | ~705 MB | **Godot 4.7.2 mono** 运行时（含 `*_console.exe`，门禁脚本调用它） | 必须还原到 **`D:\Godot.NET\`** |
| `repo.bundle` | ~94 MB | **git 全历史单文件包**（`git bundle verify` 可校验） | 备用/异地/只取历史 |
| `03_user_data\` | 小 | Godot `user://` 用户数据（存档、`editor_bindings.cfg`、快照）+ 编辑器设置 `*.tres` | 可选，"无缝"建议还原 |
| `START_HERE.md` / `NEXT_STEPS.md` | 小 | 本文件 + **下一步清单/工作规则/踩坑** | 先读 |

> **为什么用 tar**：这台 U 盘**小文件写入极慢**（实测 0.18 MB/s、约 63 文件/秒 —— 20 万个小文件直拷要 ~25 分钟只完成 70%），改成"SSD 上打包成单一大文件 + 顺序拷贝"后，1.6 GB 只用 **91 秒**（17.6 MB/s）。
> **未包含 `.godot\`**（724 MB 导入缓存，可重建）。重装后第一次打开工程，Godot 会自动重建（几分钟，一次性）。

---

## 1. 还原步骤

### 1.1 装基础环境
1. **.NET SDK 9.0.317**（原机版本；`dotnet build` 与 mono 版 Godot 需要）
   - 校验：`dotnet --version` 输出 `9.0.x`
2. **Godot 4.7.2 mono → 必须放回 `D:\Godot.NET\`**
   ```powershell
   mkdir D:\Godot.NET
   tar.exe -xf F:\WorldMinesweeper_backup_20261006\godot_runtime.tar -C D:\
   # 校验
   Test-Path 'D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe'   # 应为 True
   ```

### 1.2 还原工程（两种方式，任选）
**方式 A：解归档（推荐，含未提交/被忽略的东西）**
```powershell
mkdir C:\Users\zjh30\CodeBuddy -Force
tar.exe -xf F:\WorldMinesweeper_backup_20261006\project.tar -C C:\Users\zjh30\CodeBuddy
# 得到 C:\Users\zjh30\CodeBuddy\20260906184916
```
**方式 B：从 bundle 克隆（最干净，只含被提交内容）**
```powershell
git clone F:\WorldMinesweeper_backup_20261006\repo.bundle C:\Users\zjh30\CodeBuddy\20260906184916
cd C:\Users\zjh30\CodeBuddy\20260906184916; git checkout main
```

### 1.3 还原用户数据（可选）
```powershell
Copy-Item -Recurse -Force "F:\WorldMinesweeper_backup_20261006\03_user_data\app_userdata\*" "$env:APPDATA\Godot\app_userdata\"
Copy-Item -Force "F:\WorldMinesweeper_backup_20261006\03_user_data\*.tres" "$env:APPDATA\Godot\"
```

### 1.4 为什么建议还原到同一路径
工程里有 **8 个脚本硬编码了 Godot 路径** `D:\Godot.NET\...`：
`tools\ci_check.ps1:32`、`tools\ci_quick.ps1:22`、`tools\gut_shards.ps1:47`、`tools\batch_pipeline.ps1:19`、`tools\fill_level_lib.ps1:52`、`tools\run_batch.ps1:22/40/44`、`tools\verify_all.ps1:22`。
工程路径本身不硬编码；若你改了工程位置，grep 一下再改：
```powershell
Get-ChildItem tools,test,docs -Recurse -Include *.ps1,*.gd,*.md | Select-String -Pattern '20260906184916|D:\\Godot\.NET'
```

---

## 2. 还原后第一件事：跑门禁，确认与备份前一致

```powershell
cd C:\Users\zjh30\CodeBuddy\20260906184916
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_check.ps1
```
**必须看到**：末行 **`CI GREEN (build + GUT + preset health)`**；unit **201 脚本 / 1473 用例 / Failing 0**；ui **33 脚本 / 212 用例 / Failing 0**；build **0 警告 0 错误**。
（耗时约 160~250 秒，随负载浮动；首次因重建导入缓存会更慢。）

日常迭代用增量门禁：`powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci_quick.ps1`

---

## 3. 门禁红了先读这条（能省几小时）

1. **先看是不是"缺摘要/并发假红"**：`gut_shards.ps1` 现在会对**没有摘要的分片自动定向重跑一次**；仍缺 ⇒ 判红并**打印可定位证据**（片号、分片日志绝对路径、字节数、有无 `[Failed]`）。看到 `[retry]` 说明发生过缺摘要。
2. **红了不许删 `tools\_shard_*.log`**（我曾删掉失败证据，导致那条用例至今无名）。
3. **Godot 没有 `--user-data-dir`**：多进程共用同一份 `user://` ⇒ 有状态用例**并发时假红**。**一切 Godot 运行都要拿锁**：
   ```powershell
   . tools\ci_lock.ps1
   $lk = Enter-CiLock -Path tools\.ci_lock -TimeoutSeconds 900
   try { & $G --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/xxx.gd -gexit } finally { Exit-CiLock -Lock $lk }
   ```
4. **`--check-only --script` 不是有效的语法检查**（不注册 autoload，会假报 `ThemeManager` 缺失）⇒ 要验就**真跑**一个加载它的用例。
5. **含中文的 `.ps1` 必须带 UTF-8 BOM**（否则 PS 5.1 按 GBK 读 ⇒ 乱码 + 解析失败）。改完自检头三字节 = `239,187,191`。

---

## 4. 建议的机器设置（可选）

```powershell
# 管理员 PowerShell：GUT 要读上万个脚本文件
Add-MpPreference -ExclusionPath C:\Users\zjh30\CodeBuddy\20260906184916, D:\Godot.NET, "$env:APPDATA\Godot"
```
撤销：`Remove-MpPreference -ExclusionPath <同上>`。原机上这条**没成功**（权限不足，且 `Get-MpPreference` 报 `0x800106ba` ⇒ 当时 Defender 可能没在跑），效果未知。

---

## 5. 备份完整性自检

```powershell
cd F:\WorldMinesweeper_backup_20261006
# 文件大小应与 BACKUP_INFO.txt 记录一致
Get-ChildItem *.tar,*.bundle | Select-Object Name,Length

# tar 可读（只读开头几项，很快）
tar.exe -tf project.tar | Select-Object -First 5
tar.exe -tf godot_runtime.tar | Select-Object -First 5

# git 包完好性
git bundle verify repo.bundle
```

下一步要做什么，见 **`NEXT_STEPS.md`**。
