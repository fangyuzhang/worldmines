# S3「无环」全链路验证：mod 加载 → 全尺寸生成 → ProofLog 复核 → Board 载盘 round-trip
# + 「八邻接图是森林」独立复算（每个连通分量：边数 == 点数 − 1）。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := [5, 6, 7, 8, 9]
const DIRS8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


func _forest_ok(mines: Array) -> Dictionary:
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
		var verts := 0
		var edge_twice := 0
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			verts += 1
			for d in DIRS8:
				var q: Vector2i = p + (d as Vector2i)
				if ms.has(q):
					edge_twice += 1
					if not seen.has(q):
						seen[q] = true
						stack.append(q)
		if edge_twice / 2 != verts - 1:
			return {"ok": false, "info": "分量边%d≠点%d−1" % [edge_twice / 2, verts]}
	return {"ok": true, "info": "分量数=%d" % comps}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/s3_wuhuan")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var rule: Object = RuleRegistry.default().resolve(&"s3")
	if rule == null:
		print("!!! s3 未注册")
		CliShutdown.request_exit(1)
		return
	print("规则注册: %s / %s / kind=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("describe").get("name")), str(rule.call("get_kind"))])
	var gen := PuzzleGenerator.new()
	var all_ok := true
	for side in SIZES:
		var rres: Dictionary = RuleFeasibility.resolve_mines("classic", ["s3"], side)
		var mines_n: int = int(rres.get("mines", -1))
		if mines_n < 0:
			print("%dx%d: 全候选 UNSAT" % [side, side])
			continue
		var std: bool = bool(rres.get("standard", true))
		var t0 := Time.get_ticks_msec()
		var lv: Dictionary = gen.generate_with_rules("classic", ["s3"], Vector2i(side, side),
			mines_n, 1, 0, 30, null, 90000)
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if lv.is_empty():
			print("%dx%d(%d雷%s): 生成失败（%.1fs）——GDD 预警小盘可能欠产" % [
				side, side, mines_n, "回退" if not std else "标准", cost])
			all_ok = false
			continue
		var solved := bool(ProofLog.build(lv).get("solved", false))
		var b := Board.new()
		b.load_level(lv)
		var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
		var fo := _forest_ok(lv.get("mines", []))
		print("%dx%d(%d雷%s): clues=%d solved=%s board_ok=%s 森林=%s %s (%.1fs)" % [
			side, side, mines_n, "回退" if not std else "标准",
			(lv.get("revealed", []) as Array).size(), str(solved), str(board_ok),
			str(fo["ok"]), str(fo["info"]), cost])
		if not bool(fo["ok"]) or not solved or not board_ok:
			all_ok = false
	print("=== S3 全链路: %s ===" % ("OK" if all_ok else "FAILED"))
	CliShutdown.request_exit(0 if all_ok else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
