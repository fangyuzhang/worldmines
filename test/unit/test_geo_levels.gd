# test_geo_levels.gd —— 四族「铺装」关卡的落盘门禁（2026-09-22）
#
# 与 test_shape_tilings.gd 的分工：那个管**生成器函数**，这个管**产出的关卡文件**
#（geometry 落盘后是否仍与 topology 一致、能否被 LevelLoader 载入、能否进档位）。
# 核心一条与等轴菱面同源：**落盘几何的每条拓扑边，两端多边形必须真的共边** ——
# 渲染只读 custom_shapes、邻接只读 topology，两者一旦脱节玩家就会看到错的连接。
extends GutTest

const LEVEL_DIR := "res://levels"
const EPS := 0.001     # 落盘顶点按 0.0001 量化，且格心/偏移各量化一次 → 误差可达 ~2e-4

## 族 → 期望的形状指纹：{顶点数: 最少出现次数}
const FAMILIES := {
	"tri": {"style": "tri_grid", "faces": {3: 1}, "max_deg": 3},
	"trihex": {"style": "trihex", "faces": {3: 1, 6: 1}, "max_deg": 6},
	"t31212": {"style": "t31212", "faces": {3: 1, 12: 1}, "max_deg": 12},
	"ring": {"style": "ring", "faces": {}, "max_deg": 6},
}
const VARIANT_FILES: Array[String] = [
	"vg_tri_s1.json", "vg_trihex_s2.json", "vg_trihex_dt.json",
	"vg_t31212_s3.json", "vg_ring_s5.json", "vg_ring_z2.json", "vg_ring_dt.json",
]


func test_every_family_level_loads_as_adjacency_grid() -> void:
	for f in _family_files():
		var board := _load(f)
		assert_not_null(board, "%s 应能载入成 Board" % f)
		if board == null:
			continue
		assert_true(board.grid is AdjacencyGrid, "%s 应是异形棋盘" % f)
		assert_eq(board.grid.style, _style_of(f), "%s 的 style 应落盘为 %s" % [f, _style_of(f)])


func test_shape_fingerprints_survive_to_disk() -> void:
	## 形状即族的身份证：落盘后每族的「面型组合」必须还在（三角网格只有三角；
	## 3.6.3.6 是三角+六边；3.12.12 是三角+十二边）。
	for f in _family_files():
		var want: Dictionary = FAMILIES[_family_of(f)]["faces"]
		if want.is_empty():
			continue
		var hist := _vertex_count_histogram(f)
		for n in want:
			assert_gte(int(hist.get(n, 0)), int(want[n]),
					"%s：应至少 %d 个 %d 顶点的面（实际分布 %s）" % [f, int(want[n]), int(n), str(hist)])


func test_degree_never_exceeds_the_family_ceiling() -> void:
	## 各族的度数上限是几何决定的（三角 3 / 六边 6 / 十二边 12），落盘后不该被放大 ——
	## 若有人把邻接表改成「共顶点」（更密口径），这条会立刻红。
	for f in _family_files():
		var ceil_deg := int(FAMILIES[_family_of(f)]["max_deg"])
		var worst := _max_degree(f)
		assert_lte(worst, ceil_deg, "%s：实测最大度 %d 超过该族几何上限 %d" % [f, worst, ceil_deg])


func test_every_topology_edge_is_a_real_shared_edge_in_saved_geometry() -> void:
	for f in _family_files():
		var d := _json(f)
		var polys := _polys(d)
		var adj: Array = (d["topology"] as Dictionary)["adjacency"]
		assert_gt(adj.size(), 0, "%s 应有邻接边" % f)
		for e: Dictionary in adj:
			var ka := "%d,%d" % [int(e["a"]["x"]), int(e["a"]["y"])]
			var kb := "%d,%d" % [int(e["b"]["x"]), int(e["b"]["y"])]
			assert_true(polys.has(ka) and polys.has(kb), "%s：边 %s-%s 两端应在盘内" % [f, ka, kb])
			assert_true(_share_edge(polys[ka], polys[kb]),
					"%s：边 %s-%s 的两格不共边（渲染几何与邻接表脱节）" % [f, ka, kb])


func test_every_cell_carries_a_group_and_all_three_bands_are_used() -> void:
	for f in _family_files():
		var d := _json(f)
		var tally := {}
		for c: Dictionary in (d["custom_shapes"] as Dictionary)["cells"]:
			var g := str(c.get("group", ""))
			assert_ne(g, "", "%s：每格都应有圈层分组（分色计数器的数据源）" % f)
			tally[g] = int(tally.get(g, 0)) + 1
		assert_gte(tally.size(), 2, "%s：圈层分组应至少用到 2 带（实际 %s）" % [f, str(tally)])
		# 每个用到的分组都必须在 palette.groups 里有颜色，否则计数器会拿到透明色
		var groups: Dictionary = (d["palette"] as Dictionary).get("groups", {})
		for g2 in tally:
			assert_true(groups.has(g2), "%s：分组 %s 缺配色" % [f, g2])


func test_mines_and_difficulty_are_consistent() -> void:
	for f in _family_files():
		var d := _json(f)
		var mines: Array = d["mines"]
		assert_eq(mines.size(), int(d["total_mines"]), "%s：mines 数组应与 total_mines 一致" % f)
		var board := _load(f)
		assert_not_null(board, "%s 应能载入" % f)
		if board != null:
			for m: Dictionary in mines:
				var pos := Vector2i(int(m["c"]), int(m["r"]))
				assert_not_null(board.grid.get_cell(pos), "%s：雷 %s 应在盘内" % [f, str(pos)])
		var prof: Dictionary = d.get("difficulty_profile", {})
		assert_false(prof.is_empty(), "%s 应带 difficulty_profile" % f)
		assert_gte(int(prof.get("max_complexity", -1)), 2,
				"%s：峰值应 >= 2（否则进不了任何档位）" % f)


func test_variant_levels_really_declare_their_global_rule() -> void:
	## 「异形 × 变体」的价值全在 global_rules 上 —— 若那栏空了，产出就退化成普通 classic 关。
	for f in VARIANT_FILES:
		var d := _json(f)
		var gr: Array = d.get("global_rules", [])
		assert_gt(gr.size(), 0, "%s：应带至少一条全局规则（否则与纯 classic 形状关无区别）" % f)
		assert_eq(str(d["clue_rule"]), "classic",
				"%s：异形拓扑上线索恒为 classic 邻域计数（方向型变体不适用）" % f)


# ==================== 工具 ====================

func _family_files() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(LEVEL_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json") and _family_of(fname) != "":
			out.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## 文件名 → 族（"" = 不属于本文件覆盖的族）。vg_ 前缀是「异形 × 变体」，族从第二段取。
func _family_of(fname: String) -> String:
	var base := fname.get_basename()
	var parts := base.split("_")
	var head := str(parts[0])
	if head == "vg" and parts.size() >= 2:
		head = str(parts[1])
	if FAMILIES.has(head):
		return head
	return ""


func _style_of(fname: String) -> String:
	return str(FAMILIES[_family_of(fname)]["style"])


func _json(fname: String) -> Dictionary:
	var p := LEVEL_DIR + "/" + fname
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _load(fname: String) -> Board:
	var p := LEVEL_DIR + "/" + fname
	if not FileAccess.file_exists(p):
		return null
	var b: Variant = LevelLoader.load_level(p)
	return b as Board


func _polys(d: Dictionary) -> Dictionary:
	var out := {}
	for c: Dictionary in (d["custom_shapes"] as Dictionary)["cells"]:
		var ctr: Array = c["center"]
		var pts := PackedVector2Array()
		for v: Variant in c["poly"]:
			pts.append(Vector2(float(ctr[0]) + float(v[0]), float(ctr[1]) + float(v[1])))
		out["%d,%d" % [int(c["x"]), int(c["y"])]] = pts
	return out


func _vertex_count_histogram(fname: String) -> Dictionary:
	var hist := {}
	for c: Dictionary in (_json(fname)["custom_shapes"] as Dictionary)["cells"]:
		var n: int = (c["poly"] as Array).size()
		hist[n] = int(hist.get(n, 0)) + 1
	return hist


func _max_degree(fname: String) -> int:
	var deg := {}
	for e: Dictionary in (_json(fname)["topology"] as Dictionary)["adjacency"]:
		var ka := "%d,%d" % [int(e["a"]["x"]), int(e["a"]["y"])]
		var kb := "%d,%d" % [int(e["b"]["x"]), int(e["b"]["y"])]
		deg[ka] = int(deg.get(ka, 0)) + 1
		deg[kb] = int(deg.get(kb, 0)) + 1
	var m := 0
	for k in deg:
		m = maxi(m, int(deg[k]))
	return m


func _share_edge(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	if a.size() < 3 or b.size() < 3:
		return false
	for i in a.size():
		for j in b.size():
			if _same(a[i], b[j]) and _same(a[(i + 1) % a.size()], b[(j + 1) % b.size()]):
				return true
			if _same(a[i], b[(j + 1) % b.size()]) and _same(a[(i + 1) % a.size()], b[j]):
				return true
	return false


func _same(p: Vector2, q: Vector2) -> bool:
	return absf(p.x - q.x) < EPS and absf(p.y - q.y) < EPS
