# test_def_constraint.gd —— Def 驱动约束检查器测试（文档 §2.6）
extends GutTest


func test_def_constraint_matches_variant() -> void:
	var engine := DefEngine.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var gsize := Vector2i(5, 5)
	for t in 20:
		var mine_set: Array[Vector2i] = []
		for r in gsize.y:
			for c in gsize.x:
				if rng.randf() < 0.3:
					mine_set.append(Vector2i(c, r))
		var ms := {}
		for p in mine_set:
			ms[p] = true
		var revealed := {}
		for r in gsize.y:
			for c in gsize.x:
				if rng.randf() < 0.5:
					var pos := Vector2i(c, r)
					var val: Variant = ClueEngine.compute(ClueEngine.Variant.CLASSIC, ms, pos, gsize)
					revealed[pos] = {"type": "equality", "value": val}
		# 经典线索 + 镜像约束：DefConstraint vs VariantConstraint
		var vc := VariantConstraint.new(ClueEngine.Variant.CLASSIC, ConstraintEngine.Variant.MX)
		var dc := DefConstraint.new(engine, "classic", "mx")
		assert_eq(dc.check(mine_set, revealed, gsize), vc.check(mine_set, revealed, gsize), "第 %d 轮一致性" % t)


func test_oracle_with_mod_constraint() -> void:
	# mod 注册镜像约束 Def，Oracle 用 DefConstraint 参与唯一解校验
	var engine := DefEngine.new()
	engine.register_constraint_def("my_mirror", {"type": "constraint", "op": DefEngine.OP_SYMMETRY_AXIS})
	var check := DefConstraint.new(engine, "classic", "my_mirror")
	var oracle := BruteForceOracle.new()
	# 3×3，中心 value=2，2 雷，镜像约束 → 3 个镜像对 + 轴列双格 (0,1)+(2,1) = 4 个解
	var revealed := {Vector2i(1, 1): {"type": "equality", "value": 2}}
	var cnt := oracle.count_solutions_variant(Vector2i(3, 3), revealed, 2, Callable(check, "check"), [], 4)
	assert_eq(cnt, 4, "mod 镜像约束下中心 value=2 应有 4 个解")
