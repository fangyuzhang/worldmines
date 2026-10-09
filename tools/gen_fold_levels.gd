# gen_fold_levels.gd —— 「静态折叠」异形关生成工具（离线 CLI）
#
# 运行： godot --headless --path . -s res://tools/gen_fold_levels.gd [-- 关卡文件名...]
# 产出： res://levels/fold_*.json
#
# 这一族把**纸的对折**搬进扫雷：盘面还是普通方阵，但一条折痕把远侧沿镜像翻过来、
# 压在近侧上 —— 镜像位上有格 ⇒ 两层贴合 ⇒ 互为邻居。线索数照拓扑邻域计数 ⇒ 压在
# 近侧的远侧格会**跨半张盘**参与计数，而屏幕上它们看着离得很远。玩家要读对数字，
# 就得先认出折痕、再在心里把远侧翻回去。
#
# 呈现层（ui/board_view.gd 的 _draw_fold_hints）画折痕线 + 折起来/摊平看双视图；
# 本工具只需保证 topology 里带 view.kind=fold 与 view.fold={axis, at}（走
# PuzzleGenerator._topology_to_dict 的 view 通道），读回即可还原。
#
# ⚠️ 生成走第一帧 _process（不是 _initialize）：规则/CP-SAT 由 autoload 装配。
extends SceneTree

const EXIT_FRAMES := 3
const ChildIso := preload("res://tools/child_isolation.gd")
## 本工具的 res:// 路径（隔离模式起子进程时要原样传给它自己）。
const TOOL_RES_PATH := "res://tools/gen_fold_levels.gd"
const OUT_DIR := "res://levels"
## 写盘走「暂存 → 校验 → 原子转正」（失败不碰正式文件）。
const LevelStaging := preload("res://tools/level_staging.gd")
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"
const ATTEMPTS := 30
const MAX_TRIES := 8
const MAX_MINES_BUMP := 3
const GEN_TIMEOUT_MS := 60000
## 单关累计生成时间上限（看门狗）。理由见 gen_iso_cubes_levels.gd 同名常量。
const WATCHDOG_MS_PER_LEVEL := 180000
## 密度上界：mines + bump 不得超过 格数 × DENSITY_CAP。
const DENSITY_CAP := 0.32
## 峰值下限 = Difficulty.PEAK_WINDOWS 的 easy 下沿（**直接引用规范源**）。
const MIN_PEAK := Difficulty.PEAK_WINDOWS["easy"]["min"]
## 雷密度：折叠盘多一层叠合边，等效度数略高，取 0.25。
const MINE_RATIO := 0.25

const ThemeMarks := preload("res://tools/theme_marks.gd")
## 形状族 kind：写进 shape_kind（选关页卡片标签）与 theme 解析（tools/theme_marks.gd 的 BY_KIND）。
const KIND := "fold"

## 规格：方阵尺寸 + 折痕 + （可选）挖掉的格。
##   rows/cols : 方阵行/列数（格数 = rows × cols − holes）
##   axis/at   : 折痕 —— axis="x" 左右折（折痕是竖直线，落在 at-1 与 at 之间）；
##               axis="y" 上下折（折痕是水平线）。远侧 = 索引 ≥ at 的那一半。
##   holes     : 挖掉的整格坐标（用来演示「悬空」：对面被挖掉 ⇒ 那一格叠不上）
const SPECS: Array = [
	{"file": "fold_01.json", "rows": 4, "cols": 6, "axis": "x", "at": 3,
		"name": "折叠 01 · 对折", "desc": "4×6 · 沿中线左右对折，右半翻过来压住左半",
		"seed": 42001, "holes": []},
	{"file": "fold_02.json", "rows": 5, "cols": 6, "axis": "x", "at": 3,
		"name": "折叠 02 · 半折五五", "desc": "5×6 · 半分对折，叠合边横贯五行",
		"seed": 42011, "holes": []},
	{"file": "fold_03.json", "rows": 5, "cols": 7, "axis": "x", "at": 4,
		"name": "折叠 03 · 长边折短", "desc": "5×7 · 左半 4 列、右半 3 列：最外一列折不到对家",
		"seed": 42021, "holes": []},
	{"file": "fold_04.json", "rows": 6, "cols": 8, "axis": "x", "at": 3,
		"name": "折叠 04 · 长边折长", "desc": "6×8 · 左半 3 列、右半 5 列：折角伸出盘外两列",
		"seed": 42031, "holes": []},
	{"file": "fold_05.json", "rows": 6, "cols": 7, "axis": "y", "at": 3,
		"name": "折叠 05 · 上下折", "desc": "6×7 · 沿水平折痕上下对折，下半翻上来压住上半",
		"seed": 42041, "holes": []},
	{"file": "fold_06.json", "rows": 6, "cols": 8, "axis": "x", "at": 4,
		"name": "折叠 06 · 残洞", "desc": "6×8 · 半分对折 + 中央挖掉两格：对面没格的那一层叠不上",
		"seed": 42051, "holes": [Vector2i(1, 2), Vector2i(6, 3)]},
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
	print("=== 折叠 异形关生成 ===")
	var todo: Array = []
	var todo_idx: Array = []
	for i in SPECS.size():
		var spec: Dictionary = SPECS[i]
		if want.is_empty() or want.has(str(spec["file"])):
			todo.append(spec)
			todo_idx.append(i)
	var total_cells := 0
	for spec: Dictionary in todo:
		total_cells += int(spec["rows"]) * int(spec["cols"]) - (spec.get("holes", []) as Array).size()
	print("  目标 %d 关 · 合计 %d 格" % [todo.size(), total_cells])
	var isolate := OS.get_cmdline_user_args().has("--isolate")
	var t_all := Time.get_ticks_msec()
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
		print("=== FOLD-OK-FAILED ===")
		_request_exit(1)
		return
	print("=== FOLD-OK ===")
	_request_exit(0)


## 命令行 `-- file1 file2`（空 = 全量）。
func _selected() -> Array:
	var out: Array = []
	for piece in OS.get_cmdline_user_args():
		var s := piece.strip_edges()
		if s != "" and s != "--" and s != "--isolate":
			out.append(s)
	return out


func _gen_one(spec: Dictionary) -> bool:
	var file_name := str(spec["file"])
	var path := OUT_DIR + "/" + file_name
	var rows := int(spec["rows"])
	var cols := int(spec["cols"])
	var axis := str(spec["axis"])
	var at := int(spec["at"])

	# 1. 拓扑：方阵（强制产出邻接表——带折叠的盘必须走 AdjacencyGrid）→ 挖洞 → 挂折痕
	var built := WrapTopology.build(rows, cols, ShapeGenerator.MOORE8, false, false, true)
	if not bool(built["ok"]):
		push_error("%s: 拓扑构建失败：%s" % [file_name, str(built["reason"])])
		return false
	var topo_dict: Dictionary = built["topology"]
	topo_dict = _carve(topo_dict, spec.get("holes", []))
	var attach := TopologyModel.attach_fold(topo_dict, {"axis": axis, "at": at})
	if not bool(attach["ok"]):
		push_error("%s: 折痕写入失败：%s" % [file_name, str(attach["errors"])])
		return false
	topo_dict = attach["topology"] as Dictionary
	var audit := TopologyModel.validate(topo_dict)
	if not bool(audit["ok"]):
		push_error("%s: 拓扑体检未过：%s" % [file_name, str(audit["errors"])])
		return false

	var topo := AdjacencyGrid.new()
	topo.setup_from_topo(topo_dict)
	var n := topo.cell_count()

	# 2. 生成（内建 R01 序贯无猜）→ 峰值验收 → ProofLog 复核
	var mines := maxi(1, int(round(float(n) * MINE_RATIO)))
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var best_peak := -1
	var tries := 0
	var max_mines := int(floor(float(n) * DENSITY_CAP))
	var level_t0 := Time.get_ticks_msec()
	for b in MAX_MINES_BUMP + 1:
		if mines + b > max_mines:
			break
		for t in MAX_TRIES:
			tries += 1
			if Time.get_ticks_msec() - level_t0 > WATCHDOG_MS_PER_LEVEL:
				push_error("%s: 单关累计生成超过 %d 秒（看门狗），放弃。已试 %d 次，最高 peak=%d" % [
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

	# 3. 落盘：标题 + 形状标签 + 主题配色（必须过 ThemeMarks.apply，否则全库门禁判红）
	level["name"] = str(spec["name"])
	level["desc"] = str(spec["desc"])
	level["shape_kind"] = "折叠"
	level["palette"] = ThemeMarks.apply({}, "", "", KIND)
	# 拓扑自述必须与网格一致（LevelLoader 会再验一次；这里先自证，失败就不落盘）
	var persisted: Dictionary = level.get("topology", {})
	if not bool(TopologyModel.validate(persisted)["ok"]):
		push_error("%s: 落盘拓扑自述未过体检" % file_name)
		return false

	var tmp := LevelStaging.write_text(path, JSON.stringify(level, "  "))
	if tmp == "":
		push_error("%s: 无法写入暂存区" % file_name)
		return false

	# 4. 自校验（真实重载）：邻接表 + 折痕声明 + 叠合边必须都在
	var board: Board = _load_level(tmp)
	if board == null or not (board.grid is AdjacencyGrid):
		push_error("%s: 自校验失败（重载为 null 或不是邻接表网格）" % file_name)
		LevelStaging.discard(tmp)
		return false
	var ag := board.grid as AdjacencyGrid
	if str(ag.view_meta.get("kind", "")) != TopologyModel.VIEW_FOLD:
		push_error("%s: 自校验失败（读回后不是折叠呈现）" % file_name)
		LevelStaging.discard(tmp)
		return false
	var got_fold: Variant = ag.view_meta.get("fold", {})
	if not (got_fold is Dictionary):
		push_error("%s: 自校验失败（读回后缺 fold 声明）" % file_name)
		LevelStaging.discard(tmp)
		return false
	var gf: Dictionary = got_fold
	if str(gf.get("axis", "")) != axis or int(gf.get("at", -1)) != at:
		push_error("%s: 自校验失败（折痕 %s != 期望 %s）" % [file_name, str(gf), str({"axis": axis, "at": at})])
		LevelStaging.discard(tmp)
		return false
	var ps: Array[Vector2i] = []
	for p in ag.all_positions():
		ps.append(p)
	var rep := FoldModel.audit(gf, ps)
	if not bool(rep["ok"]):
		push_error("%s: 自校验失败（折痕审计不过：%s）" % [file_name, str(rep["errors"])])
		LevelStaging.discard(tmp)
		return false
	var pairs: Array = rep["pairs"]
	if pairs.is_empty():
		push_error("%s: 自校验失败（一对叠格都没有）" % file_name)
		LevelStaging.discard(tmp)
		return false
	for pr: Dictionary in pairs:
		if not ag.get_neighbors(pr["a"]).has(pr["b"]) or not ag.get_neighbors(pr["b"]).has(pr["a"]):
			push_error("%s: 自校验失败（叠合边不成双向：%s-%s）" % [file_name, str(pr["a"]), str(pr["b"])])
			LevelStaging.discard(tmp)
			return false
	if not LevelStaging.promote(tmp, path):
		push_error("%s: 暂存转正失败，正式文件未改动" % file_name)
		return false
	var prof2: Dictionary = level.get("difficulty_profile", {})
	print("  OK   %-14s %-22s %d 格 · %d 雷 · 峰值 %s · %d 对叠格 · %d 次" % [
		file_name, str(spec["name"]), n, used_mines,
		str(prof2.get("max_complexity", "?")), pairs.size(), tries])
	return true


## 从拓扑里挖掉若干格：**position 与所有指向它的邻接一起删**。
## 只删 position 不删边 ⇒ 校验器把「盘外邻接」判成错误、关卡被加载器拒收（本族最容易踩的坑）。
func _carve(topo: Dictionary, holes: Array) -> Dictionary:
	var dead := {}
	for h: Variant in holes:
		var p_v: Variant = TopologyModel.parse_pos(h)
		if p_v != null:
			dead[p_v] = true
	if dead.is_empty():
		return topo
	var out := {"positions": [], "neighbors": {}}
	for key in ["style", "params", "editor", "view"]:
		if topo.has(key):
			out[key] = topo[key]
	for pv: Variant in topo.get("positions", []):
		var pd: Dictionary = pv
		var pos := Vector2i(int(pd["x"]), int(pd["y"]))
		if not dead.has(pos):
			out["positions"].append({"x": pos.x, "y": pos.y})
	var nb_in: Dictionary = topo.get("neighbors", {})
	var nb_out: Dictionary = {}
	for raw_src: Variant in nb_in:
		var av: Variant = TopologyModel.parse_key(raw_src)
		if av == null:
			continue
		var a: Vector2i = av
		if dead.has(a):
			continue
		var kept: Array = []
		for raw_nb: Variant in (nb_in[raw_src] as Array):
			var bv: Variant = TopologyModel.parse_key(raw_nb)
			if bv == null:
				continue
			var b: Vector2i = bv
			if not dead.has(b):
				kept.append(TopologyModel.key_of(b))
		nb_out[TopologyModel.key_of(a)] = kept
	out["neighbors"] = nb_out
	return out


func _proof_ok(level: Dictionary) -> bool:
	var pl: GDScript = load("res://core/proof_log.gd")
	if pl == null:
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
