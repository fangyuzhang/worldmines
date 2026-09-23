# 一锤定音：o5x 载盘后隐藏态(_s1)丢失 → 线索值重算错误 → 推理踩雷。
# 实验：同 seed 重放 place_mines（恢复 _s1）→ 再推理应全通。
# 用法：godot --headless --path . -s res://tools/_probe_o5x_replay.gd -- <level.json>
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var mods_dir := DirAccess.open("res://demo/mods")
	if mods_dir != null:
		for sub in mods_dir.get_directories():
			var entry := "res://demo/mods/%s/entry.gd" % sub
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
	var args := OS.get_cmdline_user_args()
	var path := str(args[0]) if args.size() > 0 else "res://_staged_levels/harvest_0915b/batch_o5x/x_o5x/9x9/intro_13.json"
	var f := FileAccess.open(path, FileAccess.READ)
	var level: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var size: Dictionary = level.get("size", {})
	var rows := int(size.get("rows", 0))
	var cols := int(size.get("cols", 0))
	var seed_v := int(level.get("seed", 0))
	var mine_count := int(level.get("total_mines", 0))
	var mine_set := {}
	for m in level.get("mines", []):
		mine_set[Vector2i(int(m["c"]), int(m["r"]))] = true
	print("盘: %dx%d mines=%d seed=%d" % [cols, rows, mine_count, seed_v])

	# 1) 原始载盘（_s1 空/残留）：看线索与推理
	var b0 := Board.new()
	b0.load_level(level)
	print("重放前 (0,0) 约束: %s" % str(b0.get_player_constraint(Vector2i(0, 0))))
	var log0: Dictionary = ProofLog.build(level)
	print("重放前 ProofLog: solved=%s rounds=%s reason=[%s]" % [log0.get("solved"), log0.get("rounds"), log0.get("reason")])

	# 2) 同 seed 重放 place_mines（遍历 attempt 找匹配盘）
	var rule: Object = RuleRegistry.default().resolve(&"o5x")
	if rule == null:
		print("o5x 规则未注册")
		CliShutdown.request_exit(1)
		return
	var matched := -1
	for attempt in 40:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v * 1000003 + attempt
		var mines: Array = rule.call("place_mines", rng, cols, rows, mine_count)
		var s := {}
		for m in mines:
			s[m] = true
		if s.size() == mine_set.size():
			var same := true
			for k in s:
				if not mine_set.has(k):
					same = false
					break
			if same:
				matched = attempt
				break
	print("重放匹配 attempt=%d（命中后 _s1 已为正确值）" % matched)
	if matched < 0:
		print("重放失败——无法由 seed 恢复隐藏态")
		CliShutdown.request_exit(1)
		return

	# 3) 重放后：线索与推理应恢复正确
	var b1 := Board.new()
	b1.load_level(level)
	print("重放后 (0,0) 约束: %s" % str(b1.get_player_constraint(Vector2i(0, 0))))
	var log1: Dictionary = ProofLog.build(level)
	print("重放后 ProofLog: solved=%s rounds=%s reason=[%s]" % [log1.get("solved"), log1.get("rounds"), log1.get("reason")])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
