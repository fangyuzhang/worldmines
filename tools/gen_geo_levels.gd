# gen_geo_levels.gd —— 「铺装族 × 变体」异形关生成工具（离线 CLI）
#
# 运行： godot --headless --path . -s res://tools/gen_geo_levels.gd [-- 文件名...]
# 产出： res://levels/tri_*.json / trihex_*.json / t31212_*.json / ring_*.json
#        res://levels/vg_<族>_<规则>.json   （vg = variant × geometry，带 S/Z/dt 全局约束）
#
# 与既有工具的分别：
#   · gen_shape_levels.gd        —— 纯 classic 形状关（入库用，逐关写死形状指纹）
#   · gen_style_shape_levels.gd  —— 同一邻接图 + 盘面形变/涡流/叠瓦（「风格谱系」）
#   · gen_variant_shape_levels.gd —— 变体 × 既有形状（挖洞方格 / 蜂窝）
#   · gen_iso_cubes_levels.gd    —— 等轴菱面（错觉盘，三面配色）
#   · **本工具**                 —— 四族「精确铺装」新几何：三角网格 / 3.6.3.6 /
#     3.12.12 / 同心环盘；并支持同一几何直接挂 S/Z/dt 全局约束（异形 × 变体）。
#
# 为什么这批几何值得单独做：它们带来**全新的邻域结构**（玩法本身不同），不是换皮——
#   tri_grid 度 3（线索只覆盖 3 格，极简）；trihex 度 3/6（编织）；
#   t31212 度 3/12（同一盘里最大与最小信息量并存）；ring 是**环状拓扑**
#   （角向首尾相接，环向可绕回 —— 守恒类约束在这种图上特别有意思）。
#
# 颜色分组：按「圈层」分 3 色（内/中/外），走项目既有的 groups 机制
#（右上角会按圈层报「该环还剩几颗雷」）—— 好看且是真实线索，不是纯装饰。
#
# ⚠️ 生成走第一帧 _process（autoload 就绪后才跑，同 gen_style_shape_levels）。
extends SceneTree

const EXIT_FRAMES := 3
const OUT_DIR := "res://levels"
const LEVEL_LOADER_PATH := "res://ui/level_loader.gd"
const ATTEMPTS := 30
const MAX_TRIES := 12
const MAX_MINES_BUMP := 3
const GEN_TIMEOUT_MS := 60000
## 峰值下限 = 2（= core/difficulty.gd 普通档下限）。峰值 0~1 的「一眼盘」不进任何档，
## 产出来在选关页/库里没有档位归属，等于白产。
# 峰值下限 = Difficulty.PEAK_WINDOWS 的 easy 下沿（**直接引用规范源**，2026-09-23 审计）。
const MIN_PEAK := Difficulty.PEAK_WINDOWS["easy"]["min"]

## 雷密度按族给：邻域越小（度越低）信息越稀，需要更低的雷密度才留得出可推的空间。
## 三角网格度 3、环盘最内环度 3 —— 都用 0.24；其余 0.28。
const MINE_RATIO := {
	"tri_grid": 0.24,
	"trihex": 0.28,
	"t31212": 0.28,
	"ring": 0.24,
}

const RING_COLORS := {
	"RING_0": [82, 179, 255],
	"RING_1": [126, 217, 87],
	"RING_2": [255, 200, 87],
}
const PALETTE_BASE := {
	"background": [20, 0, 35],
	"tile": [127, 127, 127],
	"tile_border": [200, 200, 200],
	"tile_highlight": [255, 255, 255],
	"flagged_tile": [230, 230, 230],
	"revealed": [51, 51, 51],
	"revealed_text": [255, 255, 255],
}

## 规格：
##   kind   : tri_grid / trihex / t31212 / ring
##   cols/rows（前三种）或 sectors（ring）
##   globals: 可选。异形上可用的 S/Z 轴规则（见 gen_variant_shape_levels.gd 的实测清单：
##            s1/s2/s3/s5/s7/z2/dt 可用；z1 镜像 / z3 四象限语义依赖方阵 ⇒ 异形上不成立）
##   ⚠️ 但「可用」是按**拓扑**逐族而定的，不是一张通用表（实测 2026-09-22）：
##      · trihex + z2（相邻行锁）**不成立**：3.6.3.6 没有「行」这个结构（48 次尝试全空）；
##        需要行语义的约束（z2 等）应配**有行/环序**的族（本文件里换成 ring + z2 即通过）。
##      · 三角网格 + s1 / 3.6.3.6 + s2 / 3.12.12 + s3 / 环盘 + s5 / 环盘 + z2 / 环盘 + dt 实测可产。
const SPECS: Array = [
	# ---- 纯 classic：四族各来两关 ----
	{"file": "tri_01.json", "kind": "tri_grid", "cols": 4, "rows": 4,
		"name": "三角 01 · 素三角", "desc": "4×4 菱形格 = 32 个等边三角形 · 每格仅 3 邻", "seed": 32001},
	{"file": "tri_02.json", "kind": "tri_grid", "cols": 6, "rows": 4,
		"name": "三角 02 · 宽幅", "desc": "6×4 菱形格 = 48 个等边三角形", "seed": 32011},
	{"file": "trihex_01.json", "kind": "trihex", "cols": 4, "rows": 3,
		"name": "编织 01 · 卡果梅", "desc": "3.6.3.6 · 三角与六边互相穿插", "seed": 32021},
	{"file": "trihex_02.json", "kind": "trihex", "cols": 5, "rows": 4,
		"name": "编织 02 · 大卡果梅", "desc": "3.6.3.6 · 更大的编织盘", "seed": 32031},
	{"file": "t31212_01.json", "kind": "t31212", "cols": 2, "rows": 2,
		"name": "十二边 01 · 大格与小角", "desc": "3.12.12 · 十二边形 12 邻 vs 三角形 3 邻", "seed": 32041},
	{"file": "t31212_02.json", "kind": "t31212", "cols": 3, "rows": 3,
		"name": "十二边 02 · 密铺", "desc": "3.12.12 · 3×3 蜂窝截角", "seed": 32051},
	{"file": "ring_01.json", "kind": "ring", "sectors": [6, 9, 12],
		"name": "环盘 01 · 三环", "desc": "同心三环 · 角向首尾相接（可绕回）", "seed": 32061},
	{"file": "ring_02.json", "kind": "ring", "sectors": [6, 9, 12, 18],
		"name": "环盘 02 · 四环", "desc": "同心四环 · 内密外疏", "seed": 32071},

	# ---- 异形 × 变体（S 轴结构 / Z 轴守恒 / dt 骨牌） ----
	{"file": "vg_tri_s1.json", "kind": "tri_grid", "cols": 4, "rows": 4, "globals": ["s1"],
		"name": "三角 · 禁形", "desc": "等边三角网格 + S1 局部禁形", "seed": 32101},
	{"file": "vg_trihex_s2.json", "kind": "trihex", "cols": 3, "rows": 3, "globals": ["s2"],
		"name": "编织 · 中心", "desc": "3.6.3.6 + S2 中心约束", "seed": 32111},
	{"file": "vg_trihex_dt.json", "kind": "trihex", "cols": 3, "rows": 3, "globals": ["dt"],
		"name": "编织 · 骨牌", "desc": "3.6.3.6 + DT 骨牌", "seed": 32121},
	{"file": "vg_t31212_s3.json", "kind": "t31212", "cols": 2, "rows": 2, "globals": ["s3"],
		"name": "十二边 · 环环", "desc": "3.12.12 + S3 禁环", "seed": 32131},
	{"file": "vg_ring_s5.json", "kind": "ring", "sectors": [6, 9, 12], "globals": ["s5"],
		"name": "环盘 · 行列", "desc": "同心环 + S5 行列约束", "seed": 32141},
	{"file": "vg_ring_z2.json", "kind": "ring", "sectors": [6, 9, 12], "globals": ["z2"],
		"name": "环盘 · 行锁", "desc": "同心环 + Z2 相邻行锁", "seed": 32151},
	{"file": "vg_ring_dt.json", "kind": "ring", "sectors": [6, 9, 12], "globals": ["dt"],
		"name": "环盘 · 骨牌", "desc": "同心环 + DT 骨牌", "seed": 32161},
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
	print("=== 铺装族 异形关生成 ===")
	var todo: Array = []
	for spec: Dictionary in SPECS:
		if want.is_empty() or want.has(str(spec["file"])):
			todo.append(spec)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var t_all := Time.get_ticks_msec()
	for spec: Dictionary in todo:
		if _gen_one(spec):
			_ok += 1
		else:
			_fail += 1
	print("=== 完成：成功 %d / 失败 %d，耗时 %.1f s ===" % [
		_ok, _fail, float(Time.get_ticks_msec() - t_all) / 1000.0])
	if _fail > 0:
		print("=== GEO-FAILED ===")
		_request_exit(1)
		return
	print("=== GEO-OK ===")
	_request_exit(0)


func _selected() -> Array:
	var out: Array = []
	for a in OS.get_cmdline_user_args():
		for piece in str(a).split(","):
			var s := piece.strip_edges()
			if s != "":
				out.append(s)
	return out


## 按 kind 取几何（拓扑与几何同源：拓扑由几何反推）。
func _geo_of(spec: Dictionary) -> Array:
	match str(spec["kind"]):
		"tri_grid":
			return ShapeGenerator.tri_grid_cells_geo(int(spec["cols"]), int(spec["rows"]))
		"trihex":
			return ShapeGenerator.trihex_cells_geo(int(spec["cols"]), int(spec["rows"]))
		"t31212":
			return ShapeGenerator.t31212_cells_geo(int(spec["cols"]), int(spec["rows"]))
		"ring":
			return ShapeGenerator.ring_cells_geo(spec["sectors"])
	return []


func _params_of(spec: Dictionary) -> Dictionary:
	match str(spec["kind"]):
		"ring":
			return {"sectors": spec["sectors"]}
		_:
			return {"cols": int(spec["cols"]), "rows": int(spec["rows"])}


func _gen_one(spec: Dictionary) -> bool:
	var file_name := str(spec["file"])
	var path := OUT_DIR + "/" + file_name
	var kind := str(spec["kind"])

	var geo: Array = _geo_of(spec)
	if geo.is_empty():
		push_error("%s: 几何构建失败（kind=%s）" % [file_name, kind])
		return false
	var topo := ShapeGenerator.to_adjacency_grid(kind, _params_of(spec))
	if topo == null:
		push_error("%s: 拓扑构建失败" % file_name)
		return false
	topo = AdjacencyGrid.normalized(topo)
	# ⚠️ normalized() 会把坐标整体平移到「最小坐标 = (0,0)」，而几何是按未平移的坐标生成的。
	# 不平移几何 → 落盘后 topology 与 custom_shapes 的格坐标错位（渲染按几何画、邻接按拓扑算，
	# 玩家会看到「连错格」）。这里按同一个最小坐标平移几何，并逐点核对两边一致。
	geo = _align_geo_to_origin(geo)
	var n := topo.cell_count()
	if n != geo.size():
		push_error("%s: 拓扑格数 %d != 几何格数 %d" % [file_name, n, geo.size()])
		return false
	var tset := {}
	for p: Vector2i in topo.all_positions():
		tset[p] = true
	for rec3: Dictionary in geo:
		if not tset.has(rec3["pos"]):
			push_error("%s: 几何格 %s 不在拓扑里（坐标未对齐）" % [file_name, str(rec3["pos"])])
			return false

	var globals: Array = spec.get("globals", [])
	var ratio := float(MINE_RATIO.get(kind, 0.28))
	var mines := maxi(1, int(round(float(n) * ratio)))
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	var used_mines := 0
	var best_peak := -1
	var tries := 0
	for b in MAX_MINES_BUMP + 1:
		for t in MAX_TRIES:
			tries += 1
			var cand: Dictionary = gen.generate_with_rules(
					"classic", globals, topo.size(), mines + b, int(spec["seed"]) + t, 0, ATTEMPTS,
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

	level["name"] = str(spec["name"])
	level["desc"] = str(spec["desc"])
	level["shape_kind"] = _shape_kind_text(kind)
	level["custom_shapes"] = _custom_shapes(geo, kind, spec)
	var pal := PALETTE_BASE.duplicate(true)
	pal["groups"] = RING_COLORS.duplicate(true)
	level["palette"] = pal

	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("%s: 无法写入 %s" % [file_name, path])
		return false
	f.store_string(JSON.stringify(level, "  "))
	f.close()

	var board: Board = _load_level(path)
	if board == null or not board.has_meta("custom_shapes"):
		push_error("%s: 自校验失败（载入 %s / custom_shapes meta）" % [
			file_name, "null" if board == null else "ok"])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return false
	var prof2: Dictionary = level.get("difficulty_profile", {})
	print("  OK   %-18s %-22s %3d 格 · %2d 雷 · 峰值 %s%s · %d 次" % [
		file_name, str(spec["name"]), n, used_mines, str(prof2.get("max_complexity", "?")),
		"" if globals.is_empty() else " · 规则 %s" % str(globals), tries])
	return true


func _shape_kind_text(kind: String) -> String:
	match kind:
		"tri_grid":
			return "等边三角网格"
		"trihex":
			return "三角六边编织"
		"t31212":
			return "十二边镶嵌"
		"ring":
			return "同心环盘"
	return kind


## 圈层分组：按「到盘心的圈层」分 3 带（内/中/外）。
## 环盘用**物理环号**（那正是它的圈层语义）；其余族用坐标的 Chebyshev 圈层。
func _group_of(pos: Vector2i, kind: String, spec: Dictionary, mid: Vector2i,
		max_ring: int) -> String:
	if kind == "ring":
		# 环盘用**物理环号**（那正是它的圈层语义），按环数三等分。
		var nr: int = (spec["sectors"] as Array).size()
		return "RING_%d" % clampi(int(float(pos.y) / maxf(float(nr), 1.0) * 3.0), 0, 2)
	# 其余族：到格心集合质心的 Chebyshev 距离，按该盘实测的最大圈层三等分。
	# （早先写成「除以 cols/rows」的版本在行数少时会把所有格算成第 0 带 —— 当时实测
	#   整盘全落 RING_0，分色计数器只有一个色块。改成按实测范围归一才稳定。）
	var d := maxi(absi(pos.x - mid.x), absi(pos.y - mid.y))
	var band := 0 if max_ring <= 0 else int(float(d) / float(max_ring + 1) * 3.0)
	return "RING_%d" % clampi(band, 0, 2)


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


func _custom_shapes(geo: Array, kind: String, spec: Dictionary) -> Dictionary:
	var min_v := Vector2(1e9, 1e9)
	var max_v := Vector2(-1e9, -1e9)
	for rec: Dictionary in geo:
		for v: Vector2 in rec["poly"]:
			min_v = Vector2(minf(min_v.x, v.x), minf(min_v.y, v.y))
			max_v = Vector2(maxf(max_v.x, v.x), maxf(max_v.y, v.y))
	# 圈层分组需要「全盘质心 + 实测最大圈层」两个量 —— 先过一遍格心再逐格填组。
	var mid := Vector2i.ZERO
	for rec0: Dictionary in geo:
		mid += rec0["pos"]
	mid = Vector2i(int(round(float(mid.x) / maxf(float(geo.size()), 1.0))),
			int(round(float(mid.y) / maxf(float(geo.size()), 1.0))))
	var max_ring := 1
	for rec1: Dictionary in geo:
		var p1: Vector2i = rec1["pos"]
		max_ring = maxi(max_ring, maxi(absi(p1.x - mid.x), absi(p1.y - mid.y)))
	var out_cells: Array = []
	for rec2: Dictionary in geo:
		var poly: PackedVector2Array = rec2["poly"]
		var pos: Vector2i = rec2["pos"]
		var center := Vector2.ZERO
		for v2: Vector2 in poly:
			center += v2
		center /= float(poly.size())
		var rel: Array = []
		for v3: Vector2 in poly:
			var d := v3 - center
			rel.append([snappedf(d.x, 0.0000001), snappedf(d.y, 0.0000001)])
		out_cells.append({
			"x": pos.x, "y": pos.y,
			"center": [snappedf(center.x - min_v.x, 0.0000001), snappedf(center.y - min_v.y, 0.0000001)],
			"poly": rel,
			"hl": [],
			"taper": [false, false],
			"group": _group_of(pos, kind, spec, mid, max_ring),
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
		return true
	var log: Variant = pl.call("build", level)
	return log is Dictionary and bool((log as Dictionary).get("solved", false))


func _load_level(path: String) -> Board:
	var loader: GDScript = load(LEVEL_LOADER_PATH)
	if loader == null:
		return null
	var b: Variant = loader.call("load_level", path)
	return b as Board


func _request_exit(code: int) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_exit_code = code
	_exit_frames = 0
	_exit_pending = true
