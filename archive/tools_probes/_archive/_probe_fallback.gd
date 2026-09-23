extends SceneTree

## 候选雷数回退探索：现有变体在各尺寸下的 resolve_mines 结果
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var cases := [
		["classic", []],
		["classic", ["rl"]],
		["classic", ["qd"]],
		["classic", ["mx", "rl"]],
		["sc", ["qd"]],
		["classic", ["pf"]],
		["classic", ["4c"]],
		["classic", ["mx", "dt"]],
	]
	for cd in cases:
		var line := ""
		for side in [5, 6, 7, 8, 9]:
			var r := RuleFeasibility.resolve_mines(cd[0], cd[1], side)
			line += " %d:%s%s" % [side, str(r["mines"]), "" if bool(r["standard"]) else "*"]
		print("%s+%s ->%s" % [cd[0], str(cd[1]), line])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
