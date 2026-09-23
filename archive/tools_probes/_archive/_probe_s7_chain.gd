# S7「分量数 K」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 「八连通块数 == K」独立复算。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := [5, 6, 7, 8, 9]
const K_BY_SIZE := {5: 2, 6: 3, 7: 3, 8: 4, 9: 4}
const DIRS8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


func _components(mines: Array) -> int:
	var ms := {}
	for m in mines:
		ms[Vector2i(int(m["c"]), int(m["r"]))] = true
	var seen := {}
	var comps := 0
	for start in ms:
		if seen.has(start):
			continue
		comps += 1
		var stack: Array = [start]
		seen[start] = true
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			for d in DIRS8:
				var q: Vector2i = p + (d as Vector2i)
				if ms.has(q) and not seen.has(q):
					seen[q] = true
					stack.append(q)
	return comps


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s7_fenliang")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s7")
	if rule == null:
		print("!!! s7 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var all_ok := true
	for side in SIZES:
		var rres: Dictionary = RuleFeasibility.resolve_mines("classic", ["s7"], side)
		var mines_n: int = int(rres.get("mines", -1))
		if mines_n < 0:
			print("%dx%d: 全候选 UNSAT" % [side, side])
			continue
		var std: bool = bool(rres.get("standard", true))
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["s7"], Vector2i(side, side),
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
		var comps := _components(lv.get("mines", []))
		var k: int = int(K_BY_SIZE.get(side, 4))
		print("%dx%d(%d雷%s): clues=%d solved=%s board_ok=%s 块数=%d 期望K=%d OK=%s (%.1fs)" % [
			side, side, mines_n, "回退" if not std else "标准",
			(lv.get("revealed", []) as Array).size(), str(solved), str(board_ok),
			comps, k, str(comps == k), cost])
		if comps != k or not solved or not board_ok:
			all_ok = false
	print("=== S7 全链路: %s ===" % ("OK" if all_ok else "FAILED"))
	CliShutdown.request_exit(0 if all_ok else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
