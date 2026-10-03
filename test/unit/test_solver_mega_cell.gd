# test_solver_mega_cell.gd —— 复合格「当逻辑一格」求解映射（core/solver/mega_solver.gd）
#
# 钉住的不变量：
#   ① 小盘上「复合格 = 一格」的求解结果 == **手工枚举**真值（核心要求）；
#   ② `MegaCell.adjacency()` 折算出的约束正确（相邻复合格按单元去重、只算 1 个邻居）；
#   ③ 无复合格时与既有玩家视角口径**逐点一致**（回归）；
#   ④ 边界：单格复合格 / 复合格相邻 / 复合格带雷；
#   ⑤ 硬要求：「当一格」(M) 与「按单元聚合展开成基础格」(U) 的解集（投影）一致，
#      并给出「逐基础格计数」口径不一致的**反例**；
#   ⑥ 无法保证一致的情形必须**明确拒绝**（非经典线索 / 全局约束 / 脏嵌套），不许含糊。
#
# 用 preload 而非全局类名，避免新增脚本的全局类缓存尚未刷新时测试无法解析。
extends GutTest

const MS := preload("res://core/solver/mega_solver.gd")
const MC := preload("res://core/mega_cell.gd")


# ==================== 测试装置 ====================

func _board(rows: int, cols: int, mines: Array, revealed: Array, total: int) -> Board:
	var b := Board.new()
	var lvl := {
		"size": {"rows": rows, "cols": cols},
		"total_mines": total,
		"mines": [],
		"revealed": [],
	}
	for m: Vector2i in mines:
		lvl["mines"].append({"r": m.y, "c": m.x})
	for r: Vector2i in revealed:
		lvl["revealed"].append({"r": r.y, "c": r.x})
	b.load_level(lvl)
	return b


func _mega(groups: Array) -> MegaCell:
	var reg := MC.new()
	for g in groups:
		var res: Dictionary = reg.merge(g)
		assert_true(bool(res["ok"]), "测试装置：合并应成功 %s" % str(res))
	return reg


func _pair_has(pairs: Array, c: int, r: int) -> bool:
	for p in pairs:
		var a: Array = p
		if int(a[0]) == r and int(a[1]) == c:
			return true
	return false


func _combos(items: Array, k: int) -> Array:
	var out: Array = []
	_combos_rec(items, k, 0, [], out)
	return out


func _combos_rec(items: Array, k: int, start: int, cur: Array, out: Array) -> void:
	if cur.size() == k:
		out.append(cur.duplicate())
		return
	for i in range(start, items.size()):
		cur.append(items[i])
		_combos_rec(items, k, i + 1, cur, out)
		cur.pop_back()


func _key_of(anchors: Array) -> String:
	var arr: Array = anchors.duplicate()
	arr.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	return str(arr)


func _keys_of(sols: Array) -> Dictionary:
	var out := {}
	for s in sols:
		out[_key_of(s)] = true
	return out


## 集合语义比较（忽略顺序）：只关心「有哪些锚点」，不关心生成顺序。
func _same_set(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for x in a:
		if not b.has(x):
			return false
	return true


## 既有玩家视角口径（现状）：经典 8 邻 + `get_player_constraint`。
func _player_view_ok(board: Board, mines: Array) -> bool:
	var mset := {}
	for m in mines:
		mset[m] = true
	if mset.size() != board.total_mines:
		return false
	for pos in board.grid.all_positions():
		var cell: Cell = board.grid.get_cell(pos)
		if cell == null or cell.state != Cell.State.REVEALED:
			continue
		var con := board.get_player_constraint(pos)
		if str(con.get("type", "")) != "equality":
			continue
		var want: int = int(con["value"])
		var got := 0
		for nb in board.grid.get_neighbors(pos):
			if mset.has(nb):
				got += 1
		if got != want:
			return false
	return true


# ==================== ① 小盘「复合格 = 一格」== 手工枚举 ====================

func test_mega_one_cell_solution_matches_hand_enumeration() -> void:
	var b := _board(3, 3, [Vector2i(2, 1)], [Vector2i(1, 0)], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)]])
	var model := MS.build(b, b.mega)
	assert_true(bool(model["ok"]), "建模应成功：%s" % str(model.get("reason", "")))

	# 8 个逻辑单元 = 1 个复合格 + 7 个未合并基础格（(0,1) 被复合格占用，不再是单元）。
	var anchors: Array = model["anchors"]
	assert_eq(anchors.size(), 8, "逻辑单元数应为 8")
	assert_true(anchors.has(Vector2i(0, 0)), "复合格锚点应参与变量集合")
	assert_false(anchors.has(Vector2i(0, 1)), "复合格非锚点成员不应单独成变量")
	var non_anchor: Array = model["non_anchor_cells"]
	assert_eq(non_anchor.size(), 1, "非锚点固定安全格应恰为 1 个")
	assert_true(non_anchor.has(Vector2i(0, 1)))
	# 线索格 (1,0) 的邻居单元 = {A(0,0), (2,0), (1,1), (2,1)}（(0,1) 归入 A 后去重）。
	var nbs: Array = model["neighbors"][Vector2i(1, 0)]
	assert_eq(nbs, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 0), Vector2i(2, 1)],
		"线索格邻接应折算成 4 个逻辑单元")
	assert_eq(int(model["clues"][Vector2i(1, 0)]), 1, "真值雷在 (2,1) ⇒ 线索值 1")

	# 手工枚举真值：总雷数 1，且必须落在 (1,0) 的 4 个邻居单元之一 ⇒ 恰 4 个解。
	var expect := {
		_key_of([Vector2i(0, 0)]): true,
		_key_of([Vector2i(2, 0)]): true,
		_key_of([Vector2i(1, 1)]): true,
		_key_of([Vector2i(2, 1)]): true,
	}
	var sols := MS.enumerate_solutions(model)
	assert_eq(sols.size(), 4, "解得集应为 4（手工枚举）")
	for s in sols:
		assert_true(expect.has(_key_of(s)), "解 %s 不在手工枚举集合内" % str(s))
	for k in expect:
		var hit := false
		for s2 in sols:
			if _key_of(s2) == k:
				hit = true
				break
		assert_true(hit, "手工枚举解 %s 未被枚举到" % k)

	# 拼接既有 CP-SAT 原语：spec 解数一致（GDScript 回退后端，无 C# 依赖）。
	var spec := MS.build_spec(model)
	assert_eq(RuleCpSat.fallback_count(spec, 100), 4, "spec 解数应与手工枚举一致")
	assert_true(_pair_has(spec["safe_cells"], 0, 1), "复合格非锚点 (0,1) 必须在 spec 里固定安全")
	assert_true(_pair_has(spec["safe_cells"], 1, 0), "已翻开的线索格锚点 (1,0) 必须安全")
	assert_false(_pair_has(spec["mine_cells"], 2, 1), "真值雷位不得泄漏进 spec")


# ==================== ② adjacency() 折算的约束正确 ====================

func test_adjacency_folded_constraint_counts_unit_once() -> void:
	# A={(0,0),(1,0)} 与 B={(0,1),(1,1)} 纵向相邻：B 有两格贴着 A，但只能算 1 个邻居单元。
	var b := _board(3, 3, [Vector2i(1, 1)], [Vector2i(2, 0)], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1), Vector2i(1, 1)]])
	var model := MS.build(b, b.mega)
	assert_true(bool(model["ok"]), str(model.get("reason", "")))

	var a_nb: Array = model["neighbors"][Vector2i(0, 0)]
	assert_eq(a_nb, [Vector2i(0, 1), Vector2i(2, 0), Vector2i(2, 1)],
		"相邻复合格 B 被两格命中，但只能折算成 1 个邻居")
	assert_eq(int(model["clues"][Vector2i(2, 0)]), 1, "雷在 B 内 ⇒ 线索格 (2,0) 计数 1")
	# 线索 (2,0) 的邻居单元 = {A, B, (2,1)}；总雷 1 ⇒ 解只能是这 3 者之一。
	var got := _keys_of(MS.enumerate_solutions(model))
	assert_eq(got.size(), 3, "解集应为 {A, B, (2,1)}")
	assert_true(got.has(_key_of([Vector2i(0, 0)])))
	assert_true(got.has(_key_of([Vector2i(0, 1)])))
	assert_true(got.has(_key_of([Vector2i(2, 1)])))
	# 不在邻域内的单元放雷 ⇒ 线索为 0 ≠ 1，必须被拒绝。
	assert_false(MS.check_assignment(model, [Vector2i(2, 2)]), "非邻域单元放雷应不满足线索")


# ==================== ③ 无复合格 ⇒ 与现状逐点一致（回归）====================

func test_no_mega_regression_matches_player_view() -> void:
	var b := _board(3, 3, [Vector2i(0, 0), Vector2i(2, 2)], [Vector2i(1, 1)], 2)
	var model := MS.build(b, null)
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	var anchors: Array = model["anchors"]
	assert_eq(anchors.size(), 9, "无复合格时每基础格一个变量")
	assert_true((model["non_anchor_cells"] as Array).is_empty(), "无复合格 ⇒ 无固定安全成员")
	assert_eq(int(model["clues"][Vector2i(1, 1)]), 2, "线索值应与经典邻域雷数一致")

	var positions: Array = b.grid.all_positions()
	var subsets := _combos(positions, 2)
	assert_eq(subsets.size(), 36, "装置：9 选 2")
	var agree := 0
	for s in subsets:
		var mine_arr: Array[Vector2i] = []
		mine_arr.assign(s)
		var mine_model := MS.check_assignment(model, mine_arr)
		var mine_view := _player_view_ok(b, s)
		assert_eq(mine_model, mine_view,
			"无复合格时模型判定必须与玩家视角逐点一致：%s" % str(s))
		if mine_view:
			agree += 1
	assert_eq(agree, 28, "手工枚举真值：两雷都落在 (1,1) 的 8 邻内 ⇒ C(8,2)=28")
	assert_eq(MS.enumerate_solutions(model).size(), 28, "模型解集应与真值一致")
	assert_eq(RuleCpSat.fallback_count(MS.build_spec(model), 1000), 28, "spec 解数应与真值一致")


# ==================== ④a 单格复合格 == 基础格 ====================

func test_single_cell_mega_behaves_like_base() -> void:
	var b := _board(3, 3, [Vector2i(0, 0)], [], 1)
	var single := MS.build(b, _mega([[Vector2i(1, 1)]]))
	var none := MS.build(b, null)
	assert_true(_same_set(single["anchors"], none["anchors"]), "单格复合格不应改变变量集合")
	assert_true((single["non_anchor_cells"] as Array).is_empty(), "单格复合格无内部非锚点成员")
	assert_eq(MS.build_spec(single)["safe_cells"], MS.build_spec(none)["safe_cells"],
		"单格复合格不应引入额外固定安全格")
	var ks := _keys_of(MS.enumerate_solutions(single))
	var kn := _keys_of(MS.enumerate_solutions(none))
	assert_eq(ks.size(), 9, "总雷 1、9 格、无线索 ⇒ 9 解")
	assert_eq(ks.size(), kn.size(), "单格复合格解集应与基础格一致")
	for k in ks:
		assert_true(kn.has(k), "单格复合格解应与基础格解相同：%s" % k)


# ==================== ④c 复合格带雷 ====================

func test_mega_with_mine_represented_by_anchor() -> void:
	# 真值雷落在复合格**非锚点**格 (0,1)：逻辑层必须记为「该单元有雷」，由锚点变量表示。
	var b := _board(3, 3, [Vector2i(0, 1)], [], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)]])
	var model := MS.build(b, b.mega)
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	var v := MS.validate_ground_truth(b, model)
	assert_true(bool(v["ok"]), "真值应与模型口径相容：%s" % str(v["reasons"]))
	assert_eq(int(v["logical_total"]), 1, "逻辑总雷数应为 1（单元级）")
	assert_true(MS.unit_has_mine(b, model["unit_at"][Vector2i(0, 0)]), "锚点单元应被判定含雷")
	assert_true(MS.check_assignment(model, [Vector2i(0, 0)]), "单元含雷 ⇒ 锚点变量为真")
	assert_true(_pair_has(MS.build_spec(model)["safe_cells"], 0, 1),
		"物理雷格 (0,1) 是复合格非锚点成员 ⇒ 固定安全、不是变量")
	# 违反「区域至多 1 雷」的真值必须被校验拒绝（不静默）。
	var b2 := _board(3, 3, [Vector2i(0, 0), Vector2i(0, 1)], [], 2)
	b2.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)]])
	var v2 := MS.validate_ground_truth(b2, MS.build(b2, b2.mega))
	assert_false(bool(v2["ok"]), "同一复合格内 2 雷必须被判为违反口径")
	assert_true((v2["reasons"] as Array).size() > 0, "拒绝必须给人话原因")


# ==================== ⑤ 硬要求：「当一格」与「展开」解集一致（含反例）====================

func _unfold_ok(model: Dictionary, units: Array, mset: Dictionary) -> bool:
	# (a) 复合格区域 ≤ 1 雷
	for u in units:
		if str(u["kind"]) == MS.KIND_MEGA:
			var n := 0
			for c: Vector2i in (u["cells"] as Array):
				if mset.has(c):
					n += 1
			if n > MS.MINE_CAP:
				return false
	# (b) 已翻开单元的所有基础格安全
	var revealed: Array = model["revealed"]
	for a in revealed:
		var ur: Dictionary = model["unit_at"][a]
		for c2: Vector2i in (ur["cells"] as Array):
			if mset.has(c2):
				return false
	# (c) 线索按**单元**求和（相邻复合格整体算 1，不按内部相邻基础格数计）
	var clues: Dictionary = model["clues"]
	for a2 in clues:
		var got := 0
		for nb in model["neighbors"][a2]:
			var un: Dictionary = model["unit_at"][nb]
			for c3: Vector2i in (un["cells"] as Array):
				if mset.has(c3):
					got += 1
		if got != int(clues[a2]):
			return false
	return true


func _unfold_solutions(board: Board, model: Dictionary) -> Array:
	var positions: Array = board.grid.all_positions()
	var units: Array = model["units"]
	var total := int(model["total_mines"])
	var out: Array = []
	for mines in _combos(positions, total):
		var mset := {}
		for m in mines:
			mset[m] = true
		if not _unfold_ok(model, units, mset):
			continue
		var proj: Array[Vector2i] = []
		for u in units:
			var has := false
			for c: Vector2i in (u["cells"] as Array):
				if mset.has(c):
					has = true
					break
			if has:
				proj.append(u["anchor"])
		out.append(proj)
	return out


func test_one_cell_model_equals_unfolded_base_projection() -> void:
	var b := _board(3, 3, [Vector2i(2, 1)], [Vector2i(1, 0)], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)]])
	var model := MS.build(b, b.mega)
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	var m_sols := MS.enumerate_solutions(model)
	var u_sols := _unfold_solutions(b, model)
	var m_keys := _keys_of(m_sols)
	var u_keys := _keys_of(u_sols)
	assert_eq(m_keys.size(), 4, "M 解集应为 4")
	assert_eq(u_sols.size(), 5, "U 原始解 5 个：A 内部两格各可承载那唯一一雷（该自由度不可观测）")
	assert_eq(u_keys.size(), m_keys.size(), "投影后两侧解集大小应一致")
	for k in m_keys:
		assert_true(u_keys.has(k), "展开模型应包含 M 的解：%s" % k)
	for k2 in u_keys:
		assert_true(m_keys.has(k2), "M 应包含展开模型的每个投影解：%s" % k2)


func test_naive_per_base_counting_counterexample() -> void:
	# 反例：逐基础格经典邻域计数与「单元聚合」口径不一致。
	# 区域 A={(0,0),(1,0)} 有雷（雷在 (0,0)），线索格 (2,0)。
	var b := _board(3, 3, [Vector2i(0, 0)], [Vector2i(2, 0)], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(1, 0)]])
	var con := b.get_player_constraint(Vector2i(2, 0))
	assert_eq(str(con.get("type", "")), "equality", "装置：(2,0) 应是经典线索格")
	assert_eq(int(con["value"]), 0,
		"逐基础格口径：雷在 (0,0)（不与 (2,0) 相邻）⇒ 显示 0")
	var model := MS.build(b, b.mega)
	assert_eq(int(model["clues"][Vector2i(2, 0)]), 1,
		"单元聚合口径：A 是逻辑一格且与 (2,0) 相邻 ⇒ 显示 1 —— 与逐基础格口径不同")


# ==================== ⑥ 无法保证一致的情形必须明确拒绝 ====================

func test_refuses_cases_that_cannot_be_consistent() -> void:
	# 非经典线索窗口
	var b := _board(3, 3, [Vector2i(0, 0)], [], 1)
	b.rule_clue_id = "classic"
	var r1 := MS.build(b, _mega([[Vector2i(1, 1)]]))
	assert_false(bool(r1["ok"]), "规则线索窗口不在折算口径内，必须拒绝")
	assert_true(str(r1["reason"]).length() > 0, "拒绝必须给原因")

	# 全局约束
	var b2 := _board(3, 3, [Vector2i(0, 0)], [], 1)
	b2.constraint_variant = ConstraintEngine.Variant.MX
	var r2 := MS.build(b2, _mega([[Vector2i(1, 1)]]))
	assert_false(bool(r2["ok"]), "全局约束未折算，必须拒绝")
	assert_true(str(r2["reason"]).length() > 0)

	# 脏嵌套（同一基础格被两个复合格占用）
	var dirty := MC.from_dict({
		"version": MC.VERSION,
		"groups": [
			{"id": 1, "cells": [[0, 0], [1, 0]]},
			{"id": 2, "cells": [[1, 0], [2, 0]]},
		],
	})
	var b3 := _board(3, 3, [Vector2i(0, 0)], [], 1)
	var r3 := MS.build(b3, dirty)
	assert_false(bool(r3["ok"]), "共格嵌套必须拒绝，不许在脏数据上求解")
	assert_true(str(r3["reason"]).length() > 0)


# ==================== 棋盘接线（Board.build_mega_model）====================

func test_board_hook_build_mega_model() -> void:
	var b := _board(3, 3, [Vector2i(2, 1)], [Vector2i(1, 0)], 1)
	assert_eq(b.mega, null, "load_level 后复合格应清空（无残留）")
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)]])
	var via_board := b.build_mega_model()
	var direct := MS.build(b, b.mega)
	assert_true(bool(via_board["ok"]), "Board 接线应成功：%s" % str(via_board.get("reason", "")))
	assert_eq(via_board["anchors"], direct["anchors"], "Board 接线与直接调用应一致")
	assert_eq(int(via_board["total_mines"]), 1)
