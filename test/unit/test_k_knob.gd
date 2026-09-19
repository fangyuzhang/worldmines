extends GutTest

## k 旋钮测试（o4/o5x，2026-09-16 实装）：k_ratio 生效 / k_public 落盘 / 公开档零影响 / o5x 契约。
## 实测依据：不公开盘 6×6 3/3 可生成（seed 200-202）、难度 1.21–2.60；5×5 无冗余全 FAIL（不回测）。


func before_all() -> void:
	for mod_name in ["o4_bianjing", "o5_xiemai", "o5_sanjiao"]:
		var script: Variant = load("res://demo/mods/%s/entry.gd" % mod_name)
		if script != null:
			script.new().call("on_load")


func after_each() -> void:
	var r4: Object = RuleRegistry.default().resolve(&"o4")
	if r4 != null:
		r4.call("set_k_ratio", 0.25)
		r4.call("set_k_public", true)
	var r5: Object = RuleRegistry.default().resolve(&"o5x")
	if r5 != null:
		r5.call("set_k_ratio", 0.25)
		r5.call("set_k_public", true)


func test_o4_k_ratio_effective() -> void:
	var rule: Object = RuleRegistry.default().resolve(&"o4")
	rule.call("set_k_ratio", 0.2)
	rule.call("place_mines", RandomNumberGenerator.new(), 8, 8, 26)
	assert_eq((rule.get("_r2") as Dictionary).size(), 12, "ratio=0.2 → k=12（floor(64×0.2)）")
	rule.call("set_k_ratio", 0.3)
	rule.call("place_mines", RandomNumberGenerator.new(), 8, 8, 26)
	assert_eq((rule.get("_r2") as Dictionary).size(), 19, "ratio=0.3 → k=19（floor(64×0.3)）")


func test_o4_k_public_false_marks_level() -> void:
	# 不公开（不知 k 口径）：6×6 实测 3/3 可生成，且落 k_public=false 标记
	var rule: Object = RuleRegistry.default().resolve(&"o4")
	rule.call("set_k_public", false)
	var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"o4", [], Vector2i(6, 6), 14, 200, 0, 50, null, 300_000)
	assert_false(lv.is_empty(), "6×6 不公开盘应可生成（无 Σw=k 演绎通过 = 满足 R01）")
	assert_eq(lv.get("k_public", true), false, "应落 k_public=false 标记")


func test_o4_k_public_true_default_no_flag() -> void:
	# 公开档（默认）：不写 k_public 字段（存量/产线零影响）。
	# 注：o4 在 5×5 设计停用（半径 2 退化，本就产不出）——用 6×6 验证。
	var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"o4", [], Vector2i(6, 6), 14, 300, 0, 50, null, 300_000)
	assert_false(lv.is_empty(), "公开档应可生成（6×6）")
	assert_false(lv.has("k_public"), "公开档不应有 k_public 字段")


func test_gen_opts_entry_equivalent() -> void:
	# 参数对象化入口（评审 C1）：generate_with_opts 与位置参数逐位等价
	# 注：v4.0 起生成器有「开局即胜门禁」（初始线索覆盖全部非雷格 = 死盘 → 拒收），
	# 原 5×5/10 雷 + 遮蔽 3 因「遮蔽格不许删」结构上必须给全线索 → 该配置全 seed 被拒，
	# 故本用例改用 7×7/14 雷（有剪枝空间）。
	var a: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"o5", [], Vector2i(7, 7), 14, 3, 3, 50, null, 120_000, 0.0, 1, 0, true)
	var b: Dictionary = PuzzleGenerator.new().generate_with_opts({
		"clue_rule_id": "o5", "size": Vector2i(7, 7), "mine_count": 14, "seed": 3,
		"mask_count": 3, "timeout_ms": 120_000, "mask_pre": true})
	assert_false(a.is_empty(), "位置参数应可生成")
	assert_false(b.is_empty(), "opts 入口应可生成")
	assert_eq((a.get("revealed", []) as Array).size(), (b.get("revealed", []) as Array).size(),
		"两入口线索数应一致（同 seed 同盘）")


func test_o5x_k_knob_contract() -> void:
	var rule: Object = RuleRegistry.default().resolve(&"o5x")
	rule.call("set_k_ratio", 0.2)
	rule.call("place_mines", RandomNumberGenerator.new(), 8, 8, 26)
	assert_eq((rule.get("_s1") as Dictionary).size(), 12, "o5x ratio=0.2 → s1=12")
	assert_true(bool(rule.call("is_k_public")), "o5x 默认公开")
	rule.call("set_k_public", false)
	assert_false(bool(rule.call("is_k_public")), "o5x 可切不公开（编码省略 Σs=k）")
