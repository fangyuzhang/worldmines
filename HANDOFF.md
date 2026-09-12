# 交接索引（精简版）

> 完整交接文档见：**`C:\Users\zjh30\Desktop\世界扫雷_Agent交接文档_v2.9.3.md`**。
> 本文档只放「新 Agent 上手前 30 分钟」必须知道的信息。

## 30 秒速览

| 项 | 值 |
|---|---|
| 项目 | 世界扫雷（15 变体 + 绘画 + 自举式 Mod 平台） |
| 引擎 | Godot 4.7.2 **.NET(mono)** + GDScript/C# 混合（OR-Tools 9.15 CP-SAT） |
| 主场景 | `res://ui/main_menu.tscn` |
| 版本控制 | **git（`main`）+ 远端备份**（工程外裸仓库 `C:\Users\zjh30\worldmines_git_backup\worldmines.git`）。改完 `git push origin main` |
| 测试 | GUT，**unit 255 用例全绿（254 通过 0 失败）**（2026-09-11 收敛后基线） |
| Mod 平台 | 单一 ModAPI（Def 数据包 / GDScript 代码 Mod / wasm Mod 三条创作路径） |

## 跑起来（必须先装 .NET 版 Godot）

```powershell
# 0) 路径
$GODOT = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
cd "C:\Users\zjh30\CodeBuddy\20260906184916"

# 1) 构建 C#
dotnet build

# 2) 刷新类缓存（新增 class_name 后必跑）
& $GODOT --headless --path . --import

# 3) 启动冒烟
& $GODOT --headless --path . --quit-after 10

# 4) 全量测试
& $GODOT --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/unit -gexit
```

⚠️ **不要用 Steam 版 Godot**（只有非 .NET 版，C# 编译不过）。

## 目录速记（平铺，非子目录）

| 目录 | 放什么 |
|---|---|
| `core/` | 引擎核心（棋盘/格子/变体/求解/生成/Mod/规则平台）63 个 .gd |
| `ui/` | 表现 + 会话 + 皮肤/设置/存档协调（autoload：RNGService/ModAPI/SettingsManager/ThemeManager/GameSession/AudioManager/SkinService） |
| `solver/` | **C#** CP-SAT 后端（仅 `RuleSolver.cs`） |
| `tools/` | wasm 测试模块（`clue_test.wasm`/`huge_mem.wasm`；2026-09 从 `archive/tools/` 恢复，勿再删） |
| `levels/` | 关卡 JSON（classic_01~10 手工 + generated_01~10 生成） |
| `test/unit/` | GUT 测试（顶层 `tests/` 是空目录，别被骗） |
| `archive/` | 遗留工具与生成脚本（`tools/` 下的 gen_*.gd、`spike/`） |

## 改功能去哪（反查）

| 想改 | 文件 |
|---|---|
| 翻格/扩散/插旗/判负 | `core/board.gd` |
| 线索型变体 | `core/clue_engine.gd`（内置）/`core/rule_builder.gd`（自举） |
| 全局约束 | `core/constraint_engine.gd` |
| 生成关卡 | `core/puzzle_generator.gd` |
| 难度量化/复杂度 | `core/puzzle_generator.gd`（`difficulty_from_stats` / `_minimal_clue_count`）|
| 难度分档 | `core/difficulty.gd`（TIERS / tier_of / filter_by_tier / generate_tiered）|
| 单格强制探测 | `solver/RuleSolver.cs::IsForcedCell` |
| 提示 | `core/hint_solver.gd` |
| 唯一解计数 | `core/brute_force_oracle.gd` / `solver/RuleSolver.cs` |
| 关卡 JSON 加载 | `ui/level_loader.gd` |
| 存档/崩溃恢复 | `ui/save_coordinator.gd` |
| 对局流程 | `ui/game_session.gd` |
| 棋盘渲染 | `ui/board_view.gd` |
| 绘画 | `ui/drawing_layer.gd` |

## 生成器能力边界（2026-09 实测，改生成前必读）

**一句话**：小盘高质量、大盘能出但慢。序贯可解（R01 不靠猜）保证很强，代价是性能随尺寸平方级劣化。

### 实测耗时

| 配置 | 耗时 | 判定 |
|---|---|---|
| 5×5 | 0.96s | ✅ 实时 |
| **8×8 / 14 雷（22%，生产默认）** | **459ms** | ✅ 实时 |
| 7×7 | 3.2–4.3s | ⚠️ 勉强 |
| 8×8 / 26 雷（40% 密度） | 16.4s | ❌ 离线 |
| 9×9 | ~17s | ❌ 离线 |
| 12×12（144 格） | 16–21s | ❌ 离线 |
| 六边形 547 格 / 109 雷（20%） | 16.8s | ❌ 离线 |

**实时判定线**：约 ≤50 格 且 雷密度 ≤25%（<1s）；超出即进离线批量区间。
**生产 UI 参数**：`ui/level_select.gd` 的 `SIZES=[5,6,7,8,9]`，雷数按 R07 固定（10/14/20/26/32，约 40% 密度）。

**全组合批量生成**：`tools/batch_all_variants.gd`（92 组合 = 15 单变体 + 56 G+C + 21 G+G × 5 尺寸 × 每类 N 关）。
自动跳过两类「不可生成」（都是事实而非 bug，产出废品才需要复工）：
1. **数学 UNSAT**（is_feasible 预筛，共 43 单元）：**含 rl 的组合 6×6 全 UNSAT**（6 项 ±1 序列总和恒奇，14 偶）；**含 qd 的组合 6×6/8×8 全 UNSAT**（四象限雷数须 4 倍数）；mx+rl 6×6/8×8（mx 偶数列盘每行雷数必偶 → 行差必偶 ≠ 1）；rl+qd 5×5/6×6/8×8（双重叠加）；
2. **难度不足**（design_skip，v2.9.3 决策）：FR 系 8 组合（difficulty 恒 0.06~0.28，线索直接锁雷）+ **mx+dt**（全局约束自带全部开局信息——骨牌外强制非雷 + 镜像锁死骨牌内选择，0 线索即可序贯推完，生成关难度恒 0.04~0.17）。
每个生成的关都过 `ProofLog.build` 序贯可解复核，不过即拒；单关批量入口（指定变体）用 `batch_pipeline.ps1`。

**dt 系列组合的难度特征**：dt 全局约束强（选中骨牌恰 1 雷 = 骨牌外全部禁雷），生成关以 easy 档为主（实测 dt 5×5 e/n/h=10/2/0、pf 9×9 全 normal），normal/hard 稀少——这是约束强度的数学后果，属正常现象。

**生成器删线索/布雷修复（v2.9.3）**：① `_prune_sequential` 保底至少留 1 条线索——全局约束自带开局信息的组合会把线索删光而被 `active.is_empty()` 拒绝整个 attempt（曾致 mx+dt 全灭）；② 单 G 构造式布雷失败后改用 CP-SAT `find_solution` 兜底（原 fallback 随机布雷违反全局约束，曾致 pf 9×9 接受率 0/12，修复后 12/12 且全 normal 档）。

**三道机制防线（v2.9.3，对内置与 Mod 变体一致生效——治本，防 bug 复发）**：
1. **生成器硬校验**：`_place_mines_rules` 出口统一校验「雷数 == 请求 count」，插件违规（如 QD 偷调平）拒收——违规只会导致「该组合生成失败」，永不产出坏关；
2. **唯一可行性真值**：`core/rule_feasibility.gd`（`RuleFeasibility.query`，CP-SAT is_feasible + 缓存 + dt 骨牌重采样）——UI 尺寸选择器 / 批量预筛 / Mod 自检三处共用的唯一入口，**不维护任何手写 UNSAT 规则表**（手写表曾漏 rl 6×6 / qd 6×6、8×8 致 UI 转圈）；
3. **生成后门禁**：`verify_batch`（Board 构造 + 序贯可解）+ `batch_audit_r07`（R07 雷数契约）+ ProofLog 复核。
**Mod 作者工具**：`tools/mod_selfcheck.gd -- <clue_id> [globals]`——全尺寸体检（可行性/试生成/复核/难度分档），作者上架前自跑。契约与防线详见 GDD 23 号 §3.1.x。

**生成质量优化批（v2.9.3）**：
- **多解采样（mod 试验修正版）**：`_find_solution_best` 对同约束采样 5 解——每次采样**随机把 1 个自由格固定为雷/安全**（解空间切片；CP-SAT 对简单模型「不同 random_seed 同一解」，hpair mod 试验实锤 5 seed 只出 1 种解），随后**淘汰最差（方差最大）解 + 候选集内确定性随机选**（原「取最均匀」会让「最均匀结构唯一」的约束全 seed 收敛同盘——多样性被压缩）。堆簇解结构差仍是序贯低产的根因（保留淘汰收益，rl_ep 9×9 实测 3/3 盘全不同）。回归测试 `test/unit/test_cross_seed_diversity.gd`。
- **多样性门**：批量生成时新关与组内已有盘峰值 Jaccard > 0.85 拒收（强约束小盘如 dt_4c 5×5 可行空间小、不同 seed 撞相似盘；随机独立盘期望 J≈0.25，0.85 只拦几乎同盘）。审计工具 `tools/diversity_report.gd`。
- **目标难度**：批量工具第 8/12 参 `target_difficulty`（>0 删到达标即停，可定向产 hard 档）。
- **报告汇总**：`tools/report_merge.gd`（多分片报告合并；全库权威统计仍用 `batch_audit_r07.gd`）。
- **UI**：不可行尺寸 tooltip 说明原因；生成中文案带按尺寸耗时预估。

### 服务器全量生成（2026-09-13 启动，无人值守）

**背景**：本地全量 5~10h 太慢，转腾讯云 CVM 跑（ins-0fwm81qf · 上海 · 2核2G · TencentOS 4 · 到期 2026-10-12）。
本地可安全关机——服务器侧全部「发射后不管」（nohup/setsid/systemd）。

**运维脚本**（`tools/` 下划线开头，**不入 git 但磁盘常驻**；Python 用 `C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe`）：
```
python tools\_cvm_tat.py runfile tools\_remote_progress.sh 120   # 查进度（产关数/心跳/进程）
python tools\_cvm_tat.py runfile tools\_remote_collect.sh 180    # 打包产物 → /root/wm_results.tar.gz
python tools\_cvm_pull.py <远程文件> <本地文件>                   # 拉回（分片+md5 校验）
python tools\_cvm_push.py <本地文件> <远程文件>                   # 推送（改代码后单文件推）
powershell -File tools\_analyze_issues.ps1                        # 本地分析拉回的 issues jsonl
```
凭证自动读 `~/.workbuddy/mcp.json`（tencent-cvm.env）。TAT 已知坑：字段在 `InvocationTaskSet` / `TaskResult.ExitCode`，传参必须 from_json_string（已在脚本封装）。

**服务器环境**：
- 代码 `/root/minesweeper`（精简包；**godot-wasm 插件被剔除** → 启动时 mod_api/wasm_sandbox 报解析错，**无害**——生成链路不碰 mod 系统，冒烟已证）；
- Godot 4.7.2 mono `/opt/godot/Godot_v4.7.2-stable_mono_linux_x86_64/…`；.NET SDK 9（dnf 装）；
- 该项目名已改 ASCII `wm_server`（user:// = `~/.local/share/godot/app_userdata/wm_server/`）；csproj 改名 `wm_server.csproj` + assembly_name 同步（原中文名被 tar 打包链双重编码损坏）；
- **生成**：2 分片 nohup 跑 `batch_all_variants`（`user://batch_all 10 40 0 <i> 2`，超时系数 3000）；2G swap 已挂；
- **守护**：systemd 服务 `wm-gen-watchdog`（10 分钟巡检：状态摘要写 /root/watchdog.log、分片异常退出自动重启续跑、服务器重启后自动拉起）；
- **记录**：`issues_shard_0X.jsonl`（empty / empty_timeout / tier_empty / proof_fail / dup_fp / similar 逐事件 + unit_done 心跳含 tried/made/耗时）。

**当前状态**：2026-09-13 03:05 启动，预计 4~6 小时（约 07:00~09:00 完成）。产物在服务器 `user://batch_all`（372 单元 × 10 关）。

**恢复流程（明天/新会话照此执行）**：
1. **查完成**：`runfile _remote_progress.sh`——看两分片 `all_report_shard_0X.json` 是否都已生成、进程是否已退出、watchdog.log 尾部；若分片消失且未完成 → watchdog 应已重启（查日志）；若 watchdog 也死 → 重发 `_remote_launch_full.sh` 续跑。
2. **收集**：`_remote_collect.sh` → `_cvm_pull.py /root/wm_results.tar.gz <本地>` → 解包 → 关卡 json 合入本地题库评估；
3. **分析 + 修复**：`_analyze_issues.ps1` 分析事件分布（tier_empty 0.04~0.28 属正常概率性进档；proof_fail/empty_timeout/similar 需逐个查）→ 定位 bug → 本地修复（模式参照 commit 3fabba6/fa5f6d0）→ `verify_all` → 提交 → 单文件推服务器重跑受影响单元。

### 能 / 不能

| 能 | 不能 / 受限 |
|---|---|
| 任意形状拓扑（矩形 + 通用邻接表异形） | **大盘实时生成**（根因见下） |
| 序贯可解 + CP-SAT 唯一解保证 | 异形下**线索强制 classic 邻域计数**（4n/sc/clock/knight 方向型不适用，会强制回退并告警） |
| 异形洞格固定非雷（CP-SAT 排除假解） | wasm 生成只适合小盘（黑盒穷举 200 万组合上限） |
| DT 骨牌 dominoes 落盘 + 加载同步 | E 类线索混合、DT 双布局 = **archive 遗产**，不服务生产 |
| 三种 Mod 创作路径（见下） | 非 classic 语义的 wasm clue 关卡，Board 加载走 classic 重算会不一致 |

### 性能根因（不要试图调参解决）

序贯可解验证 `solver/RuleSolver.cs::FindForcedCells` 是 **O(n²) 次 CP-SAT 求解**（每个自由格 2 次 assumption 探测）。

⚠️ **副作用**：默认 `timeout_ms=15_000` 会截断"删线索"阶段 → **线索删不干净、关卡偏简单**（冗余线索多）。放宽 timeout 能拿更精简线索，但耗时涨到 30s+。

要根治需算法改造（增量传播 / 分块求解 / 大盘改用静态唯一解口径放弃严格序贯可解）——**这是产品取舍，不是纯技术问题**。

## 难度体系（2026-09 P0-难度量化）

每个生成的关卡自带 `difficulty_profile`（Board 加载不读，纯元数据，供筛选/分档/展示）：

```json
"difficulty_profile": {
    "max_complexity": 7,            // ★ 主指标：最难一步的「必要线索数」
    "histogram": "7x1,3x1,2x2,1x1", // 复杂度直方图（对齐对标游戏的 SolutionSummary 格式）
    "difficulty": 1.86,             // 辅助：演绎紧凑度 Σ(1/批量)
    "rounds": 5,                    // 推理步数（轮数）
    "max_batch": 9,                 // 最大雪崩规模
    "clue_count": 6,                // 剩余线索数
    "clue_ratio": 0.40,             // 线索覆盖率（线索数/非雷格）
    "profile": "9x1,4x1,2x3",       // 批量直方图（辅助）
    "target_difficulty": 1.2        // 生成标签（对齐对标游戏的 L 字段）
}
```

**核心机制**：

| 概念 | 说明 |
|---|---|
| **必要线索数**（`max_complexity`） | 序贯演绎每轮，用 **unsat_core** 求「推出一步所需的最少线索数」（对齐对标游戏的「最少线索数」复杂度）。每条线索用 `use_i` 门控，assumptions 全激活，假设格取某值不可满足 → unsat_core = 必要线索子集（近似极小不可满足子集 MUS）。实测显著优于移除顺序敏感的贪心：大盘 45 线索时贪心 11 vs unsat 2，且更快（一次 Solve vs O(N) 次探测） |
| **删线索 = 提升难度** | 实测：不删（38 线索）maxC=4 → 删到 9 线索 maxC=6。删冗余后玩家被迫「精打细算组合线索」 |
| **复杂度上限随盘面增长** | 实测 maxC：5×5→4、6×6→6、7×7→10、9×9→11。必要线索数上限 = 线索数（大盘线索多 → 上限自然更高）。**注意**：组合约束（mx/rl）不提升反而降低 maxC（约束使盘面结构化、每步所需线索更少）——不要试图靠加全局约束冲上限，正确路径是加大盘面 |

**难度分档**（`core/difficulty.gd`，三档，对标对标游戏的无标记/!/!!）：

```gdscript
const TIERS := {
    "easy":   {"label": "轻松", "min": 0.3, "max": 1.2},
    "normal": {"label": "普通", "min": 1.2, "max": 2.2},
    "hard":   {"label": "挑战", "min": 2.2, "max": 1e9},
}
```

| 能力 | 函数 | 说明 |
|---|---|---|
| 档位归属 | `Difficulty.tier_of(d)` | 难度分 → 档位 |
| 运行时筛选 | `Difficulty.filter_by_tier(levels, tier)` | 读 difficulty_profile 按区间筛（**零生成**） |
| 定向生成 | `Difficulty.generate_tiered(...)` | 多 seed 尝试，达标即返回 |

**生成定向**：`generate_with_rules(..., target_difficulty: float = 0.0)`——>0 时删线索改为「难度驱动」（删到难度达标即停，早停=提速，同档难度可控）。注意 target 是**下限**（顺序删除的粒度会让 difficulty 跳跃），精确分档用 `filter_by_tier`。

**C# 侧新增**：`RuleSolver.IsForcedCell(spec, r, c)`（单格强制探测，2 次 assumption）；`RuleSolver.MinimalForcedClueCount(spec, r, c)`（unsat_core 必要线索数——`AddConstraint` 已有 `OnlyEnforceIf` 门控能力，每条线索 `use_i` 门控 + `SufficientAssumptionsForInfeasibility` 取 core，单 worker 求解保证确定性）。

**性能**：`FindForcedCells` 每格探测从 2 次 Solve 降到 1 次——先解出「第一解」，格在第一解里是雷则只探测「安全」方向（反之亦然），利用第一解的已知信息省掉一个方向的探测。删线索循环（删块 × 序贯演绎）占总生成耗时 93-97%；`find_forced_cells` 单次 6-174ms。

**删块策略**：从「二分删块」改为「顺序删除」（逐条尝试，O(n) 次验证）。实测 8×8 26雷：二分 16.2s/10 线索 → 顺序 8.0s/9 线索——40% 密度下大部分线索必要（删不掉），二分退化成 ~2n 次验证反而更慢；顺序删除快 ~2 倍且线索数更少。

**worker 调优结论**：`num_workers` 已做成 spec 可配置参数（默认 4）。实测 find_forced_cells：w=1 124ms / w=2 107ms / w=4 107ms / w=8 118ms——**4 已最优**，无需改。

**模型瘦身（P0-大盘提速）**：`BuildModel` 只为自由格建 BoolVar，safe/mine 格用常量（`_fixedCells` + 恒真/恒假 literal）替换——不再 `Add(cell==0/1)`。序贯演绎后期大量格已确定，模型显著缩小，单次 Solve 更快。9×9 32雷 15.8s → 8.1s。

**候选格剪枝（P0-大盘提速）**：`FindForcedCells` 只探测「被约束引用」的格（`_referencedCells`，ToExpr/ToVar/ToLit 记录），未被任何线索/全局约束引用的格只受总雷数约束——`free==remaining` 时全必雷（纯推理，零探测），`free>remaining` 时对称非强制（跳过）。9×9 8.1s → 6.4s，累计 2.5 倍提速。

**试过并否决的优化**（避免后来者重走）：① 枚举解分析强制格——序贯可解盘面解数 ≥1000，枚举比逐格探测慢；② 删线索「第一轮快速失败」——大多数线索删后第一轮仍有强制格，额外 ffc 是净浪费（实测变慢）；③ GDScript Thread × C# 共享单例并行——`Collection was modified`（线程不安全）。

**unsat_core 迭代收缩**：`MinimalForcedClueCount` 在单次 unsat_core 基础上加「迭代核心收缩」（把 core 作为下一轮唯一激活集反复求 core，上限 4 轮），逼近最小 MUS——精确最小是 Σ2 问题无法单模型求解，这是工程上最接近的方案。

**多 seed 并行（不做，实测否决）**：GDScript `Thread` 并发调用 C# `RuleSolver` 共享单例有根本性线程安全障碍（实测 `Collection was modified`，4 线程仅 2 返回）。要做需 ThreadLocal 重构 + 多线程生成器，风险远超收益。顺序删除已把生成从 16s 降到 8s，性能瓶颈已缓解。

**代码拆分**：`puzzle_generator.gd` 从 1167 行拆到 652 行——旧管线（旧实现 + 旧布雷策略）移入 `core/puzzle_generator_legacy.gd`（`PuzzleGeneratorLegacy`）。生产主路径（规则平台）保留在原文件；入口 `generate_constructive/mixed/dual/mixed_clue` 经 `_legacy` 委托。

**WASM 生产入口收尾**：`mod_select.gd` 补 wasm mod 黑盒生成入口（线索关 + 约束关两个按钮 → `WasmLevelGenerator.generate_clue/global`）。沙箱接线（加载 + 三道防线 + get_sandbox）此前已完成，wasm 测试 4/4 通过。

## Mod 创作契约（2026-09 P0 收敛后）

Mod 目录约定：`user://mods/<mod_name>/`

| 形式 | 入口 | 表达力 |
|---|---|---|
| **Def 数据包** | `defs/*.json` | 窗口×聚合原子 + 7 种约束 op（规则平台的**严格子集**） |
| **GDScript 代码 Mod** | `manifest.json`（`runtime=gdscript`）+ `entry.gd` | 完整 `RulePlugin`，可表达 Def 无法表达的加权/非线性语义 |
| **wasm Mod** | `manifest.json`（`runtime=wasm`）+ `.wasm` | 黑盒 `clue(邻域)` / `globalCheck(盘面)`，经沙箱三道防线 |
| **任意形状拓扑** | **`board.json`** | 通用邻接表 `{positions, adjacency}`，**不做形状枚举**（三角/六边/自定义同一格式） |

`board.json` 缺失 = 回退矩形。坐标可为任意值（含负），引擎会自动归一化到非负（见已知坑 #16）。

ModAPI 关键方法：`load_mod` / `unload_mod`（含规则清理）/`scan_mods` / `get_board` / `get_sandbox` / `find_rule_owner` / `has_capability`。

⚠️ 旧 `ModService` 已删除（2026-09 并入 ModAPI）——搜到它说明是过期文档。

## 红线（违反即返工，详见 GDD `21_红线规范_绝对不可改变.md` R01~R37）

- **R01** 序贯纯逻辑可解是硬红线（全程无二选一）
- **R02** 提示永不害死玩家（结论必须 100% 正确）
- **R03** 双视角隔离（Mod 与求解器只能拿 `PlayerView`，结构上无雷位）
- **R04** 构造式反向选格是官方关唯一生成算法（禁暴力重试）
- **R17** 禁止暴力测试/生成/解题
- **R19** 绘画功能永久保留
- **T1** 禁止写死 RGB（绘画层除外），一律走 `ThemeManager`
- **T3** `SaveData` 新增字段只能放 `metadata`（6 个顶层字段锁死）
- **T5** 三段式写盘

## 锁死接口（禁止改字段/签名）

`core/board.gd`（判负接口/`get_player_constraint`/`GameState`）、`core/grid_interface.gd`、`core/save_data.gd`、`core/rng_service.gd`。

## 已知坑

1. Steam 版 Godot 非 .NET → 必须用 mono 版。
2. 无 git，误删难回滚。
3. 程序集名/项目名含空格 `世界扫雷 (Copy)` → 命令行引用加引号。
4. `tests/`（顶层）是空目录，测试在 `test/unit/`。
5. ~~`test_wasm_sandbox.gd` 因 wasm DLL 环境稳定失败~~ **已于 2026-09 修复**：根因是 `res://tools/` 下的 wasm 测试模块被归档到 `archive/tools/` 导致读到空字节；已恢复文件，并给 `WasmSandbox.load_module` 加魔数防线（`\0asm`，避免 Godot `Wasm.load` 对垃圾字节 push_error 被 GUT 记为 Unexpected Error）。现在 4/4 通过——**请勿再删 `tools/` 下的 wasm 文件**。
6. 坐标：JSON `{r,c}` → `Vector2i(c, r)`；存档 `[row,col]` → `Vector2i(col,row)`。
7. 关卡 `revealed` 里 `value=0` 的格**故意不翻开**（保持 HIDDEN 浅色可点击），见 `core/board.gd:108-111`。
8. 失败局存档打 `ended` 标记，恢复时拒绝——禁止用「失败→回主菜单→继续」复活对局。
9. 规则关卡 `clue_rule` 未注册时 `level_loader` 显式报错（此前静默降级为经典 → 数字全错、不可解、不报错）。
10. 提示对非 classic 的规则关卡显式返回空：Def 推理套用 8 邻会给出**错误**结论，宁可不给。
11. 手工关 `revealed[].value` 引擎**不读**（真值一律用计算值），仅在加载时比对并告警。
12. QD 四象：只有奇数尺寸才跳过中央行列（偶数盘面已修正为均分）。
13. **Godot 4 中 `class_name` 与 autoload 同名会冲突**（`Class "X" hides an autoload singleton` 是硬错误）。项目约定：**autoload 脚本不写 class_name**（`core/mod_api.gd` 即如此）；测试需实例化时用 `preload("res://core/mod_api.gd").new()`。
14. 删掉某脚本的 `class_name` 后，`.godot/global_script_class_cache.cfg` **不会自动失效**，编译器仍按旧映射把它当脚本类（表现为 `Cannot find member "x" in base res://...`）。修复：删除该缓存文件 + 跑一次完整 `--headless --path . --import` 重建。
15. `BruteForceOracle.count_solutions_classic` **不接受自定义 check 回调**（只支持内置 `constraint` 枚举）。需要自定义 check（如 wasm globalCheck）时必须改用 `count_solutions_variant`——否则 check 定义了却从未被调用，**静默失效**。
16. **异形拓扑坐标必须非负**：CP-SAT 的 cell 索引是 `[0,rows)×[0,cols)`，负坐标会触发 `RuleSolver.FindForcedCells: Index was outside the bounds of the array`。Mod 可用任意坐标（含负），入口统一调用 `AdjacencyGrid.normalized()` 归一化。
17. **GDScript 缩进 tab/空格不能混用**（Parse Error）。本项目 `ui/`、`core/` 主流是 **4 空格**；新增代码务必用空格，否则出现"看着对齐却编译不过"。

> v2.9.3 已完成全量交叉验证，42 项发现中 24 项已修、2 项误报推翻、1 项回滚。
> 完整清单见 GDD `25_HANDOFF交接文档.md` §13.1（已修复）/ §13.2（未修复，含重构级与需拍板项）。

## 接手后第一步

1. 跑通 `dotnet build` + 全量测试，确认基线绿。
2. 读完整交接文档第 6 章（核心领域模型与算法）+ GDD `21 号红线`。
3. 精读 `core/board.gd` 与 `core/puzzle_generator.gd`，自己画一遍数据流。
4. 跑 `test_rule_platform.gd` 理解本阶段核心交付「自举式规则平台」。
5. **改生成器前先读本文「生成器能力边界」章节**（含实测耗时与 O(n²) 根因），避免重复踩大盘性能坑。
6. 跑 `test_mod_topology.gd` + `test_mod_api.gd` 理解 Mod 创作契约（`board.json` 任意形状 / 三种 Mod 形式）。
7. 跑 `test_difficulty.gd` + `test_difficulty_tiers.gd` 理解难度体系（必要线索数复杂度 / 三档分档）。
8. 补 git 首次提交（当前无版本控制，见开放问题 #1）。
