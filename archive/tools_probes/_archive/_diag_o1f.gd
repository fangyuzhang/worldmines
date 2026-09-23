extends SceneTree

## O1 诊断 v6：用生成器同款序贯引擎（find_forced_cells）交叉验证「推不动」是真实结论。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var rule: Object = RuleRegistry.default().resolve(&"o1")
	var side := 5
	var mines_n := 10
	var rng := RandomNumberGenerator.new()
	rng.seed = 1000
	var mine_set := {}
	while mine_set.size() < mines_n:
		mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true

	var active := {}
	for r in range(1, side - 1):
		for c in range(1, side - 1):
			var pos := Vector2i(c, r)
			if mine_set.has(pos):
				continue
			active[pos] = rule.call("compute_clue", mine_set, pos, Vector2i(side, side))
	print("线索 %d 条" % active.size())

	var oracle := RuleOracle.new(rule, [], Vector2i(side, side), mines_n, null)
	# 接口注意：build_spec 的 known_mines 期望 Vector2i 数组（内部取 m.y/m.x）。
	var known_safe: Array = []
	var known_mine: Array = []
	for pos in active:
		known_safe.append(Vector2i(pos.x, pos.y))
	var derived := 0
	for round_i in 12:
		var spec := oracle.build_spec(active, known_mine, {})
		var safe_extra: Array = (spec.get("safe_cells", []) as Array).duplicate()
		for ks in known_safe:
			var pair_s := [ks.y, ks.x]
			if not safe_extra.has(pair_s):
				safe_extra.append(pair_s)
		spec["safe_cells"] = safe_extra
		var res: Dictionary = RuleCpSat.find_forced_cells(spec)
		var new_safe := 0
		var new_mine := 0
		for s in res.get("safe", []):
			var sv := Vector2i(int(s[1]), int(s[0]))
			if not known_safe.has(sv):
				known_safe.append(sv)
				new_safe += 1
		for m in res.get("mine", []):
			var mv := Vector2i(int(m[1]), int(m[0]))
			if not known_mine.has(mv):
				known_mine.append(mv)
				new_mine += 1
		derived += new_safe + new_mine
		print("第 %d 轮: 新推 safe=%d mine=%d（累计 %d/%d 格）" % [
			round_i + 1, new_safe, new_mine, known_safe.size() + known_mine.size(), side * side])
		if new_safe + new_mine == 0:
			print("  → 无新强制格（推不动，停在 %d/%d 格）" % [known_safe.size() + known_mine.size(), side * side])
			break
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
