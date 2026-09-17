# test_variant_catalog.gd —— 变体目录（选关页 / 图鉴 的唯一事实源）
#
# 这个测试存在的意义：**防止 UI 与规则注册表再次脱钩**。
# 历史上 ui/level_select.MODES 与 ui/codex 的规则文字都是手写表，
# 引擎新增 knight、新增 O/S/Z 系列算子后 UI 完全不知情。
# 现在成员一律从 RuleRegistry 派生，这里锁死「注册表里有什么，UI 就必须有什么」。
extends GutTest


# V1：目录必须覆盖注册表里全部内置线索型规则（排除元规则）
func test_v1_covers_all_builtin_clue_rules() -> void:
	var listed := VariantCatalog.clue_ids()
	var missing: Array[String] = []
	for id in RuleRegistry.default().builtin_ids():
		var r := RuleRegistry.default().resolve(StringName(id))
		if r == null or not r.has_method("get_kind"):
			continue
		if str(r.call("get_kind")) != RulePlugin.KIND_CLUE:
			continue
		if VariantCatalog.HIDDEN_RULES.has(id):
			continue
		if not listed.has(id):
			missing.append(id)
	assert_eq(missing.size(), 0, "线索型规则漏进目录：%s" % ", ".join(missing))


# V2：目录必须覆盖注册表里全部内置全局约束
func test_v2_covers_all_builtin_global_rules() -> void:
	var listed := VariantCatalog.global_ids()
	var missing: Array[String] = []
	for id in RuleRegistry.default().builtin_ids():
		var r := RuleRegistry.default().resolve(StringName(id))
		if r == null or not r.has_method("get_kind"):
			continue
		if str(r.call("get_kind")) != RulePlugin.KIND_GLOBAL:
			continue
		if VariantCatalog.HIDDEN_RULES.has(id):
			continue
		if not listed.has(id):
			missing.append(id)
	assert_eq(missing.size(), 0, "全局约束漏进目录：%s" % ", ".join(missing))


# V3：knight 必须在目录里（它就是当年被手写表漏掉的那一个）
func test_v3_knight_is_listed() -> void:
	assert_true(VariantCatalog.clue_ids().has("knight"), "knight 已注册，目录必须包含")


# V4：元规则 total_mines 不能作为独立变体出现
func test_v4_meta_rule_is_hidden() -> void:
	assert_false(VariantCatalog.clue_ids().has("total_mines"))
	assert_false(VariantCatalog.global_ids().has("total_mines"))


# V5：名称与规则文字能取到（图鉴依赖 describe()）
func test_v5_display_name_and_text() -> void:
	for id in ["classic", "4n", "mx", "pf"]:
		assert_ne(VariantCatalog.display_name(id), id,
				"%s 应能取到中文名（而不是退回 id）" % id)
		assert_false(VariantCatalog.rule_text(id).is_empty(), "%s 应有规则说明文字" % id)
	# 未注册的 id 退回自身，不崩
	assert_eq(VariantCatalog.display_name("__not_a_rule__"), "__not_a_rule__")


# V6：混合组合 = 线索 × 全局约束的**完整交叉**（交叉表的所有格子都必须有对应条目）
# 旧实现每个 G 只配一个 C（7 个），那是径向图「每条枝干只能挂一个」的排布限制——
# 改为交叉表后 56 个组合全部可达，这条锁死「表里的每一格都能查到变体」。
func test_v6_mixed_covers_full_cross() -> void:
	var size := Vector2i(5, 5)
	var pairs := VariantCatalog.mixed_all(size, LevelSequence.mine_count(5))
	var clues := VariantCatalog.mixed_clue_ids()
	var globals := VariantCatalog.mixed_global_ids()
	assert_true(clues.size() > 0 and globals.size() > 0, "应有线索型与全局约束参与配对")
	assert_eq(pairs.size(), clues.size() * globals.size(),
			"混合档应为完整交叉（%d 线索 × %d 约束）" % [clues.size(), globals.size()])
	var seen := {}
	for p in pairs:
		var d: Dictionary = p as Dictionary
		var g: String = str(d["globals"][0])
		var c: String = str(d["clue"])
		seen["%s_%s" % [g, c]] = true
		assert_ne(c, "classic", "混合档的线索不应是中心基线")
		assert_true(clues.has(c), "混合档的线索应在配对用线索列表内：%s" % c)
		assert_true(globals.has(g), "混合档的约束应在配对用约束列表内：%s" % g)
		assert_ne(str(RuleSignature.compat(g, c, size, LevelSequence.mine_count(5))["verdict"]),
				RuleSignature.FORBID, "%s + %s 被判 forbid，不应出现在组合里" % [g, c])
	assert_eq(seen.size(), pairs.size(), "组合 id 不得重复（否则交叉格会指到同一个变体）")


# V8：加载 Mod 注册的新规则 → 目录 / 选关节点自动跟上；卸载 → 自动消失
# （这就是本模块存在的意义：修复「引擎换了、UI 没动」）
func test_v8_mod_rules_follow_the_registry() -> void:
	var reg := RuleRegistry.default()
	assert_false(VariantCatalog.clue_ids().has("__fake_mod_rule__"),
			"测试前置：假规则不应已在目录中")
	assert_true(reg.register(_FakeModRule.new()), "假 Mod 规则应注册成功")
	# 注册表实时变化 → 目录实时跟上
	assert_true(VariantCatalog.clue_ids().has("__fake_mod_rule__"), "加载 Mod 后目录应自动包含")
	# 选关节点表也应包含，且带 Mod 标记
	var modes := VariantCatalog.build_modes(Vector2i(5, 5), LevelSequence.mine_count(5))
	var found := {}
	for m in modes:
		if str((m as Dictionary)["id"]) == "__fake_mod_rule__":
			found = m as Dictionary
	assert_true(not found.is_empty(), "选关节点表应包含 Mod 变体")
	assert_eq(str(found.get("source", "")), "mod", "应标记来源为 Mod")
	assert_true(str(found.get("tip", "")).contains("Mod"), "节点 tip 应带 ·Mod 标记")
	# 卸载 → 自动消失（mod_api.unload_mod 正是这么做的）
	assert_true(reg.unregister(&"__fake_mod_rule__"), "非内置规则可注销")
	assert_false(VariantCatalog.clue_ids().has("__fake_mod_rule__"), "卸载后目录应自动移除")


# V9：混合组合只在**内置**规则间配对
# （Mod 算子的构造式布雷 / 可行性未经验证，混进去会产生成倍「生成不出来」的死节点）
func test_v9_mixed_pairs_are_builtin_only() -> void:
	var reg := RuleRegistry.default()
	assert_true(reg.register(_FakeModRule.new()), "注册假 Mod 规则")
	var pairs := VariantCatalog.mixed_all(Vector2i(5, 5), LevelSequence.mine_count(5))
	for p in pairs:
		var d: Dictionary = p as Dictionary
		assert_false(str(d["clue"]) == "__fake_mod_rule__", "混合档线索不应使用 Mod 规则")
		assert_false((d["globals"] as Array).has("__fake_mod_rule__"), "混合档全局不应使用 Mod 规则")
	reg.unregister(&"__fake_mod_rule__")
	assert_true(pairs.size() > 0, "内置规则间应能产生混合组合")


# V10：双约束组合（G+G）—— C(7,2) 全部配对，判 forbid 的不产生
# 与 V6 同源契约：表里的每一格都能查到变体；且 id 与 G+C 的 id 空间不得相撞
func test_v10_gg_covers_all_pairs() -> void:
	var size := Vector2i(5, 5)
	var mines := LevelSequence.mine_count(5)
	var globals := VariantCatalog.mixed_global_ids()
	var pairs := VariantCatalog.gg_all(size, mines)

	var total := globals.size() * (globals.size() - 1) / 2
	assert_eq(total, 21, "C(7,2) = 21 对（结构契约）")
	var forbid := 0
	for i in globals.size():
		for j in range(i + 1, globals.size()):
			if str(RuleSignature.compat(globals[i], globals[j], size, mines)["verdict"]) \
					== RuleSignature.FORBID:
				forbid += 1
	assert_eq(pairs.size(), total - forbid,
			"产出的对 = 全部对 − 判 forbid 的对（不写死数字，签名表更新后自动跟上）")

	var seen := {}
	for p in pairs:
		var d: Dictionary = p as Dictionary
		var gs: Array = d["globals"]
		assert_eq(gs.size(), 2, "双约束应携带两条约束")
		assert_ne(str(gs[0]), str(gs[1]), "两条约束不得相同（同约束重复判 forbid）")
		assert_eq(str(d["clue"]), "classic", "双约束不加线索（线索走经典）")
		assert_false(seen.has(str(d["id"])), "组合 id 不得重复：%s" % str(d["id"]))
		seen[str(d["id"])] = true
	# 已知的具体冗余例：mx 逻辑蕴含 ep → 二者同关时 ep 完全冗余，没有信息增量
	assert_false(seen.has("mx_ep"), "mx 蕴含 ep，不应产生该组合")
	# id 空间：G+G 形如 mx_rl（第二位也是约束），不与 G+C 形如 mx_4n（第二位是线索）相撞
	for p in pairs:
		var parts := str((p as Dictionary)["id"]).split("_")
		assert_eq(parts.size(), 2, "id 应为 约束_约束 两段")
		assert_true(globals.has(str(parts[0])) and globals.has(str(parts[1])),
				"id 两段都应是全局约束：%s" % str((p as Dictionary)["id"]))


# V7：选关页节点表结构完整（下游布局/绘制/进度键都依赖这些字段）
func test_v7_build_modes_shape() -> void:
	var modes := VariantCatalog.build_modes(Vector2i(5, 5), LevelSequence.mine_count(5))
	assert_true(modes.size() > 15, "新表应比旧写死表（15 条）更多：至少多了 knight")
	var kinds := {}
	for m in modes:
		var d: Dictionary = m as Dictionary
		for key in ["id", "name", "kind", "tip", "clue", "globals", "enabled"]:
			assert_true(d.has(key), "节点 %s 缺字段 %s" % [str(d.get("id", "?")), key])
		kinds[str(d["kind"])] = int(kinds.get(str(d["kind"]), 0)) + 1
	assert_eq(int(kinds.get("core", 0)), 1, "中心基线且只有一个")
	assert_true(kinds.has("clue") and kinds.has("global") and kinds.has("mixed"))
	# 混合档的 parents 必须都能在表里找到（否则布局会把它摆到中心）
	var ids := {}
	for m in modes:
		ids[str((m as Dictionary)["id"])] = true
	for m in modes:
		if str((m as Dictionary)["kind"]) != "mixed":
			continue
		for p in (m as Dictionary)["parents"]:
			assert_true(ids.has(str(p)), "混合档父节点 %s 不在表内" % str(p))


## 测试用假 Mod 规则（鸭子类型满足 RulePlugin 契约的最小实现）。
class _FakeModRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"__fake_mod_rule__"

	func get_kind() -> String:
		return RulePlugin.KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "假算子", "rule_text": "仅用于测试目录的 Mod 派生"}
