# test_shape_levels.gd —— T2 挖洞方格 + T3 蜂窝关卡：存在性 + 契约（端到端产物门禁）
#
# 被测对象 = res://tools/gen_shape_levels.gd 产出的关卡文件：
#   T2 挖洞方格 holed_01..06.json；T3 蜂窝 hex_01..05.json（含偶数尺寸 6/8）。
# 本测试**不生成**（生成是 CLI + CP-SAT 的活），只对产物做黑盒契约断言：
#   文件可载入 / 异形棋盘格数 / 雷数与雷位 / 洞格（盘外格）不在盘内 / revealed 合法 /
#   边数非零且自洽 / 蜂窝度分布指纹（角 3 度、边 4 度、内 6 度）。
# 产物缺失 → pending（附生成命令），绝不用红测试表达「还没生成」。
extends GutTest

const GEN_CMD := "godot --headless --path . -s res://tools/gen_shape_levels.gd"
## 只产蜂窝族（T3）；同上命令等价（同一条族驱动链路）。
const GEN_CMD_HEX := "godot --headless --path . -s res://tools/gen_shape_levels.gd -- hex"

# 期望值来自关卡规格（tools/gen_shape_levels.gd:SPECS）：8×8−4 洞 = 60、8×8−6 洞 = 58、9×9−5 洞 = 76、
# 5×5−1 洞 = 24、6×6−4 洞 = 32、7×7−9 洞 = 40。
const CASES: Array = [
	{
		"file": "holed_01.json", "cells": 60, "mines": 10, "bbox": Vector2i(8, 8),
		"holes": [Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)],
	},
	{
		"file": "holed_02.json", "cells": 58, "mines": 11, "bbox": Vector2i(8, 8),
		"holes": [
			Vector2i(0, 0), Vector2i(7, 0), Vector2i(0, 7), Vector2i(7, 7),
			Vector2i(3, 3), Vector2i(3, 4),
		],
	},
	{
		"file": "holed_03.json", "cells": 76, "mines": 15, "bbox": Vector2i(9, 9),
		"holes": [Vector2i(4, 4), Vector2i(4, 3), Vector2i(4, 5), Vector2i(3, 4), Vector2i(5, 4)],
	},
	# 接线补产（选关页全尺寸入口需要 5/6/7 有内容）：中心单格洞 / 中央 2×2 / 中央 3×3
	{
		"file": "holed_04.json", "cells": 24, "mines": 4, "bbox": Vector2i(5, 5),
		"holes": [Vector2i(2, 2)],
	},
	{
		"file": "holed_05.json", "cells": 32, "mines": 6, "bbox": Vector2i(6, 6),
		"holes": [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)],
	},
	{
		"file": "holed_06.json", "cells": 40, "mines": 8, "bbox": Vector2i(7, 7),
		"holes": [
			Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
			Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3),
			Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4),
		],
	},
]


func _path(case: Dictionary) -> String:
	return "res://levels/%s" % str(case["file"])


## 载入关卡的 Board；文件缺失 → pending（不红）并返回 null。
func _board(case: Dictionary) -> Board:
	var p := _path(case)
	if not FileAccess.file_exists(p):
		pending("缺少 %s —— 先跑：%s" % [p, str(case.get("gen_cmd", GEN_CMD))])
		return null
	var b: Board = LevelLoader.load_level(p)
	assert_not_null(b, "%s 应能被 LevelLoader.load_level 载入" % str(case["file"]))
	return b


## 关卡 JSON 原文（结构字段断言用）。
func _json(case: Dictionary) -> Dictionary:
	var f := FileAccess.open(_path(case), FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


## 无向边数（度数总和 / 2）——与 test_shape_generator.gd:_grid_edge_count 同算法。
func _grid_edge_count(g: GridInterface) -> int:
	var total := 0
	for p in g.all_positions():
		total += g.get_neighbors(p).size()
	return total / 2


# ==================== 存在性 + 拓扑类型 ====================

func test_files_load_as_adjacency_grid() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		assert_true(b.grid is AdjacencyGrid, "%s 应重建异形棋盘（AdjacencyGrid）" % str(case["file"]))
		assert_eq(b.grid.size(), case["bbox"], "%s 包围盒应与规格一致" % str(case["file"]))


func test_cell_count_matches_bbox_minus_holes() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		assert_eq(b.grid.cell_count(), int(case["cells"]),
				"%s 格数 = 满格 − 洞（期望 %d）" % [str(case["file"]), int(case["cells"])])
		assert_ne(b.grid.cell_count(), 0, "%s 不应是空盘" % str(case["file"]))


# ==================== 雷数 / 雷位 ====================

func test_total_mines_matches_mines_array() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		var data := _json(case)
		var mines: Array = data.get("mines", [])
		assert_eq(b.total_mines, int(case["mines"]), "%s total_mines 应等于规格雷数" % str(case["file"]))
		assert_eq(mines.size(), b.total_mines, "%s mines 数组长度应等于 total_mines" % str(case["file"]))
		# 无重复（loader 已校验，此处再独立数一遍，防止文件被手改后蒙混过关）
		var keys := {}
		for m: Dictionary in mines:
			keys[Vector2i(int(m["c"]), int(m["r"]))] = true
		assert_eq(keys.size(), mines.size(), "%s 雷位不得重复" % str(case["file"]))


func test_mines_all_in_board() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		var n := 0
		for m in b.get_mine_positions():
			assert_true(b.grid.in_board(m), "%s 雷位 (%d,%d) 应在盘内" % [str(case["file"]), m.x, m.y])
			n += 1
		assert_eq(n, b.total_mines, "%s 引擎内雷数应与 total_mines 一致" % str(case["file"]))


# ==================== 洞格确实不在盘内 ====================

func test_holes_are_off_board() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		for hole: Vector2i in case["holes"]:
			assert_false(b.grid.in_board(hole), "%s 洞格 (%d,%d) 不应在盘内（in_board==false）" % [
					str(case["file"]), hole.x, hole.y])
			assert_null(b.grid.get_cell(hole), "%s 洞格 (%d,%d) 应无 Cell（get_cell==null）" % [
					str(case["file"]), hole.x, hole.y])


func test_all_positions_excludes_holes_and_fits_bbox() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		var positions := b.grid.all_positions()
		assert_eq(positions.size(), int(case["cells"]), "%s all_positions 应恰为盘内格" % str(case["file"]))
		for p in positions:
			assert_false(case["holes"].has(p), "%s all_positions 不得含洞格 (%d,%d)" % [
					str(case["file"]), p.x, p.y])
			assert_true(p.x >= 0 and p.y >= 0, "%s 坐标应为非负" % str(case["file"]))


# ==================== 初始 revealed 合法性 ====================

func test_revealed_in_board_and_not_mines() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		var data := _json(case)
		var revealed: Array = data.get("revealed", [])
		assert_gt(revealed.size(), 0, "%s 应有初始线索格（否则开局无信息）" % str(case["file"]))
		for rv: Dictionary in revealed:
			var pos := Vector2i(int(rv["c"]), int(rv["r"]))
			assert_true(b.grid.in_board(pos), "%s revealed (%d,%d) 应在盘内" % [
					str(case["file"]), pos.x, pos.y])
			assert_false(b.is_mine(pos), "%s revealed (%d,%d) 不应是雷" % [
					str(case["file"]), pos.x, pos.y])
			var cell := b.grid.get_cell(pos)
			assert_ne(cell.state, Cell.State.HIDDEN, "%s revealed (%d,%d) 加载后应已翻开" % [
					str(case["file"]), pos.x, pos.y])


# ==================== 边数：非零且与落盘拓扑一致 ====================

func test_edges_nonzero_and_match_topology_adjacency() -> void:
	for case: Dictionary in CASES:
		var b := _board(case)
		if b == null:
			continue
		var topo: Dictionary = _json(case).get("topology", {})
		var adjacency: Array = topo.get("adjacency", [])
		var edges := _grid_edge_count(b.grid)
		assert_gt(edges, 0, "%s 不应是零边盘（洞删边不重连，但绝不能删空）" % str(case["file"]))
		assert_eq(adjacency.size(), edges, "%s 落盘拓扑边数应等于棋盘无向边数" % str(case["file"]))
		assert_eq((topo.get("positions", []) as Array).size(), int(case["cells"]),
				"%s 落盘拓扑 positions 应恰为盘内格" % str(case["file"]))


# ==================== T3：蜂窝（六边形盘）====================
#
# 期望值来自 tools/gen_shape_levels.gd:SPECS。deg_hist / edges 写成**字面量**，与生成侧工具里的
# 闭式互为独立核对——公式错的话不会两边一起错：
#   奇数 size=2R+1：格数 3R²+3R+1、边 9R²+3R、度分布 {3:6, 4:6(R−1), 6:3R²−3R+1}
#   偶数 size=2R+2：格数 3R²+5R+2、边 9R²+9R+1、度分布 {3:6, 4:6R−4, 6:3R²−R}（size=6/8 两条）
# 几何：6 个角格 3 度、边格 4 度、其余内格 6 度（偶数盘心是 2×2 四格 ⇒ 中轴两行等长）；
#   无向边 size=5→42、6→55、7→90、8→109、9→156（**不是** 162，见本次报告「遇到的问题」）。
# 包围盒 = 左对齐的 size×size 窗口 ⇒ 四角**并非**全在盘外：(size−1,0)、(0,size−1) 在盘内
#   （偶数同理：size=6 → (5,0)/(0,5)；size=8 → (7,0)/(0,7)）。
const HEX_CASES: Array = [
	{
		"file": "hex_01.json", "gen_cmd": GEN_CMD_HEX, "size": 5, "R": 2, "cells": 19, "mines": 4, "seed": 4004,
		"row_lens": [3, 4, 5, 4, 3],
		"bbox": Vector2i(5, 5), "edges": 42, "deg_hist": "3:6,4:6,6:7",
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1),
			Vector2i(3, 4), Vector2i(4, 4), Vector2i(4, 3)],
		"in_board": [Vector2i(4, 0), Vector2i(0, 4)],
	},
	{
		"file": "hex_02.json", "gen_cmd": GEN_CMD_HEX, "size": 7, "R": 3, "cells": 37, "mines": 8, "seed": 5001,
		"row_lens": [4, 5, 6, 7, 6, 5, 4],
		"bbox": Vector2i(7, 7), "edges": 90, "deg_hist": "3:6,4:12,6:19",
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1),
			Vector2i(0, 2), Vector2i(6, 4), Vector2i(5, 5), Vector2i(6, 5),
			Vector2i(4, 6), Vector2i(5, 6), Vector2i(6, 6)],
		"in_board": [Vector2i(6, 0), Vector2i(0, 6)],
	},
	{
		"file": "hex_03.json", "gen_cmd": GEN_CMD_HEX, "size": 9, "R": 4, "cells": 61, "mines": 14, "seed": 6003,
		"row_lens": [5, 6, 7, 8, 9, 8, 7, 6, 5],
		"bbox": Vector2i(9, 9), "edges": 156, "deg_hist": "3:6,4:18,6:37",
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0),
			Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(0, 2), Vector2i(1, 2),
			Vector2i(0, 3),
			Vector2i(8, 5),
			Vector2i(7, 6), Vector2i(8, 6),
			Vector2i(6, 7), Vector2i(7, 7), Vector2i(8, 7),
			Vector2i(5, 8), Vector2i(6, 8), Vector2i(7, 8), Vector2i(8, 8)],
		"in_board": [Vector2i(8, 0), Vector2i(0, 8)],
	},
	# 接线补产（选关页全尺寸入口需要 6/8 有内容）：偶数尺寸蜂窝（盘心 2×2）
	{
		"file": "hex_04.json", "gen_cmd": GEN_CMD_HEX, "size": 6, "R": 2, "cells": 24, "mines": 5, "seed": 7006,
		"row_lens": [3, 4, 5, 5, 4, 3],
		"bbox": Vector2i(6, 6), "edges": 55, "deg_hist": "3:6,4:8,6:10",
		# 盘外格 = 36−24 = 12
		"off_board": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
			Vector2i(0, 1), Vector2i(1, 1),
			Vector2i(0, 2),
			Vector2i(5, 3),
			Vector2i(4, 4), Vector2i(5, 4),
			Vector2i(3, 5), Vector2i(4, 5), Vector2i(5, 5)],
		"in_board": [Vector2i(5, 0), Vector2i(0, 5)],
	},
	{
		"file": "hex_05.json", "gen_cmd": GEN_CMD_HEX, "size": 8, "R": 3, "cells": 44, "mines": 9, "seed": 7005,
		"row_lens": [4, 5, 6, 7, 7, 6, 5, 4],
		"bbox": Vector2i(8, 8), "edges": 109, "deg_hist": "3:6,4:14,6:24",
		# 盘外格 = 64−44 = 20
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
]


## 度分布 → "3:6,4:6,6:7"（键升序）。用字符串比较避开 Dictionary 比较语义的歧义，
## 失败时也能一眼看出实测 vs 期望的差在哪一档。
func _degree_hist_str(g: GridInterface) -> String:
	var h := {}
	for p in g.all_positions():
		var d := g.get_neighbors(p).size()
		h[d] = int(h.get(d, 0)) + 1
	var keys: Array = h.keys()
	keys.sort()
	var parts: Array[String] = []
	for k in keys:
		parts.append("%d:%d" % [int(k), int(h[k])])
	return ",".join(parts)


func test_hex_files_load_with_expected_size() -> void:
	for case: Dictionary in HEX_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		assert_true(b.grid is AdjacencyGrid, "%s 应重建异形棋盘（AdjacencyGrid）" % f)
		assert_eq(b.grid.cell_count(), int(case["cells"]),
				"%s 格数 = 3R²+3R+1（R=%d，期望 %d）" % [f, int(case["R"]), int(case["cells"])])
		assert_eq(b.grid.size(), case["bbox"], "%s 包围盒应为 size×size 方阵" % f)
		assert_eq(b.total_mines, int(case["mines"]), "%s total_mines 应等于规格雷数" % f)


func test_hex_mines_in_board_and_min_degree_is_3() -> void:
	for case: Dictionary in HEX_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		var mines := b.get_mine_positions()
		assert_eq(mines.size(), int(case["mines"]), "%s 引擎内雷数与规格应一致" % f)
		for m: Vector2i in mines:
			assert_true(b.grid.in_board(m), "%s 雷位 (%d,%d) 应在盘内" % [f, m.x, m.y])
			# 蜂窝不存在「度 < 3」的格（角 3 / 边 4 / 内 6）⇒ 雷所在格的邻格数 ≥ 3
			assert_gte(b.grid.get_neighbors(m).size(), 3,
					"%s 雷位 (%d,%d) 邻格数应 ≥ 3" % [f, m.x, m.y])
		var min_deg := 99
		for p: Vector2i in b.grid.all_positions():
			min_deg = mini(min_deg, b.grid.get_neighbors(p).size())
		assert_eq(min_deg, 3, "%s 蜂窝最小度应为 3（角格），不存在度 < 3 的格" % f)


func test_hex_degree_histogram_and_edge_count() -> void:
	for case: Dictionary in HEX_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		assert_eq(_degree_hist_str(b.grid), str(case["deg_hist"]),
				"%s 度分布（角 3 / 边 4 / 内 6）应与蜂窝几何指纹一致" % f)
		var edges := _grid_edge_count(b.grid)
		assert_eq(edges, int(case["edges"]), "%s 无向边 = 9R²+3R（R=%d）" % [f, int(case["R"])])
		var topo: Dictionary = _json(case).get("topology", {})
		var adjacency: Array = topo.get("adjacency", [])
		assert_eq(adjacency.size(), edges, "%s 落盘拓扑边数应等于棋盘无向边数" % f)
		assert_eq((topo.get("positions", []) as Array).size(), int(case["cells"]),
				"%s 落盘拓扑 positions 应恰为盘内格" % f)


func test_hex_off_board_cells_are_holes() -> void:
	for case: Dictionary in HEX_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		for p: Vector2i in case["off_board"]:
			assert_false(b.grid.in_board(p), "%s 盘外格 (%d,%d) 不应在盘内（in_board==false）" % [f, p.x, p.y])
			assert_null(b.grid.get_cell(p), "%s 盘外格 (%d,%d) 应无 Cell（get_cell==null）" % [f, p.x, p.y])
		# bbox 边角并非全在盘外：窗口左对齐 ⇒ (size−1,0)、(0,size−1) 是盘内格（锁形状取向）
		for p: Vector2i in case["in_board"]:
			assert_true(b.grid.in_board(p), "%s 盘内格 (%d,%d) 应在盘内" % [f, p.x, p.y])
		var off := b.grid.size().x * b.grid.size().y - b.grid.cell_count()
		assert_eq(off, (case["off_board"] as Array).size(),
				"%s 盘外格数应等于 off_board 表长度（bbox 面积 − 盘内格数）" % f)
		for p: Vector2i in b.grid.all_positions():
			assert_true(p.x >= 0 and p.y >= 0, "%s 坐标应为非负（CP-SAT cell 索引从 0 起）" % f)



func test_hex_row_length_fingerprint() -> void:
	# 最强形状指纹：六边形盘逐行格数 = R+1 … 2R+1 … R+1（左右对称、中心行最长）。
	# 比「格数/边数」强得多——窗口取向改变、裁剪式写错、坐标被平移压扁都会被抓到。
	for case: Dictionary in HEX_CASES:
		var b := _board(case)
		if b == null:
			continue
		var s := int(case["size"])
		var counts: Array = []
		for r in s:
			var n := 0
			for p: Vector2i in b.grid.all_positions():
				if p.y == r:
					n += 1
			counts.append(n)
		assert_eq(counts, case["row_lens"],
				"%s 逐行格数应为六边形盘指纹（R+1 … 2R+1 … R+1）" % str(case["file"]))


# ==================== (d) T7 mask 图案关（art_target / art_carpet / art_jelly）====================
#
# 期望值来自 tools/gen_shape_levels.gd:SPECS 的手写 mask（逐字符可复核）与实跑结果：
#   同心靶 41 格 / 9 雷 seed=8002（换 seed 1 次）；分形地毯 64 格 / 13 雷 seed=8106（换 4 次）；
#   小水母 40 格 / 7 雷 seed=8205（换 2 次）。三关同 shape_holed 9×9，seed 段错开防入库去重碰撞。
# row_lens = mask 逐行有格数（图案指纹：形状被改必红灯）；mask 另从**产物 JSON**（topology.params.mask）
# 独立数一遍与其 cells 比对——「cells 与 mask 数一致」的黑盒复核（生成器自校验之外的第三只眼）。
const ART_CASES: Array = [
	{
		"file": "art_target.json", "cells": 152, "mines": 42, "seed": 8003, "bbox": Vector2i(21, 21),
		"row_lens": [3, 6, 4, 11, 8, 7, 8, 8, 7, 9, 11, 9, 7, 8, 8, 7, 8, 11, 4, 6, 2], "edges": 206,
		"holes": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"in_board": [Vector2i(10, 10), Vector2i(9, 0), Vector2i(10, 20)],
	},
	{
		"file": "art_carpet.json", "cells": 296, "mines": 82, "seed": 8103, "bbox": Vector2i(21, 21),
		"row_lens": [21, 14, 21, 15, 10, 15, 21, 14, 21, 12, 8, 12, 9, 6, 9, 12, 8, 12, 21, 14, 21], "edges": 812,
		"holes": [Vector2i(1, 1), Vector2i(4, 1), Vector2i(7, 1)],
		"in_board": [Vector2i(10, 8), Vector2i(0, 0), Vector2i(20, 20)],
	},
	{
		"file": "art_jelly.json", "cells": 148, "mines": 41, "seed": 8208, "bbox": Vector2i(17, 17),
		"row_lens": [9, 13, 15, 17, 17, 17, 13, 9, 4, 2, 4, 8, 3, 4, 4, 5, 4], "edges": 413,
		"holes": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)],
		"in_board": [Vector2i(8, 7), Vector2i(4, 0), Vector2i(14, 16)],
	},
]


func test_art_files_load_as_holed_grid_boards() -> void:
	for case: Dictionary in ART_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		assert_true(b.grid is AdjacencyGrid, "%s 应重建异形棋盘（AdjacencyGrid）" % f)
		assert_eq(b.grid.cell_count(), int(case["cells"]), "%s 格数应与 mask 有格数一致" % f)
		assert_eq(b.grid.size(), case["bbox"], "%s 包围盒应与规格一致" % f)
		assert_eq(b.total_mines, int(case["mines"]), "%s 雷数应与规格一致" % f)
		assert_eq(int(_json(case).get("seed", -1)), int(case["seed"]),
				"%s seed 应与 SPECS 实跑结果一致（换 seed 次数变了这里会红灯）" % f)
		for m: Vector2i in b.get_mine_positions():
			assert_true(b.grid.in_board(m), "%s 雷位 (%d,%d) 应在盘内" % [f, m.x, m.y])


func test_art_mask_in_json_matches_cells() -> void:
	# 产物 JSON 自带审计 mask（to_adjacency_grid 的 "mask" 分支落盘 params.mask）：
	# 从 JSON 独立数 '#'/X/1 应等于 cells，且 9 行 × 9 列 —— 「cells 与 mask 数一致」的黑盒复核。
	for case: Dictionary in ART_CASES:
		var topo: Dictionary = _json(case).get("topology", {})
		var f := str(case["file"])
		assert_eq(str(topo.get("style", "")), "holed_grid",
				"%s topology.style 应为 holed_grid（入库自动归 shape_holed 的依据）" % f)
		var mask: Array = (topo.get("params", {}) as Dictionary).get("mask", [])
		assert_eq(mask.size(), int(case["bbox"].y), "%s 审计 mask 行数应与 bbox 一致" % f)
		var filled := 0
		for row in mask:
			assert_eq(str(row).length(), int(case["bbox"].x),
				"%s 审计 mask 每行列数应与 bbox 一致" % f)
			for ch in str(row):
				if "#X1".contains(ch):
					filled += 1
		assert_eq(filled, int(case["cells"]), "%s mask 有格数应与 cells 一致" % f)


func test_art_row_length_fingerprint_and_edges() -> void:
	# 形状指纹（最强）：逐行格数 = mask 行指纹；无向边数也与生成日志一致——图案被改必红灯。
	for case: Dictionary in ART_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		var counts: Array = []
		for y in int(case["bbox"].y):
			var n := 0
			for p: Vector2i in b.grid.all_positions():
				if p.y == y:
					n += 1
			counts.append(n)
		assert_eq(counts, case["row_lens"], "%s 逐行格数应为 mask 行指纹" % f)
		assert_eq(_grid_edge_count(b.grid), int(case["edges"]), "%s 无向边数应与生成日志一致" % f)


func test_art_holes_off_board_and_key_cells_in_board() -> void:
	for case: Dictionary in ART_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		for hole: Vector2i in case["holes"]:
			assert_false(b.grid.in_board(hole), "%s 洞格 (%d,%d) 不应在盘内" % [f, hole.x, hole.y])
			assert_null(b.grid.get_cell(hole), "%s 洞格 (%d,%d) 应无 Cell" % [f, hole.x, hole.y])
		for p: Vector2i in case["in_board"]:
			assert_true(b.grid.in_board(p), "%s 图案关键格 (%d,%d) 应在盘内" % [f, p.x, p.y])
