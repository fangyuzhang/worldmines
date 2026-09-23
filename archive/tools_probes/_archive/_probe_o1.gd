extends SceneTree

## O1 对穿全链路试点冒烟：生产加载（ModAPI）→ 可行性 → 生成 → ProofLog →
## Board 加载 + 线索值 round-trip → 外圈无线索核对。目标：找「新算子接入」的流程 bug。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	# 1) 生产路径加载
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/o1_duichuan")
	print("mod 加载: ok=%s id=%s" % [str(r.get("ok")), str(r.get("mod_id", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"o1")
	if rule == null:
		print("!!! o1 未注册，终止")
		CliShutdown.request_exit(1)
		return
	print("规则: %s (%s)" % [str(rule.call("describe").get("name")), str(rule.call("get_kind"))])

	# 2) 可行性（全尺寸）
	for side in [5, 6, 7, 8, 9]:
		var rr := RuleFeasibility.resolve_mines("o1", [], side)
		print("可行性 %dx%d: mines=%s standard=%s" % [side, side, str(rr["mines"]), str(rr["standard"])])

	# 3) 生成 5 尺寸各 1 关
	for side in [5, 6, 7, 8, 9]:
		var mines: int = int(RuleFeasibility.resolve_mines("o1", [], side)["mines"])
		var t0 := Time.get_ticks_msec()
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
			"o1", [], Vector2i(side, side), mines, 1, 0, 50, null, side * side * 3000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if level.is_empty():
			print("生成 %dx%d: FAIL（空，%.1fs）" % [side, side, cost])
			continue
		var log2: Dictionary = ProofLog.build(level)
		var solved := bool(log2.get("solved", false))
		var diff := float(level.get("difficulty_profile", {}).get("difficulty", 0.0))
		print("生成 %dx%d @%d雷: 线索 %d 条, 难度 %.2f, 序贯可解=%s（%.1fs）" % [
			side, side, mines, (level.get("revealed", []) as Array).size(), diff, str(solved), cost])
		# 4) Board 加载 + 外圈无线索核对（5×5 详查）
		var board := Board.new()
		board.load_level(level)
		var revealed: Array = level.get("revealed", [])
		var outer := 0
		for rv in revealed:
			var c := int(rv["c"])
			var rr2 := int(rv["r"])
			if c == 0 or rr2 == 0 or c == side - 1 or rr2 == side - 1:
				outer += 1
		# v3.0 方案 A：全部格铺线索——外圈出现线索是预期（原「应为 0」检查反转）
		if outer == 0:
			print("  !! 最外圈无线索（方案 A 下应为全部格铺线索）")
		else:
			print("  外圈线索 %d 条（方案 A 预期 >0）" % outer)
		if side == 5:
			# 逐格 round-trip：Board 值 vs 规则独立重算
			var mine_set := {}
			for m in level.get("mines", []):
				mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
			var bad := 0
			for rv in revealed:
				var p := Vector2i(int(rv["c"]), int(rv["r"]))
				var want: Variant = rule.call("compute_clue", mine_set, p, Vector2i(side, side))
				var got: Variant = board.grid.get_cell(p).value
				if int(want) != int(got):
					bad += 1
			print("  5x5 round-trip: 不一致 %d 格" % bad)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
