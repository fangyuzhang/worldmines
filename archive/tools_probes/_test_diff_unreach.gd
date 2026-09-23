extends SceneTree

## 验证「难度不可达」判定前提：这些组合×尺寸的难度上限是否真的远低于 easy 门槛（0.3）。
## 若 max_diff < 0.15 → 预筛成立（不会误杀波动组合）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var cases := [
		["classic", ["mx", "ep"], 8],
		["classic", ["mx", "4c"], 8],
		["classic", ["dt", "4c"], 8],
		["classic", ["mx", "rl"], 5],
		["classic", ["mx", "sc"], 5],  # 对照：接受率 36.6%，应能出关（不该判不可达）
	]
	for cd in cases:
		var clue: String = cd[0]
		var globals: Array = cd[1]
		var side: int = cd[2]
		var maxd := -1.0
		var ok := 0
		for seed in range(1, 5):
			var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
				clue, globals, Vector2i(side, side), int(SIZES_MINE[side]), seed, 0, 50, null, side * side * 3000)
			if level.is_empty():
				continue
			var d := float(level.get("difficulty_profile", {}).get("difficulty", 0.0))
			maxd = maxf(maxd, d)
			if Difficulty.tier_of(d) != "":
				ok += 1
		print("%-14s %dx%d: 4 次尝试中进档 %d 关, max_diff=%.2f → 预筛判定%s" % [
			str(globals), side, side, ok, maxd, "不可达" if (ok == 0 and maxd < 0.15) else "正常(不拦截)"])
	CliShutdown.request_exit(0)


const SIZES_MINE := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
