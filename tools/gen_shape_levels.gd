# gen_shape_levels.gd —— 异形关卡生成工具（离线 CLI）：T2 挖洞方格 + T3 蜂窝 + T7 mask 图案
#
# 运行： godot --headless --path . -s res://tools/gen_shape_levels.gd               # 全部族
#        godot --headless --path . -s res://tools/gen_shape_levels.gd -- hex        # 只产蜂窝族
#        godot --headless --path . -s res://tools/gen_shape_levels.gd -- holed_grid # 只产挖洞方格族
#        godot --headless --path . -s res://tools/gen_shape_levels.gd -- mask       # 只产 mask 图案族
# 产出： res://levels/holed_01..06.json（挖洞方格）、hex_01..05.json（蜂窝）、
#       art_target/art_carpet/art_jelly.json（T7 mask 图案：同心靶 / 分形地毯 / 小水母）
#
# 族驱动（T3 扩展，**不是**新脚本）：SPECS 每关一条 spec，由 kind + params 决定形状族，
#   kind ∈ {"holed_grid", "hex", "mask"}（= ShapeGenerator.to_adjacency_grid 的注册 kind；
#   别名 "holed" 亦可）。
#   mask 族（T7）：ASCII 轮廓由 SPECS 手写（style + mask 两字段，人可读可审计），经
#   ShapeGenerator.build_from_mask 建图 —— 「任意轮廓图案」（剪影/花纹/分形）直接成关。
#   新增族 = 往 SPECS 加条目（+ 可选族专属指纹），生成/换 seed 重试/落盘/自校验/退出全部代码不动。
#   族过滤走 OS.get_cmdline_user_args()（不传参数 = 全部族 ⇒ 与 T2 行为逐位一致，holed 三关照产）。
#
# 链路（与 core/level_generator.gd:33-53 的 _generate_adjacency 同一口径，零新逻辑）：
#   ShapeGenerator.to_adjacency_grid(kind, params) —— 形状 → AdjacencyGrid（内部已 setup_from_topo）
#       · holed_grid：满格 Moore 8 邻 → 删洞格（删格删边、不重连）
#       · hex：轴向坐标窗口 [0,size)² 按 |r+c−(size−1)| ≤ (size−1)/2 裁成六边形盘，6 邻
#   → AdjacencyGrid.normalized        —— 坐标非负化（CP-SAT cell 索引从 0 起）
#       本工具两族的 build_* 产出坐标**本就非负**（hex 窗口固定在原点，选不中负格），故这一步
#       对当前两族恒等返回原实例（adjacency_grid.gd:69-76 早退）；保留下它是为了兜住未来
#       产出负坐标的形状族，不为此多做一次拷贝。
#   → PuzzleGenerator.generate_with_rules(..., topology)
#       · 异形拓扑下线索规则强制 classic（puzzle_generator.gd:306-314，方向型线索在邻接表上语义矛盾）
#       · 洞格由 RuleOracle.build_spec 固定为非雷
#       · 序贯无猜（R01）验证是生成器内建步骤，**不绕过、不重跑自研校验**
# 档位验收（入库口径，v4.0/v4.1 = 峰值窗口，core/difficulty.gd）：每关必须
#   Difficulty.tier_of_profile(level.difficulty_profile) == REQUIRED_TIER（"easy"，峰值 ∈ [2,3]）。
#   不达标的盘不落盘：先换 seed 重试（seed+STRIDE 递增，每轮最多 MAX_TRIES 个），
#   一轮 seed 全不达标 → 加雷 +1（最多 MAX_MINES_BUMP 轮）重搜；
#   mines+bump 受密度上界「格数 × DENSITY_CAP(0.35)」约束（形状关是低密度设计，超界如实失败，
#   不无限加雷）。全部候选都不达标 → 该关失败（push_error + 退出码 1）。
#   尝试顺序确定性（雷数递增 → seed 递增），重跑逐字节复现。
# 生成失败（返回空）→ 视同不达标，同样换 seed 继续；仍失败 → 退出码 1。
#
# 写盘后逐关自校验（LevelLoader.load_level 真实重载），任一不符即删掉坏文件并报错退出 1——
# 「写出去的文件必须能玩」是这条链路唯一的验收标准，宁可红灯也不留半成品。
#
# 退出方式（**有意不用 tools/cli_shutdown.gd**，附实测数据；改回前请重跑下面三组对照）：
#   本工程 -s 脚本确实会「跑完不退出」，但 cli_shutdown 的看门狗路径在本机（4.7.2 mono）
#   反而把成功也变成失败——它在 quit() 前 OS.execute 起 `cmd /c ping … & taskkill /pid`，
#   进程被看门狗强杀 ⇒ **退出码 1**（同一份工作 + 延后 quit(0) 则干净退出且码 0）：
#     [探针] 同跑 CP-SAT 后 CliShutdown.request_exit(0)  → 6.05 s  ExitCode=1
#     [探针] 同跑 CP-SAT 后 _process 里延后 quit(0)      → 3.05 s  ExitCode=0
#     [本工具] 之前用 cli_shutdown → 退出码 1；现改为延后 3 帧 quit(code) → 退出码 0
#   故这里只借用它的**策略**（延后几帧、让 autoload 初始化完毕再退；先打印成功标记再退，
#   好让 tools/run_batch.ps1 按日志内容判成功），看门狗不装——退出码要如实反映成功/失败。
#
# 蜂窝盘规模（R = (size−1)÷2 整除；**奇偶尺寸都产**——size=6/8 见 SPECS 的 hex_04/hex_05）：
#   奇数 size=2R+1：格数 3R²+3R+1、无向边 9R²+3R、度分布 {3:6, 4:6(R−1), 6:3R²−3R+1}
#     （几何：6 个角格 3 度、6(R−1) 个边格 4 度、其余内格 6 度），即
#     size=5(R=2) → 19 格 / 42 边；size=7(R=3) → 37 格 / 90 边；size=9(R=4) → 61 格 / 156 边。
#   偶数 size=2R+2（R≥1）：格数 3R²+5R+2、无向边 9R²+9R+1、度分布 {3:6, 4:6R−4, 6:3R²−R}
#     （裁剪式 |r+c−(size−1)| ≤ (size−1)÷2 对偶数同样成立，只是盘心不是一个格而是 2×2 四格，
#      故中轴两行等长）；size=6(R=2) → 24 格 / 55 边；size=8(R=3) → 44 格 / 109 边。
#     偶数闭式经独立枚举（n=4/6/8/10/12 的格数 / 边数 / 度分布逐项）核对，
#     与 build_hex 实现互为独立核对——实现改了而闭式没改就会红灯。
# 蜂窝包围盒 = size×size（AdjacencyGrid.size() 返回 bbox）。**注意**：窗口是左对齐的 [0,size)²，
#   行 r 的列区间 = [max(0, lo−r), min(size−1, hi−r)]（lo=size−1−half、hi=size−1+half、half=(size−1)÷2），
#   故 bbox 四角**并非**全在盘外：
#   size=5 时 (0,0)、(4,4) 在盘外，而 (4,0)、(0,4) **在盘内**（第 0 行占 c∈[2,4]、第 4 行占 c∈[0,2]）；
#   偶数同理（size=6：第 0 行占 c∈[3,5]、第 5 行占 c∈[0,2]，(5,0)/(0,5) 在盘内）。
#   自校验按实际几何断言（off_board / in_board 两张表都写死），不按「四角皆洞」的想当然。
# 盘外格（bbox 内非盘格）= 洞格：in_board == false、get_cell() == null；
#   CP-SAT 侧 RuleOracle.build_spec 已把洞格固定为非雷（core/rule_oracle.gd:150-155）。
extends SceneTree

## 退出前等待的帧数（cli_shutdown.FRAMES_BEFORE_EXIT 同值：让 autoload 初始化完毕再退）。
const EXIT_FRAMES := 3

var _exit_code := 0
var _exit_pending := false
var _exit_frames := 0

## 关卡加载器（自校验用）。**必须运行期 load，不能写成编译期依赖**：
## `-s` 工具脚本在 autoload 注册**之前**编译（Godot main.cpp：先载 -s 脚本、后建 autoload），
## 而 ui/level_loader.gd:45 直接引用 autoload 全局标识符 ModAPI → 编译期连带失败
## （实测：SECURITY/SCRIPT ERROR "Identifier not found: ModAPI"，LevelLoader.load_level 变 nonexistent）。
## 运行期 load（_gen_one 内调用时 autoload 已就绪）即可正常编译；静态方法用 GDScript.call 派发。
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"

const OUT_DIR := "res://levels"
## 线索规则 id = "classic"（邻域计数）。
## 依据：core/rule_registry.gd:114-118 `_register_builtins()` 注册 ClassicRule，
##       其 get_rule_id() 返回 &"classic"（core/rule_registry.gd:162-163）；
##       异形拓扑在 core/puzzle_generator.gd:306-314 强制 classic，落盘 clue_rule 同步为 "classic"。
const CLUE_RULE := "classic"
const GLOBALS: Array = []
## 单次调用内部的尝试次数（与 core/level_generator.gd / ui/level_select.gd 同口径）。
const ATTEMPTS := 50
## 生成返回空 / 档位不达标（该 seed 下 50 次 attempt 全败或画像不进窗）时的换 seed 重试上限。
const MAX_TRIES := 20
const SEED_STRIDE := 1

## 入库档位口径（core/difficulty.gd:PEAK_WINDOWS，v4.1）：库契约要求「库内档位 == 集文件名档位」，
## 形状关全部入 easy 集 ⇒ 每关必须 tier_of_profile == REQUIRED_TIER（峰值落 [2,3]）。
## 不达标的盘一律不落盘（换 seed → 加雷重试）；**不放宽/绕过这条口径**（内容不达标就调内容）。
const REQUIRED_TIER := "easy"
## 档位不达标时的加雷轮数上限（每轮 +1 雷、重搜 MAX_TRIES 个 seed；0 = 只换 seed 不加雷）。
const MAX_MINES_BUMP := 4
## 形状关密度上界（低密度设计）：mines + bump 不得超过 格数 × DENSITY_CAP——
## 超过说明该形状在小尺寸下数学上难出深推理，此时如实失败并在报告里列出，不无限加雷。
const DENSITY_CAP := 0.35

# 关卡规格（族驱动）。字段：
#   file/kind/name/desc —— 文件名 / 形状族 / 中文名 / 日志描述
#   params  —— 传给形状族的参数（holed_grid: rows/cols/holes；hex: size）
#   style/mask —— 仅 mask 族（kind="mask"）：style 选建图语义、mask 是手写 ASCII 轮廓
#                 （行 = y、列 = x；#/X/1 = 有格；口径见 ShapeGenerator.build_from_mask）；
#                 _gen_one 把这两个字段组装成 to_adjacency_grid 的 params（{"style":..,"mask":..}），
#                 cells/bbox 由 _shape_problems 的 mask 分支与 mask 逐字符互核（防手抄错）
#   cells   —— 期望盘内格数（自校验；另有族公式与之独立核对，防 spec 手抄错）
#   bbox    —— 期望包围盒（AdjacencyGrid.size()；= CP-SAT 的索引范围）
#   mines/seed —— 基准雷数 / 固定起始 seed（档位不达标时按 MAX_MINES_BUMP 加雷、seed 递增重搜；
#                 落盘雷数 = 实际使用的雷数，可能 > mines，密度上界见 DENSITY_CAP）
#   off_board —— 必须**不在盘内**的格（holed_grid/mask = 洞；hex = 实际盘外格）
#   in_board  —— 必须**在盘内**的格（hex 用：锁定窗口取向；mask 用：图案关键格，形状口径变了要红灯）
const SPECS: Array = [
	{
		"file": "holed_01.json", "kind": "holed_grid", "name": "挖洞 01 · 中央空腔",
		"desc": "8×8 − 4 洞（中央空腔）",
		"params": {"rows": 8, "cols": 8, "holes": [
			Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)]},
		"cells": 60, "bbox": Vector2i(8, 8), "mines": 10, "seed": 1001,
		"off_board": [Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)],
		"in_board": [],
	},
	{
		"file": "holed_02.json", "kind": "holed_grid", "name": "挖洞 02 · 贴边洞",
		"desc": "8×8 − 6 洞（四角 + 中心竖条）",
		"params": {"rows": 8, "cols": 8, "holes": [
			Vector2i(0, 0), Vector2i(7, 0), Vector2i(0, 7), Vector2i(7, 7),  # 四角各 1 格
			Vector2i(3, 3), Vector2i(3, 4)]},                                # 中心竖条 2 格
		"cells": 58, "bbox": Vector2i(8, 8), "mines": 11, "seed": 2001,
		"off_board": [Vector2i(0, 0), Vector2i(7, 0), Vector2i(0, 7), Vector2i(7, 7),
			Vector2i(3, 3), Vector2i(3, 4)],
		"in_board": [],
	},
	{
		"file": "holed_03.json", "kind": "holed_grid", "name": "挖洞 03 · 十字洞",
		"desc": "9×9 − 5 洞（十字）",
		"params": {"rows": 9, "cols": 9, "holes": [
			Vector2i(4, 4),                                                   # 中心 1 格
			Vector2i(4, 3), Vector2i(4, 5), Vector2i(3, 4), Vector2i(5, 4)]},  # 上下左右各 1 格
		"cells": 76, "bbox": Vector2i(9, 9), "mines": 15, "seed": 3001,
		"off_board": [Vector2i(4, 4), Vector2i(4, 3), Vector2i(4, 5), Vector2i(3, 4), Vector2i(5, 4)],
		"in_board": [],
	},
	{
		# T3 蜂窝（见文件头：R=(size−1)/2；格数 3R²+3R+1；6 角 3 度 / 6(R−1) 边 4 度 / 内 6 度）
		"file": "hex_01.json", "kind": "hex", "name": "蜂窝 01 · 初环",
		"desc": "蜂窝 size=5（R=2）",
		"params": {"size": 5},
		"cells": 19, "bbox": Vector2i(5, 5), "mines": 4, "seed": 4001,
		# 盘外格 = 5×5 bbox 内非盘格（25−19 = 6）：左上三角 3 格 + 右下三角 3 格
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1),
			Vector2i(3, 4), Vector2i(4, 4), Vector2i(4, 3)],
		# 盘内却坐在 bbox 边角的两格（锁「窗口左对齐」取向，见文件头注释）
		"in_board": [Vector2i(4, 0), Vector2i(0, 4)],
	},
	{
		"file": "hex_02.json", "kind": "hex", "name": "蜂窝 02 · 蜂巢",
		"desc": "蜂窝 size=7（R=3）",
		"params": {"size": 7},
		"cells": 37, "bbox": Vector2i(7, 7), "mines": 8, "seed": 5001,
		# 盘外格 = 49−37 = 12
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1),
			Vector2i(0, 2), Vector2i(6, 4), Vector2i(5, 5), Vector2i(6, 5),
			Vector2i(4, 6), Vector2i(5, 6), Vector2i(6, 6)],
		"in_board": [Vector2i(6, 0), Vector2i(0, 6)],
	},
	{
		"file": "hex_03.json", "kind": "hex", "name": "蜂窝 03 · 大蜂巢",
		"desc": "蜂窝 size=9（R=4）",
		"params": {"size": 9},
		"cells": 61, "bbox": Vector2i(9, 9), "mines": 14, "seed": 6001,
		# 盘外格 = 81−61 = 20
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
			Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(0, 2), Vector2i(1, 2),
			Vector2i(0, 3),
			Vector2i(8, 5),
			Vector2i(7, 6), Vector2i(8, 6),
			Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7),
			Vector2i(5, 8), Vector2i(6, 8), Vector2i(7, 8), Vector2i(8, 8)],
		"in_board": [Vector2i(8, 0), Vector2i(0, 8)],
	},
	# ---- 接线补产：形状关接入选关页需要「5/6/7/8/9 全尺寸有库内容」----
	# 为什么必须全尺寸：选关页尺寸按钮的禁用只看规则可行性（classic 全尺寸可行），
	# 形状卡片若某尺寸无库内容就会回退「按种子生成普通矩形关」——卡名与实物不符（在售 bug）。
	# 下面每条都是**追加**（既有 6 条逐字未动）：holed 补 5/6/7、hex 补 6/8（偶数尺寸，见文件头闭式）。
	{
		"file": "holed_04.json", "kind": "holed_grid", "name": "挖洞 04 · 小空腔",
		"desc": "5×5 − 1 洞（中心单格）",
		"params": {"rows": 5, "cols": 5, "holes": [Vector2i(2, 2)]},
		"cells": 24, "bbox": Vector2i(5, 5), "mines": 4, "seed": 7001,
		"off_board": [Vector2i(2, 2)],
		"in_board": [],
	},
	{
		"file": "holed_05.json", "kind": "holed_grid", "name": "挖洞 05 · 中央方洞",
		"desc": "6×6 − 4 洞（中央 2×2）",
		"params": {"rows": 6, "cols": 6, "holes": [
			Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]},
		"cells": 32, "bbox": Vector2i(6, 6), "mines": 6, "seed": 7002,
		"off_board": [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)],
		"in_board": [],
	},
	{
		"file": "holed_06.json", "kind": "holed_grid", "name": "挖洞 06 · 大空腔",
		"desc": "7×7 − 9 洞（中央 3×3）",
		"params": {"rows": 7, "cols": 7, "holes": [
			Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
			Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3),
			Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4)]},
		"cells": 40, "bbox": Vector2i(7, 7), "mines": 8, "seed": 7003,
		"off_board": [
			Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
			Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3),
			Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4)],
		"in_board": [],
	},
	{
		"file": "hex_04.json", "kind": "hex", "name": "蜂窝 04 · 扁巢",
		"desc": "蜂窝 size=6（R=2，偶数尺寸：盘心 2×2）",
		"params": {"size": 6},
		"cells": 24, "bbox": Vector2i(6, 6), "mines": 5, "seed": 7004,
		# 盘外格 = 36−24 = 12（左上三角 3+2+1 + 右下三角 1+2+3）
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
			Vector2i(0, 1), Vector2i(1, 1),
			Vector2i(0, 2),
			Vector2i(5, 3),
			Vector2i(4, 4), Vector2i(5, 4),
			Vector2i(3, 5), Vector2i(4, 5), Vector2i(5, 5)],
		"in_board": [Vector2i(5, 0), Vector2i(0, 5)],
	},
	{
		"file": "hex_05.json", "kind": "hex", "name": "蜂窝 05 · 宽巢",
		"desc": "蜂窝 size=8（R=3，偶数尺寸：盘心 2×2）",
		"params": {"size": 8},
		"cells": 44, "bbox": Vector2i(8, 8), "mines": 9, "seed": 7005,
		# 盘外格 = 64−44 = 20（左上三角 4+3+2+1 + 右下三角 1+2+3+4）
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
			Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
			Vector2i(0, 2), Vector2i(1, 2),
			Vector2i(0, 3),
			Vector2i(7, 4),
			Vector2i(6, 5), Vector2i(7, 5),
			Vector2i(5, 6), Vector2i(6, 6), Vector2i(7, 6),
			Vector2i(4, 7), Vector2i(5, 7), Vector2i(6, 7), Vector2i(7, 7)],
		"in_board": [Vector2i(7, 0), Vector2i(0, 7)],
	},
	# ---- T7 自创图案关（mask 驱动：style + mask 手写在 spec 里；cells/bbox 由生成器与 mask 互核）----
	# mask 口径（ShapeGenerator.build_from_mask）：行 = y、列 = x；#/X/1 有格、./0/空格 空。
	# 三关图案均为自创（非原版关卡数据），bbox 固定 9×9（选关页尺寸轴上界）。
	# 注意：三关同为 shape_holed 9×9，seed 基值互相错开 ≥ 20（8001 / 8102 / 8203）——
	# import 工具按 (mode, size, seed) 去重，撞 seed 的关会被静默跳过；换 seed 重试只 +1，
	# 故 20 的间隔覆盖 MAX_TRIES 全部重试范围（本工具当前不动序列，防的是未来调参）。
	{
		# 9×9 满格挖掉「内两圈」（距边 1、2 的方环：24 + 16 格）⇒ 保留外环带 32 + 内环带 8 + 中心 1 = 41 格
		"file": "art_target.json", "kind": "mask", "name": "图案 01 · 同心靶",
		"desc": "9×9 同心靶（外环带 + 内环带 + 中心；洞 = 内两圈方环）",
		"style": "holed_grid",
		"mask": [
			"#########",
			"#.......#",
			"#.......#",
			"#..###..#",
			"#..###..#",  # 中行 = 内环带 (x=3,5) + 中心 (x=4) —— 与上下两行的 3×3 内芯一致
			"#..###..#",
			"#.......#",
			"#.......#",
			"#########",
		],
		"cells": 41, "bbox": Vector2i(9, 9), "mines": 9, "seed": 8001,
		"off_board": [Vector2i(1, 1), Vector2i(4, 1), Vector2i(2, 4)],
		"in_board": [Vector2i(0, 0), Vector2i(3, 3), Vector2i(4, 4)],
	},
	{
		# 谢尔宾斯基地毯 2 阶：挖 (x%3==1 且 y%3==1) 与 (x//3==1 且 y//3==1) ⇒ 81 − 17 = 64 格
		"file": "art_carpet.json", "kind": "mask", "name": "图案 02 · 分形地毯",
		"desc": "9×9 谢尔宾斯基地毯 2 阶（保留 64 格 = 8²）",
		"style": "holed_grid",
		"mask": [
			"#########",
			"#.##.##.#",
			"#########",
			"###...###",
			"#.#...#.#",
			"###...###",
			"#########",
			"#.##.##.#",
			"#########",
		],
		"cells": 64, "bbox": Vector2i(9, 9), "mines": 13, "seed": 8102,
		"off_board": [Vector2i(1, 1), Vector2i(4, 4), Vector2i(7, 7)],
		"in_board": [Vector2i(0, 0), Vector2i(2, 2)],
	},
	{
		# 像素水母：上 5 行伞盖（5/7/9/7/5 对称收放）+ 下 4 行触手（每行 1~2 格，摆动错位）⇒ 40 格
		"file": "art_jelly.json", "kind": "mask", "name": "图案 03 · 小水母",
		"desc": "9×9 像素水母剪影（伞盖 + 3 条摆尾触手）",
		"style": "holed_grid",
		"mask": [
			"..#####..",
			".#######.",
			"#########",
			".#######.",
			"..#####..",
			".#...#...",
			"..#..#...",
			"...#..#..",
			"....#....",
		],
		"cells": 40, "bbox": Vector2i(9, 9), "mines": 7, "seed": 8203,
		"off_board": [Vector2i(0, 0), Vector2i(8, 0), Vector2i(0, 4)],
		"in_board": [Vector2i(4, 2), Vector2i(1, 5), Vector2i(4, 8)],
	},
]


## 单次 generate_with_rules 的 CP-SAT 超时（毫秒）。**显式传值**（不用默认 15s）：
## 删线索循环受墙钟 deadline 控制 ⇒ timeout 越小、机器负载对产物影响越大
## （同 seed 可能产出不同 difficulty_profile ⇒ 被采纳的 seed 与落盘内容漂移）。
## 放大到 60s：单关实测 0.8~7.3s 远小于上限，显著降低负载导致的漂移概率。
## 注意：这**不消除**墙钟依赖——真正确定性需把删线索判停改成步数/迭代数（生成算法变更，另议）。
const GEN_TIMEOUT_MS := 60000
## 批次暂存目录：先生成到临时文件并自校验，**全批通过后才提交到 res://levels/**（TM5）。
## 原实现逐 spec 立即写目标 ⇒ 后面的 spec 失败时前面的文件已更新（半成品批次），
## 且自校验失败会删掉盘上原有的好文件。现在失败批次完全不触碰 res://levels/。
const TMP_DIR := "user://_shape_gen_tmp"
var _staged: Array = []   # 暂存 [{"file":…, "tmp":…}]，全批通过后统一提交


func _initialize() -> void:
	var kinds := _selected_kinds()
	if kinds.is_empty():
		_request_exit(1)
		return
	print("=== 异形关卡生成（T2 挖洞方格 / T3 蜂窝）===")
	print("  clue_rule=%s  globals=%s  attempts=%d  max_tries=%d  档位要求=%s  max_mines_bump=%d  density_cap=%.2f  本次族=%s（SPECS 含：%s）" % [
		CLUE_RULE, str(GLOBALS), ATTEMPTS, MAX_TRIES, REQUIRED_TIER, MAX_MINES_BUMP, DENSITY_CAP,
		", ".join(kinds), ", ".join(_all_kinds())])
	var t_all := Time.get_ticks_msec()
	var total := 0
	var failures := 0
	_staged.clear()
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	for spec: Dictionary in SPECS:
		if not kinds.has(str(spec["kind"])):
			continue
		total += 1
		if not _gen_one(spec):
			failures += 1
	var total_ms := Time.get_ticks_msec() - t_all
	if total == 0:
		push_error("族 %s 在 SPECS 里没有对应规格" % ", ".join(kinds))
		_cleanup_tmp()
		_request_exit(1)
		return
	if failures > 0:
		# TM5：批次失败 → **不触碰 res://levels/**（旧关卡原样保留），只清暂存。
		print("=== FAILED：%d/%d 关失败（res://levels 未改动，旧关卡保留），耗时 %.1f s ===" % [
			failures, total, total_ms / 1000.0])
		_cleanup_tmp()
		_request_exit(1)
		return
	# 全批通过 → 统一提交（TM5：把「生成+自校验」与「改盘」分成两阶段）
	var commit_failures := _commit_staged()
	_cleanup_tmp()
	var total_ms2 := Time.get_ticks_msec() - t_all
	if commit_failures > 0:
		print("=== FAILED：提交阶段 %d 关写盘失败（已提交的部分均为有效关卡，未提交的保持旧版）===" % commit_failures)
		_request_exit(1)
		return
	print("=== 全部 %d 关生成 + 自校验 + 提交通过，耗时 %.1f s ===" % [total, total_ms2 / 1000.0])
	print("=== SHAPE-LEVELS-OK ===")
	_request_exit(0)


func _process(_delta: float) -> bool:
	if not _exit_pending:
		return false
	_exit_frames += 1
	if _exit_frames < EXIT_FRAMES:
		return false
	quit(_exit_code)
	return true


## 登记退出（不是立刻退）：等几帧让 autoload/引擎初始化完毕，避免「关机流程抢跑」死锁。
## flush_stdout_on_print 必须打开——stdout 重定向到文件时是全缓冲，日志可能丢尾（cli_shutdown 同款）。
func _request_exit(code: int) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_exit_code = code
	_exit_frames = 0
	_exit_pending = true


## SPECS 里声明过的形状族（去重、保持声明顺序）。
func _all_kinds() -> Array[String]:
	var out: Array[String] = []
	for spec: Dictionary in SPECS:
		var k := str(spec["kind"])
		if not out.has(k):
			out.append(k)
	return out


## 命令行族过滤：`-s res://tools/gen_shape_levels.gd -- hex`（不传参数 = 全部族）。
## 多参数取并集；"all" = 全部；"holed" 是 "holed_grid" 的别名。
## 未知族 → push_error + 返回空（调用方退 1）——宁可红灯，也不静默产错族。
func _selected_kinds() -> Array[String]:
	var all := _all_kinds()
	var picked: Array[String] = []
	for a in OS.get_cmdline_user_args():
		var s := str(a).strip_edges().to_lower()
		if s == "":
			# L7（2026-09-21 审计修复）：空串是"无参数"的误传形态（如 runner 传了 `-- ""`）——
			# 报错比静默当"全部族"安全。
			push_error("族名参数为空串（不传参数 = 全部族，不需要显式空串）")
			return []
		if s == "-":
			push_error("未知族 \"-\"（占位符不再被忽略：不传参数 = 全部族）")
			return []
		if s == "all":
			return all
		var k := "holed_grid" if s == "holed" else s
		if not all.has(k):
			push_error("未知族 \"%s\"（可用：%s、all）" % [s, ", ".join(all)])
			return []
		if not picked.has(k):
			picked.append(k)
	return picked if not picked.is_empty() else all


## 生成一关：形状 → 拓扑 → 生成（内建 R01 验证）→ 落盘 → LevelLoader 重载自校验。
## 返回 true 表示该关已产出且通过自校验（失败文件会被删除，不留半成品）。
func _gen_one(spec: Dictionary) -> bool:
	var file_name: String = str(spec["file"])
	var path := "%s/%s" % [OUT_DIR, file_name]
	# L5（2026-09-21 审计修复）：目标文件已存在但**不是形状关**（无 topology.style）→ 拒绝覆盖。
	# 防 spec 的 file 名撞经典关（如手滑写成 "classic_01.json"）静默覆盖既有内容。
	if FileAccess.file_exists(path):
		var existing: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		var is_shape := false
		if existing is Dictionary:
			var topo_v: Variant = (existing as Dictionary).get("topology", {})
			is_shape = topo_v is Dictionary and (topo_v as Dictionary).has("style")
		if not is_shape:
			push_error("%s: 目标文件已存在且不是形状关（无 topology.style）——拒绝覆盖：%s" % [file_name, path])
			return false
	var kind: String = str(spec["kind"])
	# mask 族（T7）：spec 的 style + mask 是形状规格，这里组装成 to_adjacency_grid 的 params。
	# 其它族照旧用 spec["params"]（holed_grid: rows/cols/holes；hex: size）。
	var params: Dictionary = spec.get("params", {})
	if kind == "mask":
		params = {"style": str(spec.get("style", "")), "mask": spec.get("mask", [])}
	var mine_count: int = int(spec["mines"])
	var base_seed: int = int(spec["seed"])

	# 1. 形状 → 拓扑（统一走形状库的 kind 分派，不再手写 setup_from_topo）+ 非负化兜底
	var topo: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(kind, params)
	if topo == null:
		push_error("%s: 形状构建失败（kind=%s, params=%s）" % [file_name, kind, str(params)])
		return false
	topo = AdjacencyGrid.normalized(topo)
	if topo == null:
		push_error("%s: 坐标归一化失败（kind=%s）" % [file_name, kind])
		return false
	# 形状自校验先跑：形状本身不对就没必要烧 CP-SAT
	var shape_problems := _shape_problems(spec, topo)
	if not shape_problems.is_empty():
		push_error("%s: 形状自校验失败 —— %s" % [file_name, "；".join(shape_problems)])
		return false
	# 包围盒 = CP-SAT 的 (rows, cols) 索引范围（同 core/level_generator.gd:_coord_range）
	var size := topo.size()
	var edges := _edge_count(topo)
	var histogram := _degree_histogram(topo)

	# 2. 生成 + 档位验收（换 seed → 仍不达标则加雷；两步都确定性递增，可复现）
	#    生成返回空（该 seed 下 50 次 attempt 全败）与画像不进窗同待遇：都换下一个候选。
	#    验收口径 = 入库口径：Difficulty.tier_of_profile == REQUIRED_TIER（峰值窗口，core/difficulty.gd）。
	var max_mines := int(floor(float(topo.cell_count()) * DENSITY_CAP))
	if mine_count > max_mines:
		push_error("%s: 基准雷数 %d 已超密度上界 %d（格数 %d × %.2f）——规格本身不合低密度设计" % [
			file_name, mine_count, max_mines, topo.cell_count(), DENSITY_CAP])
		return false
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var bump := 0             # 达标时实际用掉的加雷量（落盘雷数 = mine_count + bump）
	var tries := 0            # 累计生成调用次数（换 seed / 加雷都算一次尝试）
	var best_peak := -1       # 全部候选里的最高 peak（失败报告用）
	var t0 := Time.get_ticks_msec()
	for b in MAX_MINES_BUMP + 1:
		if mine_count + b > max_mines:
			break
		for t in MAX_TRIES:
			tries += 1
			var seed := base_seed + t * SEED_STRIDE
			# TH2：显式传 GEN_TIMEOUT_MS（不用默认 15s）——降低机器负载对产物的影响。
			var candidate: Dictionary = gen.generate_with_rules(
					CLUE_RULE, GLOBALS, size, mine_count + b, seed, 0, ATTEMPTS, topo,
					GEN_TIMEOUT_MS)
			if candidate.is_empty():
				continue
			var cand_prof: Dictionary = candidate.get("difficulty_profile", {})
			best_peak = maxi(best_peak, int(cand_prof.get("max_complexity", -1)))
			if Difficulty.tier_of_profile(cand_prof) == REQUIRED_TIER:
				level = candidate
				used_mines = mine_count + b
				bump = b
				break
			# 不达标（peak ≤1 纯一眼盘 / 或 peak ≥4 更深档）：丢弃，不落盘；下一 seed 继续
		if not level.is_empty():
			break
	var gen_ms := Time.get_ticks_msec() - t0
	if level.is_empty():
		push_error("%s: 加雷 %d 轮 × 每轮 %d 个 seed（共 %d 次尝试，雷数上界 %d）无一达到 %s 档（最高 peak=%d）" % [
			file_name, mini(MAX_MINES_BUMP, max_mines - mine_count) + 1, MAX_TRIES, tries, max_mines,
			REQUIRED_TIER, best_peak])
		return false

	# 3. 写**暂存文件**（TM5：不直接改 res://levels/；补中文名；seed 由生成器写入 = 实际用时 seed）
	level["name"] = str(spec["name"])
	var tmp_path := "%s/%s" % [TMP_DIR, file_name]
	DirAccess.make_dir_recursive_absolute(TMP_DIR)
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_error("%s: 无法写入暂存 %s" % [file_name, tmp_path])
		return false
	f.store_string(JSON.stringify(level, "  "))
	f.close()

	# 4. 自校验：用真实加载器重载暂存文件（写出去的文件必须能玩）；形状断言在**真实产物**上再跑一遍
	var board: Board = _load_level(tmp_path)
	var problems: Array[String] = []
	if board == null:
		problems.append("LevelLoader.load_level 返回 null")
	else:
		if not (board.grid is AdjacencyGrid):
			problems.append("board.grid 不是 AdjacencyGrid（实际 %s）" % str(board.grid))
		else:
			problems.append_array(_shape_problems(spec, board.grid))
			if board.grid.cell_count() != topo.cell_count():
				problems.append("board.grid.cell_count()=%d ≠ 拓扑 %d" % [board.grid.cell_count(), topo.cell_count()])
			if board.grid.size() != size:
				problems.append("board.grid.size()=%s ≠ 拓扑 bbox %s" % [str(board.grid.size()), str(size)])
		# 雷数一致性（三级互核）：board.total_mines == JSON total_mines == mines 数组长度 == 实际使用雷数
		var json_mines := int(level.get("total_mines", -1))
		var mines_arr: Array = level.get("mines", [])
		if board.total_mines != json_mines:
			problems.append("board.total_mines=%d ≠ JSON total_mines=%d" % [board.total_mines, json_mines])
		if json_mines != used_mines:
			problems.append("JSON total_mines=%d ≠ 实际使用雷数 %d" % [json_mines, used_mines])
		if mines_arr.size() != used_mines:
			problems.append("JSON mines 数组 %d 条 ≠ 实际使用雷数 %d" % [mines_arr.size(), used_mines])
		if board.total_mines != used_mines:
			problems.append("board.total_mines=%d ≠ 实际使用雷数 %d" % [board.total_mines, used_mines])
		# 独立核对（2026-09-21 审计修复）：上面四条多源自 JSON（board.total_mines 本身就读 JSON），
		# 可能"一起错"。这里补两条**真检查**：引擎内雷位数量一致 + 全部落在盘内
		# （落在洞格/越界的雷会被 Board 静默跳过 —— 那正是"雷数与盘不符"的真实故障形态）。
		var actual_mines := board.get_mine_positions()
		if actual_mines.size() != used_mines:
			problems.append("board.get_mine_positions()=%d ≠ 实际使用雷数 %d（引擎内雷位丢失/被跳过）" % [
				actual_mines.size(), used_mines])
		for mm in actual_mines:
			if not board.grid.in_board(mm):
				problems.append("雷位 %s 不在盘内（洞格或越界）" % str(mm))
	if not problems.is_empty():
		push_error("%s: 自校验失败 —— %s（暂存文件已丢弃；res://levels 未触碰）" % [
			file_name, "；".join(problems)])
		if FileAccess.file_exists(tmp_path):
			DirAccess.remove_absolute(tmp_path)
		return false

	var prof: Dictionary = level.get("difficulty_profile", {})
	var tier := Difficulty.tier_of_profile(prof)
	var window := Difficulty.tier_range(REQUIRED_TIER)
	print("  [%s] %s（kind=%s, %s）" % [file_name, str(spec["name"]), kind, str(spec["desc"])])
	print("    bbox=%d×%d  格=%d  雷=%d（基准 %d + 提升 %d）  盘外格=%d  无向边=%d  度分布 %s  seed=%d  生成调用=%d 次（含换 seed 与加雷轮）  生成 %d ms  暂存 %d bytes（待提交）" % [
		size.x, size.y, topo.cell_count(), board.total_mines, mine_count, bump,
		size.x * size.y - topo.cell_count(), edges,
		_hist_to_str(histogram), int(level.get("seed", -1)), tries, gen_ms,
		FileAccess.get_file_as_bytes(tmp_path).size()])
	print("    档位验收：tier=%s  peak=%d（要求 %s，窗口 %d–%d）  雷数提升=%d  雷数上界=%d（= 格数 %d × %.2f）" % [
		tier, int(prof.get("max_complexity", -1)), REQUIRED_TIER, window.x, window.y,
		bump, max_mines, topo.cell_count(), DENSITY_CAP])
	print("    难度字段：difficulty=%s  max_complexity=%s  rounds=%s  clue_count=%s  clue_ratio=%s  profile=%s" % [
		str(prof.get("difficulty", "n/a")), str(prof.get("max_complexity", "n/a")),
		str(prof.get("rounds", "n/a")), str(prof.get("clue_count", "n/a")),
		str(prof.get("clue_ratio", "n/a")), str(prof.get("profile", "n/a"))])
	_staged.append({"file": file_name, "tmp": tmp_path})
	return true


## 形状自校验（族无关 + 族专属）。生成前对拓扑跑一遍、落盘后对**重载的棋盘**再跑一遍，
## 同一套断言覆盖「造得对」与「写得对、读得回」两件事。
func _shape_problems(spec: Dictionary, g: GridInterface) -> Array[String]:
	var problems: Array[String] = []
	var kind: String = str(spec["kind"])
	var expect_cells: int = int(spec["cells"])
	# 族无关：格数 / 包围盒 / 盘外格 / 盘内格
	if g.cell_count() != expect_cells:
		problems.append("格数 %d ≠ 规格 cells=%d（%s）" % [g.cell_count(), expect_cells, str(spec["desc"])])
	if g.size() != Vector2i(spec["bbox"]):
		problems.append("bbox %s ≠ 规格 bbox=%s" % [str(g.size()), str(spec["bbox"])])
	for p: Vector2i in spec.get("off_board", []):
		if g.in_board(p):
			problems.append("盘外格 (%d,%d) 竟在盘内" % [p.x, p.y])
		if g.get_cell(p) != null:
			problems.append("盘外格 (%d,%d) 竟有 Cell（应为 null）" % [p.x, p.y])
	for p: Vector2i in spec.get("in_board", []):
		if not g.in_board(p):
			problems.append("盘内格 (%d,%d) 竟不在盘内" % [p.x, p.y])
	# 族专属
	if kind == "hex":
		var n := int(spec["params"]["size"])
		if n < 3:
			problems.append("蜂窝 size 应 ≥ 3（收到 %d；size≤2 是退化盘，闭式不适用）" % n)
			return problems
		# 规格 cells 与蜂窝规模闭式互为独立核对（防 spec 手抄错）
		if expect_cells != _hex_cells(n):
			problems.append("规格 cells=%d ≠ 蜂窝闭式 %d" % [expect_cells, _hex_cells(n)])
		if Vector2i(spec["bbox"]) != Vector2i(n, n):
			problems.append("规格 bbox=%s ≠ size×size=%s" % [str(spec["bbox"]), str(Vector2i(n, n))])
		# 几何指纹：度分布 + 无向边（换算成独立于实现的整数序列比较，避免 Dictionary 比较语义歧义）
		var want_hist := _hex_degree_histogram(n)
		var got_hist := _degree_histogram(g)
		if _hist_to_str(got_hist) != _hist_to_str(want_hist):
			problems.append("度分布 %s ≠ 期望 %s" % [_hist_to_str(got_hist), _hist_to_str(want_hist)])
		var edges := _edge_count(g)
		if edges != _hex_edges(n):
			problems.append("无向边 %d ≠ 期望闭式 %d" % [edges, _hex_edges(n)])
		# 盘外格总数必须与 bbox 面积自洽（洞格既不进盘也不进 CP-SAT 变量）
		var off := int(spec["off_board"].size())
		if g.size().x * g.size().y - g.cell_count() != off:
			problems.append("盘外格 %d ≠ off_board 表 %d 条（表不全或形状变了）" % [
				g.size().x * g.size().y - g.cell_count(), off])
	elif kind == "holed_grid":
		var p: Dictionary = spec["params"]
		var want := int(p["rows"]) * int(p["cols"]) - (p["holes"] as Array).size()
		if expect_cells != want:
			problems.append("规格 cells=%d ≠ rows×cols−holes=%d" % [expect_cells, want])
	elif kind == "mask":
		# mask 自校验：cells 与 mask 数一致、bbox 与 mask 行列数一致（对拓扑跑一遍、
		# 对 LevelLoader 重载的棋盘再跑一遍，见 _gen_one 步骤 4）。
		var mask: Array = spec.get("mask", [])
		var style := str(spec.get("style", "holed_grid"))
		var filled := 0
		var cols := 0
		for row in mask:
			cols = maxi(cols, str(row).length())
			for ch in str(row):
				if "#X1".contains(ch):
					filled += 1
		if style == "t488":
			# M8（2026-09-21 审计修复）：t488 的 mask 会自动补小方块（4 个八边形包围的空隙全在才补）
			# 且坐标 ×2 整数化 ⇒ cells/bbox 都不能直接按 mask 格数/行列数比（原实现必然误杀）。
			# 期望：cells ≥ mask 八边形数（补方块只增不减）；bbox = 2×行列 − 1（八边形格阵跨度）。
			if expect_cells < filled:
				problems.append("规格 cells=%d < mask 八边形数 %d（t488 只会补方块、不会减格）" % [expect_cells, filled])
			var want_bbox := Vector2i(2 * cols - 1, 2 * mask.size() - 1)
			if Vector2i(spec["bbox"]) != want_bbox:
				problems.append("规格 bbox=%s ≠ t488 期望 %s（2×行列−1）" % [str(spec["bbox"]), str(want_bbox)])
		else:
			if expect_cells != filled:
				problems.append("规格 cells=%d ≠ mask 有格数 %d" % [expect_cells, filled])
			if Vector2i(spec["bbox"]) != Vector2i(cols, mask.size()):
				problems.append("规格 bbox=%s ≠ mask 行列数 %s" % [
					str(spec["bbox"]), str(Vector2i(cols, mask.size()))])
		# M8 补强：hex 的 mask 加度数上限校验（防把 8 邻方格盘错标成蜂窝）
		if style == "hex":
			for p: Vector2i in g.all_positions():
				if g.get_neighbors(p).size() > 6:
					problems.append("style=hex 的格 (%d,%d) 度 %d > 6（几何指纹不符）" % [
						p.x, p.y, g.get_neighbors(p).size()])
					break
	return problems


## 蜂窝半径 R = (size−1)÷2（整除；奇偶尺寸共用，见文件头闭式表）。
func _hex_radius(size: int) -> int:
	return (size - 1) / 2


## 蜂窝盘格数闭式：奇数 3R²+3R+1、偶数 3R²+5R+2（与 build_hex 的裁剪式互为独立核算）。
func _hex_cells(size: int) -> int:
	var r := _hex_radius(size)
	if size % 2 == 1:
		return 3 * r * r + 3 * r + 1
	return 3 * r * r + 5 * r + 2


## 蜂窝无向边数闭式（度分布求和 / 2）：奇数 9R²+3R、偶数 9R²+9R+1。
func _hex_edges(size: int) -> int:
	var r := _hex_radius(size)
	if size % 2 == 1:
		return 9 * r * r + 3 * r
	return 9 * r * r + 9 * r + 1


## 蜂窝度分布指纹：6 角格 3 度；边格 4 度（奇数 6(R−1)、偶数 6R−4）；
## 其余内格 6 度（奇数 3R²−3R+1、偶数 3R²−R——偶数盘心是 2×2 四格，故内格多一档）。
## 注（L4，2026-09-21）：闭式仅在 size ≥ 3 成立（size ≤ 2 会给出负计数）——
## 调用方必须先过 `_shape_problems` 的 size ≥ 3 守卫；本函数保持纯函数、不自行断言。
func _hex_degree_histogram(size: int) -> Dictionary:
	var r := _hex_radius(size)
	if size % 2 == 1:
		return {3: 6, 4: 6 * (r - 1), 6: 3 * r * r - 3 * r + 1}
	return {3: 6, 4: 6 * r - 4, 6: 3 * r * r - r}


## 度分布（度 → 格数）。
func _degree_histogram(g: GridInterface) -> Dictionary:
	var h := {}
	for p in g.all_positions():
		var d := g.get_neighbors(p).size()
		h[d] = int(h.get(d, 0)) + 1
	return h


## 度分布 → "3:6,4:6,6:7"（键升序；字符串比较，跨版本确定）。
func _hist_to_str(h: Dictionary) -> String:
	# 审计修复（2026-09-21）：过滤 **0 计数**档。闭式对某些 size 会产出 0 值键
	# （如 hex(3) 的 {3:6, 4:0, 6:1}），而实测 `_degree_histogram` 没有 0 键
	# ⇒ 字符串比较永不相等 ⇒ 该关"形状自校验失败"永远红灯（潜伏 bug：当前 SPECS 无 size=3）。
	var keys: Array = h.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		if int(h[k]) == 0:
			continue
		parts.append("%d:%d" % [int(k), int(h[k])])
	return ",".join(parts)


## 提交阶段（TM5）：把全部暂存文件复制到 res://levels/。跨卷不能用 rename（user:// 与
## res:// 可能不同分区）⇒ 读全文再写目标。单关失败计入返回值（已提交的部分是有效关卡，
## 绝不写出半份 JSON；未提交的关卡保持旧版）。
func _commit_staged() -> int:
	var fails := 0
	for it: Dictionary in _staged:
		var src := str(it["tmp"])
		var dst := "%s/%s" % [OUT_DIR, str(it["file"])]
		var txt := FileAccess.get_file_as_string(src)
		if txt.is_empty():
			push_error("提交失败（暂存为空）: %s" % src)
			fails += 1
			continue
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			push_error("提交失败（目标不可写）: %s" % dst)
			fails += 1
			continue
		f.store_string(txt)
		f.close()
		print("  [提交] %s → res://levels/" % str(it["file"]))
	return fails


## 清理暂存目录（成功/失败路径都调用；失败时保证不留垃圾文件）。
func _cleanup_tmp() -> void:
	var d := DirAccess.open(TMP_DIR)
	if d != null:
		for n in d.get_files():
			d.remove(str(n))
	_staged.clear()


## LevelLoader.load_level 的运行期包装（见 LEVEL_LOADER_PATH 注释：不能写成编译期依赖）。
## 返回 null 表示「加载/校验失败」（LevelLoader 内部已 push_error 说明原因）。
func _load_level(path: String) -> Board:
	var script: Variant = load(LEVEL_LOADER_PATH)
	if script == null:
		push_error("无法加载 %s" % LEVEL_LOADER_PATH)
		return null
	return script.call("load_level", path) as Board


## 无向边数（度数总和 / 2）——与 test/unit/test_shape_generator.gd:_grid_edge_count 同算法。
func _edge_count(g: GridInterface) -> int:
	var total := 0
	for p in g.all_positions():
		total += g.get_neighbors(p).size()
	return total / 2
