# S6「度偶数」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 度数偶数的独立复算（不信任生成侧）。S6 是全局约束类，故以「经典线索 + s6」组合验证。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const DIRS8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s6_duou")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s6")
	if rule == null:
		print("!!! s6 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		var size := Vector2i(side, side)
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["s6"], size, int(SIZES[side]), 1, 0, 30, null, 60000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d: 生成失败（%.1fs）" % [side, side, cost])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
		# 度数偶数独立复算
		var ms := {}
		for m in lv.get("mines", []):
			ms[Vector2i(int(m["c"]), int(m["r"]))] = true
		var degs: Array = []
		var even_ok := true
		for p in ms:
			var deg := 0
			for d in DIRS8:
				if ms.has((p as Vector2i) + d):
					deg += 1
			degs.append(deg)
			if deg % 2 != 0:
				even_ok = false
		degs.sort()
		print("%dx%d: mines=%d clues=%d solved=%s board_ok=%s 度数分布=%s 全偶=%s (%.1fs)" % [
			side, side, int(lv.get("total_mines", 0)), (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), str(degs), str(even_ok), cost])
		if not even_ok:
			print("   !! 存在奇数度数的雷")
			ok_all = false
		if not solved or not board_ok:
			ok_all = false
	print("=== S6 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
