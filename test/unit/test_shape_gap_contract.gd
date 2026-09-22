# test_shape_gap_contract.gd —— 形状关卡的「连通视觉」契约（长期门禁）
#
# 规范（2026-09-21）：**同一连通区域内相邻格子之间不得有可见空隙** —— 玩家必须能一眼
# 看出哪些格子是连通的；不同区域之间才允许有间隔。
#
# 判据：对每条**拓扑邻接边**，两格多边形的几何最小距离（缝宽）≤ 该关格宽 unit 的 0.5%
# （屏幕上一格约 60px ⇒ 0.3px，亚像素、肉眼不可见）。用相对口径（gap/unit）是为了让
# unit=1 的生成关卡与 unit≈78.8 的原版复刻关能横向比较。
#
# 为什么需要它：2026-09-21 实测发现两类真实缺陷——
#   ① 线性变换只作用于「顶点偏移」而非盘面坐标 ⇒ 格子被单独压扁、裂出大小不均的缝
#      （大素巢 / 扁巢 / 宽砖 全中招）；
#   ② 逐格旋转的涡流 ⇒ 每格朝向不同、共享边错开 ⇒ 缝。
# 两者已修（变换改为盘面坐标、涡流改为坐标场扭转），本测试把它们钉死，防回归。
#
# 例外：`custom_shapes.unit` 明显小于格子尺寸时（不是同一坐标口径）本测试会失真——
# 当前所有形状关 unit 与格宽同量级，无需例外；将来若引入另类口径，在此显式说明。
extends GutTest

const RATIO := 0.005
const LEVEL_DIR := "res://levels"


func test_adjacent_cells_have_no_visible_gap() -> void:
	var checked := 0
	var offenders: Array[String] = []
	var dir := DirAccess.open(LEVEL_DIR)
	if dir == null:
		fail_test("levels 目录不可读")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var d := _read_json(LEVEL_DIR + "/" + fname)
			if _has_shape_data(d):
				checked += 1
				var unit := float((d["custom_shapes"] as Dictionary).get("unit", 1.0))
				if unit <= 0.0:
					unit = 1.0
				var worst := _worst_gap(d)
				if worst > unit * RATIO:
					offenders.append("%s（最大缝 %.3f%% 格宽）" % [fname, 100.0 * worst / unit])
		fname = dir.get_next()
	dir.list_dir_end()
	assert_gt(checked, 0, "应至少检查到一个带自定义几何的形状关卡")
	assert_eq(offenders.size(), 0,
			"以下关卡的相邻格之间有可见空隙（违反连通视觉规范）：%s" % str(offenders))


func test_geometry_helpers_are_sane() -> void:
	# 自检：单位正方形的相邻两格（贴合）→ 缝 0；拉开 0.1 → 缝 0.1
	var a := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var b := PackedVector2Array([Vector2(1, 0), Vector2(2, 0), Vector2(2, 1), Vector2(1, 1)])
	assert_almost_eq(_poly_gap(a, b), 0.0, 0.000001, "贴合两格缝应为 0")
	var c := PackedVector2Array([Vector2(1.1, 0), Vector2(2.1, 0), Vector2(2.1, 1), Vector2(1.1, 1)])
	assert_almost_eq(_poly_gap(a, c), 0.1, 0.0001, "拉开 0.1 的两格缝应为 0.1")


# ---- 工具 ----

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _has_shape_data(d: Dictionary) -> bool:
	if not (d.get("custom_shapes") is Dictionary):
		return false
	if not (d.get("topology") is Dictionary):
		return false
	var cells: Variant = (d["custom_shapes"] as Dictionary).get("cells", null)
	var adj: Variant = (d["topology"] as Dictionary).get("adjacency", null)
	return (cells is Array) and not (cells as Array).is_empty() \
			and (adj is Array) and not (adj as Array).is_empty()


## 全盘最大缝（世界单位）。
func _worst_gap(d: Dictionary) -> float:
	var polys := {}
	for c: Variant in (d["custom_shapes"] as Dictionary)["cells"]:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c
		var ctr: Array = cd["center"]
		var pts := PackedVector2Array()
		for v: Variant in cd["poly"]:
			pts.append(Vector2(float(ctr[0]) + float(v[0]), float(ctr[1]) + float(v[1])))
		polys[Vector2i(int(cd["x"]), int(cd["y"]))] = pts
	var worst := 0.0
	for e: Variant in (d["topology"] as Dictionary)["adjacency"]:
		var ed: Dictionary = e
		var ka := Vector2i(int(ed["a"]["x"]), int(ed["a"]["y"]))
		var kb := Vector2i(int(ed["b"]["x"]), int(ed["b"]["y"]))
		if polys.has(ka) and polys.has(kb):
			worst = maxf(worst, _poly_gap(polys[ka], polys[kb]))
	return worst


## 两多边形的最小距离（相交/包含 → 0）。
func _poly_gap(a: PackedVector2Array, b: PackedVector2Array) -> float:
	for p: Vector2 in a:
		if _in_poly(p, b):
			return 0.0
	for p: Vector2 in b:
		if _in_poly(p, a):
			return 0.0
	var best := INF
	for i in a.size():
		var a1: Vector2 = a[i]
		var a2: Vector2 = a[(i + 1) % a.size()]
		for j in b.size():
			best = minf(best, _seg_seg_dist(a1, a2, b[j], b[(j + 1) % b.size()]))
	return best


func _seg_seg_dist(p1: Vector2, p2: Vector2, p3: Vector2, p4: Vector2) -> float:
	var d1 := _cross(p3, p4, p1)
	var d2 := _cross(p3, p4, p2)
	var d3 := _cross(p1, p2, p3)
	var d4 := _cross(p1, p2, p4)
	if ((d1 > 0.0) != (d2 > 0.0)) and ((d3 > 0.0) != (d4 > 0.0)):
		return 0.0
	return minf(minf(_pt_seg(p1, p3, p4), _pt_seg(p2, p3, p4)),
			minf(_pt_seg(p3, p1, p2), _pt_seg(p4, p1, p2)))


func _cross(o: Vector2, a: Vector2, b: Vector2) -> float:
	return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)


func _pt_seg(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 <= 1e-12:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _in_poly(p: Vector2, pts: PackedVector2Array) -> bool:
	var inside := false
	var n := pts.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = pts[i]
		var pj: Vector2 = pts[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var den := (pj.y - pi.y) if not is_equal_approx(pj.y, pi.y) else 0.000000001
			if p.x < (pj.x - pi.x) * (p.y - pi.y) / den + pi.x:
				inside = not inside
		j = i
	return inside
