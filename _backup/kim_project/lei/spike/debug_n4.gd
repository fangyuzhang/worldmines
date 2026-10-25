extends SceneTree

func _initialize() -> void:
	# 手工构造一个 N4 盘面
	var level := {
		"size": {"rows": 5, "cols": 5},
		"total_mines": 5,
		"mines": [{"r":0,"c":0},{"r":0,"c":4},{"r":2,"c":2},{"r":4,"c":0},{"r":4,"c":4}],
		"revealed": [],
	}
	var b := Board.new()
	b.clue_variant = ClueEngine.Variant.N4
	b.load_level(level)
	b.reveal(Vector2i(2, 0))

	var size := b.grid.size()
	for y in size.y:
		for x in size.x:
			var p := Vector2i(x, y)
			var c := b.grid.get_cell(p)
			if c.state == Cell.State.REVEALED:
				print("revealed ", p, "  constraint=", b.get_player_constraint(p), "  raw_value=", c.value)

	# 收集 revealed
	var revealed := {}
	for y in size.y:
		for x in size.x:
			var p := Vector2i(x, y)
			if b.grid.get_cell(p).state == Cell.State.REVEALED:
				revealed[p] = b.get_player_constraint(p)

	# 直接调 _n4_check 验证真解
	print("n4_check(真解) = ", _n4_check(b.get_mine_positions(), revealed, size))

	# 直接调 query_variant
	var oracle := BruteForceOracle.new()
	var verdict := oracle.query_variant(size, revealed, 5, _n4_check, [])
	print("query_variant 返回键数 = ", verdict.size())
	print("verdict 内容 = ", verdict)
	quit(0)


func _n4_check(mine_set: Array, revealed: Dictionary, grid_size: Vector2i) -> bool:
	var ms := {}
	for m in mine_set:
		ms[m] = true
	for pos in revealed:
		var con: Dictionary = revealed[pos]
		if con.get("type", "") != "equality":
			continue
		if not (con.get("value", 0) is int):
			continue
		var v: int = con["value"]
		var cnt := 0
		for d in ClueEngine.orthogonal_dirs():
			var p: Vector2i = pos + d
			if p.x >= 0 and p.x < grid_size.x and p.y >= 0 and p.y < grid_size.y and ms.has(p):
				cnt += 1
		if cnt != v:
			return false
	return true
