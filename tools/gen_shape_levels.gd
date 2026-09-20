# gen_shape_levels.gd —— 异形关卡生成工具（离线 CLI）：T2 挖洞方格 + T3 蜂窝
#
# 运行： godot --headless --path . -s res://tools/gen_shape_levels.gd               # 全部族
#        godot --headless --path . -s res://tools/gen_shape_levels.gd -- hex        # 只产蜂窝族
#        godot --headless --path . -s res://tools/gen_shape_levels.gd -- holed_grid # 只产挖洞方格族
# 产出： res://levels/holed_01..03.json（挖洞方格）、hex_01..03.json（蜂窝）
#
# 族驱动（T3 扩展，**不是**新脚本）：SPECS 每关一条 spec，由 kind + params 决定形状族，
#   kind ∈ {"holed_grid", "hex"}（= ShapeGenerator.to_adjacency_grid 的注册 kind；别名 "holed" 亦可）。
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
# 生成失败（返回空）→ 换 seed 重试（seed+1，最多 MAX_TRIES 次）；仍失败 → 退出码 1。
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
# 蜂窝盘规模（R = (size−1)/2，本工具只产奇数 size）：
#   格数 3R²+3R+1、无向边 9R²+3R、度分布 {3:6, 4:6(R−1), 6:3R²−3R+1}
#   （几何：6 个角格 3 度、6(R−1) 个边格 4 度、其余内格 6 度），即
#   size=5(R=2) → 19 格 / 42 边；size=7(R=3) → 37 格 / 90 边；size=9(R=4) → 61 格 / 156 边。
# 蜂窝包围盒 = size×size（AdjacencyGrid.size() 返回 bbox）。**注意**：窗口是左对齐的 [0,size)²，
#   行 c 区间 = [max(0, size−1−half−r), min(size−1, size−1+half−r)]，故 bbox 四角**并非**全在盘外：
#   size=5 时 (0,0)、(4,4) 在盘外，而 (4,0)、(0,4) **在盘内**（第 0 行占 c∈[2,4]、第 4 行占 c∈[0,2]）。
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
## 生成返回空（该 seed 下 50 次 attempt 全败）时的换 seed 重试上限。
const MAX_TRIES := 20
const SEED_STRIDE := 1

# 关卡规格（族驱动）。字段：
#   file/kind/name/desc —— 文件名 / 形状族 / 中文名 / 日志描述
#   params  —— 传给形状族的参数（holed_grid: rows/cols/holes；hex: size）
#   cells   —— 期望盘内格数（自校验；另有族公式与之独立核对，防 spec 手抄错）
#   bbox    —— 期望包围盒（AdjacencyGrid.size()；= CP-SAT 的索引范围）
#   mines/seed —— 雷数 / 固定起始 seed
#   off_board —— 必须**不在盘内**的格（holed_grid = 洞；hex = 实际盘外格）
#   in_board  —— 必须**在盘内**的格（hex 用：锁定窗口取向，形状口径变了要红灯）
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
]


func _initialize() -> void:
	var kinds := _selected_kinds()
	if kinds.is_empty():
		_request_exit(1)
		return
	print("=== 异形关卡生成（T2 挖洞方格 / T3 蜂窝）===")
	print("  clue_rule=%s  globals=%s  attempts=%d  max_tries=%d  本次族=%s（SPECS 含：%s）" % [
		CLUE_RULE, str(GLOBALS), ATTEMPTS, MAX_TRIES, ", ".join(kinds), ", ".join(_all_kinds())])
	var t_all := Time.get_ticks_msec()
	var total := 0
	var failures := 0
	for spec: Dictionary in SPECS:
		if not kinds.has(str(spec["kind"])):
			continue
		total += 1
		if not _gen_one(spec):
			failures += 1
	var total_ms := Time.get_ticks_msec() - t_all
	if total == 0:
		push_error("族 %s 在 SPECS 里没有对应规格" % ", ".join(kinds))
		_request_exit(1)
		return
	if failures > 0:
		print("=== FAILED：%d/%d 关失败，耗时 %.1f s ===" % [failures, total, total_ms / 1000.0])
		_request_exit(1)
		return
	print("=== 全部 %d 关生成 + 自校验通过，耗时 %.1f s ===" % [total, total_ms / 1000.0])
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
		if s == "" or s == "-":
			continue
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
	var kind: String = str(spec["kind"])
	var params: Dictionary = spec["params"]
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

	# 2. 生成（generate_with_rules 内建序贯无猜验证）；失败换 seed 重试
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var tries := 0
	var t0 := Time.get_ticks_msec()
	for t in MAX_TRIES:
		tries += 1
		var seed := base_seed + t * SEED_STRIDE
		level = gen.generate_with_rules(CLUE_RULE, GLOBALS, size, mine_count, seed, 0, ATTEMPTS, topo)
		if not level.is_empty():
			break
	var gen_ms := Time.get_ticks_msec() - t0
	if level.is_empty():
		push_error("%s: 生成失败（%d 次换 seed 重试，共 %d ms）" % [file_name, tries, gen_ms])
		return false

	# 3. 落盘（补中文名；seed 由生成器写入 = 实际用时 seed）
	level["name"] = str(spec["name"])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("%s: 无法写入 %s" % [file_name, path])
		return false
	f.store_string(JSON.stringify(level, "  "))
	f.close()

	# 4. 自校验：用真实加载器重载（写出去的文件必须能玩）；形状断言在**真实产物**上再跑一遍
	var board: Board = _load_level(path)
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
		if board.total_mines != int(level.get("total_mines", -1)):
			problems.append("board.total_mines=%d ≠ JSON %d" % [board.total_mines, int(level.get("total_mines", -1))])
		if board.total_mines != mine_count:
			problems.append("board.total_mines=%d ≠ 规格 %d" % [board.total_mines, mine_count])
	if not problems.is_empty():
		push_error("%s: 自校验失败 —— %s（已删除坏文件）" % [file_name, "；".join(problems)])
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return false

	var prof: Dictionary = level.get("difficulty_profile", {})
	print("  [%s] %s（kind=%s, %s）" % [file_name, str(spec["name"]), kind, str(spec["desc"])])
	print("    bbox=%d×%d  格=%d  雷=%d  盘外格=%d  无向边=%d  度分布 %s  seed=%d  尝试=%d/%d  生成 %d ms  落盘 %d bytes" % [
		size.x, size.y, topo.cell_count(), board.total_mines, size.x * size.y - topo.cell_count(), edges,
		_hist_to_str(histogram), int(level.get("seed", -1)), tries, MAX_TRIES, gen_ms,
		FileAccess.get_file_as_bytes(path).size()])
	print("    难度字段：difficulty=%s  max_complexity=%s  rounds=%s  clue_count=%s  clue_ratio=%s  profile=%s" % [
		str(prof.get("difficulty", "n/a")), str(prof.get("max_complexity", "n/a")),
		str(prof.get("rounds", "n/a")), str(prof.get("clue_count", "n/a")),
		str(prof.get("clue_ratio", "n/a")), str(prof.get("profile", "n/a"))])
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
		if n % 2 == 0:
			problems.append("蜂窝 size 应为奇数（收到 %d）" % n)
			return problems
		# 规格 cells 与蜂窝规模公式互为独立核对（防 spec 手抄错）
		if expect_cells != _hex_cells(n):
			problems.append("规格 cells=%d ≠ 蜂窝公式 3R²+3R+1=%d" % [expect_cells, _hex_cells(n)])
		if Vector2i(spec["bbox"]) != Vector2i(n, n):
			problems.append("规格 bbox=%s ≠ size×size=%s" % [str(spec["bbox"]), str(Vector2i(n, n))])
		# 几何指纹：度分布 + 无向边（换算成独立于实现的整数序列比较，避免 Dictionary 比较语义歧义）
		var want_hist := _hex_degree_histogram(n)
		var got_hist := _degree_histogram(g)
		if _hist_to_str(got_hist) != _hist_to_str(want_hist):
			problems.append("度分布 %s ≠ 期望 %s" % [_hist_to_str(got_hist), _hist_to_str(want_hist)])
		var edges := _edge_count(g)
		if edges != _hex_edges(n):
			problems.append("无向边 %d ≠ 期望 9R²+3R=%d" % [edges, _hex_edges(n)])
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
	return problems


## 蜂窝半径 R = (size−1)/2（本工具只产奇数 size）。
func _hex_radius(size: int) -> int:
	return (size - 1) / 2


## 蜂窝盘格数 3R²+3R+1（与 build_hex 的裁剪式互为独立核算）。
func _hex_cells(size: int) -> int:
	var r := _hex_radius(size)
	return 3 * r * r + 3 * r + 1


## 蜂窝无向边数 9R²+3R（度分布求和 / 2 的闭式）。
func _hex_edges(size: int) -> int:
	var r := _hex_radius(size)
	return 9 * r * r + 3 * r


## 蜂窝度分布指纹：6 角格 3 度、6(R−1) 边格 4 度、其余 3R²−3R+1 内格 6 度。
func _hex_degree_histogram(size: int) -> Dictionary:
	var r := _hex_radius(size)
	return {3: 6, 4: 6 * (r - 1), 6: 3 * r * r - 3 * r + 1}


## 度分布（度 → 格数）。
func _degree_histogram(g: GridInterface) -> Dictionary:
	var h := {}
	for p in g.all_positions():
		var d := g.get_neighbors(p).size()
		h[d] = int(h.get(d, 0)) + 1
	return h


## 度分布 → "3:6,4:6,6:7"（键升序；字符串比较，跨版本确定）。
func _hist_to_str(h: Dictionary) -> String:
	var keys: Array = h.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		parts.append("%d:%d" % [int(k), int(h[k])])
	return ",".join(parts)


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
