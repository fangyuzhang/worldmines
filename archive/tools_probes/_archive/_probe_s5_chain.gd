# S5「行列凸」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 「每行每列的雷都连续」独立复算。
# 说明：本插件用**保守编码**（整盘行列连续 ⊂ GDD 的按块连续）——验证的是整盘形式。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := [5, 6, 7, 8, 9]


func _convex_ok(ms: Dictionary, cols: int, rows: int) -> Dictionary:
	var bad := 0
	for r in rows:
		var seen := false
		var closed := false
		for c in cols:
			if ms.has(Vector2i(c, r)):
				if closed:
					bad += 1
				seen = true
			elif seen:
				closed = true
	for c in cols:
		var seen2 := false
		var closed2 := false
		for r in rows:
			if ms.has(Vector2i(c, r)):
				if closed2:
					bad += 1
				seen2 = true
			elif seen2:
				closed2 = true
	return {"ok": bad == 0, "info": "断裂%d" % bad}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s5_hanglie")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s5")
	if rule == null:
		print("!!! s5 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var all_ok := true
	for side in SIZES:
		var rres: Dictionary = RuleFeasibility.resolve_mines("classic", ["s5"], side)
		var mines_n: int = int(rres.get("mines", -1))
		if mines_n < 0:
			print("%dx%d: 全候选 UNSAT" % [side, side])
			continue
		var std: bool = bool(rres.get("standard", true))
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["s5"], Vector2i(side, side),
			mines_n, 1, 0, 30, null, 90000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d(%d雷%s): 生成失败（%.1fs）" % [side, side, mines_n, "回退" if not std else "标准", cost])
			all_ok = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
		var ms := {}
		for m in lv.get("mines", []):
			ms[Vector2i(int(m["c"]), int(m["r"]))] = true
		var co := _convex_ok(ms, side, side)
		print("%dx%d(%d雷%s): clues=%d solved=%s board_ok=%s 连续=%s %s (%.1fs)" % [
			side, side, mines_n, "回退" if not std else "标准",
			(lv.get("revealed", []) as Array).size(), str(solved), str(board_ok),
			str(co["ok"]), str(co["info"]), cost])
		if not bool(co["ok"]) or not solved or not board_ok:
			all_ok = false
	print("=== S5 全链路: %s ===" % ("OK" if all_ok else "FAILED"))
	CliShutdown.request_exit(0 if all_ok else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
