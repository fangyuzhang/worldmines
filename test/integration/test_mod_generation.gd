# test_mod_generation.gd —— mod 关卡生成 + 加载 + 线索一致性（第二篇 mod 系统集成）
# Def 路径已并入规则平台：generate_from_def 委托 generate_with_rules，
# 输出 clue_rule / global_rules（规则平台格式），加载后是 rule_clue_id / rule_global_ids。
extends GutTest


func after_each() -> void:
	# 兜底清理：无论测试中途如何 return，都恢复 ModAPI 与 user://mods/ 的干净状态。
	_cleanup_code_mod()


## Def 声明式子集（window / aggregate 均为封闭枚举）能表达的恰好是「四邻 n4 / 同色 diag /
## 镜像 axis」这三位旧算子。它们已于 2026-09-18 移出主项目（收进 demo/mods/legacy_rules，
## 默认不自举）→ 规则不在场时这两条 Def 翻译链无意义：直接 pending，而不是误判成「生成失败」。
func _legacy_ready() -> bool:
	var reg := RuleRegistry.default()
	return reg.resolve(&"4n") != null and reg.resolve(&"sc") != null


## 用 mod Def（DefEngine 的 4n + mx）生成关卡 → 规则平台加载 → 线索值一致。
func test_mod_level_generate_and_load() -> void:
	if not _legacy_ready():
		pending("Def→4n 翻译链依赖 legacy_rules（旧算子已移出主项目，模组页可加载）")
		return
	var gen := PuzzleGenerator.new()
	var level := gen.generate_from_def("4n", "mx", Vector2i(5, 5), 5, 1)
	assert_false(level.is_empty(), "mod 关卡应生成")
	assert_eq(str(level.get("clue_rule", "")), "4n", "clue_rule 字段应为 4n")
	assert_eq(level.get("global_rules", []), ["mx"], "global_rules 字段应为 [mx]")

	var board := Board.new()
	board.load_level(level)
	assert_eq(board.rule_clue_id, "4n", "加载后 rule_clue_id")
	assert_eq(board.rule_global_ids, ["mx"], "加载后 rule_global_ids")

	var rule: Object = RuleRegistry.default().resolve(&"4n")
	var ok := true
	for rv in level.get("revealed", []):
		var pos := Vector2i(int(rv["c"]), int(rv["r"]))
		var expected: Variant = rule.compute_clue(board._mine_set_dict(), pos, Vector2i(5, 5))
		if str(expected) != str(board.grid.get_cell(pos).value):
			ok = false
	assert_true(ok, "mod 关卡线索值应与规则平台计算一致")


## 无约束 mod 关卡（仅线索 Def）也能生成 + 加载。
func test_mod_level_clue_only() -> void:
	if not _legacy_ready():
		pending("Def→sc 翻译链依赖 legacy_rules（旧算子已移出主项目，模组页可加载）")
		return
	var gen := PuzzleGenerator.new()
	var level := gen.generate_from_def("sc", "", Vector2i(5, 5), 5, 1)
	assert_false(level.is_empty(), "仅线索 Def 的 mod 关卡应生成")
	var board := Board.new()
	board.load_level(level)
	assert_eq(board.rule_clue_id, "sc", "加载后 rule_clue_id")
	assert_eq(board.rule_global_ids, [], "无约束时 rule_global_ids 应为空")


## P0-T6 端到端：demo 代码 Mod 安装 → ModAPI(autoload) 加载 → on_load 注册 → 生成 → Board 加载 → 可玩。
## 走生产路径（autoload 单例 ModAPI），而非测试专用 new()，验证「社区代码 Mod」完整闭环。
func test_code_mod_end_to_end() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	# 1. 安装 demo 代码 Mod 到 user://mods/
	var inst: Dictionary = ExampleMod.install_demo_rule_mod()
	assert_true(inst.get("ok", false), "demo 代码 Mod 应安装成功")
	if not inst.get("ok", false):
		return
	# 2. ModAPI（autoload 单例，生产路径）加载
	var r: Dictionary = ModAPI.load_mod("user://mods/custom_rule_mod")
	assert_true(r.get("ok", false), "ModAPI 应能加载代码 Mod: %s" % str(r.get("reason", "")))
	if not r.get("ok", false):
		return
	# 3. on_load 注册 x2diag 规则
	assert_true(RuleRegistry.default().all_ids().has("x2diag"), "on_load 应注册 x2diag 规则")
	# 4. 生成（多 seed 重试）
	var gen := PuzzleGenerator.new()
	var level := {}
	for seed in range(1, 11):
		level = gen.generate_with_rules("x2diag", [], Vector2i(5, 5), 4, seed)
		if not level.is_empty():
			break
	assert_false(level.is_empty(), "x2diag 应能在 10 个种子内生成关卡")
	if level.is_empty():
		return
	assert_eq(str(level.get("clue_rule", "")), "x2diag", "关卡 clue_rule 应为 x2diag")
	# 5. Board 加载 + 线索对拍（x2diag 正向计算）
	var b := Board.new()
	b.load_level(level)
	assert_eq(b.rule_clue_id, "x2diag", "Board 应识别规则关卡")
	var rule: Object = RuleRegistry.default().resolve(&"x2diag")
	var ms := {}
	for m in b._static_mines:
		ms[m] = true
	var size := b.grid.size()
	for rr in size.y:
		for cc in size.x:
			var p := Vector2i(cc, rr)
			if ms.has(p):
				continue
			assert_eq(b.grid.get_cell(p).value, rule.compute_clue(ms, p, size), "线索值应等于 x2diag 正向计算")
	# 6. 可玩：翻开全部非雷格 → 胜利
	for rr in size.y:
		for cc in size.x:
			var p := Vector2i(cc, rr)
			if not ms.has(p):
				b.reveal(p)
	assert_eq(b.state, Board.GameState.WON, "翻完非雷格应胜利")
	# 7. 卸载清理（卸载应清理规则）
	var ur := ModAPI.unload_mod("custom_rule_mod")
	assert_true(ur.get("ok", false), "卸载应成功")
	assert_false(RuleRegistry.default().all_ids().has("x2diag"), "卸载后 x2diag 应被清理")


func _cleanup_code_mod() -> void:
	if ModAPI.list_mods().has("custom_rule_mod"):
		ModAPI.unload_mod("custom_rule_mod")
	ExampleMod.uninstall_demo_rule_mod()
