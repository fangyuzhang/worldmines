extends SceneTree

# 临时探针：新增「开局即胜门禁」（全非雷格皆线索 → 拒收）后，
# 哪些 (配置, seed) 仍能生成？用于修被门禁误卡的 3 个固定 seed 单测。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var script: Variant = load("res://demo/mods/o5_sanjiao/entry.gd")
	script.new().call("on_load")
	var cfgs: Array = [
		{"side": 5, "mines": 10, "mask": 3, "pre": true},
		{"side": 7, "mines": 14, "mask": 3, "pre": true},
		{"side": 7, "mines": 14, "mask": 3, "pre": false},
		{"side": 5, "mines": 6, "mask": 3, "pre": true},
	]
	for cfg in cfgs:
		var ok_seeds: Array = []
		var clue_min := 999
		for seed_v in range(1, 13):
			var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
				"o5", [], Vector2i(int(cfg["side"]), int(cfg["side"])), int(cfg["mines"]),
				seed_v, int(cfg["mask"]), 50, null, 120_000, 0.0, 1, 0, bool(cfg["pre"]))
			if not lv.is_empty():
				ok_seeds.append(seed_v)
				clue_min = mini(clue_min, (lv.get("revealed", []) as Array).size())
		print("[maskprobe] %s → 可生成 seed %s（最少线索数=%d）" % [
			str(cfg), str(ok_seeds), clue_min if clue_min != 999 else -1])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
