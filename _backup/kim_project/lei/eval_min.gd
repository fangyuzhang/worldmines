extends SceneTree

func _init() -> void:
	print("step1: start")
	var board: Board = LevelLoader.load_level("res://levels/classic_01.json")
	print("step2: loaded mines=", board.total_mines, " clue=", board.clue_variant)
	var check := VariantConstraint.new(board.clue_variant, board.constraint_variant, board.dominoes)
	print("step3: check created")
	var player := SolverPerfectPlayer.new()
	print("step4: solving...")
	var r := player.solve(board, Callable(check, "check"))
	print("step5: result=", r)
	quit()
