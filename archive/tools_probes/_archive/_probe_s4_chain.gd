# S4「洋葱」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 层密度单调性独立复算（不信任生成侧）。S4 是全局约束类，故以「经典线索 + s4」组合验证。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _layers(rows: int, cols: int) -> Array:
	var nc := mini(rows, cols)
	var t_max := (nc - 1) / 2
	var out: Array = []
	for t in t_max + 1:
		out.append([])
	for r in rows:
		for c in cols:
			var d := mini(mini(r, rows - 1 - r), mini(c, cols - 1 - c))
			(out[d] as Array).append(Vector2i(c, r))
	return out


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s4_yangcong")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s4")
	if rule == null:
		print("!!! s4 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		var size := Vector2i(side, side)
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["s4"], size, int(SIZES[side]), 1, 0, 30, null, 60000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d: 生成失败（%.1fs）" % [side, side, cost])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
		# 层密度单调性独立复算
		var ms := {}
		for m in lv.get("mines", []):
			ms[Vector2i(int(m["c"]), int(m["r"]))] = true
		var layers := _layers(side, side)
		var dens: Array = []
		var mono_ok := true
		for t in layers.size():
			var layer: Array = layers[t]
			var mine_n := 0
			for p in layer:
				if ms.has(p):
					mine_n += 1
			dens.append("%d/%d" % [mine_n, layer.size()])
			if t > 0:
				var prev_m := 0
				for p in (layers[t - 1] as Array):
					if ms.has(p):
						prev_m += 1
				# m_{t-1}/|L_{t-1}| ≤ m_t/|L_t|
				if prev_m * layer.size() > mine_n * (layers[t - 1] as Array).size():
					mono_ok = false
		print("%dx%d: mines=%d clues=%d solved=%s board_ok=%s 层密度[外→内]=%s 单调=%s (%.1fs)" % [
			side, side, int(lv.get("total_mines", 0)), (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), " ".join(dens), str(mono_ok), cost])
		if not mono_ok:
			print("   !! 层密度非单调")
			ok_all = false
		if not solved or not board_ok:
			ok_all = false
	print("=== S4 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
