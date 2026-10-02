# test_spec_helper.gd —— 零代码创作路径（给 AI 的话 / 宽容解析 / 白话解释 / 报错翻译 / 配方）
#
# 这一层是"小白不会写 JSON"的唯一依靠，所以断言必须钉在**真实输入形态**上：
#   · AI 的回复带解释文字、``` 围栏、注释（不是干净的 JSON）；
#   · 提示词必须自包含（对方的 AI 看不到本仓库，也看不到《变体规则编写规范》）；
#   · 提示词必须**指定该用哪种 geometry**（选错是唯一一个"校验能过、数字却全错"的坑）；
#   · 配方必须真的能在盘上算出数字（能注册 ≠ 能用）。
extends GutTest


var _registered: Array[String] = []


func after_each() -> void:
	# 注册表是进程级单例（core/rule_registry.gd:32-39，且没有 clear()）：
	# 本文件会注册配方 id，必须逐个注销，否则会污染别的套件（尤其那条"枚举全表"的归纳测试）。
	for rid in _registered:
		RuleRegistry.default().unregister(StringName(rid))
	_registered.clear()


func _register(spec: Dictionary) -> Dictionary:
	var r := SpecRulePlugin.register_from_json(JSON.stringify(spec))
	if bool(r.get("ok", false)):
		_registered.append(str(r.get("id", spec.get("id", ""))))
	return r


func _recipe(id: String) -> Dictionary:
	for r in SpecHelper.recipes():
		if str(r["id"]) == id:
			return r
	return {}


## 5×5、（0,0）/（1,1）/（2,2）三颗雷的文档；可带规则规格。
func _doc_with(spec: Dictionary = {}) -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]:
		d.mines.append(m)
	if not spec.is_empty():
		d.rule_spec = spec
	return d


## 按给定方向集合数雷（测试自算期望值，不用被测代码算）。
func _count_dirs(rows: int, cols: int, mines: Array, dirs: Array) -> Dictionary:
	var ms := {}
	for m in mines:
		ms[m] = true
	var out := {}
	for y in rows:
		for x in cols:
			var p := Vector2i(x, y)
			if ms.has(p):
				continue
			var n := 0
			for dd in dirs:
				var q := p + (dd as Vector2i)
				if q.x >= 0 and q.y >= 0 and q.x < cols and q.y < rows and ms.has(q):
					n += 1
			out[p] = n
	return out


func _mismatch(a: Dictionary, b: Dictionary) -> int:
	var bad := 0
	if a.size() != b.size():
		return 999
	for k in a:
		if not b.has(k) or int(b[k]) != int(a[k]):
			bad += 1
	return bad


# ==================== 1. 提示词 ====================

func test_ai_prompt_is_self_contained() -> void:
	# 对方的 AI 看不到本仓库 ⇒ 提示词必须自带：字段表 / 原子表 / 硬约束 / 正确示例 / 输出格式
	var p := SpecHelper.ai_prompt({})
	for token in ["spec_version", "spec_", "geometry", "rect_only", "adj_generic", "topo",
			"clue", "refs", "expr", "ref", "sum", "wsum", "const", "title",
			"json 代码块", "不要写 GDScript", "做不到"]:
		assert_true(p.find(token) != -1, "提示词必须包含「%s」" % token)
	# 必须含至少一个**能直接照抄**的完整示例（否则 AI 会自由发挥字段名）
	assert_true(p.find("\"spec_version\": 1") != -1, "提示词里必须有可照抄的完整示例")
	assert_true(p.find("max") != -1, "示例里要带 max 字段")


func test_ai_prompt_does_not_repeat_the_retired_end_to_end_gap() -> void:
	# 规范文档 §12.4 里曾有一条"refs=topo 只在生成侧可用"的告警，该缺口已修（2026-10-01）。
	# 提示词若抄到它，会让我们自己发出去的话术撒谎 ⇒ 反向钉住。
	var p := SpecHelper.ai_prompt({})
	assert_eq(p.find("端到端缺口"), -1, "提示词不得再出现已修复的端到端缺口说法")
	assert_eq(p.find("只在生成侧"), -1, "提示词不得再说「只在生成侧可用」")


func test_ai_prompt_tells_the_ai_which_geometry_to_use() -> void:
	# 选错 geometry 是唯一一个"校验通过但数字全错"的坑：
	# 普通方盘没有邻接表，refs="topo" 会走 compute_clue 返回 empty_value（全 0）。
	var plain := SpecHelper.ai_prompt({"rows": 9, "cols": 9, "mines": 10})
	assert_true(plain.find("普通矩形棋盘") != -1, "方盘应说明是普通矩形盘")
	assert_true(plain.find("rect_only") != -1, "方盘必须指定用 rect_only")
	assert_true(plain.find("全是 0") != -1, "方盘必须警告 topo 写法会算不出数字")

	var wrapped := SpecHelper.ai_prompt({"rows": 9, "cols": 9, "wrap": true})
	assert_true(wrapped.find("环绕") != -1, "环绕盘应说明边界相通")
	assert_true(wrapped.find("adj_generic") != -1, "环绕盘应指定用 adj_generic")

	var shaped := SpecHelper.ai_prompt({"shape": "蜂窝六边形"})
	assert_true(shaped.find("蜂窝六边形") != -1, "形状盘应把盘型告诉 AI")
	assert_true(shaped.find("adj_generic") != -1, "形状盘应指定用 adj_generic")


func test_ai_prompt_embeds_the_users_own_words() -> void:
	var p := SpecHelper.ai_prompt({"idea": "数字 = 斜角算双倍"})
	assert_true(p.find("数字 = 斜角算双倍") != -1, "用户的想法必须原样出现在提示词里")
	assert_true(SpecHelper.ai_prompt({}).find("我还没想好") != -1, "没写想法时要给默认建议（不能空着）")


func test_idea_examples_are_usable_sentences() -> void:
	var ex := SpecHelper.idea_examples()
	assert_gt(ex.size(), 2, "应给若干个可直接点的想法示例")
	var bad := 0
	for s in ex:
		if str(s).strip_edges() == "" or str(s).find("数字") == -1:
			bad += 1
	assert_eq(bad, 0, "每条示例都应是一句可读的规则想法")


# ==================== 2. 宽容解析 ====================

func test_extract_json_handles_real_ai_replies() -> void:
	var good := "{\"spec_version\":1,\"id\":\"spec_a\",\"title\":\"t\",\"clue\":{\"refs\":\"topo\",\"expr\":{\"t\":\"const\",\"v\":0}}}"
	var cases: Array = [
		["纯 JSON", good, true],
		["带解释 + ```json 围栏", "好的，这是你的规则：\n```json\n%s\n```\n希望对你有帮助！" % good, true],
		["无语言标记的围栏", "```\n%s\n```" % good, true],
		["标题里带大括号", "```json\n{\"title\":\"带 { 的标题\",\"spec_version\":1}\n```", true],
		["多个代码块（第一个是坏的）", "```json\n{ 坏的\n```\n再试一次：\n```json\n%s\n```" % good, true],
		["纯废话", "我没有看懂你的需求，请再说明一次。", false],
		["空字符串", "", false],
	]
	var bad := 0
	for c in cases:
		var r := SpecHelper.extract_json(str(c[1]))
		if bool(r["ok"]) != bool(c[2]):
			bad += 1
			gut.p("「%s」期望 ok=%s，实际 %s（%s）" % [str(c[0]), str(c[2]), str(r["ok"]), str(r["errors"])])
		elif bool(r["ok"]) and (r["data"] as Dictionary).is_empty():
			bad += 1
			gut.p("「%s」解析出的对象为空" % str(c[0]))
	assert_eq(bad, 0, "真实 AI 回复的各种形态都必须能读懂")


func test_extract_json_mends_comments_not_silently() -> void:
	var r := SpecHelper.extract_json("```json\n{\n  // 这是说明\n  \"spec_version\": 1\n}\n```")
	assert_true(bool(r["ok"]), "夹着注释的 JSON 应能被兜底修好：%s" % str(r["errors"]))
	assert_true(str(r["note"]).find("自动修") != -1, "修过就必须在结果里说明（不许静默）")


func test_godot_json_tolerates_trailing_commas_so_we_do_not_patch_them() -> void:
	# 这条用例**钉住一条引擎行为**，也是"为什么不写去逗号的兜底代码、也不声称有"的证据：
	# Godot 的 JSON 解析器接受尾随逗号 ⇒ 我们不需要修补它。
	# 若哪天引擎收紧了这个行为，这条会红，届时再补兜底不迟（此前那段代码永远走不到，
	# 是"看起来在干活"的死分支，已按本仓纪律删除）。
	var r := SpecHelper.extract_json("```json\n{\"spec_version\": 1, \"id\": \"spec_x\",}\n```")
	assert_true(bool(r["ok"]), "尾随逗号应能被引擎直接接受：%s" % str(r["errors"]))
	assert_eq(str(r["note"]), "", "引擎自己就能读，就不该虚报「已自动修过」")


func test_extract_json_does_not_break_on_braces_inside_strings() -> void:
	# 直接 last_index_of("}") 会切坏；必须跳过字符串内部的括号
	var text := "```json\n{\"title\":\"a { b } c\",\"id\":\"spec_x\",\"spec_version\":1}\n```"
	var r := SpecHelper.extract_json(text)
	assert_true(bool(r["ok"]), "字符串里的大括号不该影响取 JSON：%s" % str(r["errors"]))
	assert_eq(str((r["data"] as Dictionary).get("title", "")), "a { b } c", "字符串内容必须逐字保留")


func test_extract_json_reports_failure_with_a_next_step() -> void:
	var r := SpecHelper.extract_json("抱歉，我需要更多信息。")
	assert_false(bool(r["ok"]), "没有 JSON 时必须如实报失败")
	assert_true(str(r["errors"]).find("粘") != -1, "失败提示要告诉用户怎么给（整段粘进来）")


# ==================== 3. 类型判定 ====================

func test_kind_of_detects_spec_level_and_manifest() -> void:
	var cases: Array = [
		["spec", {"spec_version": 1, "id": "spec_x", "title": "t", "clue": {}}],
		["spec", {"id": "spec_x", "globals": []}],
		["level", {"size": {"rows": 5, "cols": 5}, "mines": []}],
		["level", {"name": "x", "total_mines": 3}],
		["manifest", {"id": "mymod", "version": "1.0", "entry": {"path": "entry.gd"}}],
		["unknown", {"hello": 1}],
	]
	var bad := 0
	for c in cases:
		var got := SpecHelper.kind_of(c[1])
		if got != str(c[0]):
			bad += 1
			gut.p("期望 %s，实际 %s（%s）" % [str(c[0]), got, str(c[1])])
	assert_eq(bad, 0, "必须能分辨「规则 / 关卡 / 清单」，才能分流到正确入口")


# ==================== 4. 白话解释 ====================

func test_explain_spec_says_it_in_plain_chinese() -> void:
	var r8 := (_recipe("spec_r8")["spec"] as Dictionary)
	var t := SpecHelper.explain_spec(r8)
	assert_true(t.find("周围") != -1, "配方名要说人话：%s" % t)
	assert_true(t.find("雷数之和") != -1, "要直接说成「雷数之和」，不能打印 8 个下标")
	assert_true(t.find("矩形盘") != -1, "必须说明适用棋盘")
	assert_true(t.find("有雷的格子不显示数字") != -1, "要说明雷格不显示数字")

	var topo := (_recipe("spec_anyneighbors")["spec"] as Dictionary)
	var tt := SpecHelper.explain_spec(topo)
	assert_true(tt.find("相邻格") != -1, "topo 形态要说成「相邻格」")
	assert_true(tt.find("普通方盘") != -1, "必须提醒方盘上会算成 0（这是最容易踩的坑）")


func test_explain_spec_describes_the_plus_one_shift() -> void:
	var r := SpecHelper.explain_spec(_recipe("spec_r8_plus1")["spec"])
	assert_true(r.find("再加 1") != -1, "「加偏移」要说成人话：%s" % r)


func test_explain_spec_is_honest_when_the_spec_is_invalid() -> void:
	var broken := {"spec_version": 1, "id": "spec_broken", "clue": {"refs": "topo", "expr": {"t": "const", "v": 0}}}
	var t := SpecHelper.explain_spec(broken)
	assert_true(t.find("不能生效") != -1, "缺 title 的规格必须被说成「还不能生效」：%s" % t)


# ==================== 5. 报错翻译 ====================

func test_friendly_translates_errors_with_actionable_hints() -> void:
	# 真实会遇到的组合：固定偏移 + 缺 geometry（AI 最常忘的一行）
	var spec := {"spec_version": 1, "id": "spec_ai_x", "title": "t",
		"clue": {"refs": [{"dx": 0, "dy": -1}], "expr": {"t": "sum", "xs": [{"t": "ref", "i": 0}]}}}
	var items := SpecHelper.friendly(SpecSchema.validate(spec))
	assert_gt(items.size(), 0, "必须给出至少一条问题")
	var hit := 0
	for it in items:
		if str((it as Dictionary)["hint"]).find("rect_only") != -1:
			hit += 1
	assert_eq(hit, 1, "缺 geometry 必须给出「加 rect_only」的可执行建议：%s" % str(items))


func test_friendly_mentions_replacement_when_the_id_is_taken() -> void:
	var spec := (_recipe("spec_r8")["spec"] as Dictionary)
	var reg := _register(spec)
	assert_true(bool(reg["ok"]), "先注册一份配方用于制造重复 id：%s" % str(reg["errors"]))
	var items := SpecHelper.friendly(SpecSchema.validate(spec))
	var hit := 0
	for it in items:
		if str((it as Dictionary)["hint"]).find("替换") != -1:
			hit += 1
	assert_eq(hit, 1, "重复 id 要告诉用户「同名会被替换」，而不是让他去手改 JSON")


func test_friendly_falls_back_to_the_ai_repair_loop() -> void:
	var items := SpecHelper.friendly({"errors": ["某个全新的、还没写关键词规则的错误"], "warnings": []})
	assert_eq(items.size(), 1, "一条错误对应一条说明")
	var it: Dictionary = items[0]
	assert_eq(str(it["level"]), "error", "错误的级别必须是 error")
	assert_true(str(it["hint"]).find("让 AI 修") != -1, "认不出的错误必须回退到「交给 AI 修」：%s" % str(it))


func test_friendly_explains_the_topo_warning_in_plain_words() -> void:
	var topo := _recipe("spec_anyneighbors")["spec"] as Dictionary
	var v := SpecSchema.validate(topo)
	assert_gt((v["warnings"] as PackedStringArray).size(), 0, "topo 规格应带不阻断告警")
	var items := SpecHelper.friendly(v)
	var hit := 0
	for it in items:
		if str((it as Dictionary)["level"]) == "warn" and str((it as Dictionary)["hint"]).find("方盘") != -1:
			hit += 1
	assert_eq(hit, 1, "compute_clue_na 的白话要落到「方盘上会是 0」这条可行动的提醒上")


# ==================== 6. 让 AI 修 ====================

func test_repair_prompt_carries_errors_and_hard_rules() -> void:
	var p := SpecHelper.repair_prompt("```json\n{\"a\":1}\n```", PackedStringArray(["id 必须以 spec_ 开头"]))
	assert_true(p.find("id 必须以 spec_ 开头") != -1, "必须把校验器原文带上（AI 才知道错在哪）")
	assert_true(p.find("只输出一个 json 代码块") != -1, "必须重申输出格式")
	assert_true(p.find("spec_version") != -1, "必须重申硬约束")
	assert_true(p.find("{\"a\":1}") != -1, "必须把上次的 JSON 带回去（否则 AI 会重写一份不相干的）")
	var empty := SpecHelper.repair_prompt("", [])
	assert_true(empty.find("没能从你的回复里读出") != -1, "解析失败时也要能生成一段可发的话")


# ==================== 7. 配方库 ====================

func test_every_recipe_passes_the_schema_and_registers() -> void:
	var rs := SpecHelper.recipes()
	assert_gt(rs.size(), 3, "配方库应有若干条，覆盖常见玩法")
	var bad := 0
	var explain_bad := 0
	for r in rs:
		var spec: Dictionary = r["spec"]
		var v := SpecSchema.validate(spec)
		if not bool(v["ok"]):
			bad += 1
			gut.p("配方 %s 校验失败：%s" % [str(r["id"]), str(v["errors"])])
			continue
		# 白话解释必须在**注册前**查：注册之后再 validate 会撞「id 已被注册」，
		# 那是测试自己造成的污染，不是配方有问题（第一版就把它误报成配方缺陷）。
		if SpecHelper.explain_spec(spec).find("不能生效") != -1:
			explain_bad += 1
			gut.p("配方 %s 的白话解释说自己不可用" % str(r["id"]))
		var reg := _register(spec)
		if not bool(reg["ok"]):
			bad += 1
			gut.p("配方 %s 注册失败：%s" % [str(r["id"]), str(reg["errors"])])
	assert_eq(bad, 0, "每条配方都必须能通过校验并注册（这是零 AI 路径的底线）")
	assert_eq(explain_bad, 0, "每条配方都必须能被白话解释成一条可用规则")


func test_recipe_ids_are_unique_and_prefixed() -> void:
	var seen := {}
	var bad := 0
	for r in SpecHelper.recipes():
		var id := str(r["id"])
		if not id.begins_with("spec_") or seen.has(id):
			bad += 1
		seen[id] = true
	assert_gt(seen.size(), 3, "配方数量")
	assert_eq(bad, 0, "配方 id 必须以 spec_ 开头且互不重复")


func test_rect_recipes_compute_the_numbers_they_promise() -> void:
	# 「能注册」不等于「能用」：逐条与测试自算的期望值对拍（不用被测代码算期望）。
	var mines: Array = [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)]
	var cases: Array = [
		["spec_r8", ClueEngine.ring_dirs(), 0],
		["spec_orth4", [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)], 0],
		["spec_diag4", [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)], 0],
		["spec_r8_plus1", ClueEngine.ring_dirs(), 1],
	]
	var bad := 0
	for c in cases:
		var rec := _recipe(str(c[0]))
		var want := _count_dirs(5, 5, mines, c[1])
		if int(c[2]) != 0:
			for k in want:
				want[k] = int(want[k]) + int(c[2])
		var d := _doc_with(rec["spec"])
		var got: Dictionary = d.preview_clues()["values"]
		var m := _mismatch(want, got)
		if m != 0:
			bad += 1
			gut.p("配方 %s 与期望不符：mismatch=%d" % [str(c[0]), m])
	assert_eq(bad, 0, "每条方盘配方算出的数字都必须与手算期望一致")


func test_topo_recipe_needs_a_table_and_says_so() -> void:
	var rec := _recipe("spec_anyneighbors")
	assert_true(str(rec["note"]).find("环绕") != -1, "配方卡必须写明它只对环绕/异形盘有意义")

	# 1) 普通方盘：必须给出"数字会是 0"的告警（否则小白看到满屏 0 会以为编辑器坏了）
	var d := _doc_with(rec["spec"])
	var rep := d.validate()
	var flagged := 0
	for w in rep["warnings"]:
		if str((w as Dictionary)["code"]) == "topo_needs_table":
			flagged += 1
	assert_eq(flagged, 1, "普通方盘 + refs=topo 必须告警并可定位：%s" % str(rep["warnings"]))

	# 2) 换成环绕盘：告警消失，且真的算出非零数字（证明这条路走得通）
	d.wrap = true
	var rep2 := d.validate()
	var still := 0
	for w in rep2["warnings"]:
		if str((w as Dictionary)["code"]) == "topo_needs_table":
			still += 1
	assert_eq(still, 0, "环绕盘有邻接表，不该再报该告警")
	var vals: Dictionary = d.preview_clues()["values"]
	var peak := 0
	for k in vals:
		peak = maxi(peak, int(vals[k]))
	assert_gt(peak, 0, "环绕盘上「相邻格求和」必须真的算出非零数字")


# ==================== 8. 注册表查询 ====================

func test_is_replaceable_spec_only_accepts_spec_rules() -> void:
	var spec := (_recipe("spec_orth4")["spec"] as Dictionary)
	assert_false(SpecHelper.is_replaceable_spec("spec_orth4"), "还没注册时不该认为可替换")
	var reg := _register(spec)
	assert_true(bool(reg["ok"]), "注册应成功：%s" % str(reg["errors"]))
	assert_true(SpecHelper.is_replaceable_spec("spec_orth4"), "本插件注册的规格规则可被新版本替换")
	assert_false(SpecHelper.is_replaceable_spec("classic"), "内置规则绝不允许被规格替换")
	assert_false(SpecHelper.is_replaceable_spec("mx"), "官方规则绝不允许被规格替换")
