extends SceneTree

# 实测：各尺寸/各规则在大盘上的生成耗时与命中率。
# 目的：「生成器被 MAX_COMBOS 钉死在 5×5」的说法已证伪（生产路径走 CP-SAT，见坑表 #29）；
# 本脚本留作各尺寸单关耗时的性能基准（含 9×9）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	print("RuleCpSat.available = ", RuleCpSat.available())
	for spec in [
		["classic", 5, 1], ["classic", 6, 1], ["classic", 7, 1], ["classic", 8, 1], ["classic", 9, 1],
		["classic", 9, 3], ["knight", 9, 1], ["4n", 9, 1], ["sc", 9, 1],
	]:
		var clue: String = spec[0]
		var side: int = spec[1]
		var seed: int = spec[2]
		var size := Vector2i(side, side)
		var mines := int(round(float(side * side) * 0.3))
		var t0 := Time.get_ticks_msec()
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
			clue, [], size, mines, seed, 0, 1, null, 60_000)
		var dt := Time.get_ticks_msec() - t0
		var ok := not level.is_empty()
		var clues := 0
		var prof := 0.0
		if ok:
			clues = (level.get("revealed", []) as Array).size()
			prof = float((level.get("difficulty_profile", {}) as Dictionary).get("difficulty", 0.0))
		print("%-8s %dx%d mines=%-3d seed=%d -> %s  %6d ms  clues=%d  D=%.2f" % [
			clue, side, side, mines, seed, "OK " if ok else "FAIL", dt, clues, prof])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
