# test_repair_can_apply.gd —— 修复建议「能不能落笔」判据的**单一真相源**自证（2026-10-03）。
#
# 背景：UI 侧原本抄了一份 `RepairSuggest._apply` 的 5 条判据（动机是"不适用就不该白记一步撤销"），
# 但两份真相会漂移 ⇒ 本轮把判据收进 `core/repair_suggest.gd:_plan_reason()`，并开公开纯函数
# `can_apply(plan, doc)` 供 UI 先问。本文件钉住：
#   ① `can_apply` 对"过期 / 不适用 / 未知"的 plan 一律 ok=false + **非空可读原因**，且**纯读无副作用**；
#   ② `can_apply`（探测）与 `apply_plan`（执行）对同一批 plan **同判** —— 这是"判据唯一"的核心钉子；
#   ③ `suggest()` 自己给出的 plan 必然通过 `can_apply`（真实路径不打架）。
extends GutTest

const RepairSuggest := preload("res://core/repair_suggest.gd")


## 确定性「需要猜测」小盘：1×4、雷 (0,0)(3,0)、只翻开 (1,0)。
func _guessy_doc() -> EditorDoc:
	var d := EditorDoc.new(1, 4)
	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(3, 0))
	d.revealed[Vector2i(1, 0)] = null
	return d


## 与 `RepairSuggest._copy` 同法：从快照造副本（探测/执行对照时用，绝不动原件）。
func _copy_of(d: EditorDoc) -> EditorDoc:
	var c := EditorDoc.new()
	assert_true(c.restore(d.snapshot()), "前提：快照恢复应成功")
	return c


## 真带洞的盘：11×11 坐标框上的环形 annulus（外径 5 / 内径 2）⇒ 存在「包围盒内但不在盘上」的格。
func _holed_doc() -> EditorDoc:
	var d := EditorDoc.new(11, 11)
	d.shape_kind = "annulus"
	d.shape_params = {"outer_radius": 5, "inner_radius": 2}
	return d


func _first_in_board(d: EditorDoc) -> Vector2i:
	for y in d.rows:
		for x in d.cols:
			var p := Vector2i(x, y)
			if d.grid().in_board(p):
				return p
	return Vector2i(-1, -1)


func _first_off_board(d: EditorDoc) -> Vector2i:
	for y in d.rows:
		for x in d.cols:
			var p := Vector2i(x, y)
			if not d.grid().in_board(p):
				return p
	return Vector2i(-1, -1)


# ==================== ① 拒绝 + 可读原因 + 纯读 ====================

func test_can_apply_rejects_with_readable_reason_and_never_touches_doc() -> void:
	var d := _guessy_doc()
	var before := JSON.stringify(d.snapshot())
	# [plan, 原因里必须出现的字样]
	var cases := [
		[{"op": "move_mine", "from": {"c": 1, "r": 0}, "to": {"c": 2, "r": 0}}, "没有雷"],
		[{"op": "add_clue", "cell": {"c": 0, "r": 0}}, "已经是雷"],
		[{"op": "add_clue", "cell": {"c": 1, "r": 0}}, "已经"],
		[{"op": "add_clue", "cell": {"c": 9, "r": 9}}, "不在盘上"],
		[{"op": "move_mine", "from": {"c": 0, "r": 0}, "to": {"c": 3, "r": 0}}, "占用"],
		[{"op": "move_mine", "from": {"c": 0, "r": 0}, "to": {"c": -1, "r": 0}}, "不在盘上"],
		[{"op": "布尔修法", "cell": {"c": 2, "r": 0}}, "未知修法"],
		[{}, "未知修法"],
	]
	for c in cases:
		var plan: Dictionary = c[0]
		var r: Dictionary = RepairSuggest.can_apply(plan, d)
		assert_false(bool(r["ok"]), "该 plan 不该被判可用：%s" % str(plan))
		assert_true(str(r["reason"]).length() > 0, "ok=false 必须给非空原因：%s" % str(plan))
		assert_true(str(r["reason"]).find(str(c[1])) != -1,
			"原因要说清是哪一类问题（应含「%s」）：%s" % [str(c[1]), str(r["reason"])])
	# 纯读：探测不许改文档（这是 UI「先问再决定要不要记撤销步」的前提）
	assert_eq(JSON.stringify(d.snapshot()), before, "can_apply 必须无副作用（纯读）")


func test_can_apply_accepts_valid_plans() -> void:
	var d := _guessy_doc()
	# add_clue 到隐藏安全格（2,0）；move_mine 从 (0,0) 挪到 (2,0)
	for plan in [{"op": "add_clue", "cell": {"c": 2, "r": 0}, "value": 1},
			{"op": "move_mine", "from": {"c": 0, "r": 0}, "to": {"c": 2, "r": 0}}]:
		var r: Dictionary = RepairSuggest.can_apply(plan, d)
		assert_true(bool(r["ok"]), "可用 plan 应 ok=true：%s（原因：%s）" % [str(plan), str(r["reason"])])
		assert_eq(str(r["reason"]), "", "可用 plan 的 reason 应为空串")
	# 空文档：也只是 ok=false + 原因（不崩）
	var null_r: Dictionary = RepairSuggest.can_apply({"op": "add_clue", "cell": {"c": 0, "r": 0}}, null)
	assert_false(bool(null_r["ok"]), "doc 为空应拒绝")
	assert_true(str(null_r["reason"]).length() > 0, "doc 为空也要给可读原因")


# ==================== ② 探测与执行同判（判据唯一的核心钉子） ====================

func test_can_apply_agrees_with_apply_plan_on_a_plan_matrix() -> void:
	var d := _guessy_doc()
	var before := JSON.stringify(d.snapshot())
	var plans := [
		{"op": "add_clue", "cell": {"c": 2, "r": 0}},                       # 可用
		{"op": "move_mine", "from": {"c": 0, "r": 0}, "to": {"c": 2, "r": 0}},  # 可用
		{"op": "add_clue", "cell": {"c": 0, "r": 0}},                       # 目标是雷
		{"op": "add_clue", "cell": {"c": 1, "r": 0}},                       # 已翻开
		{"op": "move_mine", "from": {"c": 2, "r": 0}, "to": {"c": 1, "r": 0}},  # 源格没雷
		{"op": "move_mine", "from": {"c": 0, "r": 0}, "to": {"c": 3, "r": 0}},  # 目标已被雷占用
		{"op": "unknown_op"},                                               # 未知修法
	]
	for i in plans.size():
		var plan: Dictionary = plans[i]
		var probe: Dictionary = RepairSuggest.can_apply(plan, d)
		var executed: Dictionary = RepairSuggest.apply_plan(_copy_of(d), plan)
		assert_eq(bool(probe["ok"]), bool(executed["ok"]),
			"第 %d 条 plan：探测与执行必须同判（probe=%s / exec=%s：%s）" % [
				i, str(probe["ok"]), str(executed["ok"]), str(executed["reason"])])
		if not bool(executed["ok"]):
			assert_true(_reason_contains(probe, executed),
				"第 %d 条：拒绝原因也该同源（probe=%s / exec=%s）" % [
					i, str(probe["reason"]), str(executed["reason"])])
	# 用副本执行 ⇒ 原件必须一字未变
	assert_eq(JSON.stringify(d.snapshot()), before, "对照用的 apply_plan 只许改副本，原件不得变动")


## 执行侧的拒绝原因里应含探测原因（apply_plan 前缀"计划无法执行："，其后是同一句判据文案）。
func _reason_contains(probe: Dictionary, executed: Dictionary) -> bool:
	var p := str(probe["reason"])
	return p.length() > 0 and str(executed["reason"]).find(p) != -1


# ==================== ③ 真实路径：suggest() 的 plan 必然可应用 ====================

func test_every_suggested_plan_passes_can_apply() -> void:
	var d := _guessy_doc()
	var r: Dictionary = RepairSuggest.suggest(d)
	assert_true(bool(r["ok"]), "前提：该盘应能给出建议：%s" % str(r["reason"]))
	var sugg: Array = r["suggestions"]
	assert_gt(sugg.size(), 0, "前提：应至少有 1 条建议")
	for s in sugg:
		var plan: Dictionary = (s as Dictionary)["plan"]
		var probe: Dictionary = RepairSuggest.can_apply(plan, d)
		assert_true(bool(probe["ok"]),
			"建议里的 plan 必须能通过 can_apply（否则 UI 会「显示得出、点不动」）：%s → %s" % [
				str(plan), str(probe["reason"])])


# ==================== ④ 判界口径：形状盘上「包围盒内但不在盘上」的目标必须被拒 ====================
#
# 【为什么用**构造的 plan** 而不是 `suggest()` 的产物】当前 `suggest()` 只从实例化岛的格出发，
# 产不出这种目标 ⇒ 这条路径**今天不可达、但可达性会变**（换候选空间 / 换调用方就能走到）。
# 这正是必须钉住的原因：判界口径回归成包围盒时，只有这种测试会红。

func test_can_apply_rejects_targets_inside_the_bbox_but_off_the_board() -> void:
	var d := _holed_doc()
	var hole := _first_off_board(d)
	assert_ne(hole, Vector2i(-1, -1), "前提：环形盘上必须存在「包围盒内但不在盘上」的格")
	assert_true(hole.x >= 0 and hole.y >= 0 and hole.x < d.cols and hole.y < d.rows,
		"前提：该格要在**包围盒内**（%s），否则测的不是这个 bug 类" % str(hole))
	# 把"旧口径会放行"这个前提也钉住：bbox 内 + 非障碍 ⇒ 旧的 `_plausible_target` 恰好会判 true。
	# 这一行就是本用例的**回归判据**（上方两条断言仍必须在）。
	assert_true(not d.obstacles.has(hole),
		"前提：该格不是显式障碍格（旧口径因此会误判可用，正是本用例要拦的回归）：%s" % str(hole))
	# ① 给洞格 / 轮廓外格加线索 ⇒ 必须被拒，且原因可读
	var add := {"op": "add_clue", "cell": {"c": hole.x, "r": hole.y}}
	var r1: Dictionary = RepairSuggest.can_apply(add, d)
	assert_false(bool(r1["ok"]), "bbox 内、盘外的格不许判为可用：%s" % str(hole))
	assert_true(str(r1["reason"]).find("不在盘上") != -1, "原因要说清「不在盘上」：%s" % str(r1["reason"]))
	# ② 把一颗**盘上**的雷挪到该格 ⇒ 同样必须被拒
	var mine := _first_in_board(d)
	d.mines.append(mine)
	var move := {"op": "move_mine",
		"from": {"c": mine.x, "r": mine.y}, "to": {"c": hole.x, "r": hole.y}}
	var r2: Dictionary = RepairSuggest.can_apply(move, d)
	assert_false(bool(r2["ok"]), "挪到盘外格不许判为可用：from=%s to=%s" % [str(mine), str(hole)])
	assert_true(str(r2["reason"]).find("不在盘上") != -1, "原因要说清「不在盘上」：%s" % str(r2["reason"]))
	# ③ 执行侧同判（判据唯一）且不许写坏文档：尤其不许落一条**不在盘上**的初始翻开格
	var before := JSON.stringify(d.snapshot())
	var applied: Dictionary = RepairSuggest.apply_plan(d, add)
	assert_false(bool(applied["ok"]), "apply_plan 也必须拒绝盘外目标")
	assert_eq(JSON.stringify(d.snapshot()), before, "被拒的 plan 不得改动文档")


func test_on_board_targets_still_pass_on_a_holed_board() -> void:
	# 防"一刀切拒绝"：盘上格必须照旧可用（否则正常修复路径被改死）。
	var d := _holed_doc()
	var mine := _first_in_board(d)
	d.mines.append(mine)
	for y in d.rows:
		for x in d.cols:
			var p := Vector2i(x, y)
			if not d.grid().in_board(p) or d.mines.has(p) or d.revealed.has(p):
				continue
			var add := {"op": "add_clue", "cell": {"c": p.x, "r": p.y}}
			assert_true(bool(RepairSuggest.can_apply(add, d)["ok"]),
				"盘上的隐藏安全格加线索应可用：%s" % str(p))
			var move := {"op": "move_mine",
				"from": {"c": mine.x, "r": mine.y}, "to": {"c": p.x, "r": p.y}}
			assert_true(bool(RepairSuggest.can_apply(move, d)["ok"]),
				"盘上的空格挪雷应可用：%s" % str(p))
			return
	fail_test("前提：环形盘上应存在至少一个「盘上且隐藏安全」的格")


func test_rect_board_bounds_still_behave_the_same() -> void:
	# 矩形盘回归：越界 / 障碍格照旧被拒，盘内普通格照旧可用（口径变更没伤到正交路径）。
	var d := EditorDoc.new(5, 5)
	d.mines.append(Vector2i(0, 0))
	d.obstacles.append(Vector2i(1, 1))
	assert_false(bool(RepairSuggest.can_apply({"op": "add_clue", "cell": {"c": 1, "r": 1}}, d)["ok"]),
		"障碍格（格不存在）必须被拒")
	assert_false(bool(RepairSuggest.can_apply({"op": "add_clue", "cell": {"c": 5, "r": 0}}, d)["ok"]),
		"越界格（x == cols）必须被拒")
	assert_false(bool(RepairSuggest.can_apply({"op": "add_clue", "cell": {"c": -1, "r": 0}}, d)["ok"]),
		"负坐标必须被拒")
	assert_true(bool(RepairSuggest.can_apply({"op": "add_clue", "cell": {"c": 2, "r": 2}}, d)["ok"]),
		"矩形盘上的普通空格应照旧可用")
