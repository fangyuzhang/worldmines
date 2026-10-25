extends SceneTree

func _solve(board: Board) -> Array:
	var check := VariantConstraint.new(board.clue_variant, board.constraint_variant, board.dominoes)
	var player := SolverPerfectPlayer.new()
	return player.solve(board, Callable(check, "check"))


func _init() -> void:
	print("=== 手工 classic_01~05（基准） ===")
	for i in range(1, 6):
		var text := FileAccess.get_file_as_string("res://levels/classic_%02d.json" % i)
		var d: Variant = JSON.parse_string(text)
		var b := Board.new()
		b.load_level(d)
		var r := _solve(b)
		print("  classic_%02d: revealed=%d 步数=%d" % [i, int(d["revealed"].size()), r[1]])

	print("=== generate() 7雷 (30%密度) ===")
	for seed in range(1, 4):
		var level := PuzzleGenerator.new().generate("classic", Vector2i(5, 5), 7, seed)
		if level.is_empty():
			print("  seed=%d 失败" % seed)
			continue
		var b := Board.new()
		b.load_level(level)
		var r := _solve(b)
		print("  seed=%d: revealed=%d 步数=%d" % [seed, int(level["revealed"].size()), r[1]])

	print("=== generate() 10雷 (40%密度) ===")
	for seed in range(1, 4):
		var level := PuzzleGenerator.new().generate("classic", Vector2i(5, 5), 10, seed)
		if level.is_empty():
			print("  seed=%d 失败" % seed)
			continue
		var b := Board.new()
		b.load_level(level)
		var r := _solve(b)
		print("  seed=%d: revealed=%d 步数=%d" % [seed, int(level["revealed"].size()), r[1]])
	quit()
