# Z1「镜像」/ Z3「四象」/ Z5「等差行」统一全链路验证：
#   mod 加载（生产路径）→ 全尺寸生成（含雷数候选回退）→ ProofLog 复核 → Board 载盘 round-trip
#   + 各自约束的**独立复算**（不信任生成侧）。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")
const SIZES := [5, 6, 7, 8, 9]
const CASES := [
	{"dir": "z1_jingxiang", "id": "z1", "name": "镜像"},
	{"dir": "z3_sixiang", "id": "z3", "name": "四象"},
	{"dir": "z5_dengcha", "id": "z5", "name": "等差行"},
]


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var gen := PuzzleGenerator.new()
	var all_ok := true
	for c in CASES:
		var cid := str(c["id"])
		var r: Dictionary = api.load_mod("res://demo/mods/%s" % str(c["dir"]))
		var rule: Object = RuleRegistry.default().resolve(StringName(cid))
		print("=== %s「%s」 mod 加载: ok=%s ===" % [cid, str(c["name"]), str(r.get("ok"))])
		if rule == null:
			print("!!! %s 未注册" % cid)
			all_ok = false
			continue
		print("    规则: %s / %s / kind=%s" % [
			str(rule.call("get_rule_id")), str(rule.call("describe").get("name")),
			str(rule.call("get_kind"))])
		for side in SIZES:
			var rres: Dictionary = RuleFeasibility.resolve_mines("classic", [cid], side)
			var mines_n: int = int(rres.get("mines", -1))
			if mines_n < 0:
				print("    %dx%d: 全候选 UNSAT（理论不可行）" % [side, side])
				continue
			var std: bool = bool(rres.get("standard", true))
			var t0 := Time.get_ticks_msec()
			var lv: Dictionary = gen.generate_with_rules("classic", [cid], Vector2i(side, side),
				mines_n, 1, 0, 30, null, 60000)
			var cost := float(Time.get_ticks_msec() - t0) / 1000.0
			if lv.is_empty():
				print("    %dx%d(%d雷%s): 生成失败（%.1fs）" % [
					side, side, mines_n, "回退" if not std else "标准", cost])
				all_ok = false
				continue
			var solved := bool(ProofLog.build(lv).get("solved", false))
			var b := Board.new()
			b.load_level(lv)
			var board_ok := not b.get_player_constraint(Vector2i(0, 0)).is_empty()
			var detail := _check(cid, lv, side)
			var ok := bool(detail["ok"])
			print("    %dx%d(%d雷%s): clues=%d solved=%s board_ok=%s %s=%s %s (%.1fs)" % [
				side, side, mines_n, "回退" if not std else "标准",
				(lv.get("revealed", []) as Array).size(), str(solved), str(board_ok),
				str(c["name"]), str(ok), str(detail["info"]), cost])
			if not ok or not solved or not board_ok:
				all_ok = false
	print("=== Z1/Z3/Z5 全链路: %s ===" % ("OK" if all_ok else "FAILED"))
	CliShutdown.request_exit(0 if all_ok else 1)


## 各算子的独立约束复算。
func _check(cid: String, lv: Dictionary, side: int) -> Dictionary:
	var ms := {}
	for m in lv.get("mines", []):
		ms[Vector2i(int(m["c"]), int(m["r"]))] = true
	var n := side
	if cid == "z1":
		var bad := 0
		for r in n:
			for c in int(n / 2):
				if ms.has(Vector2i(c, r)) != ms.has(Vector2i(n - 1 - c, r)):
					bad += 1
		return {"ok": bad == 0, "info": "非对称点%d" % bad}
	if cid == "z3":
		var cnt := [0, 0, 0, 0]
		for m in lv.get("mines", []):
			var qi := ConstraintEngine.quadrant_of(int(m["r"]), int(m["c"]), n, n)
			if qi >= 0:
				cnt[qi] = int(cnt[qi]) + 1
		var eq: bool = int(cnt[0]) == int(cnt[1]) and int(cnt[1]) == int(cnt[2]) and int(cnt[2]) == int(cnt[3])
		return {"ok": eq, "info": "象限=%s" % str(cnt)}
	# z5
	var cnt2: Array = []
	for i in n:
		cnt2.append(0)
	for m in lv.get("mines", []):
		cnt2[int(m["r"])] = int(cnt2[int(m["r"])]) + 1
	if n < 2:
		return {"ok": true, "info": "行=%s" % str(cnt2)}
	var d: int = int(cnt2[1]) - int(cnt2[0])
	var ap := true
	for i in n - 1:
		if int(cnt2[i + 1]) - int(cnt2[i]) != d:
			ap = false
	return {"ok": ap, "info": "行=%s d=%d" % [str(cnt2), d]}


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
