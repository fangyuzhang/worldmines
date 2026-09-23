extends SceneTree

## o5x 单盘性能剖面：跑一次生成，打印阶段分解（place/prune/verify + attempts）。
## 用法：godot --headless --path . -s res://tools/_profile_o5x.gd -- <side> <seed>
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var side := int(args[0]) if args.size() >= 1 else 8
	var seed_v := int(args[1]) if args.size() >= 2 else 1
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/o5_xiemai")
	print("mod 加载: ok=%s" % str(r.get("ok")))
	var rule_id := "o5x"
	var mines: int = int(RuleFeasibility.resolve_mines(rule_id, [], side)["mines"])
	print("=== %dx%d @%d雷 seed=%d ===" % [side, side, mines, seed_v])
	var t0 := Time.get_ticks_msec()
	var gen := PuzzleGenerator.new()
	var level: Dictionary = gen.generate_with_rules(
		rule_id, [], Vector2i(side, side), mines, seed_v, 0, 50, null, side * side * 6000, 0.0)
	var cost := float(Time.get_ticks_msec() - t0) / 1000.0
	if level.is_empty():
		print("结果: FAIL 空（总耗时 %.1fs）" % cost)
	else:
		print("结果: OK 线索 %d 条 难度 %.2f（总耗时 %.1fs）" % [
			(level.get("revealed", []) as Array).size(),
			float(level.get("difficulty_profile", {}).get("difficulty", 0.0)), cost])
	print("阶段统计: %s" % JSON.stringify(gen.last_call_stats))
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
