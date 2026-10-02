# test_editor_verify.gd —— 编辑器逻辑验证器（EditorVerify）自证
#
# 四态各用**确定性构造**钉住（不靠随机盘，避免 flaky）：
#   * 无需猜测可解：3x3 单雷 + 只翻开 (0,0)——由 0 值约束连锁推出，必然可推完；
#   * 可能需要猜测：9x9 十颗雷 + 只翻开 (4,4)（值 2，0 < 2 < 度数-1 ⇒ 单条线索钉不住任何一格）；
#   * 存在逻辑矛盾：翻开全部安全格 + 声明雷数 > 可能的最大值（隐藏格只有 2 个却要 5 颗雷）；
#   * 未知：文档没通过校验 / 预算耗尽（1ms）。
# 另钉两条设计约束：验证器**不注册规则**（不污染全局表）、无后端时的组合数预检必须拦住大棋盘。
extends GutTest


func _doc(p_rows: int, p_cols: int, mine_list: Array) -> EditorDoc:
	var d := EditorDoc.new(p_rows, p_cols)
	for m in mine_list:
		d.mines.append(m)
	return d


func _reveal_all_safe(d: EditorDoc) -> void:
	for y in d.rows:
		for x in d.cols:
			var p := Vector2i(x, y)
			if not d.mines.has(p):
				d.revealed[p] = null


func _classic_spec(id: String) -> Dictionary:
	var refs: Array = []
	for d in ClueEngine.ring_dirs():
		refs.append({"dx": d.x, "dy": d.y})
	var xs: Array = []
	for i in refs.size():
		xs.append({"t": "ref", "i": i})
	return {
		"spec_version": 1, "id": id, "title": "验证器测试用经典8邻", "geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}},
	}


# ==================== 1. 无需猜测可解 ====================

func test_no_guess_on_a_fully_deducible_board() -> void:
	# 3x3、雷在 (2,2)、只翻开 (0,0)：其值为 0 ⇒ 邻格全安全 ⇒ 再由 (1,1) 的 1 推出 (2,2) 是雷
	var d := _doc(3, 3, [Vector2i(2, 2)])
	d.revealed[Vector2i(0, 0)] = null
	var r := EditorVerify.verify(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_NO_GUESS,
		"可完全演绎的盘应为无需猜测（实际：%s / %s）" % [str(r["state"]), str(r["reason"])])
	# 「解数」衡量的是**线索集是否唯一确定雷分布**，与「可否无猜推出」是两件事：
	# 本盘只钉住 (2,2) 是雷，其余 5 个格都满足线索（多解），但仍可完全演绎 ⇒ 故只断言 >= 1。
	assert_true(int((r["stats"] as Dictionary)["solutions"]) >= 1, "应至少有一个解")
	assert_eq(int((r["stats"] as Dictionary)["forced_mine"]), 1, "应推出 1 颗雷")
	assert_gt(int((r["stats"] as Dictionary)["forced_safe"]), 0, "应推出若干安全格")


# ==================== 2. 可能需要猜测 ====================

func test_needs_guess_when_one_clue_cannot_pin_anything() -> void:
	# (4,4) 的 8 邻里有 2 颗雷（(3,3) 与 (5,5)），其余 8 颗雷远在一角 ⇒ 单条线索钉不住任何一格
	var mine_list := [
		Vector2i(3, 3), Vector2i(5, 5),
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(2, 2),
	]
	var d := _doc(9, 9, mine_list)
	d.revealed[Vector2i(4, 4)] = null
	var r := EditorVerify.verify(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_NEEDS_GUESS,
		"单条线索、0<值<度数-1 时应判为需要猜测（实际：%s / %s）" % [str(r["state"]), str(r["reason"])])
	assert_eq(int((r["stats"] as Dictionary)["solutions"]), 2, "多解应按 2 截断报告")


# ==================== 3. 存在逻辑矛盾 ====================

func test_contradiction_when_declared_mines_cannot_fit() -> void:
	# 全部安全格都翻开 ⇒ 约束把 23 个格钉成非雷，只剩 2 个隐藏格；
	# 却声明总雷数 5 ⇒ 无解 ⇒ 必须报"存在逻辑矛盾"（而不是被静默修正成 2）
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(4, 4)])
	_reveal_all_safe(d)
	d.declared_total_mines = 5
	var r := EditorVerify.verify(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_CONTRADICTION,
		"声明雷数不可能满足时应报矛盾（实际：%s / %s）" % [str(r["state"]), str(r["reason"])])
	assert_true(str(r["reason"]).find("矛盾") != -1, "理由里应点明矛盾：%s" % str(r["reason"]))


# ==================== 4. 未知 ====================

func test_invalid_doc_yields_unknown_not_a_guess() -> void:
	var d := EditorDoc.new(5, 5)   # 没放雷 ⇒ 校验不过
	var r := EditorVerify.verify(d)
	assert_eq(str(r["state"]), EditorVerify.STATE_UNKNOWN, "文档不合法时不得给出可解/需猜结论")
	assert_true(str(r["reason"]).find("校验") != -1, "理由应点明校验未过：%s" % str(r["reason"]))
	assert_true((r["issues"] as Array).size() > 0, "应把具体的校验问题带出来（UI 要显示）")


func test_time_budget_exhaustion_reports_unknown() -> void:
	var d := _doc(9, 9, [Vector2i(0, 0), Vector2i(2, 3), Vector2i(4, 4), Vector2i(6, 1), Vector2i(8, 8)])
	var r := EditorVerify.verify(d, {"total_budget_ms": 1})
	assert_eq(str(r["state"]), EditorVerify.STATE_UNKNOWN, "预算耗尽必须如实报未知，不能猜")
	assert_true(str(r["reason"]).find("预算") != -1, "理由应点明预算：%s" % str(r["reason"]))


# ==================== 5. 设计约束 ====================

func test_verifier_does_not_register_the_rule() -> void:
	# 验证全程只用内存实例 + IR ⇒ 编辑器里随便试规则不该污染全局注册表
	var sid := "spec_verify_probe_%d" % randi()
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)])
	d.rule_spec = _classic_spec(sid)
	var r := EditorVerify.verify(d)
	assert_true([EditorVerify.STATE_NO_GUESS, EditorVerify.STATE_NEEDS_GUESS,
		EditorVerify.STATE_CONTRADICTION, EditorVerify.STATE_UNKNOWN].has(str(r["state"])),
		"应返回四态之一：%s" % str(r["state"]))
	assert_null(RuleRegistry.default().resolve(StringName(sid)),
		"验证器不得把规则注册进全局表（否则编辑器每改一次规则就留一条）")


func test_fallback_combo_guard_rejects_huge_enumeration() -> void:
	# 无后端时的组合数预检：9x9 / 10 雷远超上限 ⇒ 必须拒绝启动 GDScript 枚举（否则会长时间占住编辑器）
	var d := _doc(9, 9, [Vector2i(0, 0), Vector2i(2, 3), Vector2i(4, 4), Vector2i(6, 1), Vector2i(8, 8),
		Vector2i(1, 7), Vector2i(3, 5), Vector2i(5, 2), Vector2i(7, 6), Vector2i(8, 0)])
	var pv := d.preview_clues()
	var values: Dictionary = pv["values"]
	# 只翻开 (5,5)（它不是雷）⇒ 自由格约 80、需要 10 颗 ⇒ C(80,10) ≈ 1.6e12，远超上限。
	# 刻意**不用** suggest_reveal()：0 值闭包会白送几十个安全格，组合数可能反而落在上限内
	#（本用例的第一版就是这么写的，被"守卫返回 true"打回——守卫是对的，是用例选错了盘）。
	var active: Dictionary = {Vector2i(5, 5): values.get(Vector2i(5, 5), null)}
	var oracle := RuleOracle.new(d.rule_object(), [], Vector2i(9, 9), 10, null)
	var spec := oracle.build_spec(active, [])
	assert_false(EditorVerify._fallback_cheap_enough(spec),
		"9x9/10 雷的组合数应被判为超限（这条守卫就是防「验证时卡死」的）")


func test_wrap_board_verification_returns_a_valid_state() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 2), Vector2i(3, 3), Vector2i(4, 4), Vector2i(2, 0)])
	d.wrap = true
	var r := EditorVerify.verify(d)
	var ok := [EditorVerify.STATE_NO_GUESS, EditorVerify.STATE_NEEDS_GUESS,
		EditorVerify.STATE_CONTRADICTION, EditorVerify.STATE_UNKNOWN].has(str(r["state"]))
	assert_true(ok, "环绕盘必须给出四态之一：%s" % str(r["state"]))
	assert_true((r["stats"] as Dictionary).has("backend"), "应带后端信息（UI 要显示用的是哪个后端）")
	assert_true(str(r["label"]).length() > 0, "应带中文标签供 UI 直接用")


func test_state_labels_are_distinct() -> void:
	var labels := {}
	for s in [EditorVerify.STATE_NO_GUESS, EditorVerify.STATE_NEEDS_GUESS,
			EditorVerify.STATE_CONTRADICTION, EditorVerify.STATE_UNKNOWN]:
		labels[EditorVerify.state_label(s)] = true
	assert_eq(labels.size(), 4, "四个状态的中文标签必须各不相同")
