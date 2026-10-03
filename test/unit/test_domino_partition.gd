# test_domino_partition.gd —— 骨牌「划分」算法（缺口 #9）：1×2 / 2×1 完整覆盖 + 校验。
#
# 钉住的不变量：
#   ① 矩形区域 ⇒ ok 且**逐格计数 == 1**（覆盖完整性，不只看块数）；每块都是正交相邻的 1×2/2×1；
#   ② 同输入跑两次 ⇒ blocks **逐位相同**（确定性，不依赖全局 randi）；
#   ③ 奇数面积 / 有洞且割裂的区域 ⇒ ok=false + reason 非空（且点名问题格）；
#   ④ verify_partition 对「人为重叠 / 遗漏」能**指名哪个格**出问题；
#   ⑤ 洞格绝不能出现在任何块里（判界问网格，禁用包围盒）；
#   ⑥ place / validate 与 partition / verify 同口径：对角 (0,0)-(1,1) 不再被当骨牌（place 拒、validate block）。
#
# 用 preload 而非全局类名，避免新增脚本的全局类缓存尚未刷新时测试无法解析。
extends GutTest

const DM := preload("res://core/domino_model.gd")


func _rect(rows: int, cols: int) -> RectGrid:
	var g := RectGrid.new()
	g.setup(rows, cols)
	return g


## 逐格计数：pos -> 被几块覆盖。用于验证「恰好覆盖」（不只看块数）。
func _cell_counts(blocks: Array) -> Dictionary:
	var counts := {}
	for b in blocks:
		for p: Vector2i in (b as Array):
			counts[p] = int(counts.get(p, 0)) + 1
	return counts


## 4×4 盘挖掉中央 2×2（洞格）⇒ 12 格环形盘（真实异形盘：洞格在网格里根本不存在）。
func _holed_ring_grid() -> AdjacencyGrid:
	var hole := {Vector2i(1, 1): true, Vector2i(2, 1): true, Vector2i(1, 2): true, Vector2i(2, 2): true}
	var positions: Array = []
	var adjacency: Array = []
	for y in 4:
		for x in 4:
			var p := Vector2i(x, y)
			if hole.has(p):
				continue
			positions.append({"x": x, "y": y})
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var q := p + d
				if q.x < 4 and q.y < 4 and not hole.has(q):
					adjacency.append({"a": {"x": p.x, "y": p.y}, "b": {"x": q.x, "y": q.y}})
	var g := AdjacencyGrid.new()
	g.setup_from_topo({"positions": positions, "adjacency": adjacency})
	return g


# ==================== ① 矩形区域：逐格恰好覆盖一次 ====================

func test_partition_rect_region_full_cover_each_cell_once() -> void:
	var model := DM.new()
	var g := _rect(3, 4)
	var region := g.all_positions()
	var r := model.partition(g, region)
	assert_true(bool(r["ok"]), "矩形区域应可划分：%s" % str(r["reason"]))
	var blocks: Array = r["blocks"]
	assert_eq(blocks.size(), 6, "12 格应划成 6 块：%s" % str(r["reason"]))
	var counts := _cell_counts(blocks)
	assert_eq(counts.size(), 12, "块覆盖的格数应等于区域格数（不多不少）")
	var bad := 0
	for p: Vector2i in region:
		if int(counts.get(p, 0)) != 1:
			bad += 1
	assert_eq(bad, 0, "区域内每格必须恰好属于 1 块（不重叠、不遗漏）：%s" % str(counts))
	# 每块都必须是正交相邻的 1×2/2×1（对角不算）
	var diagonal := 0
	for b in blocks:
		var pair: Array = b
		var d: Vector2i = (pair[1] as Vector2i) - (pair[0] as Vector2i)
		if absi(d.x) + absi(d.y) != 1:
			diagonal += 1
	assert_eq(diagonal, 0, "每块必须恰好是 1×2/2×1（对角不算）：%s" % str(blocks))


# ==================== ② 确定性：同输入逐位相同 ====================

func test_partition_is_deterministic_bit_for_bit() -> void:
	var model := DM.new()
	var g := _rect(4, 4)
	var region := g.all_positions()
	var r1 := model.partition(g, region)
	var r2 := model.partition(g, region)
	assert_true(bool(r1["ok"]) and bool(r2["ok"]), "4×4 应可划分：%s / %s" % [str(r1["reason"]), str(r2["reason"])])
	assert_eq(str(r1["blocks"]), str(r2["blocks"]), "同输入两次必须逐位相同（不依赖全局 randi 状态）")
	# 换一个「有多种铺法」的环形盘再验一次
	var g2 := _holed_ring_grid()
	var region2 := g2.all_positions()
	var s1 := model.partition(g2, region2)
	var s2 := model.partition(g2, region2)
	assert_true(bool(s1["ok"]), "环形盘应可划分：%s" % str(s1["reason"]))
	assert_eq(str(s1["blocks"]), str(s2["blocks"]), "环形盘同输入也必须逐位相同")


# ==================== ③ 奇数面积 / 有洞割裂 ⇒ ok=false + reason ====================

func test_partition_odd_area_and_holed_split_fail_with_reason() -> void:
	var model := DM.new()
	# (a) 奇数面积：3×3 = 9 格
	var g := _rect(3, 3)
	var ra := model.partition(g, g.all_positions())
	assert_false(bool(ra["ok"]), "9 格（奇数）不可划分")
	assert_eq(str(ra["code"]), "odd_area", "应报 odd_area：%s" % str(ra))
	assert_true(str(ra["reason"]).find("奇数") != -1, "理由要说明奇数面积：%s" % str(ra["reason"]))
	assert_eq((ra["blocks"] as Array).size(), 0, "失败时不得给出半截划分")
	# (b) 有洞且把区域割裂成两块（各 5 格、皆奇数）⇒ 不可铺
	var g2 := _rect(3, 5)
	var region_b: Array = []
	for y in [0, 2]:          # 第 1 行整行是洞 ⇒ 上下各一条 5 格路径
		for x in 5:
			region_b.append(Vector2i(x, y))
	var rb := model.partition(g2, region_b)
	assert_false(bool(rb["ok"]), "洞格割裂后的区域不可划分：%s" % str(rb))
	assert_eq(str(rb["code"]), "no_tiling", "应报 no_tiling：%s" % str(rb))
	assert_true(str(rb["reason"]).length() > 0, "失败必须有可读理由")
	assert_true(str(rb["reason"]).find("(") != -1, "理由要点名问题格：%s" % str(rb["reason"]))
	assert_eq((rb["blocks"] as Array).size(), 0, "失败时不得给出半截划分")


# ==================== ④ verify_partition：重叠 / 遗漏逐格点名 ====================

func test_verify_partition_names_overlap_and_missing_cells() -> void:
	var model := DM.new()
	var g := _rect(2, 3)
	var region := g.all_positions()
	var good: Array = [
		[Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(1, 0), Vector2i(1, 1)],
		[Vector2i(2, 0), Vector2i(2, 1)],
	]
	var vg := model.verify_partition(g, region, good)
	assert_true(bool(vg["ok"]), "合法划分应放行：%s" % str(vg["reason"]))
	assert_eq((vg["errors"] as Array).size(), 0, "合法划分不应有任何错误")

	# 人为重叠 + 遗漏 + 非相邻块：第三块 (0,0)-(2,0) 不相邻
	var bad: Array = [
		[Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(1, 0), Vector2i(1, 1)],
		[Vector2i(0, 0), Vector2i(2, 0)],
	]
	var vb := model.verify_partition(g, region, bad)
	assert_false(bool(vb["ok"]), "重叠/遗漏必须报错")
	var ov: Array = vb["overlaps"]
	assert_eq(ov.size(), 1, "应恰有 1 个重叠格：%s" % str(ov))
	assert_eq((ov[0] as Dictionary)["pos"], Vector2i(0, 0), "重叠格应是 (0,0)")
	assert_eq(int((ov[0] as Dictionary)["count"]), 2, "(0,0) 应被 2 块占用")
	var unc: Array = vb["uncovered"]
	assert_eq(unc.size(), 1, "应恰有 1 个遗漏格：%s" % str(unc))
	assert_eq(unc[0], Vector2i(2, 1), "遗漏格应是 (2,1)")
	var na: Array = vb["not_adjacent"]
	assert_true(na.has(Vector2i(0, 0)) and na.has(Vector2i(2, 0)), "非相邻块的两格都应被点名：%s" % str(na))
	assert_true(str(vb["reason"]).find("(0,0)") != -1 or str(vb["reason"]).find("(2,0)") != -1,
		"首要理由要点名问题格：%s" % str(vb["reason"]))

	# 纯遗漏：删掉一块
	var miss: Array = [
		[Vector2i(0, 0), Vector2i(0, 1)],
		[Vector2i(1, 0), Vector2i(1, 1)],
	]
	var vm := model.verify_partition(g, region, miss)
	assert_false(bool(vm["ok"]), "遗漏必须报错")
	var unc2: Array = vm["uncovered"]
	assert_eq(unc2.size(), 2, "应指出 2 个未覆盖格：%s" % str(unc2))
	assert_true(unc2.has(Vector2i(2, 0)) and unc2.has(Vector2i(2, 1)), "未覆盖格应是 (2,0)/(2,1)：%s" % str(unc2))
	assert_true(str(vm["reason"]).find("(2,0)") != -1 or str(vm["reason"]).find("(2,1)") != -1,
		"理由要点名未覆盖格：%s" % str(vm["reason"]))


# ==================== ⑤ 洞格绝不进块；判界问网格 ====================

func test_partition_holed_board_excludes_hole_cells() -> void:
	var model := DM.new()
	var g := _holed_ring_grid()
	var holes := [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2)]
	var region := g.all_positions()
	assert_eq(region.size(), 12, "4×4 挖掉中央 2×2 应剩 12 格")
	var r := model.partition(g, region)
	assert_true(bool(r["ok"]), "环形盘应可划分：%s" % str(r["reason"]))
	var blocks: Array = r["blocks"]
	var counts := _cell_counts(blocks)
	assert_eq(blocks.size(), 6, "12 格应划成 6 块")
	for b in blocks:
		for p: Vector2i in (b as Array):
			assert_false(holes.has(p), "洞格绝不能出现在任何块里：%s" % str(b))
			assert_true(g.in_board(p), "块里的格必须在盘内（判界问网格，禁用包围盒）")
	for p: Vector2i in region:
		assert_eq(int(counts.get(p, 0)), 1, "盘内每格恰好属于 1 块：%s" % str(p))
	# 区域里塞进一个洞格 ⇒ 明确拒绝（绝不静默按包围盒铺过去）
	var with_hole: Array = []
	with_hole.append_array(region)
	with_hole.append(Vector2i(1, 1))
	var r2 := model.partition(g, with_hole)
	assert_false(bool(r2["ok"]), "区域含洞格必须拒绝")
	assert_eq(str(r2["code"]), "region_off_board", "应报 region_off_board：%s" % str(r2))
	assert_true(str(r2["reason"]).find("(1,1)") != -1, "理由要点名洞格 (1,1)：%s" % str(r2["reason"]))


# ==================== ⑥ place / validate 与 partition 同口径：对角不算骨牌 ====================

func test_place_and_validate_reject_diagonal_unified_with_partition() -> void:
	var model := DM.new()
	var g := _rect(3, 3)
	# 对角 (0,0)-(1,1) 不再被 place 接受
	var r := model.place(Vector2i(0, 0), Vector2i(1, 1), {"grid": g})
	assert_false(bool(r["ok"]), "对角不再是合法骨牌：%s" % str(r))
	assert_eq(str(r["code"]), "not_adjacent", "应报 not_adjacent：%s" % str(r))
	assert_eq(model.count(), 0, "被拒不得有副作用")
	# 正交 1×2 仍放行（同一模型不出现两套相邻口径）
	assert_true(bool(model.place(Vector2i(0, 0), Vector2i(1, 0), {"grid": g})["ok"]), "正交 1×2 应放行")
	# 脏存档里的对角骨牌：validate 明确 block（与 place 同口径）
	var dirty := DM.from_dict({"version": DM.VERSION, "dominoes": [{"id": 1, "cells": [[0, 0], [1, 1]]}]})
	var v := dirty.validate(g)
	assert_false(bool(v["ok"]), "脏存档里的对角骨牌必须 block：%s" % str(v["issues"]))
	var codes := {}
	for it in v["issues"]:
		codes[str((it as Dictionary)["code"])] = true
	assert_true(codes.has("not_adjacent"), "必须报 not_adjacent：%s" % str(v["issues"]))
