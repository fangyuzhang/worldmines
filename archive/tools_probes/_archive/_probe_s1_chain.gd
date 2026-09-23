# S1「局部禁形」全链路验证：mod 加载（生产路径）→ 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip。
# S1 是全局约束类（KIND_GLOBAL），故以「经典线索 + s1 约束」组合验证（= 总表「局部禁形（底座：经典）」）。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s1_jinxing")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s1")
	if rule == null:
		print("!!! s1 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		var size := Vector2i(side, side)
		var lv: Dictionary = gen.generate_with_rules("classic", ["s1"], size, int(SIZES[side]), 1, 0, 30, null, 60000)
		if lv.is_empty():
			print("%dx%d: 生成失败" % [side, side])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var c0: Dictionary = b.get_player_constraint(Vector2i(0, 0))
		var board_ok := not c0.is_empty()
		print("%dx%d: mines=%d clues=%d solved=%s board_ok=%s sample=(0,0):%s" % [
			side, side, int(lv.get("total_mines", 0)), (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), str(c0.get("value", c0))])
		# 独立校验：该盘的雷位必须满足「任意 2×2 ≤ 2 雷」（复算，不信任生成侧）
		var ms := {}
		for m in lv.get("mines", []):
			ms[Vector2i(int(m["c"]), int(m["r"]))] = true
		var bad := 0
		for rr in side - 1:
			for c in side - 1:
				var n := 0
				for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]:
					if ms.has(Vector2i(c + d.x, rr + d.y)):
						n += 1
				if n > 2:
					bad += 1
		if bad > 0:
			print("   !! 约束违反：%d 个 2×2 窗口 >2 雷" % bad)
			ok_all = false
		if not solved or not board_ok:
			ok_all = false
	print("=== S1 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
