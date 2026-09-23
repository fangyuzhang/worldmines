extends SceneTree

## 生成阶段计时诊断：布雷 / 删线索（试删数/成功数）/ 最终验证 三段分解。
## 用法：godot --headless --path . -s res://tools/_timing_probe.gd -- <rule_id> <mod_name> [sizes]
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var rule_id := str(args[0]) if args.size() >= 1 else "o1"
	var mod_name := str(args[1]) if args.size() >= 2 else "o1_duichuan"
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/%s" % mod_name)
	for side in [7, 8]:
		var mines: int = int(RuleFeasibility.resolve_mines(rule_id, [], side)["mines"])
		var gen := PuzzleGenerator.new()
		var t0 := Time.get_ticks_msec()
		var level: Dictionary = gen.generate_with_rules(
			rule_id, [], Vector2i(side, side), mines, 1, 0, 50, null, side * side * 3000)
		var total := Time.get_ticks_msec() - t0
		var s: Dictionary = gen.last_call_stats
		print("%s %dx%d: total=%.1fs | attempts=%d | place=%.1fs prune=%.1fs verify=%.1fs | prune_tries=%d prune_ok=%d | brep_fail=%d no_clues=%d verify_fail=%d" % [
			rule_id, side, side, total / 1000.0, int(s["attempts"]),
			int(s["t_place_ms"]) / 1000.0, int(s["t_prune_ms"]) / 1000.0, int(s["t_verify_ms"]) / 1000.0,
			int(s["prune_tries"]), int(s["prune_ok"]),
			int(s["brep_fail"]), int(s["no_clues"]), int(s["verify_fail"])])
		if not level.is_empty():
			var dp: Dictionary = level.get("difficulty_profile", {})
			print("  -> 出关 difficulty=%.2f clues=%d" % [
				float(dp.get("difficulty", 0.0)), int(dp.get("clue_count", 0))])
		else:
			print("  -> 空（该 seed 未出关）")
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
