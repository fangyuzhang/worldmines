# Z4「行列同序」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 「行和 == 列和」独立复算。Z4 是全局约束类，故以「经典线索 + z4」组合验证。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/z4_hangliesu")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"z4")
	if rule == null:
		print("!!! z4 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		var n: int = int(side)
		var size := Vector2i(n, n)
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["z4"], size, int(SIZES[side]), 1, 0, 30, null, 60000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d: 生成失败（%.1fs）" % [n, n, cost])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
		# 行和 == 列和 独立复算
		var row_cnt: Array = []
		var col_cnt: Array = []
		for i in n:
			row_cnt.append(0)
			col_cnt.append(0)
		for m in lv.get("mines", []):
			row_cnt[int(m["r"])] = int(row_cnt[int(m["r"])]) + 1
			col_cnt[int(m["c"])] = int(col_cnt[int(m["c"])]) + 1
		var eq_ok := true
		for i in n:
			if int(row_cnt[i]) != int(col_cnt[i]):
				eq_ok = false
		print("%dx%d: mines=%d clues=%d solved=%s board_ok=%s 行=%s 列=%s 同序=%s (%.1fs)" % [
			n, n, int(lv.get("total_mines", 0)), (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), str(row_cnt), str(col_cnt), str(eq_ok), cost])
		if not eq_ok:
			print("   !! 行列不同序")
			ok_all = false
		if not solved or not board_ok:
			ok_all = false
	print("=== Z4 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
