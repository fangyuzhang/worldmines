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
| 测试 | GUT，**unit 701 用例全绿 + UI 171 用例全绿（5 pending=probe40 未生成）**（2026-09-22 形状库接线后基线） |
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
| 难度分档 | `core/difficulty.gd`（**PEAK_WINDOWS 三档峰值窗口** / tier_of_peak / tier_of_profile / filter_by_tier；旧标量 TIERS 保留作画像）|
| 单格强制探测 | `solver/RuleSolver.cs::IsForcedCell` |
| 提示 | `core/hint_solver.gd` |
| 唯一解计数 | `core/brute_force_oracle.gd` / `solver/RuleSolver.cs` |
| 关卡 JSON 加载 | `ui/level_loader.gd` |
| 选关页（三页：单项/混合档/Mod） | `ui/level_select.gd`（页面排布与进度）+ `ui/variant_catalog.gd`（**成员一律从规则注册表派生**，禁止再写死变体表） |
| **进度键（`ProgressStore`）** | 生成关卡一律走 `LevelSequence.progress_key(path)` → `gen://<mode>/<size>/<idx>`；手工关保持路径。**写与读必须同键**（选关页打勾/解锁、`has_next` 都按此键读，写成文件路径会读不到 → 见坑表 #28） |
| 跳过本关（失败后的出路） | 终局页 `game_over.gd` 失败时显示 → `LevelSequence.skip_to_next()` 记 `skipped`（**不算通关**：`ProgressStore.record_skip` 与 `cleared` 分开存）→ 选关页 `_is_unlocked` 认 `cleared or skipped`，被跳过的方块显示 `›` 而非 `✓`。末关无下一关时按钮**仍显示但置灰**并改文案说明（见坑表 #29） |
| 终局 → 下一关怎么走 | `LevelSequence.request_focus(mode, size, auto_start=true)` → 选关页 `_consume_pending_focus()` 展开弹窗后**直接调 `_on_play()`**：生成仍归选关页（那里才有生成器与取消入口），玩家点一下就进对局，而不是回选关页再点一次（实测反馈：那不算「到下一关」） |
| 末关之后（跨尺寸） | `LevelSequence.advance(path)`：同尺寸 idx 用尽 → **下一个尺寸的第 1 关**（5→6→7→8→9）；最大尺寸的末关才是终点。`has_next` / `has_skip_target` / `skip_to_next` 全部基于它；`advance()` 刻意不判可行性（保持无依赖），目标尺寸不可行时由选关页 `_refresh_popup` 切到最近可行尺寸 |
| **Def 数据包能不能进选关页** | **不能也不该**（见坑表 #30）：Def 的 (window, aggregate) 是封闭枚举，永远等价于内置 8 线索 / 7 约束之一。现在的做法是把「等价关系」和「成品」摆出来：Mod 页标出 `≡ 哪个内置变体`（`PuzzleGenerator.def_to_rule`），并列出它**已生成的关卡**（`user://mods/<mod>/levels/*.json`）供直接开玩（`_open_mod_level`） |
| 交叉表的键盘 / 手柄导航 | 交叉格 `focus_mode = FOCUS_ALL`（其余按钮保持 FOCUS_NONE）：鼠标点一下即「进入」导航，方向键走格（上下=换线索、左右=换约束）、回车开这一关；`_style_card` 必须有 focus 态样式（看不见焦点等于没有） |
| 混合档有哪些组合 | **三张表**（轴不同，不是「叠几个约束」的数量差别）：T3 C 类 `mixed_all()`（结构 S × 观测 O = 7×10 = **70**）+ T3 F 类 `gg_all()`（结构 × 结构 = C(7,2) = **21**）+ T4 `conserved_all()`（结构 × 观测 + 1 守恒 = **50** 组，结构按 §10.1 循环指派）。轴 = `OBS_IDS` / `STRUCT_IDS` / `CONSERVE_IDS` 三个静态常量（GDD 口径的唯一事实源） |
| 混合档三张表怎么切 | 页内开关 `_mixed_tab`（0/1/2，`MIXED_TABS = 3`）。**焦点交接（下一关）必须同时切页和切表**——`_mixed_tab_of()` 按组合携带的算子轴判定，否则弹窗会开在一个看不见的表面上 |
| 为什么没有「任意两约束」表 | GDD §5.1 硬限制：观测恰 1、结构 ≤2、**守恒 ≤1**。代码的 `KIND_GLOBAL` 同时装 S 轴与 Z 轴（`pf` 是 S1、`mx` 是 Z1），按 KIND 配对会造出「两个守恒同关」的违规组合——早先那张 20 个的 G+G 表正是这么来的 |
| **Def 数据包（`defs/*.json`）的归属** | 它注册进 `DefEngine`（`ModLoader.load_mod_dir` 返回 `[{name,type}]`，`ModAPI` 存在 mod 记录的 `"defs"` 键），**不进 `RuleRegistry`** → 因此不产生选关页卡片，Mod 页如实列出它的 Def 名并注明去模组页生成关卡 |
| Def 包怎么玩 | 主菜单「模组」页 → `PuzzleGenerator.generate_with_engine(ModAPI.defs, def_name, ...)` 生成到 `user://mods/<mod>/levels/`。它与规则平台（CP-SAT 生成 / 提示 / 可行性）**是两条独立的链**，打通需要 Def→`RulePlugin` 桥 —— 尚未做，别误以为 Def 包是坏的 |
| 存档/崩溃恢复 | `ui/save_coordinator.gd` |
| 对局流程 | `ui/game_session.gd` |
| 棋盘渲染 | `ui/board_view.gd` |
| **异形棋盘几何**（挖洞方格 / 蜂窝 / 4.8.8 / 等轴菱面 / ASCII mask） | `core/shape_generator.gd`（纯函数几何内核，5 个 kind）；落盘工具 `tools/gen_iso_cubes_levels.gd` / `gen_style_shape_levels.gd` / `gen_shape_levels.gd` |
| **三档配色派生**（色码 → standard/dark/darker） | `core/palette_color.gd`（**双轴**：dark 提饱和降明度、darker 降饱和+收进同一明度带+朝底色靠；系数对着对标实测值反解，见文件头） |
| **四族铺装几何 / 异形×变体产关** | `tools/gen_geo_levels.gd`（SPECS 里加一行即多一关）；几何内核在 `core/shape_generator.gd` 的 `build_from_cells` 之后 |
| 异形页有哪些关 | `ui/level_select.gd::_shape_levels()`：扫 `res://levels/*.json`，**判据 = 含非空 topology 字段**（不维护白名单，新族自动进页） |
| 绘画 | `ui/drawing_layer.gd` |

## 异形棋盘（形状族，2026-09-22）

**几何内核**：`core/shape_generator.gd` 是纯函数库，一个 kind 一族几何，全部输出
`{positions, adjacency}`（+ `style` / `params`），经 `to_adjacency_grid(kind, params)` 直接变成
可上 CP-SAT 的 `AdjacencyGrid`：

| kind | 几何 | 出处 |
|---|---|---|
| `holed_grid` | 满格 Moore 8 邻挖洞（删格即删边，**不重连**） | `build_holed_grid` |
| `hex` | 正六边形盘，轴向 6 邻 | `build_hex` |
| `t488` | 截角正方形 4.8.8（八角 + 小方块，×2 整数化） | `build_t488` |
| `iso_cubes` | **等轴菱面**（60° 菱形 × 3 朝向 = 立方体阵列） | `build_iso_cubes` |
| `mask` | ASCII 轮廓 → 上述任一族（任意剪影成关） | `build_from_mask` |
| `tri_grid` | **等边三角网格** 3.3.3.3.3.3（度 3，线索只覆盖 3 格） | `build_tri_grid` |
| `trihex` | **3.6.3.6 三角+六边**（卡果梅；度 3/6，编织感） | `build_trihex` |
| `t31212` | **3.12.12 十二边+三角**（度 3/12，全库最大度数极差） | `build_t31212` |
| `ring` | **同心环盘**（甜甜圈；角向首尾相接 = 环状拓扑） | `build_ring` |


**等轴菱面（`iso_cubes`）——「看起来立体、实际是平面」的错觉盘**：
- 构造 = 正六边形三分铺装：格心 `C(i,j) = (√3/2·(2i+j), 1.5j)`，每格按 `[C, V_2k, V_2k+1, V_2k+2]`
  切成 3 个菱形。**数学上无缝无重叠** ⇒ 自动满足 2026-09-21 的连通视觉契约，不需要留缝。
- 三种朝向 = 立方体「顶面 / 右面 / 左面」在 30° 轴测下的三个面，数量严格 1:1:1。
  **眼睛数出 n 个方块，引擎里是 3n 个可点格** —— 这个「所见 ≠ 所点」的错位就是错觉本身。
- 邻接 = **共边**（内部格度恰 4）。反直觉结论：与**同朝向**面的跨方块共边 = 0 个（必须跨朝向），
  所以 `ISO_CROSS_EDGES` 表是几何反解出来的、不是想当然；`test_shape_iso_cubes` 会逐边重验
  「拓扑每条边两格真的共边」。
- 三面配色 = **同一色相的纯明度三步**（顶 1.00 / 右 0.78 / 左 0.58），走既有 `groups` 机制
  ⇒ 立体感不需要改渲染层一行，同时它还是一组真实的「分色雷数」约束。
  ⚠️ 三个值必须**严格等比**（同一个 RGB 乘系数）：非等比时 8bit 量化会让色相漂 6° 量级，
  肉眼就变成「三个不同的颜色」而不是「一个颜色的三档光」（初版手调值踩过，已锁进测试）。
- 产关：`godot --headless --path . -s res://tools/gen_iso_cubes_levels.gd` → `levels/iso_01~05.json`
  （挖洞 = 整块挖掉一个立方体 = 「空了一个方块」的凹坑）。当前 5 关峰值 2/2/4/5/8，三档都有货。

**四族「精确铺装」几何（2026-09-22 第二批）**：`tri_grid`（等边三角）/ `trihex`（3.6.3.6 卡果梅）/
`t31212`（3.12.12 十二边+三角）/ `ring`（同心环盘）。它们与前三族的**结构性差别**是
**邻接不再写手写方向表**：由 `ShapeGenerator.build_from_cells()` 从多边形集合反推（判据 = 共边，
两格共享整条边）。拓扑与几何同源 ⇒ 结构上不可能脱节；`test_shape_tilings.gd` 逐边复验。

这四族带来的**玩法差异**（不是换皮）：

| 族 | 度 | 玩法性格 |
|---|---|---|
| `tri_grid` | 3 | 每个线索只覆盖 3 格 —— 信息极稀，靠组合推理（最「硬」的一族） |
| `trihex` | 3 / 6 | 同一盘里两种邻域密度，编织状视觉 |
| `t31212` | 3 / 12 | 十二边形信息多、三角形信息少，一眼能读出「哪块是大格」 |
| `ring` | 3~6 | **环状拓扑**：角向首尾相接（第 n−1 与第 0 扇区相邻），守恒类约束在此天然有趣 |

**关卡库接线（2026-09-22 第三批，完成）**：四族纯 classic 关经
`tools/import_shape_levels_to_lib.gd` 入库（按峰值分档，v4.1 三档口径）。**入库规则**：
源文件前缀白名单（`holed_/hex_/art_/iso_/tri_/trihex_/t31212_/ring_`，sty_*/va_*/vg_*
等风格/变体关走手工异形页）+ 库尺寸窗 [5,9]（选关页弹窗只认 SIZES；越界席位会造成
孤儿 mode）。实际入库 13 集 / 17 关：shape_holed 5 尺寸 9 关、shape_hex 5 尺寸 5 关、
shape_iso 9×normal 1 关（等轴 01 peak 5）、shape_tri 8×easy 1 关、shape_trihex 9×easy 1 关；
t31212/ring 全部越界（37/51、12/18 宽）暂不入库、卡片自动隐藏。选关页形状卡扩为 7 席
（`ui/variant_catalog.gd` shape spec 表），`catalog().has()` 守卫保证空 mode 不出卡。
`test_shape_library.gd` 改为「全尺寸契约组（holed/hex）+ 期望表组（iso/tri/trihex）」；
`t488` 补登记进 STYLE_TO_MODE（shape_t488，暂无入库内容）。工具自校验临时目录从
`user://` 改 `res://levels_lib/.tmp_check`（user:// 在 CI/沙箱可能整盘只读，实测曾把
17 集全部误剔除、catalog 清空）——LS2 一并暴露并修掉「进程启动后动态入库 → 演示预设
写进库模式」的时序回归（`_ensure_mock` 写前二次复核）。

铺装正确性怎么验（`test_shape_tilings.gd` 的核心判据）：**每个铺装顶点的入射面内角和 == 360°**。
这一条同时证明「无缝」与「无重叠」——比逐边量缝隙锐利（缝隙只管相邻对，顶角和管整张图的闭合性）；
边界顶点（格集被裁掉一侧）允许 < 360°，但**任何顶点都不允许 > 360°**。

产关：`godot --headless --path . -s res://tools/gen_geo_levels.gd` → 8 个纯 classic 形状关
（`tri_*` / `trihex_*` / `t31212_*` / `ring_*`）+ 7 个「异形 × 变体」关（`vg_*`）。
⚠️ **变体那批必须在能装配 Mod 算子包的进程里跑**（S/Z/dt 规则以 Mod 身份提供；
沙箱/无写权限时 `bootstrap_bundled_mods()` 全失败、注册表只剩 9 条内置规则，
`generate_with_rules` 会**静默返回空**、报「48 次尝试无一达到峰值（最高 -1）」）。
可用组合按**拓扑**逐族而定：三角网格+s1 / 3.6.3.6+s2 / 3.12.12+s3 / 环盘+s5 / 环盘+z2 / 环盘+dt 实测可产；
**3.6.3.6 + z2 不成立**（相邻行锁需要「行」语义，编织盘没有行 —— 48 次尝试全空）；
需要行/环序语义的约束应配环盘（环盘的 y 坐标就是环号）。

**三档配色口径（v2，2026-09-22）**：旧口径是明度单轴乘系数 `V × 1.0/0.72/0.52`；
换成双轴（`core/palette_color.gd` 的 `tiered()`）后 dark 是「加深」不是「变暗」、
darker 是「统一落影」。判定见 `test_palette_color.gd`（dark 饱和度不得低于基色、
darker 八色明度必须收敛到同一档）。

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
**mx 系列组合的难度天花板（v2.9.3 实测记录）**：mx 镜像对称约束产生大量强制格 → 关卡推理天然简单，难度量化偏低（mx_sc / mx_loopruns 的 tier_empty 率 77.5%，40 seed 才凑满 10 关，接受率 36.6%）——与 FR/mx_dt 同类「设计特性而非 bug」：不跳过（用户要求全部变体都要产关），但需知道其生成成本高、难度天花板低；`_analyze_issues.ps1` 已自动标注 tier_empty≥50% 的组合。

**生成器删线索/布雷修复（v2.9.3）**：① `_prune_sequential` 保底至少留 1 条线索——全局约束自带开局信息的组合会把线索删光而被 `active.is_empty()` 拒绝整个 attempt（曾致 mx+dt 全灭）；② 单 G 构造式布雷失败后改用 CP-SAT `find_solution` 兜底（原 fallback 随机布雷违反全局约束，曾致 pf 9×9 接受率 0/12，修复后 12/12 且全 normal 档）。

**三道机制防线（v2.9.3，对内置与 Mod 变体一致生效——治本，防 bug 复发）**：
1. **生成器硬校验**：`_place_mines_rules` 出口统一校验「雷数 == 请求 count」，插件违规（如 QD 偷调平）拒收——违规只会导致「该组合生成失败」，永不产出坏关；
2. **唯一可行性真值**：`core/rule_feasibility.gd`（`RuleFeasibility.query`，CP-SAT is_feasible + 缓存 + dt 骨牌重采样）——UI 尺寸选择器 / 批量预筛 / Mod 自检三处共用的唯一入口，**不维护任何手写 UNSAT 规则表**（手写表曾漏 rl 6×6 / qd 6×6、8×8 致 UI 转圈）；
3. **生成后门禁**：`verify_batch`（Board 构造 + 序贯可解）+ `batch_audit_r07`（R07 雷数契约）+ ProofLog 复核。
**Mod 作者工具**：`tools/mod_selfcheck.gd -- <clue_id> [globals]`——全尺寸体检（可行性/试生成/复核/难度分档），作者上架前自跑。契约与防线详见 GDD 23 号 §3.1.x。

### v3.0 换血：新算子开工流程（O1 试点结论，2026-09-14）

**O2「邻序」试点结果（2026-09-14 完成，S3 第二个算子）**：
- 实现 `demo/mods/o2_linxu/`：编码 ℓ_pq ⟺ (v_q < v_p) 按格态三分（p 雷→ℓ=0 / q 雷→ℓ=1 /
  双非雷→线性比较双向），f = Σℓ —— **不引入跨格共享 v 变量**（避免平台改造，纯 Mod 表达）；
- **预检 20/20 全合格**（一步到位，对比 O1 的 0%→方案 A）；GUT 9/9（golden + **f≥v 固有性质** + 零扩散契约）；
- **实测难度 0.53~2.21**（5×5=1.53、8×8=2.21、9×9=1.85）——**normal/hard 档有货**，
  对比 O1 的 0.03~0.55（D=5 最高难度贡献设计兑现）；零值扩散正常（0 值格可扩散）；
- 代价：编码重（8×8 单关 ~81s 本地）——量产成本显著高于 O1，按尺寸分期跑。

**O1「对穿」试点结果 + 方案 A 修正（2026-09-14 完成）**：
- 试点（Mod 形态 `demo/mods/o1_duichuan/`）：插件/契约正确（测试 8/8、编码 20/20），
  但设计预检全尺寸 **0%**——根因：内部线索格少（5×5 仅 ~5.8 条）+ 值域低（0–4）+
  外圈无线索 → 信息量 < 全盘雷分布熵（GDD §8.2 预警「欠产」，实测「零产」）。
- **方案 A 落地**（外圈也铺线索）：`applies_to` 放宽到全部格 → **预检复测 0% → 100%**
  （20/20 × 5 尺寸）；全链路生成通过（0.1~1.2s/关、全序贯可解、round-trip 0 不一致）。
- **批量链路打通**（`batch_all_variants` v3.0 新参数）：
  · 第 9 参：额外组合规格 `clue[+g1+g2][@5-7]`（逗号分隔多项；尺寸用单值/闭区间）；
  · 第 10 参：Mod 预加载（demo/mods/<name> 逗号分隔，量产命令自带 Mod 清单、可复现）；
  · `limit=-1` = 仅额外组合模式（Mod 规则冒烟/量产的干净入口）。
  实测 `o1@5-9`：9 关入库（7×7+ 全 easy）。
- **已知特性（记录，非 bug）**：5×5/6×6 难度天花板过低（max_diff 0.10/0.07）→ 预筛判
  「难度不可达」自动跳过；7×7 及以上正常进 easy 档。难度旋钮（若需更高难度）是后续
  观察项。

**O3~O7 全系完成 + 平台扩展（2026-09-14 夜，S3 观测轴 7/7 就绪）**：

| 算子 | 目录 | 预检 | 难度 | 量产状态 |
|---|---|---|---|---|
| O3 分档 | `o3_fendang` | 过 | normal/hard 有货 | ✅ 服务器在跑 |
| O4 变径 | `o4_bianjing` | 20/20 | **1.30~2.29**（D=5 天花板兑现） | ✅ 服务器在跑 |
| O5 三角 | `o5_sanjiao` | 20/20 | **0.03~0.10（不可达）** | ⏸ 冻结（见下） |
| O6 热度 | `o6_redu` | 10/10 | 0.05~1.14 | ✅ 已推（编码重，分期） |
| O7 奇显 | `o7_qixian` | 20/20 | **0.78~2.55** | ✅ 已推 |

**S4 平台扩展三件套（O4 驱动，提交 4945741）**：
1. `RuleBuilder.bool_var_at/int_var_at`——显式索引共享变量池（C# aux 按索引全局池化）；
2. `RulePlugin.build_global_clue_constraints` 全局钩子——「全盘配额」类约束（Σw=k）落点，
   IR 并入 `spec["globals"]`；
3. `build_spec` aux 去重（同索引只声明一次）。
**编码坑（教科书级）**：C# 翻译器要求 **wsum/lin 的项是「叶子变量引用」**——`lin` 的 xs
不能嵌 `sum` 表达式（报「wsum 项必须是变量引用: sum」）；需要时把嵌套表达式**平铺展开**
到 cell/aux 叶子（O4 四条约束全部平铺化后通过）。

**O5「三角」冻结结论（2026-09-14，增难实验已做）**：
- 现象：玩法/验证全通，但难度 0.03~0.10（全尺寸 < easy 门槛）——**信息型简单**：
  值域 0–4 + 雷密度低 → 大量 0 值线索（9×9 46 条线索约 44 条 0 值），
  「0 值直推」主导推理 → 步数少 → 分低。
- 实验：**启用遮蔽（supports_mask + [lo,hi] 区间编码，已提交 6203236）**——mask=5/12
  难度**逐位不变**。根因：现有遮蔽机制（随机选格 + 固定 [1,hi] 区间）打在非关键格、
  对 0–4 值域弱化有限——**不足以救难度**。
- **建议（不阻塞主线）**：O5 归档为「入门档候选」；三个改进命题并入**难度体系 v2**：
  ① 低端档位（入门/教学档）的产品决策；② 遮蔽选格策略（随机 → 关键推理格优先）；
  ③ 遮蔽区间可配置（支持更低 lo / 更宽弱化）。与 M05「hard 档稀少」同族处理。

**O5b「对角」换变体实验（2026-09-14，结论：否决）**：
- 设计：隐藏「看主/副对角组（各 2 块）」+ 全盘配额 Σdir=k（借用 O4 验证过的机制），目录
  `demo/mods/o5b_duijiao/`。
- 结果：**precheck 编码可行 10/10 但序贯 0/10（假阴性——见下「工具坑」）；probe 全尺寸 FAIL**
  （5×5~9×9 全零产）。
- 机理结论（重要设计规律）：**「计数型信息」规则不能靠「隐藏维度」增难**——
  · O4 可行是因为**本体信息充足**（1/2 半径都有完整计数），隐藏后再减半仍够推；
  · O5 本体已信息不足（0 值主导），隐藏方向是**再砍一半信息 → 直接死亡**；
  · 反向（增信息）= 更简单。**两头堵——结构性死路**。
- **最终定性**：O5 系列的「简单」是规则信息结构决定的（教学友好）；「达标难度」的希望应
  放在**信息充足基座**的族（比较型如 O2 / 隐藏型如 O4）上，不在计数型上修。O5 保留为
  「入门档候选」（配合难度体系 v2 的低端档位决策）。

**预检工具适用性坑（2026-09-14 记录）**：`op_design_precheck` 与部分工具**不走 place_mines**
（随机布雷 + compute_clue 的「无状态语义」）——对**有隐藏状态的规则**（O4/O5b）会：
① 「编码可行」项用退化语义对完整编码，**可能假阳性**（O4 曾侥幸 20/20）；
② 「序贯可解」项同理，**可能假阴性**（O5b 的 0/10 即假阴性——真实可解性须走 probe/生成流程）。
**新隐藏态算子上线前，预检数据仅作参考，以 probe 全链路为准。**

**——已修复（2026-09-16，两轮）**：
- **第一轮**：隐藏态规则改走 **place_mines 真实布雷 + hidden_state 落盘传递**（与生产同契约），不再用退化语义。复测：**o5x 真盘 4/4 合格**（修复前测的是「全主斜退化盘」）；**o5b 真盘 0/3 零产**（旧「0/10 假阴性」定性修订为「真盘零产」）；无隐藏态规则零影响。
- **第二轮（复盘评审发现的 regression，重要教训）**：第一轮的「覆写检测」用 `get_script_method_list()` **不可靠**——**该列表包含继承方法** → **所有规则**都被判为隐藏态规则 → **o10**（无构造式布雷）走 place_mines 得**空盘**（指纹：线索数 = 盘面格数、序贯必然零产）。**修正**：① 判据改为 **`declares()` 声明优先 + 已知名单兜底（o4/o5x/o5b）**；② 加**空布雷防御回退**（place_mines 返回空 → 随机布雷）。**复测**：o1/o3/o9/**o10 全 3/3 合格**、o5x 路径正常、o5b 归入名单。
- **教训**：判断「规则能力」**不能用方法列表推断**（继承污染，无法区分继承 vs 覆写）——**应走显式声明**（同期落地 `RulePlugin.declares()` 能力契约 + `PuzzleGenerator.generate_with_opts()` 参数对象化，评审 C1/C3 整改）。

**O5 换变体「斜脉」+ 难度体系 v2「入门档」（2026-09-14 深夜）**：
- O5 原「三角」不达标（0.03–0.10）→ 遮蔽/隐藏变体实验穷尽否决 → **换变体「斜脉」**：
  隐藏斜向二选一（主↘/副↙）+ 全盘配额 Σs=k——与 22 席零机制重叠（边界明示：vs O4
  「隐藏投影 vs 隐藏半径」）；实测 8×8=0.38 / 9×9=0.65 入档；5×5–7×7 暂缓。已上服务器
  （o5x，per_tier=30，单关约 5 分钟——多解采样+删线索开销，提速项在案）。
- 文档同步：GDD 终版 4 处修订 + 关卡集总表 108 行「三角→斜脉」→ 均入库（`fbe08f4`）。
- **难度体系 v2 · 入门档落地**（`84f9051`）：四档 **intro[0,0.3) / easy / normal / hard**；
  `<0.3` 不再 tier_empty 弃盘；预筛改「异常兜底」（不再按 easy 门槛截杀）；batch/audit/
  merge/report 全适配；实证 O1@5×5「0 产出（判不可达）→ intro=1+easy=1」；全量 368/368。
  提案文档 `难度体系v2_入门档.md`；待接：UI 展示标识、档位命名统一（轻松/普通/挑战 vs
  普通/困难/噩梦）。
- **新机会（待拍板）**：「斜脉」5×5–7×7（0.04–0.08）可改「入门档量产」——原暂缓理由消失。

**新算子标准开工流程（此后每个算子照此执行）**：
1. 写 RulePlugin（Mod 形态先行，ASCII id，参考 `demo/mods/o1_duichuan` 与 `hpair_rule_mod`）；
2. **设计预检**：`tools/op_design_precheck.gd -- <clue_id> [globals] [trials]`——
   全尺寸×N 盘「全线索序贯可解率」快检（~2 分钟）。**<60% 需构造式布雷设计；=0 需修线索布局**——
   在写构造式布雷/量产之前先过这一关，避免白跑。预检不过时优先参考 **O1 方案 A**
   （扩大线索覆盖面：让更多格携带线索——最简单、信息量论证最硬）；
3. （如需要）构造式布雷（O 系按 GDD §6.3 基元；GDD 未列者按预检结论补设计）；
4. golden/契约 GUT 测试 + 全链路 probe（生成→ProofLog→Board round-trip）；
5. 量产（候选雷数回退已就绪）+ 门禁验收。

**接口坑（实测记录）**：`RuleOracle.build_spec(active, known_mines, masked)` 的 `known_mines`
期望 **Vector2i 数组**（内部取 `m.y/m.x`）——传 `[r,c]` 数组会在 `.y` 处报错且错误信息不指明参数；
诊断/工具脚本注意格式（生成器内部路径不受影响）。

### 变体替换作战手册（v2.9.4 准备，2026-09-14）

**当前基线**（快照：`_staged_levels/variant_snapshot_20260914.json`）：
- CLUES 9：classic / 4n / clock / hv（多值：行+列分量对）/ fr / loopruns / distsum / sc / knight（未入批量组合）
- GLOBALS 8：mx / rl / pf / qd / dt / ep / 4c / total_mines（元规则）
- 批量组合清单唯一来源：`tools/batch_all_variants.gd` 的 `CLUES` / `GLOBALS` 常量
- 3597 关旧题库已暂存（`_staged_levels/`，见其 MANIFEST.md），不入 git、不占正式目录

**新变体接入两条路（均已实战验证）**：
1. **内置**：`core/rule_registry.gd` 加规则类（`KIND_CLUE` / `KIND_GLOBAL`）→ `_register_builtins` 注册；
2. **Mod**：`demo/mods/<ascii_id>/`（manifest.json + entry.gd，RulePlugin 子类 + `on_load` 注册）→ `ModAPI.load_mod`（参考 `demo/mods/hpair_rule_mod` 与 `custom_rule_mod`）。

**接入后自动生效的链路（自举式平台，零额外接线）**：UI 尺寸选择器（RuleFeasibility 预筛）/ 批量预筛 / mod_selfcheck / verify_batch 门禁 / 生成器全流程。

**替换流程（建议顺序）**：
1. 写规则（RuleBuilder 原语；表达力边界：imp 右端仅单字面量、const 字面量已支持、多值线索返回分量对）；
2. `tools/mod_selfcheck.gd -- <clue_id> [globals]` 全尺寸体检（可行性/试生成/复核/难度）；
3. 更新 `batch_all_variants.gd` 的 CLUES/GLOBALS（替换旧变体 id）；
4. 小范围生成冒烟（limit_combos）→ 门禁抽查（verify_batch）→ 全量生成（分片+续跑）→ final_verify 总验收；
5. 旧变体题库在 `_staged_levels/` 永久保留，随时可恢复/对照。

**实战坑（务必过一遍）**：
- 多值线索（如 hv 返回分量对）→ 门禁 round-trip 走 `_value_equal` 已支持；新多值规则勿再走 int() 强转；
- 「难度天花板低」的组合会被 DIFF_PRECHECK 预筛截停（4 次全 tier_empty 且上限 <0.15）——新变体同样适用，属特性非 bug；
- tar 打包链会损坏中文文件名（码页双重编码）——mod 目录/文件一律 ASCII id；
- 跨组合同盘：同全局约束 + 同 seed 共享构造式布雷随机流（线索不同谜题不同）——需消除时用「组合 seed 偏移」（batch 层，不动生成器复现语义）。
- **门禁 clue_ratio 告警必须用相对口径（2026-09-16 实测结案）**：clue_ratio 随档位**单调递减**
  （intro 中位 0.92–0.95 → easy 0.64–0.80 → normal 0.44–0.59 → hard 0.47–0.52，o9/o10/o8 三批 2233 关一致），
  这是 tiered 产线「朝档走 + 达标即停」的**必然**——低档盘信息多是对的，hard 盘已删到档位目标下限附近（无压缩空间）。
  **绝对阈值（旧 0.5）会把正常的 intro/easy 盘 100% 判告警**（o9 252/252、o10 603/662），真信号被淹没。
  现口径：按（尺寸 × 档）**组内离群检测**（中位 +0.15，组内样本 ≥5）→ 同批只报 4%/5.5%（o9 10 关、o10 36 关），
  且报的是真异常（如 9×9|intro 组中位 0.80 而离群盘 0.96–1.00）。诊断脚本 `tools/_diag_clue_ratio.py`（分层中位 + 超阈值占比）。
  **连带修复**：`verify_batch` 的档位统计曾漏 `intro`（v3.0 新增档未同步，o9 250 关 intro 一关不计）——已补四档全计。
  **教训**：门禁阈值类告警必须与「产出策略」对齐设计，否则「按设计正常」的盘会被误报成缺陷，淹没真信号。
- **链式量产守护不能用 `pgrep -f <关键词>` 串联（2026-09-16 实战：整链静默死锁）**：
  为把多批量产排成队，曾给每批挂一个「等前序结束就启动」的守护：
  `setsid nohup bash -c "while pgrep -f 'batch_all_variants'; do sleep 300; done; <Godot 命令>"`。
  **缺陷**：`pgrep -f` 匹配的是**完整命令行**，而每个守护自己的 `bash -c` 命令行里**就含**
  `batch_all_variants` 这个字符串（既在 pgrep 模式里、也在它的 Godot 命令里）→ pgrep **永远非空**
  → 第一轮结束后 **11 个守护全部永久等待**，整条链无声停摆（日志 0 字节，看不出异常）。
  **正确做法**：① 判据用**进程名**而非命令行——`ps -eo comm= | grep -q '^Godot'`
  （该机 comm = `Godot_v4.7.2-st`，bash 守护不含 Godot）；② **全链只留一个等待点**，
  之后开 N 条并行 lane（核数分配），而不是每批各挂一个守护（多守护既易撞车又难观测）。
  脚本：`tools/_remote_fix_chain.sh`（写 `/root/gap_chain.sh`，A/B 双 lane 串行 14 批）。
  **教训**：自指式判据（判据串出现在判据自身所在进程的命令行里）必然恒真——写进程/文件守卫时先自问
  「这个判据会不会匹配到我自己的进程？」。
- **隐藏态回填必须落在「产物真相源」上，且门禁失败原因要可行动（2026-09-17 收割实测）**：
  o5x 存量补字段（2026-09-16）只做了**本地副本**，服务器上的 302 老关未补 → 次日收割原样带回，
  门禁 **250/1006 FAIL 且原因全为「()」**（ProofLog 的 `reason` 空串路径：推理中踩雷 state=LOST
  时循环从顶部 break，reason 保持初始 ""）。三处教训：
  ① **回填/修补类操作要同步回服务器真相源**（或并入收割标准步骤），否则每次收割都会重新带回旧病；
  ② `Board.load_level` 载入**无 hidden_state 字段**的隐藏态规则盘 → 线索重算全错 → 推理踩雷，
     但 round-trip 门禁③④**照样通过**（Board 与独立重算都错、互相一致）——只有序贯可解⑤能拦住；
  ③ **门禁 FAIL 原因必须可行动**：已把「()」显式化为「推理踩雷（LOST…）」，并对「隐藏态规则缺
     hidden_state 字段」（按 `declares()` 判定，**不能用 has_method**——基类空实现继承污染）附上
     回填指引。修复后复验：**o5x 1006/1006 OK**；服务器 batch_o5x 回填后缺失 0。

**生成质量优化批（v2.9.3）**：
- **多解采样（mod 试验修正版）**：`_find_solution_best` 对同约束采样 5 解——每次采样**随机把 1 个自由格固定为雷/安全**（解空间切片；CP-SAT 对简单模型「不同 random_seed 同一解」，hpair mod 试验实锤 5 seed 只出 1 种解），随后**淘汰最差（方差最大）解 + 候选集内确定性随机选**（原「取最均匀」会让「最均匀结构唯一」的约束全 seed 收敛同盘——多样性被压缩）。堆簇解结构差仍是序贯低产的根因（保留淘汰收益，rl_ep 9×9 实测 3/3 盘全不同）。回归测试 `test/unit/test_cross_seed_diversity.gd`。
- **多样性门**：批量生成时新关与组内已有盘峰值 Jaccard > 0.85 拒收（强约束小盘如 dt_4c 5×5 可行空间小、不同 seed 撞相似盘；随机独立盘期望 J≈0.25，0.85 只拦几乎同盘）。审计工具 `tools/diversity_report.gd`。
- **目标难度**：批量工具第 8/12 参 `target_difficulty`（>0 删到达标即停，可定向产 hard 档）。
- **报告汇总**：`tools/report_merge.gd`（多分片报告合并；全库权威统计仍用 `batch_audit_r07.gd`）。
- **UI**：不可行尺寸 tooltip 说明原因；生成中文案带按尺寸耗时预估。

### 服务器部署流程（固化 checklist，2026-09-15）

**工具**（`tools/` 下划线工具链的一员，Python 路径同「跑起来」节）：
- `python tools/engine_sync_check.py` —— 一键核验本地 vs 服务器全量 md5（ENGINE/TOOLS/MODS 分级；退出码可入 CI）；
- `python tools/bundle_sync_engine.py` —— 引擎文件打包一次推（全量 ~77 文件 157KB，1 分钟级）。

**checklist（每次部署必跑全序列）**：
① 本地测试全绿 → ② git commit → ③ 推改动文件（或 bundle）→ ④ **`engine_sync_check.py` 必须「一致 OK」** → ⑤ C# 有改动时 `dotnet build` → ⑥ 重启任务（断点续跑自动接续）→ ⑦ 日志验证（mod 加载 + 参数回显）。

**为何固化**：「按需推文件」模式曾致 core/ 长期未同步（首次实战查出服务器 core/ 大面积停留 09-13/09-14 快照）——并直接造成「旧引擎把 C# 超时误报当不可行 → 强制格假通过 → 产出推不动的盘」事故（60 关，09-15 侦破修复）。

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
2. **一键总验收**（跑完后在服务器上，全输出写 /root/final_verify.log，耗时 1~4h）：`runfile _remote_final_verify.sh 28800 --bg`——串联 verify_batch v3（R07/schema/round-trip/序贯可解）+ diversity_report（全局多样性 J 分布）+ 日志 ERROR 扫描 + 产物打包 `/root/wm_results.tar.gz`。
3. **收集**：`_cvm_pull.py /root/wm_results.tar.gz <本地>` + `_cvm_pull.py .../final_verify.log <本地>` → 解包 → 关卡 json 合入本地题库；
4. **分析 + 修复**：`_analyze_issues.ps1` 分析（含端到端接受率/布雷成功率榜单、性能异常检测、难度天花板标注）→ 定位 bug → 本地修复 → `verify_all` → 提交 → 单文件推服务器重跑受影响单元。

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

**难度分档**（`core/difficulty.gd`，v4.1 三档峰值窗口——2026-09-20 对齐《14MV2》常量矩阵；旧标量 TIERS 保留作「紧凑度画像」）：

```gdscript
const PEAK_WINDOWS := {   # 玩家档位判据（唯一事实源）：峰值 = 单步最大必要线索数
    "easy":   {"label": "普通", "min": 2, "max": 3},
    "normal": {"label": "困难", "min": 4, "max": 5},
    "hard":   {"label": "噩梦", "min": 6, "max": 20},
}
# PEAK_OVER := 21  # >=21 超纲淘汰；peak 0-1 纯一眼盘同样不进任何档（对方普通档 MIN=2 同语义）
```

| 能力 | 函数 | 说明 |
|---|---|---|
| 档位归属（玩家） | `Difficulty.tier_of_peak(peak)` / `tier_of_profile(dp)` | 峰值 → 档位；超纲/无画像返回 "" |
| 运行时筛选 | `Difficulty.filter_by_tier(levels, tier)` | 读 difficulty_profile 按峰值窗口筛（**零生成**） |
| 窗口谓词 | `Difficulty.in_window(peak, lo, hi)` / `tier_range(tier)` | 量产窗口验收与 UI 取窗 |
| 定向生成（旧标量） | `Difficulty.generate_tiered(...)` / `tier_of(d)` | 旧口径画像与回退，不再是玩家档位 |

**生成定向**：`generate_with_rules(..., target_difficulty: float = 0.0)`——>0 时删线索改为「难度驱动」（删到难度达标即停，早停=提速，同档难度可控）。注意 target 是**下限**（顺序删除的粒度会让 difficulty 跳跃），精确分档用 `filter_by_tier`。窗口模式下（量产工具的峰值窗口参数）走窗口验收，标量定向自动关闭。

**v4.1 存量重标（服务器侧流程）**：52,988 关存量仍按旧四档落盘——**收割回本机后、导入库之前**必须先按三档窗口重标再导入（工具与导入闸门均已同步三档）：
```
python tools/retier_stock.py --src <harvest批次目录...> \
    --out _staged_levels/relib41_harvest \
    --over-dir _staged_levels/relib41_harvest_over \
    --too-easy-dir _staged_levels/relib41_harvest_tooeasy \
    --unknown-dir _staged_levels/relib41_harvest_unknown \
    --prewon-dir _staged_levels/relib41_harvest_prewon
godot --headless --path . -s res://tools/import_batch_to_lib.gd -- _staged_levels/relib41_harvest --overwrite
```
本地实测基线（2026-09-20，6 个 harvest 批次共 14,609 关）：三档 9,392（easy 20.7% / normal 23.4% / hard 55.9%）+ 淘汰 tooeasy 5,017（34.3%）+ 超纲 35 + 开局即终局死盘 140；自校验 OK。

**C# 侧新增**：`RuleSolver.IsForcedCell(spec, r, c)`（单格强制探测，2 次 assumption）；`RuleSolver.MinimalForcedClueCount(spec, r, c)`（unsat_core 必要线索数——`AddConstraint` 已有 `OnlyEnforceIf` 门控能力，每条线索 `use_i` 门控 + `SufficientAssumptionsForInfeasibility` 取 core，单 worker 求解保证确定性）。

**性能**：`FindForcedCells` 每格探测从 2 次 Solve 降到 1 次——先解出「第一解」，格在第一解里是雷则只探测「安全」方向（反之亦然），利用第一解的已知信息省掉一个方向的探测。删线索循环（删块 × 序贯演绎）占总生成耗时 93-97%；`find_forced_cells` 单次 6-174ms。

**删块策略**：从「二分删块」改为「顺序删除」（逐条尝试，O(n) 次验证）。实测 8×8 26雷：二分 16.2s/10 线索 → 顺序 8.0s/9 线索——40% 密度下大部分线索必要（删不掉），二分退化成 ~2n 次验证反而更慢；顺序删除快 ~2 倍且线索数更少。

**worker 调优结论**：`num_workers` 已做成 spec 可配置参数（默认 4）。实测 find_forced_cells：w=1 124ms / w=2 107ms / w=4 107ms / w=8 118ms——**4 已最优**，无需改。

**模型瘦身（P0-大盘提速）**：`BuildModel` 只为自由格建 BoolVar，safe/mine 格用常量（`_fixedCells` + 恒真/恒假 literal）替换——不再 `Add(cell==0/1)`。序贯演绎后期大量格已确定，模型显著缩小，单次 Solve 更快。9×9 32雷 15.8s → 8.1s。

**候选格剪枝（P0-大盘提速）**：`FindForcedCells` 只探测「被约束引用」的格（`_referencedCells`，ToExpr/ToVar/ToLit 记录），未被任何线索/全局约束引用的格只受总雷数约束——`free==remaining` 时全必雷（纯推理，零探测），`free>remaining` 时对称非强制（跳过）。9×9 8.1s → 6.4s，累计 2.5 倍提速。

**试过并否决的优化**（避免后来者重走）：① 枚举解分析强制格——序贯可解盘面解数 ≥1000，枚举比逐格探测慢；② 删线索「第一轮快速失败」——大多数线索删后第一轮仍有强制格，额外 ffc 是净浪费（实测变慢）；③ GDScript Thread × C# 共享单例并行——`Collection was modified`（线程不安全）。

**o5x 斜脉性能实测与提速结案（2026-09-16）**：
- 单次尝试剖面（8×8 @26雷，本机，`_profile_o5x.gd`）：**18.4s，其中删线索 t_prune≈17s（93%）**——绝对瓶颈；
  place≈0s（构造式快）、verify≈1.3s；attempts=1 一次过（好盘）。
- 产线口径对照（o5x 全量 unit_done 实测）：
  · 旧批（per_tier=30 死磕时代）：**437.9s/关（8×8）、628.9s/关（9×9）**（大量失败重试堆出——单单元曾 5.2h）；
  · 新批（tiered + stall=30）：**13.7s/关（8×8）、28.8–60.1s/关（9×9）**——**已快一个量级**（「303s/关」已过时）。
- 归因（已发生的优化）：引擎 C# 超时误报修复 + tiered/stall 早停（低档优先、满档即停）+ 历史删线索优化
  （模型瘦身/候选剪枝 2.5x）。
- 剩余空间评估：**无低风险高收益项**——删线索试探为 O(n) 全试一遍（改删除顺序不省试探次数）；二分删块
  已实测否决（见上）；worker/模型/剪枝均达调优结论。**结案**：保留监控——新算子若同类瓶颈，先看
  t_prune 占比再决策。

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

### 钩子返回值契约（v3.1，硬性）

代码 Mod（`runtime=gdscript`）的钩子 **必须 `return true` 表示完成**：

```gdscript
func on_load() -> bool:
	RuleRegistry.default().register(MyRule.new())
	return true
```

- GDScript 无 try/catch：钩子内运行时错误只中止脚本栈（`call` 返回 null），实例依然 valid——`ModAPI._call_hook` 以「返回值是否为 true」判定成败，**没写 return true 的钩子一律按失败处理**。
- `on_load` 失败 → `load_mod` 回滚：按 diff **反向注销**该次注册进 RuleRegistry 的规则、按 diff **反向清除**写进共享 DefEngine 的 Def，然后整包拒绝。
- 内置 22 算子即以此形式实装于 `demo/mods/`（o1_duichuan…z5_dengcha，26 个包），全部已适配 `return true`——**新增算子 mod 照抄此结构，漏写会导致规则静默未注册**（表象：生成失败/「规则未注册」报错/大片测试红）。
- `unregister` 拒绝注销内置规则（H3 保护，v3.1）——diff 回滚误伤内置表会被拒绝并 push_warning。

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
17. **GDScript 缩进 tab/空格不能混用**（Parse Error）。本项目**逐文件风格不统一**：`hud.gd`/`game_session.gd`/`ui_theme.gd`/`progress_store.gd` 用 4 空格，`level_select.gd`/`variant_catalog.gd` 用 tab——改文件前先看它用的是什么，别把「看着对齐却编译不过」引进文件。
18. **隐藏态规则载盘丢失（2026-09-15 夜侦破，重大）**：`Board.load_level` 不恢复规则隐藏态——o5x 斜向选择 s1 / o4 隐藏半径在 JSON 无字段（DT 骨牌有专用 `dominoes` 落盘先例；后引入的隐藏态规则缺对应机制）→ 载盘后 `_compute_clues` 用空/残留状态 → **线索数字全错** → 门禁推理踩雷、游戏内将显示错误数字。**「生成时复核通过」具欺骗性（同进程状态仍正确，灯下黑）**。判盘/复验先做 seed 重放恢复（`rng.seed=seed*1000003+attempt` → `place_mines`，实测 100% 匹配、恢复后 100% 可解）；修复方案（export/import 接口 + 落盘 + 存量补字段，DT 先例通用化）见桌面待办「零」节。
19. **mod 钩子必须 `return true`（v3.1）**：`ModAPI._call_hook` 以返回值判定成败（GDScript 无 try/catch，运行时错误只能靠「没返回 true」探测）。漏写 → `load_mod` 判失败 → **diff 反清理把该 mod 注册的规则全部撤销**（表象：大片测试红「规则未注册」）。修复先查 `demo/mods/*/entry.gd` 是否漏写（见「Mod 创作契约 → 钩子返回值契约」）。
20. **UI 对引擎内部的直写已收敛（v3.1）**：Board 新增公共 API `undo_explode`/`restore_cell_states`/`evaluate_win`/`recompute`——UI 层**禁止**再直写 `cell.state`/`board.state`/调用 `_` 前缀私有方法（历史：game_session 直写曾与存档/撤销逻辑互相踩踏）。game_session 已拆出 `NoGuessGuard`（无猜守卫，Board 按次传参不持引用）与 `HintCoordinator`（提示编排）。
21. **Windows 跑全量 GUT 不要加 `-gno_error_tracking`**：该参数禁用 GUT 错误追踪，会把「预期 push_error」断言型测试（如 test_t8_quarantine / test_t9_state_machine）打成假失败。Linux 沙箱防误报才用它。
22. **Button 的最小宽度由 `text` 撑出，且 Button 不支持 autowrap**（只有 `Label` 有）。给卡片/格子按钮塞长说明文字会把它撑到几百 px——流式容器随之少排一列、末件被挤出可视区（选关页实测踩过）。正确做法：按钮 `text` 留空，内部放子 `Label`（`autowrap_mode` + `max_lines_visible` + `OVERRUN_TRIM_ELLIPSIS`），宽度只由 `custom_minimum_size` 决定；子节点 `mouse_filter = MOUSE_FILTER_IGNORE` 保证点击落到按钮上。
23. **连到 `control.draw` 信号的 lambda 里，`draw_rect` 会落在外层脚本对象上**（GDScript lambda 的 self 是外层对象，不是那个控件）→ 必须显式写 `btn.draw_rect(...)`，否则报 `Drawing is only allowed inside this node's _draw()`。加自定义绘制（如卡片底部进度条）时踩过。
24. **`autowrap_mode` 的 `Label` 最小宽度≈0**，放进 `HFlowContainer` 会被压成一列单字（整段说明竖着排满一屏）。这类「整行文字」必须挂在 `VBoxContainer` 下占满一行，不要混进流式容器。肉眼才发现的问题，测试要用 **`size.x > 阈值`** 断言锁住（见 `test_ls10_def_mod_lists_its_defs`）。
25. **Def 数据包与规则平台是两条链**：`ModLoader` 把 Def 写进共享 `DefEngine`，代码/wasm Mod 走 `RuleRegistry`。选关页变体表**只**由 `RuleRegistry` 派生，所以 Def 包天然没有卡片——这是链路差异，不是 bug（误判过一次）。要让它出现在选关页必须造 Def→`RulePlugin` 桥并且处理「无构造式 builder 的 Def 组合无法 CP-SAT 生成」的情况。
26. **改代码时同一文件的多处编辑必须串行**（工具层教训，非引擎坑）：并行发出的两处编辑各自基于同一份旧内容做替换，后落地的会整段覆盖前一处的改动——实测 `ui/variant_catalog.gd` 新增的 `gg_all()` 定义被同批另一处编辑抹掉，报 `Function "gg_all()" not found in base self`（编译失败的连锁反应更迷惑：`level_select.tscn` 实例退化成裸 `Control`，所有 UI 测试齐刷刷报 `Nonexistent function '_open_popup'`）。看到「所有 UI 测试同时失败」时先查是不是依赖脚本编译不过，而不是去改 UI。
27. **流式容器默认左对齐**（`FlowContainer.alignment` 默认 `ALIGNMENT_BEGIN`）：卡片宽度不能整除可视宽时，余量全堆右侧——实测 1280 宽下 4 列卡片左留白 0px、右留白 90px，肉眼就是「没居中」（用户实测反馈）。多行卡片流一律设 `alignment = FlowContainer.ALIGNMENT_CENTER`（`last_wrap_alignment` 默认继承它）；`GridContainer` 的表同理会左贴，改 `size_flags_horizontal = SIZE_SHRINK_CENTER`。**测试要用「左留白 == 右留白」断言锁住**（`test_ls5_cards_do_not_overlap`）：这类纯观感问题断言不写就永远不会有人发现。
28. **进度键：写与读必须同源**（v3.3 修复，用户报「希望加『下一关』」时挖出的真 bug）：`GameSession._finish` 原先直接拿 `level_path`（`user://gen_levels/<mode>_<size>_<idx>.json`）当进度键，而选关页打勾/解锁与 `LevelSequence.has_next` 一律查**序列键** `gen://<mode>/<size>/<idx>`——写的和读的永远不是同一个键。症状极具误导性：功能明明写好了（按钮、解锁、焦点交接全在）却**永不触发**，看起来像「缺功能」。现在统一走 `LevelSequence.progress_key()`；`ProgressStore` 首次加载时把旧的路径键迁移到序列键（幂等、字段按 or/min/相加合并、不丢 best）。**动任何进度相关代码前先问：这个键从哪来、谁按同一个键读？** 判别技巧：真实通关的 `best` 是浮点（`12.0925…`），mock 时代的假记录是整数（`20.0`）。
29. **功能在「此处不适用」时，宁可显示说明，也不要让入口凭空消失**（v3.3 实测反馈）：每套只有 `LEVELS_PER_SET` 关，末关没有「下一关」概念——早先实现是直接 `visible = false`，玩家（正好在末关踩雷）的结论是「按需求该有的按钮没出现」，无法区分「不支持」与「坏了」。现在改为**按钮仍显示、置灰 + 文案换成「已是本套最后一关」**。通用判断：禁用态要带原因（文案 / tooltip），而不是静默隐藏。**排查这类反馈的前提是先确认玩家处在哪个状态位**——本例用诊断脚本遍历 idx=0/1/2 才看清「只有第 3 关会隐藏」，凭猜测会去改根本没坏的逻辑（当时我差点去改 has_skip_target，而它是对的）。
30. **GUT 把 `push_error` 归到「当时正在跑的那个测试」**：报错位置会**错位**。2026-09-18 把旧算子移出主项目后，`user://probe40/` 里用旧码（`4c_4n`）生成的历史关卡无法解析 → 每次加载都 push_error → 紧随其后的 **14 个 Mod 系统测试**（能力授权 / wasm / 卸载 / 扩展点）集体报 `Unexpected Errors`，看着像 Mod 系统整个垮了（其实它们单独跑 13/13 全过）。**看到一批互不相干的测试同时报 Unexpected Errors，先查 `push_error` 的真实来源**（`addons/gut/gut_config.gd` 的 `failure_error_types` 默认含 `push_error`），别去改那些测试——修法是**在会抛错的入口之前判断前提**（如加载前先查规则是否注册），从源头不让错误产生。
31. **`generate_constructive` 只认旧变体码表**：它第一步是 `VariantRegistry.resolve(variant_code)`，而官方 22 席（`o*/s*/z*`）不在那张表里 → 传进去直接返回空。官方席位必须走 `generate_with_rules(clue, globals, ...)`。**批量 / 存档工具若还挂在旧入口，就覆盖不到官方席位**。另：`ModLoader.load_mod_dir(dir)` 是 **Def 数据包**加载器（扫 `defs/*.json` → `DefEngine`），对代码 Mod 会以「无法打开 defs 目录」失败、`loaded=0`（实测）；代码 Mod 走 `ModAPI.load_mod`。还有个纯语法坑：`load_mod_dir` 是实例方法，写成 `ModLoader.load_mod_dir(...)` 会**编译期** Parse error。
32. **组合口径靠「静态三轴常量」，不要改成注册表实时内容**：`VariantCatalog.OBS_IDS / STRUCT_IDS / CONSERVE_IDS` 是 GDD 口径的唯一事实源，混合档三表（C 类 70 / F 类 21 / T4 50）全由它们派生。把遍历改回 `clue_ids()/global_ids()` 会被**其它测试残留注册的试验规则**污染——实测某文件注册的 `broken_global`（故意 UNSAT）残留下来，让「每个全局规则都该能生成」的断言失败。
33. **调用生成器前先确认算子的 KIND 放对位置**：`generate_with_rules(clue_id, globals, …)` 的第一个参数是**线索**，结构 / 守恒算子（`KIND_GLOBAL`）必须放第二个参数——正确写法是 `generate_with_rules("classic", ["s1"], …)`。把 `s1` 当 clue 传 → 生成器找不到该线索规则 → **一路返回空**，症状与「这个算子产不出关卡」一模一样（2026-09-18 为此白查一轮：临时探针证明 `s1` 的布雷器完全正常，7×7/12 → 12 颗、8×8/26 → 26 颗，纯属参数放错位置）。排查这类「某算子产不出」时，先分清它的 `get_kind()` 再决定放哪个参数位。
34. **变体池收敛（2026-09-18，GDD 终版对齐）**：8 个终版之外的旧算子（`4n / sc / knight / fr / distsum / hv / ep / 4c`）已移入 `demo/mods/legacy_rules` 并列入 `ModAPI.BUNDLED_SKIP`（产品默认不加载，玩家在模组页自行启用）；选关页只显示官方 id，6 个与官方席位等价的实现（`clock / loopruns / pf / mx / rl / qd`）按 `HIDDEN_RULES` 隐藏但保留在注册表里。**测试进程由 `.gutconfig.json` 的 `pre_run_script`（`test/_pre_run.gd`）统一装配备用包**：它们以 mod 身份进注册表（`source="mod"` → 归 Mod 页），既不占单项变体页的 24 卡，也不进三轴 → 产品口径仍是终版。另注：`.gutconfig.json` 里**不要**写 `dirs`/`include_subdirs`，否则会盖掉命令行的 `-gtest`，把「跑一个文件」变成「跑全量」（实测踩过）。
30. **Def 是规则平台的「声明式子集」，不是新玩法**（v3.3）：`DefEngine` 的 window/aggregate/op 是**封闭枚举**，`generate_with_engine` 本来就委托 `generate_with_rules`（先翻译成规则 id）。所以任何 mod Def 要么 ≡ 某个内置变体（`n4+sum ≡ 4n`、`symmetry_axis ≡ mx`），要么映射不到规则平台而**根本生成不出来**——「把 Def 做成独立选关页变体」这条路在技术上等于造重复项或死格（与 variant_catalog 注释里警告的同一件事）。碰「让 Def 出现在 X 界面」这类需求时先问三句：它等价于哪个内置变体？它的成品（关卡文件）落在哪？玩家在哪儿能玩到？

35. **产物 mode 必须以关卡 JSON 为准，不能按目录名判（2026-09-19 取证）**：量产链（`batch_all_variants.gd` 的「额外组合」路径，参数如 `classic+s1@5-9`）产出的目录名是 `x_classic_s1` / `x_o10`，**与库内 mode id（`s1` / `o10`）不同名**。导入工具若按目录名做命名契约闸门，会把服务器 **15 批产物 100% 拒掉**（探针实测 14/14 被拒，形同整条链白跑）。正确做法：**mode 由关卡 JSON 的 `clue_rule` + `global_rules` 推导**（与《关卡集供给对账》同口径）——单算子 `o*/s*/z*`、C 类 `结构_观测`、F 类 `结构_结构`、T4 `守恒+结构+观测`；目录名只用于遍历，目录名识别仅作兼容（剥 `x_`/`c_`/`g_` 前缀与 `classic` 底座）。已修：`tools/import_batch_to_lib.gd`（`_mode_from_level`）+ 回归 `test/unit/test_import_batch.gd`（含 `x_*` 形态断言）。**教训**：凡「产物命名/布局」相关判据，先拿真实产物目录名跑一遍再做闸门。

36. **尺寸政策与 seed 预算：两条容易「不知不觉跑偏」的量产口径（2026-09-19 固化）**：
   ① **尺寸政策**（`tools/batch_all_variants.gd` 的 `sides_for()`）：总表是**逐层**尺寸范围——守恒 z* 只收 **7×7/8×8/9×9**、变径 o4 从 **6×6** 起、C 类从 **7×7** 起、F 类与 T4 只收 **8×8/9×9**、其余 5×5–9×9。此前所有路径按「全尺寸」跑 → z 轴 5×5/6×6 白产（实测 5 个 z 算子 × 800 关 ≈ 4,000 关机时，2026-09-19 已归档 z1/z4 的 1,065 关）。政策在工具里**优先于规格**（`classic+z1@5-9` 也会被收窄），回归 `test/unit/test_batch_side_policy.gd`。**别把政策放宽成「全尺寸」来"多产内容"。**
   ② **seed 预算**：`seed_max` 是「**每单元（组合×尺寸）**的种子上限」，每个 seed 至多产 1 关 → 它才是「每集最多多少关」的封顶，`per_tier` 只在其内生效（服务器链实测：每档 100 关需 ~1200）。`fill_level_lib` 默认已改 `SeedMax=0 → max(40, PerTier×10)`；旧默认 40 配 `-PerTier 100` 会让每单元最多 40 关且**不报错**（静默薄集——导入报告现已列出薄集清单）。

37. **形状关「相邻格贴边」是设计决定，不要给它补 0.95 收缩**（2026-09-22 记录）：对标作品把每块瓦片缩到 0.95 让格与格之间留 5% 缝；**本项目是反过来的** —— 2026-09-21 定的是「同一连通区域内相邻格不得有可见空隙」，`tools/gen_style_shape_levels.gd::SHRINK` 与 `test/unit/test_shape_gap_contract.gd`（阈值 0.005×格宽）都在守这条。对照外部实现时很容易把它当成「漏做了缝」，补上去会直接把这道德国测试打红 —— 先读那条契约再动手。
> v2.9.3 已完成全量交叉验证，42 项发现中 24 项已修、2 项误报推翻、1 项回滚。
> 完整清单见 GDD `25_HANDOFF交接文档.md` §13.1（已修复）/ §13.2（未修复，含重构级与需拍板项）。

38. **`AdjacencyGrid.normalized()` 会平移拓扑坐标，但不会平移你生成的几何**（2026-09-22 实测踩到）：
   落盘关卡同时存两份坐标 —— `topology.positions`（邻接）与 `custom_shapes.cells[].center`（渲染）。
   工具里若写成「先把 geometry 按公式生成 → 再把 topo 过一遍 normalized()」，而几何的最小坐标不是
   (0,0)（如 3.6.3.6 的首个六边形落在 (2,2)、或挖洞把第 0 行/列挖空），拓扑就会被整体平移、几何不会
   ⇒ 两份数据错位：渲染画在一处、邻接算在另一处，玩家看到的是**连错的格子**。
   症状很好认：`topology` 的边引用了 `custom_shapes` 里不存在的坐标（测试报「边 a-b 两端应在盘内」）。
   修法：**两边按同一个最小坐标平移**（两个生成工具都有 `_align_geo_to_origin()`，并在落盘前逐点核对
   「几何格 ∈ 拓扑格」）。凡是「拓扑与几何分别生成」的工具都要做这一步。


39. **异形盘「线断/颗粒感」双根因：落盘量化 + 共享边重复描边**（2026-09-22 修）：
   ① **数据层**：三个几何落盘工具（`gen_geo_levels` / `gen_iso_cubes_levels` / `gen_style_shape_levels`）
   的 `_custom_shapes()` 原来用 `snappedf(…, 0.0001)` 量化格心与相对顶点——相邻两格的同一条
   共享边两侧各 snap 一次，误差可叠加到 1e-4 世界单位（全库曾实测 2599 对错位顶点）。渲染按
   `scale(≈48px/unit)` 放大后仍 ≤0.005px，本身不可见，但足以让**重复描边**错开一个像素行。
   已全部改为 1e-7（剩余错位 ≤4e-6 = 双精度噪声级）。另外 `ShapeGenerator.t31212_cells_geo`
   曾从量化键反推三角形格心（`k/100000` 有 ≤5e-6 网格误差）→ 已改为存首见浮点坐标作代表值。
   ② **渲染层**：`board_view._draw_grid_lines()` 逐格画闭合折线，共享边画两遍——错位放大后
   表现为「1px 断线/颗粒感」；且 1px 斜边无 AA，60° 对角线逐列硬跳 2 行（「像素感」来源）。
   现在静态帧走 `_draw_grid_lines_dedup()`（0.05px 空间哈希做顶点归并 → 每条边只画一次；
   横竖边无 AA、斜边开 AA），波浪高亮帧保留旧的逐格路径（逐格线色/线宽反馈不变）。
   矩形路径（`draw_rect`）不受影响。**`test_shape_tilings.gd` 的 `_vkey` 已同步升到 1e-7**——
   今后再动几何落盘精度或生成公式，先跑这个测试；它红了大概率是几何又分裂，不是测试过严。
   截图核验口径：全图孤立背景缝像素应为 0（HUD 文字的 2 个是固有杂点，与棋盘无关）。


## 接手后第一步

1. 跑通 `dotnet build` + 全量测试，确认基线绿。
2. 读完整交接文档第 6 章（核心领域模型与算法）+ GDD `21 号红线`。
3. 精读 `core/board.gd` 与 `core/puzzle_generator.gd`，自己画一遍数据流。
4. 跑 `test_rule_platform.gd` 理解本阶段核心交付「自举式规则平台」。
5. **改生成器前先读本文「生成器能力边界」章节**（含实测耗时与 O(n²) 根因），避免重复踩大盘性能坑。
6. 跑 `test_mod_topology.gd` + `test_mod_api.gd` 理解 Mod 创作契约（`board.json` 任意形状 / 三种 Mod 形式）。
7. 跑 `test_difficulty.gd` + `test_difficulty_tiers.gd` 理解难度体系（必要线索数复杂度 / 三档分档）。
8. 补 git 首次提交（当前无版本控制，见开放问题 #1）。
