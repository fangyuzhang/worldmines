# test_hotmap.gd —— 猜点热力图（HotMap）自证
#
# 用**确定性构造**钉住五条不变量（不靠随机盘，避免 flaky）：
#   1) 必猜格被标记：9x9 十雷只翻开 (4,4)（0<值<度-1，单条线索钉不住任何格）⇒ 必有 must_guess；
#   2) 深度单调：3x3 单雷只翻开 (0,0)，0 值闭包先安全、后由 (1,1)=1 推出 (2,2) 是雷 ⇒ 晚推 ≥ 早推；
#   3) 推不出的格标 -1 且 reason 非空（把推演轮数压到 1，剩余格如实标未知）；
#   4) 超格数上限（EditorDoc.MAX_CELL_BUDGET）被拒；
#   5) 与 verify / oracle 结论不矛盾：must_guess 格数 > 0 ⟺ verify 判定「需要猜测」。
# 另钉复合格降级（未接入 doc）与显式传入 MegaCell 时的逻辑一格聚合。
extends GutTest

## 用 preload 引用被测脚本：不依赖 `.godot/global_script_class_cache.cfg` 是否已收录
## 新 `class_name`（首次运行/干净缓存时缓存可能尚未刷新，直接写 HotMap 会解析失败）。
const HotMapScript := preload("res://core/hotmap.gd")


func _doc(p_rows: int, p_cols: int, mine_list: Array) -> EditorDoc:
	var d := EditorDoc.new(p_rows, p_cols)
	for m in mine_list:
		d.mines.append(m)
	return d


## 9x9 十雷：只翻开 (4,4)（值 2，其 8 邻里只有 2 颗雷，其余 8 颗远在一角）⇒ 单条线索钉不住任何格。
func _guessy_board() -> EditorDoc:
	var mine_list := [
		Vector2i(3, 3), Vector2i(5, 5),
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(2, 2),
	]
	var d := _doc(9, 9, mine_list)
	d.revealed[Vector2i(4, 4)] = null
	return d


## 3x3 单雷 (2,2)，只翻开 (0,0)：可完全序贯演绎（见 test_editor_verify 同款构造）。
func _deducible_board() -> EditorDoc:
	var d := _doc(3, 3, [Vector2i(2, 2)])
	d.revealed[Vector2i(0, 0)] = null
	return d


func _count_must_guess(cells: Dictionary) -> int:
	var n := 0
	for k in cells:
		if bool((cells[k] as Dictionary).get("must_guess", false)):
			n += 1
	return n


func _count_unknown(cells: Dictionary) -> int:
	var n := 0
	for k in cells:
		if int((cells[k] as Dictionary).get("level", HotMapScript.LEVEL_UNKNOWN)) == HotMapScript.LEVEL_UNKNOWN:
			n += 1
	return n


# ==================== 1. 必猜格被标记 ====================

func test_must_guess_cells_are_marked_on_a_guessy_board() -> void:
	var d := _guessy_board()
	var r := HotMapScript.build(d)
	assert_true(bool(r["ok"]), "应能构建热力图：%s" % str(r["reason"]))
	assert_eq(str(r["state"]), EditorVerify.STATE_NEEDS_GUESS,
		"该盘应被判为需要猜测（实际：%s）" % str(r["state"]))

	var cells: Dictionary = r["cells"]
	assert_gt(_count_must_guess(cells), 0, "推不动的盘必须标出「必猜」格")

	var has_zero_index := false
	for k in cells:
		var rec: Dictionary = cells[k]
		if bool(rec.get("must_guess", false)) and int(rec.get("guess_index", -1)) == 0:
			has_zero_index = true
	assert_true(has_zero_index, "必猜格应带 guess_index（0 起），供 UI 排序展示")


# ==================== 2. 深度单调性 ====================

func test_depths_are_monotonic_on_a_deducible_board() -> void:
	var d := _deducible_board()
	var r := HotMapScript.build(d)
	assert_true(bool(r["ok"]), "可演绎的小盘应能构建：%s" % str(r["reason"]))
	assert_eq(str(r["state"]), EditorVerify.STATE_NO_GUESS, "该盘应无需猜测")

	var cells: Dictionary = r["cells"]
	var l00 := int((cells[Vector2i(0, 0)] as Dictionary)["level"])
	var l11 := int((cells[Vector2i(1, 1)] as Dictionary)["level"])
	var l22 := int((cells[Vector2i(2, 2)] as Dictionary)["level"])
	assert_eq(l00, 0, "初始翻开格深度应为 0（它不是被推理出来的）")
	assert_true(l11 >= l00, "后推出的 (1,1) 深度不应早于初始格：%d vs %d" % [l11, l00])
	assert_true(l22 >= l11, "更晚推出的雷 (2,2) 深度不应早于 (1,1)：%d vs %d" % [l22, l11])
	assert_eq(_count_must_guess(cells), 0, "可完全演绎的盘不该有必猜格")
	assert_eq(_count_unknown(cells), 0, "可完全演绎的盘不该有未知格")

	var computed := 0
	for k in cells:
		computed = maxi(computed, int((cells[k] as Dictionary)["level"]))
	assert_eq(int(r["max_level"]), computed, "max_level 应等于全部已知深度的最大值")
	assert_true(computed >= 1, "至少要有一格是被推理出来的（深度 ≥ 1）")


# ==================== 3. 推不出的格标 -1 且 reason 非空 ====================

func test_unresolved_cells_are_minus_one_with_reason() -> void:
	# 轮数上限压到 1：第一轮无强制格 ⇒ 记 1 次盲猜后即达上限，其余格如实标未知。
	var d := _guessy_board()
	var r := HotMapScript.build(d, {"max_rounds": 1})
	assert_true(bool(r["ok"]), "截断只影响深度完备性，不应整体拒绝：%s" % str(r["reason"]))
	var cells: Dictionary = r["cells"]
	assert_gt(_count_unknown(cells), 0, "推不出来的格必须标 level = -1（不假装知道）")
	assert_gt(str(r["reason"]).length(), 0, "reason 必须说明为何有未知格")
	assert_true(str(r["reason"]).find("未能推出") != -1 or str(r["reason"]).find("上限") != -1,
		"reason 应点明未知原因：%s" % str(r["reason"]))
	assert_gt(_count_must_guess(cells), 0, "第一轮推不动 ⇒ 至少记 1 个必猜格")


# ==================== 4. 超上限被拒 ====================

func test_over_cell_budget_is_refused() -> void:
	var d := EditorDoc.new(71, 71)   # 71*71 = 5041 > EditorDoc.MAX_CELL_BUDGET(5000)
	var r := HotMapScript.build(d)
	assert_false(bool(r["ok"]), "超过格数上限必须直接拒绝（防全量热力卡死编辑器）")
	assert_true(str(r["reason"]).find(str(EditorDoc.MAX_CELL_BUDGET)) != -1,
		"拒绝理由应报出上限值：%s" % str(r["reason"]))
	assert_eq((r["cells"] as Dictionary).size(), 0, "被拒时不产出任何格数据")


# ==================== 5. 与 verify / oracle 结论不矛盾 ====================

func test_must_guess_matches_verify_verdict() -> void:
	# 可解盘：must_guess 应为 0，且 verify 判 no_guess
	var d1 := _deducible_board()
	var v1 := EditorVerify.verify(d1)
	var r1 := HotMapScript.build(d1)
	assert_eq(str(v1["state"]), EditorVerify.STATE_NO_GUESS, "前置：3x3 盘应可解")
	assert_eq(str(r1["state"]), str(v1["state"]), "热力图结论必须与 verify 一致")
	assert_eq(_count_must_guess(r1["cells"] as Dictionary), 0, "可解盘必须猜格数为 0")

	# 需猜盘：must_guess > 0，且 verify 判 needs_guess
	var d2 := _guessy_board()
	var v2 := EditorVerify.verify(d2)
	var r2 := HotMapScript.build(d2)
	assert_eq(str(v2["state"]), EditorVerify.STATE_NEEDS_GUESS, "前置：9x9 盘应需猜")
	assert_eq(str(r2["state"]), str(v2["state"]), "热力图结论必须与 verify 一致")
	assert_gt(_count_must_guess(r2["cells"] as Dictionary), 0, "需猜盘必须猜格数 > 0")


# ==================== 6. 复合格：降级 / 聚合 ====================

func test_mega_degrades_when_not_wired_and_aggregates_when_provided() -> void:
	var d := _deducible_board()

	# 未接入 doc：明确降级为「按基础格计算」，且不得出现 internal 标记。
	var r1 := HotMapScript.build(d)
	assert_true(str(r1["reason"]).find("复合格未接入") != -1,
		"未接入复合格时应在 reason 里说明降级，不假装支持：%s" % str(r1["reason"]))
	for k in (r1["cells"] as Dictionary):
		assert_false(bool((r1["cells"] as Dictionary)[k].get("internal", false)),
			"未接入时不得把任何格标成复合格内部格")

	# 显式传入 MegaCell：内部格共享同一「逻辑一格」的值并标 internal。
	var mc := MegaCell.new()
	var mres := mc.merge([Vector2i(0, 0), Vector2i(1, 0)])
	assert_true(bool(mres["ok"]), "复合格合并应成功：%s" % str(mres))
	var r2 := HotMapScript.build(d, {"mega": mc})
	assert_true(bool(r2["ok"]), "带复合格仍应能构建：%s" % str(r2["reason"]))
	var cells: Dictionary = r2["cells"]
	var rec0: Dictionary = cells[Vector2i(0, 0)]
	var rec1: Dictionary = cells[Vector2i(1, 0)]
	assert_true(bool(rec0.get("internal", false)), "(0,0) 属于复合格应标 internal")
	assert_true(bool(rec1.get("internal", false)), "(1,0) 属于复合格应标 internal")
	assert_eq(int(rec0["level"]), int(rec1["level"]), "逻辑一格内部共享同一深度")
	assert_eq(bool(rec0.get("must_guess", false)), bool(rec1.get("must_guess", false)),
		"逻辑一格内部共享同一必猜标记")
	assert_true(str(r2["reason"]).find("复合格：1 个") != -1,
		"reason 应说明已聚合几个复合格：%s" % str(r2["reason"]))
