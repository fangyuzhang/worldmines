# _backup —— 整机备份区（2026-10-25 整理）

本目录是 `01_Godot世界扫雷项目` 文件夹（除主工程外）的**完整备份**，
配合仓库根目录的主工程，实现「克隆本仓库 = 完整恢复全部项目内容」。

## 内容清单

| 路径 | 来源 | 说明 |
|---|---|---|
| `staged_levels_tar_2026-10-09/` | `01_Godot世界扫雷项目/世界扫雷_staged_levels暂存数据_2026-10.09.tar`（614MB） | 暂存关卡批次全量数据（192,532 个成员）。**拆分为 7 卷**（6×90MB + 1×46MB，MD5 已校验一致），因 GitHub 单文件限 100MB |
| `kim_project/` | `01_Godot世界扫雷项目/kim project（主项目_E盘）` | E 盘主项目文件快照（387MB→379MB）。内含 `lei/` 与 `世界扫雷-(copy)/` 两个早期完整工程（含 godotsteam/godot-wasm 等全量插件二进制）、`builds/` 早期导出 |
| `kim_project_builds_split/` | kim `builds/涓栫晫鎵浄.exe`（113.7MB） | 早期 Windows 导出，**超 100MB 限制拆为 2 卷**（90+19MB） |
| `kim_project_history.git.bundle` | kim 项目 `.git`（29.5MB） | kim 项目**完整 git 历史**（master @ e46d397） |
| `related_14minesweeper/` | `01_Godot世界扫雷项目/相关项目_14扫雷` | Python 扫雷原型 + `new project/14-boom`（Godot 变体参考工程）等。该目录 git 从未提交过，文件即全部 |
| `世界扫雷_MVP_交付（源码+8截图+交付说明）.zip` | 主工作区根 | 2026-09-08 MVP 交付包 |
| `mirror_0927.tar.gz` | 主工作区根 | 2026-09-27 工程镜像快照（490KB） |
| `workspace_dot_vscode/` | 主工作区 `.vscode/` | 编辑器配置 |

## 恢复步骤

### 1. 主工程（本仓库根目录）

克隆即得，无需额外步骤：

```bash
git clone https://github.com/fangyuzhang/worldmines.git
```

环境：Godot 4.7.2 stable .NET + .NET 9 SDK（首次打开自动恢复 NuGet、编译 C#）。

### 2. 暂存关卡数据 tar（合并分卷后解压）

```powershell
# Windows（cmd）
cd _backup\staged_levels_tar_2026-10-09
copy /b 世界扫雷_staged_levels_2026-10-09.tar.part-00+世界扫雷_staged_levels_2026-10-09.tar.part-01+世界扫雷_staged_levels_2026-10-09.tar.part-02+世界扫雷_staged_levels_2026-10-09.tar.part-03+世界扫雷_staged_levels_2026-10-09.tar.part-04+世界扫雷_staged_levels_2026-10-09.tar.part-05+世界扫雷_staged_levels_2026-10-09.tar.part-06 restored.tar
tar -xf restored.tar -C <目标目录>
```

```bash
# macOS / Linux / Git Bash
cat 世界扫雷_staged_levels_2026-10-09.tar.part-* > restored.tar
tar -xf restored.tar -C <目标目录>
```

> 校验基准：合并后 614,768,640 字节，MD5 `5627e84dfeff8fb5eb510a1d254c6d8e`。

### 3. kim 项目早期导出 exe（合并分卷）

```cmd
copy /b kim_project_builds_split\世界扫雷_win_exe.part-00+kim_project_builds_split\世界扫雷_win_exe.part-01 世界扫雷.exe
```

### 4. kim 项目 git 历史（可选，恢复完整提交记录）

```bash
git clone kim_project_history.git.bundle kim_project_with_history
```

### 5. 相关项目

`related_14minesweeper/` 直接可用（该目录原本就没有提交历史）。

## 刻意未入库的内容（及重新获取方式）

| 内容 | 原因 | 重新获取 |
|---|---|---|
| 主工程 `assets/ui/_downloads/`（473MB：Kenney UI 包 + Resource Boy 蜡笔纹理） | **Resource Boy 许可证禁止再分发**；且均为素材源库，主工程内已提交的是加工后的成品资源 | Kenney：[kenney.nl](https://kenney.nl)（CC0 自由下载）；Resource Boy：[resourceboy.com](https://resourceboy.com) 邮箱获取 |
| 各工程的 `.godot/` 导入缓存 | 体积大且 Godot 打开工程时自动重建 | 自动生成 |
| `.logs/`、`.gdmcp/`、`.codebuddy/` 等工具缓存与日志 | 一次性运行产物 | 不需要 |
| 根目录 `_staged_levels/`（解压出 3,380/192,532 个文件的不完整副本） | 完整数据在 §2 的 tar 分卷中，以此为准 | 见 §2 |
| `project.godot*.tmp`、`.git-msg-*.txt`、`_fill3_start.ps1` | 一次性临时文件 | 不需要 |

## 目录名对照

| 本仓库 | 原始位置 |
|---|---|
| `_backup/kim_project/` | `01_Godot世界扫雷项目/kim project（主项目_E盘）/` |
| `_backup/related_14minesweeper/` | `01_Godot世界扫雷项目/相关项目_14扫雷/` |
| `_backup/staged_levels_tar_2026-10-09/` | `01_Godot世界扫雷项目/世界扫雷_staged_levels暂存数据_2026-10.09.tar` |
