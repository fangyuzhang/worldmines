extends SceneTree

## O1 诊断 v3：逐条线索累积加入 → 找第一条让 C# 模型 infeasible 的线索 → dump IR
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var rule: Object = RuleRegistry.default().resolve(&"o1")
	var side := 5
	var mines_n := 10
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var mine_set := {}
	while mine_set.size() < mines_n:
		mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true
	var oracle := RuleOracle.new(rule, [], Vector2i(side, side), mines_n, null)

	var active := {}
	for r in range(1, side - 1):
		for c in range(1, side - 1):
			active[Vector2i(c, r)] = rule.call("compute_clue", mine_set, Vector2i(c, r), Vector2i(side, side))

	var partial := {}
	var first_bad := -1
	var ordered: Array = active.keys()
	ordered.sort()
	for i in ordered.size():
		partial[ordered[i]] = active[ordered[i]]
		var sp := oracle.build_spec(partial, [], {})
		if not RuleCpSat.is_feasible(sp):
			first_bad = i
			break
	print("first_bad=%d（-1 = 全部累积均可）" % first_bad)
	if first_bad >= 0:
		var pos: Vector2i = ordered[first_bad]
		print("坏线索: %s value=%d" % [str(pos), int(active[pos])])
		var sp2 := oracle.build_spec(partial, [], {})
		print("aux 条目: %d 个" % (sp2.get("aux", []) as Array).size())
		var clues: Array = sp2.get("clues", [])
		print("线索数: %d" % clues.size())
		var last_ir: Array = clues[clues.size() - 1]["ir"]
		print("最后线索 IR: %s" % JSON.stringify(last_ir))
		print("aux 列表: %s" % JSON.stringify(sp2.get("aux", [])))
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
