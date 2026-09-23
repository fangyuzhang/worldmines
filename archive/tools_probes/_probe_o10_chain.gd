# O10 全链路验证：mod 加载（生产路径）→ 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/o10_huanyou")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"o10")
	if rule == null:
		print("!!! o10 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s" % [str(rule.call("get_rule_id")), str(rule.call("describe").get("name"))])
	var gen := PuzzleGenerator.new()
	var ok_all := true
	for side in SIZES:
		var size := Vector2i(side, side)
		var lv: Dictionary = gen.generate_with_rules("o10", [], size, int(SIZES[side]), 1, 0, 30, null, 60000)
		if lv.is_empty():
			print("%dx%d: 生成失败" % [side, side])
			ok_all = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var c0: Dictionary = b.get_player_constraint(Vector2i(0, 0))
		var board_ok := not c0.is_empty()
		# 样本：打印 (0,0) 的线索（校验值域 0–4）
		print("%dx%d: mines=%d clues=%d solved=%s board_ok=%s sample=(0,0):%s" % [
			side, side, int(lv.get("total_mines", 0)), (lv.get("revealed", []) as Array).size(),
			str(solved), str(board_ok), str(c0.get("value", c0))])
		if not solved or not board_ok:
			ok_all = false
	print("=== 全链路: %s ===" % ("OK" if ok_all else "FAILED"))
	CliShutdown.request_exit(0 if ok_all else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
