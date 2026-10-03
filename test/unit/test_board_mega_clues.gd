# test_board_mega_clues.gd —— 复合格「显示一个数字」的 Board 侧接线（core/board.gd）
#
# 钉住的不变量（口径见 core/solver/mega_solver.gd 头注释）：
#   ① 有复合格时，复合格区域**只显示一个**数字，且该数字标在**锚点格**（规范序首格）；
#      单元的非锚点成员一律 -1（不绘制），绝不显示互相矛盾的数字；
#   ② 该数字语义 = 邻居单元中含雷单元数（相邻复合格不论命中几格只算 1）——
#      **与 `MegaSolver.build` 的 `clues` 逐点一致**（交叉一致硬要求）；
#   ③ 无复合格时 `_compute_clues` / `refresh_mega_clues` 行为与现状**逐位一致**（回归）；
#   ④ 边界：复合格相邻 / 复合格带雷（雷在非锚点成员）/ 单格复合格。
#
# 触发入口说明：`load_level` 会把 `mega` 复位为 null（且此时 grid 尚未建好），mega 由调用方
# 在 load_level 之后设置，故设置后需调用 `Board.refresh_mega_clues()` 触发单元口径重算
#（为什么不自动重算见 board.gd `refresh_mega_clues` 注释）。
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


## 经典 8 邻雷数（现状口径，用于无复合格回归与「口径确实被改写」的对照）。
func _classic_count(board: Board, pos: Vector2i) -> int:
	var n := 0
	for nb in board.grid.get_neighbors(pos):
		if board.is_mine(nb):
			n += 1
	return n


## 单元聚合口径（独立于 Board，直接由真值 + 模型折算的邻居锚点重算，用作非自证的对照）。
func _expected_unit_clue(board: Board, model: Dictionary, anchor: Vector2i) -> int:
	var n := 0
	for nb: Vector2i in (model["neighbors"][anchor] as Array):
		if MS.unit_has_mine(board, model["unit_at"][nb]):
			n += 1
	return n


# ==================== ① 复合格区域只出一个数字，且标在锚点 ====================

func test_mega_region_shows_single_number_at_anchor() -> void:
	# A = 竖排 3 格；雷在非锚点成员 (0,1)。锚点 = 规范序首格 (0,0)。
	var b := _board(3, 3, [Vector2i(0, 1)], [Vector2i(0, 0)], 1)
	# 装置核对：锚点基础口径为 1（邻接那颗雷）；重算后应变单元口径。
	assert_eq(int(b.grid.get_cell(Vector2i(0, 0)).value), 1, "装置：重算前应为逐基础格口径 1")
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)]])
	b.refresh_mega_clues()

	var anchor: Cell = b.grid.get_cell(Vector2i(0, 0))
	assert_eq(int(anchor.value), 0, "锚点应显示单元口径数字：A 的邻居单元均不含雷 ⇒ 0")
	# 非锚点成员（非雷）不得显示数字 ⇒ 哨兵 -1。
	assert_eq(int(b.grid.get_cell(Vector2i(0, 2)).value), -1, "非锚点成员应置哨兵 -1（不显示数字）")
	# 「区域只出一个数字」：区域内非雷格中恰有一个可显示数字（= 锚点）。
	var shown := 0
	for p: Vector2i in [Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)]:
		var c: Cell = b.grid.get_cell(p)
		if c != null and not c.is_mine and c.value is int and int(c.value) >= 0:
			shown += 1
	assert_eq(shown, 1, "复合格区域非雷格中应恰有 1 个数字（锚点）")

	# 交叉一致：锚点数字 == MegaSolver 推导的单元线索值。
	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), "建模应成功：%s" % str(model.get("reason", "")))
	assert_eq(int(anchor.value), int(model["clues"][Vector2i(0, 0)]),
		"Board 显示的复合格数字必须 == MegaSolver 的单元线索值")
	assert_eq(int(anchor.value), _expected_unit_clue(b, model, Vector2i(0, 0)),
		"且应等于「邻居单元含雷数」的独立重算值")


# ==================== ①b 「忘记调用 refresh」的失败模式必须可见 ====================

func test_forgetting_refresh_keeps_base_clues() -> void:
	# 契约（见 board.gd refresh_mega_clues 注释）：设置 board.mega 之后**必须**调用 refresh_mega_clues()，
	# 否则线索仍是逐基础格口径。本用例把「忘记调用」的症状钉死，免得将来误以为「复合格没生效」。
	var b := _board(3, 3, [Vector2i(0, 1)], [Vector2i(0, 0)], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)]])
	# 故意不调用 refresh：锚点仍是逐基础格口径 1（= 邻接 (0,1) 那颗雷）；非锚点成员也未置 -1。
	assert_eq(int(b.grid.get_cell(Vector2i(0, 0)).value), 1,
		"忘记 refresh ⇒ 线索仍是逐基础格口径（这就是「没生效」的症状）")
	assert_eq(int(b.grid.get_cell(Vector2i(0, 2)).value), _classic_count(b, Vector2i(0, 2)),
		"忘记 refresh ⇒ 非锚点成员也不会被置 -1")
	assert_eq(_classic_count(b, Vector2i(0, 2)), 1, "装置：(0,2) 基础口径为 1")

	# 一旦调用 ⇒ 变为单元口径（与求解器一致），非锚点置 -1。
	b.refresh_mega_clues()
	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	assert_eq(int(b.grid.get_cell(Vector2i(0, 0)).value), int(model["clues"][Vector2i(0, 0)]),
		"调用 refresh ⇒ 锚点变为单元口径，且 == MegaSolver 单元线索值")
	assert_eq(int(b.grid.get_cell(Vector2i(0, 2)).value), -1, "调用 refresh ⇒ 非锚点成员置 -1")


# ==================== ② 无复合格 ⇒ 与现状逐位一致（回归）====================

func test_no_mega_regression_bitwise_identical() -> void:
	var mines := [Vector2i(0, 0), Vector2i(3, 3)]
	var revealed := [Vector2i(1, 1)]
	var b := _board(4, 4, mines, revealed, 2)
	# 未调用 refresh 的孪生盘，作为「现状」基准。
	var twin := _board(4, 4, mines, revealed, 2)

	b.refresh_mega_clues()  # mega == null ⇒ 只重跑基础口径，必须逐位不变
	for pos in b.grid.all_positions():
		var cell: Cell = b.grid.get_cell(pos)
		if cell == null or cell.is_mine:
			continue
		var want := _classic_count(b, pos)
		assert_eq(int(cell.value), want, "无复合格时线索必须仍是经典邻域雷数 @%s" % str(pos))
		assert_eq(int(cell.value), int(twin.grid.get_cell(pos).value),
			"无复合格时 refresh 不应改变任何格 @%s" % str(pos))

	# mega == null 时 build_mega_model 仍是「每基础格一个变量」的既有口径。
	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	assert_eq((model["anchors"] as Array).size(), 16, "无复合格 ⇒ 16 个基础格单元")
	assert_true((model["non_anchor_cells"] as Array).is_empty(), "无复合格 ⇒ 无固定安全成员")


# ==================== ③ 复合格相邻：单元去重（只算 1 个邻居）====================

func test_adjacent_megas_dedup_and_display() -> void:
	# A={(0,0),(0,1),(0,2)}（雷在非锚点 (0,1)）与 B={(0,3),(1,3)} 横向相邻。
	# 线索格 (1,1) 同时邻接 A 的三个内部格 ⇒ 单元口径只算 1（逐基础格计数会算 1 但会重复计入同单元）。
	var b := _board(4, 4, [Vector2i(0, 1)], [Vector2i(1, 1)], 1)
	assert_eq(_classic_count(b, Vector2i(1, 1)), 1, "装置：(1,1) 基础口径为 1（仅邻接 (0,1)）")
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2)], [Vector2i(0, 3), Vector2i(1, 3)]])
	b.refresh_mega_clues()

	assert_eq(int(b.grid.get_cell(Vector2i(1, 1)).value), 1,
		"相邻复合格 A 被三格命中，仍只算 1 个含雷单元 ⇒ 显示 1")
	# A 锚点：其邻居含 B（无雷）⇒ 0。
	assert_eq(int(b.grid.get_cell(Vector2i(0, 0)).value), 0, "A 锚点的单元口径数字应为 0")
	# 两个复合格的非锚点成员（非雷）都不得显示数字。
	assert_eq(int(b.grid.get_cell(Vector2i(0, 2)).value), -1, "A 非锚点成员应置 -1")
	assert_eq(int(b.grid.get_cell(Vector2i(1, 3)).value), -1, "B 非锚点成员应置 -1")

	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	assert_eq(int(b.grid.get_cell(Vector2i(1, 1)).value), int(model["clues"][Vector2i(1, 1)]),
		"线索格显示值必须 == MegaSolver 单元线索值")
	# 去重证据：命中 A 的三个内部格，但 A 在邻居表里只出现一次。
	assert_eq((model["neighbors"][Vector2i(1, 1)] as Array).count(Vector2i(0, 0)), 1,
		"相邻复合格在邻居表里只能出现一次")


# ==================== ③ 复合格带雷（雷在非锚点成员）====================

func test_mega_with_mine_on_non_anchor_member() -> void:
	# A={(0,0),(0,1)}，真值雷落在非锚点 (0,1)：逻辑层记为「A 单元含雷」，由锚点变量表示。
	var b := _board(3, 3, [Vector2i(0, 1)], [Vector2i(1, 1)], 1)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)]])
	b.refresh_mega_clues()

	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	var v := MS.validate_ground_truth(b, model)
	assert_true(bool(v["ok"]), "真值应与「复合格 = 逻辑一格」口径相容：%s" % str(v["reasons"]))
	assert_true(MS.unit_has_mine(b, model["unit_at"][Vector2i(0, 0)]), "锚点单元应被判为含雷")
	# 线索格 (1,1) 邻接 A（含雷）⇒ 显示 1，且 == 求解器线索。
	assert_eq(int(b.grid.get_cell(Vector2i(1, 1)).value), 1, "(1,1) 应显示 1")
	assert_eq(int(b.grid.get_cell(Vector2i(1, 1)).value), int(model["clues"][Vector2i(1, 1)]),
		"显示值必须 == MegaSolver 单元线索值")
	assert_eq(int(b.grid.get_cell(Vector2i(0, 0)).value), _expected_unit_clue(b, model, Vector2i(0, 0)),
		"锚点数字应等于独立重算的单元口径值")


# ==================== ③ 单格复合格 == 基础格（透明）====================

func test_single_cell_mega_is_transparent() -> void:
	var mines := [Vector2i(0, 1), Vector2i(3, 2)]
	var revealed := [Vector2i(1, 1), Vector2i(2, 2)]
	var b := _board(4, 4, mines, revealed, 2)
	var twin := _board(4, 4, mines, revealed, 2)

	b.mega = _mega([[Vector2i(2, 2)]])   # 单格复合格：锚点 = 该格，无内部非锚点成员
	b.refresh_mega_clues()

	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), str(model.get("reason", "")))
	assert_true((model["non_anchor_cells"] as Array).is_empty(), "单格复合格不应引入固定安全成员")
	for pos in b.grid.all_positions():
		var cell: Cell = b.grid.get_cell(pos)
		if cell == null:
			continue
		assert_eq(int(cell.value), int(twin.grid.get_cell(pos).value),
			"单格复合格应逐位等价于基础格 @%s" % str(pos))
	assert_eq(int(b.grid.get_cell(Vector2i(2, 2)).value), int(model["clues"][Vector2i(2, 2)]),
		"单格复合格锚点显示值应 == 求解器线索值")


# ==================== ④ 交叉一致：Board 显示 == MegaSolver 单元线索 ====================

func test_board_display_matches_mega_solver_clues() -> void:
	# 4x4：A={(0,0),(0,1)}（雷在非锚点 (0,1)）、B={(2,2),(2,3)}（无雷）、另有孤立雷 (3,3)。
	# 三个已翻开格基础口径均为 1（避开 0 值连锁，保持盘面确定）。
	var b := _board(4, 4, [Vector2i(0, 1), Vector2i(3, 3)],
		[Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)], 2)
	b.mega = _mega([[Vector2i(0, 0), Vector2i(0, 1)], [Vector2i(2, 2), Vector2i(2, 3)]])
	b.refresh_mega_clues()

	var model := b.build_mega_model()
	assert_true(bool(model["ok"]), "建模应成功：%s" % str(model.get("reason", "")))

	# 硬要求：所有已翻开单元锚点，Board 显示值 == MegaSolver 推导的单元线索值。
	var clues: Dictionary = model["clues"]
	assert_eq(clues.size(), 3, "恰有 3 个已翻开单元携带数字线索")
	for a: Vector2i in clues:
		var cell: Cell = b.grid.get_cell(a)
		assert_eq(int(cell.value), int(clues[a]),
			"Board 显示值 %d != MegaSolver 单元线索 %d @%s" % [int(cell.value), int(clues[a]), str(a)])
		assert_eq(int(cell.value), _expected_unit_clue(b, model, a),
			"显示值也不应偏离「邻居单元含雷数」的独立重算 @%s" % str(a))

	# 单元锚点上的值都应是「邻居单元含雷数」；相邻复合格只算一次（此处 A 含雷）。
	assert_eq(int(b.grid.get_cell(Vector2i(1, 0)).value), 1, "(1,0) 邻接含雷单元 A ⇒ 1")
	assert_eq(int(b.grid.get_cell(Vector2i(1, 1)).value), 1, "(1,1) 邻接含雷单元 A ⇒ 1")
	assert_eq(int(b.grid.get_cell(Vector2i(1, 2)).value), 1, "(1,2) 邻接含雷单元 A ⇒ 1")

	# 非锚点成员不得显示数字（B 的 (2,3) 非雷）。
	assert_eq(int(b.grid.get_cell(Vector2i(2, 3)).value), -1, "B 非锚点成员应置 -1")
	# A 锚点自身：邻居单元均无雷（孤立雷 (3,3) 不相邻）⇒ 0。
	assert_eq(int(b.grid.get_cell(Vector2i(0, 0)).value), 0, "A 锚点数字应为 0")


# ==================== 无法保证一致的情形：不硬塞数字，明确告警 ====================

func test_unsupported_mega_keeps_base_and_warns() -> void:
	# 非经典线索窗口：MegaSolver 本身拒绝，Board 不得硬塞单元数字（否则制造显示/求解分叉）。
	var mines := [Vector2i(0, 0)]
	var revealed := [Vector2i(1, 1)]
	var b := _board(3, 3, mines, revealed, 1)
	var twin := _board(3, 3, mines, revealed, 1)   # 同规则、无复合格 = 「未折算」基准
	b.rule_clue_id = "classic"
	twin.rule_clue_id = "classic"
	b.refresh_mega_clues()
	twin.refresh_mega_clues()
	b.mega = _mega([[Vector2i(0, 1), Vector2i(0, 2)]])
	b.refresh_mega_clues()   # mega 存在但 MegaSolver 拒绝 ⇒ 应保持基础口径

	assert_false(bool(b.build_mega_model()["ok"]), "装置：规则线索窗口应被 MegaSolver 拒绝")
	for pos in b.grid.all_positions():
		var cell: Cell = b.grid.get_cell(pos)
		if cell == null:
			continue
		assert_eq(int(cell.value), int(twin.grid.get_cell(pos).value),
			"无法折算时应逐位保持基础口径（不得硬塞单元数字 / -1）@%s" % str(pos))
