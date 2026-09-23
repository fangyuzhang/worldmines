extends SceneTree

## O4 编码二分诊断：逐层加约束，找出 is_feasible 崩在哪一层。
const CliShutdown := preload("res://tools/cli_shutdown.gd")
const NB8 := [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]
const N2_OUT := [
	Vector2i(-2, -2), Vector2i(-1, -2), Vector2i(0, -2), Vector2i(1, -2), Vector2i(2, -2),
	Vector2i(2, -1), Vector2i(2, 0), Vector2i(2, 1),
	Vector2i(2, 2), Vector2i(1, 2), Vector2i(0, 2), Vector2i(-1, 2), Vector2i(-2, 2),
	Vector2i(-2, 1), Vector2i(-2, 0), Vector2i(-2, -1),
]
const R07 := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var sc: Variant = load("res://demo/mods/o4_bianjing/entry.gd")
	sc.new().call("on_load")
	var rule: Object = RuleRegistry.default().resolve(&"o4")
	var side := 6
	var mines_n: int = int(R07[side])
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var mine_arr: Array = rule.call("place_mines", rng, side, side, mines_n)
	var mine_set := {}
	for p in mine_arr:
		mine_set[p] = true
	var active := {}
	for r in side:
		for c in side:
			var pos := Vector2i(c, r)
			if mine_set.has(pos) or not bool(rule.call("applies_to", pos, Vector2i(side, side))):
				continue
			active[pos] = rule.call("compute_clue", mine_set, pos, Vector2i(side, side))
	var oracle := RuleOracle.new(rule, [], Vector2i(side, side), mines_n, null)
	var spec: Dictionary = oracle.build_spec(active, [], {})
	var clues: Array = spec.get("clues", [])
	# 层 1：只保留每组 IR 的「最后一条」（f = A + u 那条）——u 自由
	var l1: Array = []
	var l2: Array = []
	var l3: Array = []
	for cd in clues:
		var ir: Array = cd.get("ir", [])
		l1.append({"r": cd["r"], "c": cd["c"], "ir": [ir[-1]]})
		l2.append({"r": cd["r"], "c": cd["c"], "ir": ir.slice(0, ir.size() - 1)})
		l3.append({"r": cd["r"], "c": cd["c"], "ir": ir})
	var s1 := spec.duplicate(true)
	s1["clues"] = l1
	s1["globals"] = []
	print("L1 只 f=A+u（u 自由、无配额）: %s" % str(RuleCpSat.is_feasible(s1)))
	# L0 系列：极简基线（手搭最小 spec 逐个特征排查）
	# L0a：无任何线索约束（只有 safe+雷数）——应 True
	var s0 := spec.duplicate(true)
	s0["clues"] = []
	s0["globals"] = []
	print("L0a 无线索约束（safe+雷数）: %s" % str(RuleCpSat.is_feasible(s0)))
	# L0b 系列：u 的三条线性化逐条测（w/u 自由——每条都应可满足）
	var l0b1: Array = []
	var l0b2: Array = []
	var l0b3: Array = []
	for cd in clues:
		var ir: Array = cd.get("ir", [])
		l0b1.append({"r": cd["r"], "c": cd["c"], "ir": [ir[0]]})
		l0b2.append({"r": cd["r"], "c": cd["c"], "ir": [ir[1]]})
		l0b3.append({"r": cd["r"], "c": cd["c"], "ir": [ir[2]]})
	for pair in [["L0b1 仅 u≤24w", l0b1], ["L0b2 仅 u≤D", l0b2], ["L0b3 仅 D−24(1−w)≤u", l0b3]]:
		var sx := spec.duplicate(true)
		sx["clues"] = pair[1]
		sx["globals"] = []
		print("%s: %s" % [pair[0], str(RuleCpSat.is_feasible(sx))])
	var s2 := spec.duplicate(true)
	s2["clues"] = l3
	s2["globals"] = []
	print("L2 完整逐格 IR（无配额）: %s" % str(RuleCpSat.is_feasible(s2)))
	var s3 := spec.duplicate(true)
	s3["clues"] = l3
	print("L3 完整逐格 IR + 配额 Σw=k（现状）: %s" % str(RuleCpSat.is_feasible(s3)))
	# L4：配额单测——只 Σw=k + 全 w 池（无逐格 IR）
	var s4 := spec.duplicate(true)
	s4["clues"] = []
	print("L4 仅配额 Σw=k: %s" % str(RuleCpSat.is_feasible(s4)))
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
