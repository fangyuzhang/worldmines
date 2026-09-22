# test_iso_cube_levels.gd —— 等轴菱面关卡的落盘门禁（2026-09-22）
#
# 与 test_shape_levels.gd 同角色：钉住「产出的关卡文件」而不是「生成器函数」。
# 本族特有的四条硬约束（都是「几何与数据必须一致」类）：
#   ① 每格都是单位 60° 菱形（四边 1、内角 60/120 交替）；
#   ② 三个朝向（顶/右/左）数量严格 1:1:1，且每组格数 = 存活方块数；
#   ③ topology 的每条边，落盘的 custom_shapes 几何里两格**真的共边** —— 这条是运行时
#      所依赖的东西（渲染按多边形画、邻接按表算），两者一旦脱节玩家就会看到错的连接；
#   ④ 三面配色是同一色相的三档明度（顶最亮），这是立体错觉的观感来源，不该被改平。
extends GutTest

const LEVEL_DIR := "res://levels"
const ISO_FILES: Array[String] = [
	"iso_01.json", "iso_02.json", "iso_03.json", "iso_04.json", "iso_05.json",
]
const FACE_ORDER: Array[String] = ["顶面", "右面", "左面"]
## 落盘几何的容差。为什么不是 1e-6：生成器把 **格心与顶点偏移各独立量化一次**
## （snappedf(..., 0.0001)，见 gen_iso_cubes_levels._custom_shapes），两段误差
## 叠加后绝对值可达 ~2e-4（边长因此是 0.99998 这个量级）。
## 取 1e-3：比量化误差大一个量级（够宽松），又远小于缝隙契约的 5e-3、
## 更远小于任何**结构性**错误（接错邻格是 0.4~0.8 单位的量级）——
## 所以本文件照样能抓住「渲染几何与邻接表脱节」这类真问题。
const EPS := 0.001


func test_all_iso_levels_load_as_adjacency_grids() -> void:
	for name in ISO_FILES:
		var board := _load(name)
		assert_not_null(board, "%s 应能载入成 Board" % name)
		if board == null:
			continue
		assert_true(board.grid is AdjacencyGrid, "%s 应是异形棋盘" % name)
		assert_eq(board.grid.style, "iso_cubes", "%s 的 style 应保持 iso_cubes" % name)


func test_cell_count_is_three_per_surviving_cube() -> void:
	for name in ISO_FILES:
		var d := _json(name)
		var cells: int = (d["topology"]["positions"] as Array).size()
		var p: Dictionary = d["topology"]["params"]
		var cols := int(p["cols"])
		var rows := int(p["rows"])
		var removed := (p["holes"] as Array).size()
		assert_eq(cells, (cols * rows - removed) * 3,
				"%s：格数应为「存活方块 × 3」（%d×%d - %d 洞）" % [name, cols, rows, removed])


func test_every_cell_is_a_unit_sixty_degree_rhombus() -> void:
	for name in ISO_FILES:
		var polys := _polys(name)
		for key: String in polys:
			var poly: PackedVector2Array = polys[key]
			assert_eq(poly.size(), 4, "%s/%s 应是四边形（菱形）" % [name, key])
			for i in 4:
				assert_almost_eq(poly[i].distance_to(poly[(i + 1) % 4]), 1.0, EPS,
						"%s/%s 边长应为 1" % [name, key])
			var angs: Array[float] = []
			for i in 4:
				var e0 := poly[(i + 1) % 4] - poly[i]
				var e1 := poly[(i + 2) % 4] - poly[(i + 1) % 4]
				angs.append(rad_to_deg(absf(e0.angle_to(e1))))
			angs.sort()
			assert_almost_eq(angs[0], 60.0, 0.01, "%s/%s 锐角应为 60°" % [name, key])


func test_three_orientations_are_exactly_equal_in_count() -> void:
	for name in ISO_FILES:
		var d := _json(name)
		var tally := {FACE_ORDER[0]: 0, FACE_ORDER[1]: 0, FACE_ORDER[2]: 0}
		for c: Dictionary in (d["custom_shapes"] as Dictionary)["cells"]:
			var g := str(c.get("group", ""))
			assert_true(tally.has(g), "%s：分组名 %s 不在三面名单里" % [name, g])
			tally[g] += 1
		assert_eq(tally[FACE_ORDER[0]], tally[FACE_ORDER[1]], "%s：顶/右面数应相等" % name)
		assert_eq(tally[FACE_ORDER[1]], tally[FACE_ORDER[2]], "%s：右/左面数应相等" % name)


func test_every_topology_edge_is_a_real_shared_edge_in_the_saved_geometry() -> void:
	## ★ 运行时同时依赖两份数据：渲染读 custom_shapes 的多边形，邻接读 topology。
	## 这份测试按**落盘内容**重算「共边」，确保两者讲的是同一件事。
	for name in ISO_FILES:
		var d := _json(name)
		var polys := _polys(name)
		var adj: Array = d["topology"]["adjacency"]
		assert_gt(adj.size(), 0, "%s 应有邻接边" % name)
		for e: Dictionary in adj:
			var ka := "%d,%d" % [int(e["a"]["x"]), int(e["a"]["y"])]
			var kb := "%d,%d" % [int(e["b"]["x"]), int(e["b"]["y"])]
			assert_true(polys.has(ka) and polys.has(kb), "%s：边 %s-%s 两端应在盘内" % [name, ka, kb])
			assert_true(_share_edge(polys[ka], polys[kb]),
					"%s：边 %s-%s 的两格不共边（渲染几何与邻接表脱节）" % [name, ka, kb])


func test_face_colors_are_three_brightness_steps_of_one_hue() -> void:
	## 三面同色相 + 三档明度（顶最亮 → 右中 → 左最暗）= 立方体受光。
	for name in ISO_FILES:
		var groups: Dictionary = (_json(name)["palette"] as Dictionary)["groups"]
		assert_eq(groups.size(), 3, "%s 应恰有三面配色" % name)
		var cols: Array[Color] = []
		for g in FACE_ORDER:
			assert_true(groups.has(g), "%s 缺分组色 %s" % [name, g])
			cols.append(PaletteColor.parse(groups[g]))
		# 同一色相：容差 0.006（≈2°）。为什么不是更松：三面必须是**等比明度步**
		# （同一个 RGB 乘系数），否则 8bit 量化会让算出的色相漂到 6° 量级，
		# 肉眼就变成「三个不同的颜色」而不是「一个颜色的三档光」。
		for i in range(1, 3):
			assert_almost_eq(cols[i].h, cols[0].h, 0.006, "%s：三面应同色相（等比明度步）" % name)
		# 饱和度也应基本一致（等比缩放不改变饱和度）
		for i in range(1, 3):
			assert_almost_eq(cols[i].s, cols[0].s, 0.02, "%s：三面饱和度应一致" % name)
		# 明度严格递减：顶 > 右 > 左
		assert_gt(cols[0].v, cols[1].v, "%s：顶面应比右面亮" % name)
		assert_gt(cols[1].v, cols[2].v, "%s：右面应比左面亮" % name)


func test_mines_and_difficulty_profile_are_consistent() -> void:
	for name in ISO_FILES:
		var d := _json(name)
		var mines: Array = d["mines"]
		assert_eq(mines.size(), int(d["total_mines"]), "%s：mines 数组应与 total_mines 一致" % name)
		var board := _load(name)
		assert_not_null(board, "%s 应能载入" % name)
		if board == null:
			continue
		assert_eq(board.total_mines, int(d["total_mines"]), "%s：Board 雷数应与文件一致" % name)
		# 每个雷坐标都必须在盘内
		for m: Dictionary in mines:
			var pos := Vector2i(int(m["c"]), int(m["r"]))
			assert_not_null(board.grid.get_cell(pos), "%s：雷 %s 应在盘内" % [name, str(pos)])
		# 难度画像必须存在且够进档（peak >= 2 = 普通档下限）
		var prof: Dictionary = d.get("difficulty_profile", {})
		assert_false(prof.is_empty(), "%s 应带 difficulty_profile" % name)
		assert_gte(int(prof.get("max_complexity", -1)), 2,
				"%s：峰值应 >= 2（否则进不了任何档位）" % name)


# ---- 工具 ----

func _path(name: String) -> String:
	return LEVEL_DIR + "/" + name


func _json(name: String) -> Dictionary:
	if not FileAccess.file_exists(_path(name)):
		return {}
	var f := FileAccess.open(_path(name), FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _load(name: String) -> Board:
	if not FileAccess.file_exists(_path(name)):
		return null
	var b: Variant = LevelLoader.load_level(_path(name))
	return b as Board


## 落盘几何 → { "x,y": 多边形绝对顶点 }（口径与 board_view._ensure_custom_cache 一致）。
func _polys(name: String) -> Dictionary:
	var d := _json(name)
	if d.is_empty():
		return {}
	var out := {}
	for c: Dictionary in (d["custom_shapes"] as Dictionary)["cells"]:
		var ctr: Array = c["center"]
		var pts := PackedVector2Array()
		for v: Variant in c["poly"]:
			pts.append(Vector2(float(ctr[0]) + float(v[0]), float(ctr[1]) + float(v[1])))
		out["%d,%d" % [int(c["x"]), int(c["y"])]] = pts
	return out


func _share_edge(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() < 3 or b.size() < 3:
		return false
	for i in a.size():
		var a1: Vector2 = a[i]
		var a2: Vector2 = a[(i + 1) % a.size()]
		for j in b.size():
			var b1: Vector2 = b[j]
			var b2: Vector2 = b[(j + 1) % b.size()]
			if _same(a1, b1) and _same(a2, b2):
				return true
			if _same(a1, b2) and _same(a2, b1):
				return true
	return false


func _same(p: Vector2, q: Vector2) -> bool:
	return absf(p.x - q.x) < EPS and absf(p.y - q.y) < EPS
