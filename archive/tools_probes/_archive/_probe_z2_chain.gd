# Z2「相邻行锁」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 「相邻行雷数差绝对值 == 1」独立复算。
# 注意：Z2 有 GDD 指出的**奇偶性要求**——6×6 的 R(R−1)/2 = 15 为奇 ⇒ N 必须为奇数，
# 标准 14 不可满足；故这里用 RuleFeasibility.resolve_mines 取各尺寸的实际可用雷数（候选回退）。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := [5, 6, 7, 8, 9]


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/z2_xianglin")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"z2")
	if rule == null:
		print("!!! z2 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		# 候选雷数解析（含回退）——Z2 在 6×6 上标准值不可行
		var rres: Dictionary = RuleFeasibility.resolve_mines("classic", ["z2"], side)
		var mines_n: int = int(rres.get("mines", -1))
		if mines_n < 0:
			print("%dx%d: 全候选 UNSAT（理论不可行）" % [side, side])
			continue
		var std: bool = bool(rres.get("standard", true))
		var size := Vector2i(side, side)
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["z2"], size, mines_n, 1, 0, 30, null, 60000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d=%d雷%s: 生成失败（%.1fs）" % [side, side, mines_n, "（候选回退）" if not std else "", cost])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
		# 行差绝对值 == 1 独立复算
		var cnt: Array = []
		for i in side:
			cnt.append(0)
		for m in lv.get("mines", []):
			cnt[int(m["r"])] = int(cnt[int(m["r"])]) + 1
		var lock_ok := true
		for i in side - 1:
			if absi(int(cnt[i + 1]) - int(cnt[i])) != 1:
				lock_ok = false
		print("%dx%d(%d雷%s): clues=%d solved=%s board_ok=%s 行雷数=%s 锁=%s (%.1fs)" % [
			side, side, mines_n, "回退" if not std else "标准", (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), str(cnt), str(lock_ok), cost])
		if not lock_ok:
			print("   !! 相邻行差不为 1")
			ok_all = false
		if not solved or not board_ok:
			ok_all = false
	print("=== Z2 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
