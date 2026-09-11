extends SceneTree

func _initialize() -> void:
	var level := {
		"size": {"rows": 3, "cols": 3},
		"total_mines": 3,
		"mines": [{"r":0,"c":0},{"r":1,"c":1},{"r":2,"c":2}],
		"revealed": [],
	}
	var b := Board.new()
	b.load_level(level)
	var s := SpikeASolver.new()
	var r := s.simulate(b, [Vector2i(0, 2)])
	print("classic 3x3 结果: ", r)
	print("rounds=", r.get("rounds"), " revealed=", r.get("revealed"), " target=", r.get("target"))
	quit(0)
