# S1 调试：直接调用 place_mines，对比「直接调用」与「生成器路径」的差异。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const R07 := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/s1_jinxing")
	var r: Object = RuleRegistry.default().resolve(&"s1")
	if r == null:
		print("s1 未注册")
		CliShutdown.request_exit(1)
		return
	print("--- 直接调用 place_mines（同 GUT 用法）---")
	for side in [5, 6, 7, 8, 9]:
		for t in 3:
			var rng := RandomNumberGenerator.new()
			rng.seed = t * 1000 + side
			var m: Variant = r.call("place_mines", rng, side, side, int(R07[side]))
			print("  %dx%d seed=%-5d -> %s 个" % [side, side, rng.seed, str((m as Array).size() if m is Array else "非数组:" + str(m))])
	print("--- 静态分层采样直调（绕过 place_mines 的过滤）---")
	var scr: Script = r.get_script()
	print("  script=%s" % str(scr))
	# 通过生成器路径对照
	print("--- 生成器路径（对照）---")
	var gen := PuzzleGenerator.new()
	for side in [7, 8]:
		var lv: Dictionary = gen.generate_with_rules("classic", ["s1"], Vector2i(side, side), int(R07[side]), 1, 0, 30, null, 60000)
		print("  %dx%d: %s" % [side, side, "空" if lv.is_empty() else "mines=%d" % int(lv.get("total_mines", 0))])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
