extends SceneTree

## 内置走 find_solution 的组合回归：接受率 + 盘多样性（扰动修复后）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _fp(level: Dictionary) -> String:
	var ms: Array = []
	for m in level.get("mines", []):
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	return "|".join(ms)


func _probe(tag: String, clue: String, globals: Array, side: int, mines: int, n: int) -> void:
	var ok := 0
	var fps := {}
	var t0 := Time.get_ticks_msec()
	for seed in range(1, n + 1):
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
			clue, globals, Vector2i(side, side), mines, seed, 0, 50, null,
			maxi(30_000, side * side * 1500))
		if level.is_empty():
			continue
		var tier := Difficulty.tier_of(float(level.get("difficulty_profile", {}).get("difficulty", 0.0)))
		if tier != "":
			ok += 1
			fps[_fp(level)] = true
	print("%s %dx%d: %d/%d 关 | 不同盘 %d | 平均 %.1fs/关" % [
		tag, side, side, ok, n, fps.size(), float(Time.get_ticks_msec() - t0) / 1000.0 / float(n)])


func _initialize() -> void:
	_probe("rl_ep", "classic", ["rl", "ep"], 9, 32, 3)
	_probe("qd_sc", "sc", ["qd"], 5, 10, 4)
	_probe("rl_loopruns", "loopruns", ["rl"], 9, 32, 2)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
