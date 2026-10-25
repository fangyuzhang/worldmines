# test_def_engine.gd —— Def 引擎一致性测试（文档第二篇 §2）
# 内置 Def 的 compute_clue / check_constraint 必须与 ClueEngine / ConstraintEngine 完全一致。
extends GutTest

var _engine := DefEngine.new()

const CLUE_MAP := {
	"classic": ClueEngine.Variant.CLASSIC,
	"4n": ClueEngine.Variant.N4,
	"sc": ClueEngine.Variant.SAME_COLOR,
	"clock": ClueEngine.Variant.CLOCK,
	"fr": ClueEngine.Variant.FR,
	"loopruns": ClueEngine.Variant.LOOP_RUNS,
	"distsum": ClueEngine.Variant.DIST_SUM,
	"hv": ClueEngine.Variant.HV,
}

const CONSTRAINT_MAP := {
	"mx": ConstraintEngine.Variant.MX,
	"rl": ConstraintEngine.Variant.RL,
	"pf": ConstraintEngine.Variant.PF,
	"qd": ConstraintEngine.Variant.QD,
	"ep": ConstraintEngine.Variant.EP,
	"4c": ConstraintEngine.Variant.FOUR_COLOR,
	"dt": ConstraintEngine.Variant.DT,
}


func test_clue_defs_match_engine() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var gsize := Vector2i(5, 5)
	for t in 20:
		var mine_set := {}
		for r in gsize.y:
			for c in gsize.x:
				if rng.randf() < 0.3:
					mine_set[Vector2i(c, r)] = true
		for def_name in CLUE_MAP:
			for r in gsize.y:
				for c in gsize.x:
					var pos := Vector2i(c, r)
					var got: Variant = _engine.compute_clue(def_name, mine_set, pos, gsize)
					var expected: Variant = ClueEngine.compute(CLUE_MAP[def_name], mine_set, pos, gsize)
					assert_eq(got, expected, "%s @ (%d,%d) 线索值应一致" % [def_name, c, r])


func test_constraint_defs_match_engine() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var gsize := Vector2i(5, 5)
	for t in 20:
		var mine_set := {}
		for r in gsize.y:
			for c in gsize.x:
				if rng.randf() < 0.3:
					mine_set[Vector2i(c, r)] = true
		for def_name in CONSTRAINT_MAP:
			var got: bool = _engine.check_constraint(def_name, mine_set, gsize)
			var expected: bool = ConstraintEngine.check(CONSTRAINT_MAP[def_name], mine_set, gsize)
			assert_eq(got, expected, "%s 约束检查应一致" % def_name)


func test_register_custom_clue_def() -> void:
	# 注册一个自定义线索 Def（8 邻求和，等价 classic），验证 compute 可用
	var engine := DefEngine.new()
	var ok: bool = engine.register_clue_def("my_sum8", {"type": "clue", "window": DefEngine.WINDOW_N8, "aggregate": DefEngine.AGG_SUM, "max": 8, "min_clue": 0})
	assert_true(ok, "注册自定义线索 Def 应成功")
	var mine_set := {Vector2i(0, 0): true, Vector2i(0, 1): true}
	var got: Variant = engine.compute_clue("my_sum8", mine_set, Vector2i(1, 1), Vector2i(3, 3))
	assert_eq(got, 2, "自定义 8 邻求和线索应正确计算")
