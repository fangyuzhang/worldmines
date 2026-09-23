extends SceneTree

## O4 编码诊断：验证「r2 一致盘」的 is_feasible（编码本身是否有解）。
## 场景：place_mines 设 _r2 + 同 rng 会话布雷 → compute_clue 一致 → is_feasible 检查。
const CliShutdown := preload("res://tools/cli_shutdown.gd")
const R07 := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var sc: Variant = load("res://demo/mods/o4_bianjing/entry.gd")
	sc.new().call("on_load")
	var rule: Object = RuleRegistry.default().resolve(&"o4")
	var side := 6
	var mines_n: int = int(R07[side])
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var mine_arr: Array = rule.call("place_mines", rng, side, side, mines_n)
	print("place_mines 返回 %d 雷" % mine_arr.size())
	var mine_set := {}
	for p in mine_arr:
		mine_set[p] = true
	var active := {}
	for r in side:
		for c in side:
			var pos := Vector2i(c, r)
			if mine_set.has(pos) or not bool(rule.call("applies_to", pos, Vector2i(side, side))):
				continue
			active[pos] = rule.call("compute_clue", mine_set, pos, Vector2i(side, side))
	print("线索 %d 条；f 范围采样：%d, %d, %d" % [
		active.size(), active.values()[0], active.values()[active.size() / 2], active.values()[-1]])
	var oracle := RuleOracle.new(rule, [], Vector2i(side, side), mines_n, null)
	var spec: Dictionary = oracle.build_spec(active, [], {})
	var clue_ir_total := 0
	for cd in spec.get("clues", []):
		clue_ir_total += (cd.get("ir", []) as Array).size()
	print("spec：线索 %d 组、clue IR 合计 %d 条、globals %d 条、aux %d 个" % [
		(spec.get("clues", []) as Array).size(), clue_ir_total,
		(spec.get("globals", []) as Array).size(), (spec.get("aux", []) as Array).size()])
	var ok := RuleCpSat.is_feasible(spec)
	print("SCENARIO_CONSISTENT_FEASIBLE=%s" % str(ok))
	# 场景二：无 _r2 语义——直接重建规则实例（_r2 空），f = N1 值
	var sc2: Variant = load("res://demo/mods/o4_bianjing/entry.gd")
	sc2.new().call("on_load")
	var rule2: Object = RuleRegistry.default().resolve(&"o4")
	var active2 := {}
	for r in side:
		for c in side:
			var pos := Vector2i(c, r)
			if mine_set.has(pos) or not bool(rule2.call("applies_to", pos, Vector2i(side, side))):
				continue
			active2[pos] = rule2.call("compute_clue", mine_set, pos, Vector2i(side, side))
	var oracle2 := RuleOracle.new(rule2, [], Vector2i(side, side), mines_n, null)
	print("SCENARIO_NO_R2_FEASIBLE=%s" % str(RuleCpSat.is_feasible(oracle2.build_spec(active2, [], {}))))
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
