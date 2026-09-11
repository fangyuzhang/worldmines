extends SceneTree

func _initialize() -> void:
	print("t0")
	var level := {
		"size": {"rows": 3, "cols": 3},
		"total_mines": 3,
		"mines": [{"r":0,"c":0},{"r":0,"c":1},{"r":0,"c":2}],
		"revealed": [],
	}
	var b := Board.new()
	b.load_level(level)
	print("t1 board ok")
	var s := SpikeASolver.new()
	s.l3_enabled = true
	s.l3_depth = 1
	print("t2 solver ok")
	var r := s.simulate(b, [Vector2i(2, 0)])
	print("t3 result=", r)
	print("t4 done")
	quit(0)
