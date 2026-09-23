# S2「重心」全链路验证：mod 加载（生产路径）→ 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 重心约束独立复算（不信任生成侧）。S2 是全局约束类，故以「经典线索 + s2」组合验证
# （= 总表「重心（底座：经典）」）。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s2_zhongxin")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s2")
	if rule == null:
		print("!!! s2 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		var size := Vector2i(side, side)
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["s2"], size, int(SIZES[side]), 1, 0, 30, null, 60000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d: 生成失败（%.1fs）" % [side, side, cost])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var c0: Dictionary = b.get_player_constraint(Vector2i(0, 0))
		var board_ok := not c0.is_empty()
		# 重心约束独立复算（一阶矩区间）
		var n: int = int(lv.get("total_mines", 0))
		var sx := 0
		var sy := 0
		for m in lv.get("mines", []):
			sx += int(m["c"])
			sy += int(m["r"])
		var side_i: int = int(side)
		var clo: int = (side_i - 1) / 2
		var chi: int = side_i / 2
		var lo: int = n * clo
		var hi: int = n * chi
		var cent_ok: bool = sx >= lo and sx <= hi and sy >= lo and sy <= hi
		print("%dx%d: mines=%d clues=%d solved=%s board_ok=%s Σx=%d Σy=%d 区间[%d,%d] 重心OK=%s (%.1fs)" % [
			side, side, n, (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), sx, sy, lo, hi, str(cent_ok), cost])
		if not cent_ok:
			print("   !! 一阶矩越界")
			ok_all = false
		if not solved or not board_ok:
			ok_all = false
	print("=== S2 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
