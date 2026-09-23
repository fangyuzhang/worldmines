extends SceneTree

## 通用 Mod 规则全链路 probe：加载（生产路径）→ 可行性 → 生成 → ProofLog → Board round-trip
## → 零值语义抽查。用法：
##   godot --headless --path . -s res://tools/_probe_mod.gd -- <mod_dir_name> <rule_id>
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var mod_name := str(args[0]) if args.size() >= 1 else "o1_duichuan"
	var rule_id := str(args[1]) if args.size() >= 2 else "o1"
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/%s" % mod_name)
	print("mod 加载: ok=%s id=%s" % [str(r.get("ok")), str(r.get("mod_id", ""))])
	var rule: Object = RuleRegistry.default().resolve(StringName(rule_id))
	if rule == null:
		print("!!! %s 未注册，终止" % rule_id)
		CliShutdown.request_exit(1)
		return
	print("规则: %s (%s) 值域上限=%s" % [
		str(rule.call("describe").get("name")), str(rule.call("get_kind")),
		str(rule.call("value_upper_bound", Vector2i(7, 7)))])

	for side in [5, 6, 7, 8, 9]:
		var rr := RuleFeasibility.resolve_mines(rule_id, [], side)
		print("可行性 %dx%d: mines=%s standard=%s" % [side, side, str(rr["mines"]), str(rr["standard"])])

	var mask_n := int(args[2]) if args.size() >= 3 else 0   # 可选第 3 参数：遮蔽（问号）格数
	var mask_lo := int(args[3]) if args.size() >= 4 else 1  # 第 4 参数：遮蔽区间下界（0 = 完全弱化）
	var mask_st := int(args[4]) if args.size() >= 5 else 0  # 第 5 参数：选格策略（0 随机/1 高值/2 低值）
	if mask_n > 0:
		print("遮蔽（问号）格数: %d lo=%d strategy=%d" % [mask_n, mask_lo, mask_st])
	for side in [5, 6, 7, 8, 9]:
		var mines: int = int(RuleFeasibility.resolve_mines(rule_id, [], side)["mines"])
		var t0 := Time.get_ticks_msec()
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
			rule_id, [], Vector2i(side, side), mines, 1, mask_n, 50, null, side * side * 3000, 0.0, mask_lo, mask_st)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if level.is_empty():
			print("生成 %dx%d: FAIL（空，%.1fs）" % [side, side, cost])
			continue
		var log2: Dictionary = ProofLog.build(level)
		var solved := bool(log2.get("solved", false))
		var diff := float(level.get("difficulty_profile", {}).get("difficulty", 0.0))
		print("生成 %dx%d @%d雷: 线索 %d 条, 难度 %.2f, 序贯可解=%s（%.1fs）" % [
			side, side, mines, (level.get("revealed", []) as Array).size(), diff, str(solved), cost])
		var board := Board.new()
		board.load_level(level)
		var revealed: Array = level.get("revealed", [])
		var mine_set := {}
		for m in level.get("mines", []):
			mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
		var bad := 0
		var zero_cnt := 0
		var zero_spread := 0
		for rv in revealed:
			var p := Vector2i(int(rv["c"]), int(rv["r"]))
			var want: Variant = rule.call("compute_clue", mine_set, p, Vector2i(side, side))
			var got: Variant = board.grid.get_cell(p).value
			if int(want) != int(got):
				bad += 1
			var zsn: Array = rule.call("zero_safe_neighbors", p, Vector2i(side, side), want)
			if int(want) == 0:
				zero_cnt += 1
				if not zsn.is_empty():
					zero_spread += 1
		print("  round-trip: 不一致 %d 格；0 值格 %d 个（可扩散 %d —— 0=不可扩散规则如对穿，=个数=可扩散规则如邻序）" % [
			bad, zero_cnt, zero_spread])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
