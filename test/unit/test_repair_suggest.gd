# test_repair_suggest.gd —— 自动修复建议（RepairSuggest）自证
#
# 用**确定性小盘**钉住四条契约（不靠随机盘，避免 flaky）：
#   1) 必须猜的小盘 ⇒ 返回 ≥1 条，且每条 `verified=true`（再用既有 verify 独立复核一遍）；
#   2) 试执行发生在副本上 ⇒ suggest() 前后原文档快照逐字节一致；
#   3) 无解盘 ⇒ ok=false 且原因非空（不许编建议）；
#   4) 候选硬上限 ⇒ exhaustive=false 且不崩。
# 另钉两条：已可解的盘不需要修复；apply_plan 一键应用后会重跑校验。
extends GutTest

const RepairSuggest = preload("res://core/repair_suggest.gd")


## 1x4 一行盘、2 颗雷（(0,0)、(3,0)）、只翻开 (1,0)：
## (1,0)=1 只把雷钉在 {(0,0),(2,0)} 之一，还有 2 格格推不出来 ⇒ 需要猜测。
## 加 (2,0) 这条线索（值为 1）后：(2,0)=1 钉死 (3,0)，(1,0)=1 再钉死 (0,0) ⇒ 可完全演绎。
func _guessy_doc() -> EditorDoc:
	var d := EditorDoc.new(1, 4)
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(3, 0))
	d.revealed[Vector2i(1, 0)] = null
	return d


## 3x3、雷 (2,2)、只翻开 (0,0)：0 值连锁 ⇒ 无需猜测可解（与 test_editor_verify 同构）。
func _solvable_doc() -> EditorDoc:
	var d := EditorDoc.new(3, 3)
	d.mines.append(Vector2i(2, 2))
	d.revealed[Vector2i(0, 0)] = null
	return d


## 5x5、全部安全格翻开却声明 5 颗雷 ⇒ 逻辑矛盾（现有 verify 判 CONTRADICTION）。
func _contradiction_doc() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(4, 4))
	for y in d.rows:
		for x in d.cols:
			var p := Vector2i(x, y)
			if not d.mines.has(p):
				d.revealed[p] = null
	d.declared_total_mines = 5
	return d


## 独立执行 plan（不经 RepairSuggest 的 _apply）：验证 plan 真的"可判定、可执行"。
func _apply_plan_to_copy(src: EditorDoc, plan: Dictionary) -> EditorDoc:
	var c := EditorDoc.new()
	assert_true(c.restore(src.snapshot()), "副本应能由快照恢复")
	var op := str(plan["op"])
	if op == "add_clue":
		var cell: Dictionary = plan["cell"]
		var p := Vector2i(int(cell["c"]), int(cell["r"]))
		assert_false(c.mines.has(p), "加线索的目标格不应是雷")
		c.revealed[p] = null
	elif op == "move_mine":
		var f: Dictionary = plan["from"]
		var t: Dictionary = plan["to"]
		var a := Vector2i(int(f["c"]), int(f["r"]))
		var b := Vector2i(int(t["c"]), int(t["r"]))
		assert_true(c.mines.has(a), "挪雷的源格应是雷")
		assert_false(c.mines.has(b), "挪雷的目标格不应已是雷")
		c.mines.erase(a)
		c.mines.append(b)
	else:
		fail_test("未知的 plan.op：%s" % op)
	return c


# ==================== 1. 需猜盘 ⇒ 有建议且每条自证有效 ====================

func test_needs_guess_board_gets_verified_suggestions() -> void:
	var d := _guessy_doc()
	assert_eq(str(EditorVerify.verify_islands(d)["state"]), EditorVerify.STATE_NEEDS_GUESS,
		"前提：该盘应被判为需要猜测")

	var r := RepairSuggest.suggest(d)
	assert_true(bool(r["ok"]), "需猜盘应能给出建议（实际原因：%s）" % str(r["reason"]))
	var suggestions: Array = r["suggestions"]
	assert_gt(suggestions.size(), 0, "至少应有 1 条建议")
	assert_lte(suggestions.size(), 3, "最多 3 条")

	for s in suggestions:
		var sd: Dictionary = s
		assert_true(bool(sd["verified"]), "每条建议都应自证 verified=true")
		assert_true(str(sd["text"]).length() > 0, "每条建议都要有人话说明")
		var plan: Dictionary = sd["plan"]
		assert_true(["add_clue", "move_mine"].has(str(plan["op"])), "plan.op 必须是可执行的操作")
		assert_eq(str((sd["after"] as Dictionary)["state"]), EditorVerify.STATE_NO_GUESS,
			"自证结论应记为「无需猜测可解」")
		# 用既有 verify 独立复核：把 plan 亲自落到另一份副本上再跑一次
		var c := _apply_plan_to_copy(d, plan)
		assert_eq(str(EditorVerify.verify_islands(c)["state"]), EditorVerify.STATE_NO_GUESS,
			"独立重跑既有 verify 也必须判为可解（否则这条建议是假的）")


# ==================== 2. 试执行不改原文档 ====================

func test_suggest_does_not_touch_the_original_doc() -> void:
	var d := _guessy_doc()
	var before := JSON.stringify(d.snapshot())
	var mines_before: Array = d.mines.duplicate()
	var revealed_before: int = d.revealed.size()

	RepairSuggest.suggest(d)   # 执行一遍（本身不该改原件）

	assert_eq(JSON.stringify(d.snapshot()), before,
		"suggest() 只该在副本上试执行：前后快照必须逐字节一致")
	assert_eq(str(d.mines), str(mines_before), "原文档雷位不得被改动")
	assert_eq(d.revealed.size(), revealed_before, "原文档初始翻开集合不得被改动")


# ==================== 3. 无解盘 ⇒ ok=false + 可读原因 ====================

func test_contradiction_board_returns_false_with_reason() -> void:
	var d := _contradiction_doc()
	assert_eq(str(EditorVerify.verify_islands(d)["state"]), EditorVerify.STATE_CONTRADICTION,
		"前提：该盘应被判为逻辑矛盾")

	var r := RepairSuggest.suggest(d)
	assert_false(bool(r["ok"]), "逻辑矛盾不是挪雷/加线索能修的 ⇒ 不许硬给建议")
	assert_true(str(r["reason"]).length() > 0, "必须给出可读原因")
	assert_eq((r["suggestions"] as Array).size(), 0, "无解盘不得返回任何建议")
	assert_true(str(r["reason"]).find("矛盾") != -1, "原因要点明是矛盾：%s" % str(r["reason"]))


# ==================== 4. 规模护栏：超限 ⇒ exhaustive=false 且不崩 ====================

func test_candidate_cap_marks_search_not_exhaustive() -> void:
	var d := _guessy_doc()
	# 该盘共有 3 条候选（1 条加线索 + 2 条挪雷）⇒ 上限压到 1 必然搜不完
	var r := RepairSuggest.suggest(d, {"max_candidates": 1})
	assert_false(bool(r["exhaustive"]), "候选超硬上限时必须如实标记 exhaustive=false（不许谎称最优）")
	assert_true(str(r["reason"]).length() > 0, "仍应给出可读原因")
	assert_true(int(r["searched"]) <= 1, "试执行条数不得超过上限")
	for s in r["suggestions"]:
		assert_true(bool((s as Dictionary)["verified"]), "即便搜不完，返回的每条也必须已验证")


# ==================== 5. 已可解 ⇒ 无需修复 ====================

func test_already_solvable_board_needs_no_repair() -> void:
	var d := _solvable_doc()
	assert_eq(str(EditorVerify.verify_islands(d)["state"]), EditorVerify.STATE_NO_GUESS,
		"前提：该盘应无需猜测可解")
	var r := RepairSuggest.suggest(d)
	assert_true(bool(r["ok"]), "已可解的盘不算失败")
	assert_eq((r["suggestions"] as Array).size(), 0, "无需修复时不该硬塞建议")
	assert_true(bool(r["exhaustive"]), "无需搜索 ⇒ 不存在「没搜完」")
	assert_true(str(r["reason"]).find("无需修复") != -1, "原因应说明无需修复：%s" % str(r["reason"]))


# ==================== 6. 一键应用：改文档后自动重跑校验 ====================

func test_apply_plan_mutates_doc_and_reverifies() -> void:
	var d := _guessy_doc()
	var r := RepairSuggest.suggest(d)
	assert_gt((r["suggestions"] as Array).size(), 0, "前提：应拿到建议")
	var plan: Dictionary = (r["suggestions"] as Array)[0]["plan"]

	var applied := RepairSuggest.apply_plan(d, plan)
	assert_true(bool(applied["ok"]), "一键应用应成功：%s" % str(applied["reason"]))
	assert_true(bool(applied["applied"]), "applied 标记应为 true")
	assert_eq(str((applied["verify"] as Dictionary)["state"]), EditorVerify.STATE_NO_GUESS,
		"应用后应自动重跑校验并判为可解")
	# 应用确实改了文档（与"试执行不改原件"形成对照）
	var again := EditorVerify.verify_islands(d)
	assert_eq(str(again["state"]), EditorVerify.STATE_NO_GUESS, "文档本身也应变成可解")

	# 非法计划：不得改动文档
	var snapshot := JSON.stringify(d.snapshot())
	var bad := RepairSuggest.apply_plan(d, {"op": "move_mine", "from": {"c": -1, "r": -1}, "to": {"c": 0, "r": 0}})
	assert_false(bool(bad["ok"]), "非法计划应被拒绝")
	assert_eq(JSON.stringify(d.snapshot()), snapshot, "被拒绝的计划不得改动文档")
