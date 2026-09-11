# debug_p1.gd —— 临时：验证 ClueEngine/ConstraintEngine/VariantRegistry/VariantConstraint
extends SceneTree

func _init() -> void:
	print("=== ClueEngine ===")
	var ms := {Vector2i(1, 0): true}
	var gs := Vector2i(3, 3)
	print("classic=", ClueEngine.compute(ClueEngine.Variant.CLASSIC, ms, Vector2i(1, 1), gs))
	print("n4=", ClueEngine.compute(ClueEngine.Variant.N4, ms, Vector2i(1, 1), gs))
	print("clock=", ClueEngine.compute(ClueEngine.Variant.CLOCK, ms, Vector2i(1, 1), gs))
	print("hv=", ClueEngine.compute(ClueEngine.Variant.HV, ms, Vector2i(1, 1), gs))
	print("fr=", ClueEngine.compute(ClueEngine.Variant.FR, ms, Vector2i(0, 1), gs))
	print("loopruns=", ClueEngine.compute(ClueEngine.Variant.LOOP_RUNS, ms, Vector2i(1, 1), gs))
	print("distsum=", ClueEngine.compute(ClueEngine.Variant.DIST_SUM, ms, Vector2i(1, 1), gs))
	print("sc=", ClueEngine.compute(ClueEngine.Variant.SAME_COLOR, ms, Vector2i(1, 1), gs))

	print("=== ConstraintEngine ===")
	var mx_mines := {Vector2i(0, 1): true, Vector2i(2, 1): true}
	print("MX 对称=", ConstraintEngine.check(ConstraintEngine.Variant.MX, mx_mines, Vector2i(3, 3)))

	print("=== VariantRegistry ===")
	print("变体数=", VariantRegistry.definitions().size())
	print("classic clue=", VariantRegistry.clue_of("classic"))
	print("mx constraint=", VariantRegistry.constraint_of("mx"))
	print("MX+EP=", VariantRegistry.global_pair_compat("mx", "ep"))
	print("MX+RL=", VariantRegistry.global_pair_compat("mx", "rl"))

	print("=== VariantConstraint ===")
	var vc := VariantConstraint.new(ClueEngine.Variant.N4, -1)
	var revealed := {Vector2i(1, 1): {"type": "equality", "value": 1}}
	print("n4 check=", vc.check([Vector2i(1, 0)], revealed, gs))

	quit(0)
