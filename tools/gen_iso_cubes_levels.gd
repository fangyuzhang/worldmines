# gen_iso_cubes_levels.gd —— 「等轴菱面」异形关生成工具（离线 CLI）
#
# 运行： godot --headless --path . -s res://tools/gen_iso_cubes_levels.gd [-- 关卡文件名...]
# 产出： res://levels/iso_*.json
#
# 这一族是「看起来立体、实际是平面」的错觉盘（几何机制见 core/shape_generator.gd 的
# 等轴菱面一节）：每个「立方体」= 3 个可点格（顶面 / 右面 / 左面），只有 3 种朝向，
# 数量严格 1:1:1。眼睛数出 n 个方块，引擎里是 3n 个判断格。
#
# 三个面的配色 = **同一色相的三档明度**（顶最亮 → 右中 → 左最暗），走的是项目既有的
# groups 机制（palette.groups 提供颜色、custom_shapes.cells[].group 提供归属），
# 因此：
#   · 观感上等价于给立方体打了光，立体感不需要改渲染层一行代码；
#   · 功能上它同时是一组真实的「分色雷数」约束（右上角计数器照常生效）——
#     正是对标作品把颜色变成逻辑对象的那种用法。
#
# ⚠️ 生成走第一帧 _process（不是 _initialize）：规则/CP-SAT 由 autoload 装配
#    （同 gen_style_shape_levels.gd 注释）。
# ⚠️ 已知缺口（2026-09-23 生成器审计 #4 / #5，与 gen_shape_levels.gd 的口径差）：
#   ① 本族**没有单关 240s 看门狗**。CP-SAT 的 max_time 只约束求解阶段；>100 格 + 变体规则时
#      Solve() 可能长期不返回——外部只有 tools/run_batch.ps1 的 taskkill 兜底（且它会撞上
#      半写批次窗口，见 level_staging 的说明，写盘侧已在 2026-09-23 加固）。
#   ② 加雷轮**没有密度上界**（gen_shape_levels 有 mines+bump ≤ 格数×0.35）。
#   补齐这两项需要专门窗口实跑验证（生成一次数十分钟），故本轮只记录、未实施。
extends SceneTree

const EXIT_FRAMES := 3
const ChildIso := preload("res://tools/child_isolation.gd")
## 本工具的 res:// 路径（隔离模式起子进程时要原样传给它自己）。
const TOOL_RES_PATH := "res://tools/gen_iso_cubes_levels.gd"
const OUT_DIR := "res://levels"
## 写盘走「暂存 → 校验 → 原子转正」（原实现会覆盖后删除，失败即丢原文件）。
const LevelStaging := preload("res://tools/level_staging.gd")
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"
const ATTEMPTS := 30
const MAX_TRIES := 8
const MAX_MINES_BUMP := 3
## 纹理徽记规则源（palette.texture：变体轴 / 形状族的唯一映射表）。
const TextureMarks := preload("res://tools/texture_marks.gd")
## 主题配色规则源（palette.theme）。2026-09-24 接入。
const ThemeMarks := preload("res://tools/theme_marks.gd")

## 单关**累计**生成时间上限（看门狗）。2026-09-23 审计 #4 补齐，与 gen_shape_levels.gd 同口径。
## 理由：CP-SAT 的 max_time_in_seconds 只约束求解阶段，实测 >100 格 + 变体规则时 Solve()
## 长期不返回（CPU 近 0、无输出），从外部与死锁无法区分，只能手动杀进程、整批白跑。
## 局限（如实说明）：检查点在调用之间，单次 Solve() 自身卡住则打断不了（OR-Tools 无中止接口）。
const WATCHDOG_MS_PER_LEVEL := 240000
## 密度上界（2026-09-23 审计 #5 补齐）：mines + bump 不得超过 格数 × DENSITY_CAP。
## 超过说明该形状在此尺寸下数学上难出深推理——如实失败并在报告里列出，不无限加雷。
const DENSITY_CAP := 0.35
const GEN_TIMEOUT_MS := 60000
## 峰值下限 = 2：与 core/difficulty.gd 的 PEAK_WINDOWS 对齐 ——
## 普通档（easy）的窗口是 peak 2~3，peak 0~1 是「纯一眼盘」**不进任何档**，
## 那样产出的关在选关页/关卡库里没有档位归属、等于白产。
## （gen_style_shape_levels 用 1 是因为它那批关还要过自己的风格闸门；本族直接对齐档位。）
# 峰值下限 = Difficulty.PEAK_WINDOWS 的 easy 下沿（**直接引用规范源**；见 gen_geo_levels 同名说明）。
const MIN_PEAK := Difficulty.PEAK_WINDOWS["easy"]["min"]
## 雷密度：对标作品实测各关 36~39%，取 0.30 留一点构造余地。
const MINE_RATIO := 0.30

## 三面配色 = 同一色相的**纯明度三步**（顶面受光 1.00 → 右面侧光 0.78 → 左面背光 0.58），
## 观感上等价于给立方体打了光。单色相是有意的：多色相会把「这是同一个立方体」的阅读打散。
##
## ⚠️ 三个值必须是**严格等比缩放**（= 同一个 RGB 乘不同系数），不能各自手调。
## 原因：8bit 量化下，非等比的三个颜色算出来的 HSV 色相会漂 —— 本行初版手调成
## (82,179,255)/(52,118,184)/(33,76,126)，色相实际是 206.4° / 210.0° / 212.3°，
## 最大漂移 6°，肉眼能看出三面「不是一个颜色只是明暗不同」。
## 等比取整后色相漂移 ≤ 0.14°、饱和度恒定 0.677。
## test_iso_cube_levels 的 test_face_colors_are_three_brightness_steps_of_one_hue 钉住这条。
const FACE_COLORS := {
	"顶面": [82, 179, 255],
	"右面": [64, 140, 199],
	"左面": [48, 104, 148],
}
const FACE_ORDER: Array[String] = ["顶面", "右面", "左面"]

const PALETTE_BASE := {
	"background": [20, 0, 35],
	"tile": [127, 127, 127],
	"tile_border": [200, 200, 200],
	"tile_highlight": [255, 255, 255],
	"flagged_tile": [230, 230, 230],
	"revealed": [51, 51, 51],
	"revealed_text": [255, 255, 255],
}

## 规格：方块阵列尺寸 + 挖掉的方块（holes）= 「空掉一个立方体」的凹坑。
##   cols/rows : 方块阵列（不是格子数！格数 = cols × rows × 3）
##   holes     : 整块挖掉的方块坐标 (i, j)
const SPECS: Array = [
	{"file": "iso_01.json", "cols": 3, "rows": 3, "holes": [],
		"name": "等轴 01 · 三方阵", "desc": "3×3 立方体阵列 · 无挖空", "seed": 31001},
	{"file": "iso_02.json", "cols": 4, "rows": 3, "holes": [],
		"name": "等轴 02 · 长方阵", "desc": "4×3 立方体阵列 · 无挖空", "seed": 31011},
	{"file": "iso_03.json", "cols": 4, "rows": 4, "holes": [Vector2i(1, 1), Vector2i(2, 2)],
		"name": "等轴 03 · 凹坑", "desc": "4×4 阵列 · 对角挖空两个立方体", "seed": 31021},
	{"file": "iso_04.json", "cols": 4, "rows": 4, "holes": [Vector2i(0, 0), Vector2i(3, 0), Vector2i(0, 3), Vector2i(3, 3)],
		"name": "等轴 04 · 掏四角", "desc": "4×4 阵列 · 四个角各挖一个立方体", "seed": 31031},
	{"file": "iso_05.json", "cols": 5, "rows": 4, "holes": [Vector2i(2, 1), Vector2i(2, 2)],
		"name": "等轴 05 · 隧道", "desc": "5×4 阵列 · 中央纵向贯穿两个立方体", "seed": 31041},
]

var _started := false
var _exit_pending := false
var _exit_frames := 0
var _exit_code := 0
var _fail := 0
var _ok := 0


func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		# child 模式 = 进程隔离的子进程侧：只生成一个规格后退出
		if ChildIso.is_child_mode():
			_run_child_mode()
		else:
			_run()
		return false
	if not _exit_pending:
		return false
	_exit_frames += 1
	if _exit_frames < EXIT_FRAMES:
		return false
	quit(_exit_code)
	return true


func _run() -> void:
	var want := _selected()
	print("=== 等轴菱面 异形关生成 ===")
	var todo: Array = []
	var todo_idx: Array = []      # 隔离模式按索引找子进程（父子同看 SPECS）
	for i in SPECS.size():
		var spec: Dictionary = SPECS[i]
		if want.is_empty() or want.has(str(spec["file"])):
			todo.append(spec)
			todo_idx.append(i)
	var total_cells := 0
	for spec: Dictionary in todo:
		total_cells += int(spec["cols"]) * int(spec["rows"]) * 3
	print("  规格 %d / %d 关（clue=classic；峰值要求 >= %d；合计上限 %d 格）" % [
		todo.size(), SPECS.size(), MIN_PEAK, total_cells])
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var t_all := Time.get_ticks_msec()
	var isolate := OS.get_cmdline_user_args().has("--isolate")
	if isolate:
		print("  ** 进程隔离已开启：每关独立子进程 + %d 秒强杀 **" % [ChildIso.DEFAULT_TIMEOUT_MS / 1000])
	for k in todo.size():
		var spec: Dictionary = todo[k]
		var ok := false
		if isolate:
			var code := ChildIso.run_child(TOOL_RES_PATH, int(todo_idx[k]))
			ok = code == 0
			if code == 2:
				print("  !! %s：超时强杀（该组合在此规模下超出求解器可行域）" % str(spec["file"]))
		else:
			ok = _gen_one(spec)
		if ok:
			_ok += 1
		else:
			_fail += 1
	print("=== 完成：成功 %d / 失败 %d，耗时 %.1f s ===" % [
		_ok, _fail, float(Time.get_ticks_msec() - t_all) / 1000.0])
	if _fail > 0:
		print("=== ISO-OK-FAILED ===")
		_request_exit(1)
		return
	print("=== ISO-OK ===")
	_request_exit(0)


## 命令行过滤（`-- iso_01.json,iso_02.json`）：不传 = 全部。
func _selected() -> Array:
	var out: Array = []
	for a in OS.get_cmdline_user_args():
		for piece in str(a).split(","):
			var s := piece.strip_edges()
			if s != "" and not s.begins_with("--"):
				# 跳过开关参数（--isolate 等）：它不是文件名
				out.append(s)
	return out


func _gen_one(spec: Dictionary) -> bool:
	var file_name := str(spec["file"])
	var path := OUT_DIR + "/" + file_name
	var cols := int(spec["cols"])
	var rows := int(spec["rows"])
	var holes: Array = spec.get("holes", [])

	# 1. 拓扑（等轴菱面：整数格键，直接可上 CP-SAT）
	var topo := ShapeGenerator.to_adjacency_grid("iso_cubes",
			{"cols": cols, "rows": rows, "holes": holes})
	if topo == null:
		push_error("%s: 拓扑构建失败" % file_name)
		return false
	topo = AdjacencyGrid.normalized(topo)
	var n := topo.cell_count()
	if n != _expected_cells(cols, rows, holes):
		push_error("%s: 格数不符（建得 %d，应为 %d）" % [file_name, n, _expected_cells(cols, rows, holes)])
		return false

	# 2. 几何：逐格世界坐标多边形（等轴菱面自带几何，无需再做盘面形变）
	var geo: Array = ShapeGenerator.iso_cells_geo(cols, rows, holes)
	if geo.size() != n:
		push_error("%s: 几何格数 %d ≠ 拓扑格数 %d" % [file_name, geo.size(), n])
		return false

	# ⚠️ 与 gen_geo_levels 同款防线：normalized() 会把拓扑坐标平移到「最小 = (0,0)」，
	# 而几何是按未平移的坐标生成的。若洞把第 0 行/列挖空（例如 holes 含 (0,0) 且该列无存活格），
	# 拓扑会被挪而几何不挪 → 落盘后 topology 与 custom_shapes 错位（渲染与邻接各画一处）。
	# 当前 5 关恰好不需要平移（侥幸），这里按同一个最小坐标平移几何并逐点核对，把隐患堵死。
	geo = _align_geo_to_origin(geo)
	var tset := {}
	for p: Vector2i in topo.all_positions():
		tset[p] = true
	for rec3: Dictionary in geo:
		if not tset.has(rec3["pos"]):
			push_error("%s: 几何格 %s 不在拓扑里（坐标未对齐）" % [file_name, str(rec3["pos"])])
			return false

	# 3. 生成（内建 R01 序贯无猜）→ 峰值验收 → ProofLog 复核
	var mines := maxi(1, int(round(float(n) * MINE_RATIO)))
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var best_peak := -1
	var tries := 0
	# 密度上界（2026-09-23 审计 #5）：mines + bump 不得超过 格数 × DENSITY_CAP。
	var max_mines := int(floor(float(n) * DENSITY_CAP))
	if mines > max_mines:
		push_error("%s: 基准雷数 %d 已超密度上界 %d（格数 %d × %.2f）——规格本身不合低密度设计" % [
			file_name, mines, max_mines, n, DENSITY_CAP])
		return false
	# 看门狗（2026-09-23 审计 #4）：单关累计时间超限即放弃本关（失败而非挂死整批）。
	var level_t0 := Time.get_ticks_msec()
	for b in MAX_MINES_BUMP + 1:
		if mines + b > max_mines:
			break
		for t in MAX_TRIES:
			tries += 1
			if Time.get_ticks_msec() - level_t0 > WATCHDOG_MS_PER_LEVEL:
				push_error("%s: 单关累计生成超过 %d 秒（看门狗触发）——判定超出求解器可行域，放弃本关。已尝试 %d 次，最高 peak=%d" % [
					file_name, WATCHDOG_MS_PER_LEVEL / 1000, tries, best_peak])
				return false
			var cand: Dictionary = gen.generate_with_rules(
					"classic", [], topo.size(), mines + b, int(spec["seed"]) + t, 0, ATTEMPTS,
					topo, GEN_TIMEOUT_MS)
			if cand.is_empty():
				continue
			var prof: Dictionary = cand.get("difficulty_profile", {})
			best_peak = maxi(best_peak, int(prof.get("max_complexity", -1)))
			if int(prof.get("max_complexity", 0)) < MIN_PEAK:
				continue
			if not _proof_ok(cand):
				continue
			level = cand
			used_mines = mines + b
			break
		if not level.is_empty():
			break
	if level.is_empty():
		push_error("%s: %d 次尝试无一达到峰值 >= %d（最高 %d）" % [file_name, tries, MIN_PEAK, best_peak])
		return false

	# 4. 落盘：几何 + 三面分组 + 配色
	level["name"] = str(spec["name"])
	level["desc"] = str(spec["desc"])
	level["shape_kind"] = "等轴菱面"
	level["custom_shapes"] = _custom_shapes(geo, topo)
	var pal := PALETTE_BASE.duplicate(true)
	# 纹理徽记（2026-09-23 审计修复）：本族产物一直带 texture=cube（玩家侧的第二条识别
	# 通道），但生成器此前不写该字段——重跑会把它悄悄丢掉（实测：一次重跑让 iso_01..05
	# 各少一行）。补上后「重跑 = 幂等」，与 gen_shape_levels 从 SPEC 读 texture 的做法对齐。
	pal["texture"] = TextureMarks.resolve("", "", "iso_cubes")
	pal["groups"] = FACE_COLORS.duplicate(true)
	# 主题配色（2026-09-24）：等轴族按 kind 取灰系；三面明度分组（groups）原样保留
	level["palette"] = ThemeMarks.apply(pal, "", "", "iso_cubes")

	# 2026-09-23 审计修复：先写暂存区、校验通过才原子转正（原实现会「覆盖后删除」）。
	var tmp := LevelStaging.write_text(path, JSON.stringify(level, "  "))
	if tmp == "":
		push_error("%s: 无法写入暂存区" % file_name)
		return false

	# 5. 自校验（真实重载；失败只丢暂存，正式文件不动）
	var board: Board = _load_level(tmp)
	if board == null or not board.has_meta("custom_shapes"):
		push_error("%s: 自校验失败（载入 %s / custom_shapes meta）" % [
			file_name, "null" if board == null else "ok"])
		LevelStaging.discard(tmp)
		return false
	if not LevelStaging.promote(tmp, path):
		push_error("%s: 暂存转正失败，正式文件未改动" % file_name)
		return false
	var prof2: Dictionary = level.get("difficulty_profile", {})
	print("  OK   %-14s %-18s %d 格 · %d 雷 · 峰值 %s · %d 次" % [
		file_name, str(spec["name"]), n, used_mines, str(prof2.get("max_complexity", "?")), tries])
	return true


## 把几何平移到「最小坐标 = (0,0)」——与 AdjacencyGrid.normalized() 同口径。
func _align_geo_to_origin(geo: Array) -> Array:
	var mn := Vector2i(1 << 30, 1 << 30)
	for rec: Dictionary in geo:
		var p: Vector2i = rec["pos"]
		mn = Vector2i(mini(mn.x, p.x), mini(mn.y, p.y))
	if mn == Vector2i.ZERO:
		return geo
	var out: Array = []
	for rec2: Dictionary in geo:
		out.append({"pos": (rec2["pos"] as Vector2i) - mn, "poly": rec2["poly"]})
	return out


## 期望格数 = 存活方块 × 3。
## 洞的受理口径必须与 ShapeGenerator 完全一致（Vector2i 或 {"x","y"}；越界/畸形跳过），
## 否则「期望值」与「实际建成」会各自记账 —— 那正是本函数要防的那类静默错。
func _expected_cells(cols: int, rows: int, holes: Array) -> int:
	var removed := {}
	for h: Variant in holes:
		var p: Variant = null
		if h is Vector2i:
			p = h
		elif h is Dictionary and (h as Dictionary).has("x") and (h as Dictionary).has("y"):
			p = Vector2i(int((h as Dictionary)["x"]), int((h as Dictionary)["y"]))
		if p == null:
			continue
		var v: Vector2i = p
		if v.x < 0 or v.x >= cols or v.y < 0 or v.y >= rows:
			continue
		removed[v] = true
	return maxi(0, cols * rows - removed.size()) * 3


## custom_shapes：与 gen_style_shape_levels 同格式（渲染层 _ensure_custom_cache 逐字段读），
## 额外把每个面的朝向写进 `group`（正是三面配色的归属来源）。
func _custom_shapes(cells_geo: Array, topo: AdjacencyGrid) -> Dictionary:
	var min_v := Vector2(1e9, 1e9)
	var max_v := Vector2(-1e9, -1e9)
	for rec: Dictionary in cells_geo:
		for v: Vector2 in rec["poly"]:
			min_v = Vector2(minf(min_v.x, v.x), minf(min_v.y, v.y))
			max_v = Vector2(maxf(max_v.x, v.x), maxf(max_v.y, v.y))
	var out_cells: Array = []
	for rec: Dictionary in cells_geo:
		var poly: Array = rec["poly"]
		var pos: Vector2i = rec["pos"]
		var center := Vector2.ZERO
		for v: Vector2 in poly:
			center += v
		center /= float(poly.size())
		var rel: Array = []
		for v2: Vector2 in poly:
			var d := v2 - center
			rel.append([snappedf(d.x, 0.0000001), snappedf(d.y, 0.0000001)])
		out_cells.append({
			"x": pos.x, "y": pos.y,
			"center": [snappedf(center.x - min_v.x, 0.0000001), snappedf(center.y - min_v.y, 0.0000001)],
			"poly": rel,
			"hl": [],
			"taper": [false, false],
			"group": FACE_ORDER[pos.x % ShapeGenerator.ISO_FACE_COUNT],
		})
	return {
		"kind": "poly_set",
		"bbox": [0.0, 0.0, snappedf(max_v.x - min_v.x, 0.0000001), snappedf(max_v.y - min_v.y, 0.0000001)],
		"unit": 1.0,
		"cells": out_cells,
	}


func _proof_ok(level: Dictionary) -> bool:
	var pl: GDScript = load("res://core/proof_log.gd")
	if pl == null:
		# 推演器拿不到时**按失败处理**（fail-fast，2026-09-25）：proof 复核是产线
		# 最后一道闸，闸坏了还放行 = 产出**未验证**的盘——而「门禁兜底」要等全量回归
		# 才能发现，跑批时未必在跑回归。load 失败只发生在文件缺失/编译错误，
		# 那说明环境已坏：宁可停产，也不产未验证的盘。
		push_error("proof_log.gd 加载失败——无法复核序贯可解，按失败处理（检查仓库完整性）")
		return false
	var log: Variant = pl.call("build", level)
	return log is Dictionary and bool((log as Dictionary).get("solved", false))


func _load_level(path: String) -> Board:
	var loader: GDScript = load(LEVEL_LOADER_PATH)
	if loader == null:
		return null
	var b: Variant = loader.call("load_level", path)
	return b as Board


## 子进程侧（进程隔离）：只生成第 index 个规格，把退出码写进完成标记。
## 参数形如 `-- child <index> <marker>`；索引直接取 SPECS[index] ⇒ 父子看到同一张表。
func _run_child_mode() -> void:
	var a := ChildIso.child_args()
	var idx := int(a[0])
	var marker := str(a[1])
	if idx < 0 or idx >= SPECS.size():
		ChildIso.write_marker(marker, 2)
		_request_exit(2)
		return
	var spec: Dictionary = SPECS[idx]
	var code := 0 if _gen_one(spec) else 1
	ChildIso.write_marker(marker, code)
	_request_exit(code)


func _request_exit(code: int) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_exit_code = code
	_exit_frames = 0
	_exit_pending = true
