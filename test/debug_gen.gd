# debug_gen.gd —— 临时：逐个约束布雷，每步 flush
extends SceneTree

func _test(gen: PuzzleGenerator, name: String, constraint: int, cols: int, rows: int, mines: int) -> void:
	var t0 := Time.get_ticks_msec()
	var r := gen._place_mines(constraint, cols, rows, mines)
	print("%s -> %d 雷, %d ms" % [name, r.size(), Time.get_ticks_msec() - t0])

func _init() -> void:
	var gen := PuzzleGenerator.new()
	_test(gen, "MX", ConstraintEngine.Variant.MX, 5, 5, 6)
	_test(gen, "QD", ConstraintEngine.Variant.QD, 5, 5, 6)
	_test(gen, "DT", ConstraintEngine.Variant.DT, 6, 6, 10)
	_test(gen, "EP", ConstraintEngine.Variant.EP, 5, 5, 6)
	_test(gen, "4C", ConstraintEngine.Variant.FOUR_COLOR, 6, 6, 8)
	_test(gen, "RL", ConstraintEngine.Variant.RL, 5, 5, 8)
	_test(gen, "PF", ConstraintEngine.Variant.PF, 5, 5, 8)
	quit(0)
