# spike_b_soundness.gd —— Spike B（GDScript 侧）：逐步 soundness 全穷举校验
#
# 这是对「求解内核是否 sound」的正确检验（区别于被证伪的「蕴含定理」）：
#   在完美玩家模拟的**每一步**，用 BruteForceOracle 计算「当前玩家信息下」的
#   必然安全格 / 必雷格，断言 求解器推出的结论 ⊆ Oracle 结论。
#   （plan1.3 §7.4 资产② 的原意：传播器结论 ⊆ Oracle 结论）
#
# 若 ⊆ 成立 ⇒ 求解器 sound ⇒ 「提示永不害死玩家」与「模拟成功=全盘可确定」成立。
# 若 ⊄ ⇒ UNSOUND，必须中止量产排查。
#
# 范围：3×3 全部 512 布局 × 全部可选 S₀ = 2304 局，逐步校验 ⇒ 数千次断言。

extends SceneTree

const ROWS := 3
const COLS := 3

var _solver := SpikeASolver.new()
var _oracle := BruteForceOracle.new()

# 用 Dictionary 作为可变盒（GDScript lambda 按值捕获，Dictionary 是引用类型）
var _box: Dictionary = {}


func _initialize() -> void:
	_box = {"checks": 0, "violations": 0, "steps": 0, "oracle_skipped": 0, "worst": ""}
	var t0 := Time.get_ticks_usec()
	var games := 0

	for mask in (1 << (ROWS * COLS)):
		if mask % 64 == 0:
			print("[progress] mask=%d" % mask)
		var mines_rc: Array = []
		for r in ROWS:
			for c in COLS:
				if mask & (1 << (r * COLS + c)):
					mines_rc.append([r, c])
		var safes: Array = []
		for r in ROWS:
			for c in COLS:
				if not mines_rc.has([r, c]):
					safes.append([r, c])
		if safes.is_empty():
			continue
		for s0 in safes:
			games += 1
			var board := _build(mines_rc)
			var verify := func(_bd: Board, d: Dictionary) -> bool:
				_check_step(_bd, d)
				return true        # 不中断模拟，只累计违例
			_solver.simulate(board, [Vector2i(s0[1], s0[0])], verify)

	var ms := (Time.get_ticks_usec() - t0) / 1000
	print("=== Spike B : 逐步 soundness 全穷举（3×3） ===")
	print("对局 %d / 推理步 %d / Oracle 断言 %d / 跳过 %d"
		% [games, _box.steps, _box.checks, _box.oracle_skipped])
	print("soundness（推出的结论 ⊆ Oracle 结论）： %s  违例 %d"
		% ["OK" if _box.violations == 0 else "*** UNSOUND ***", _box.violations])
	if _box.violations > 0:
		print("   首个违例： %s" % _box.worst)
	print("耗时 %dms" % ms)

	var f := FileAccess.open("user://spike_b_soundness.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"suite": "spike_b_soundness",
			"games": games, "steps": _box.steps, "checks": _box.checks,
			"oracle_skipped": _box.oracle_skipped,
			"violations": _box.violations, "worst": _box.worst,
			"elapsed_ms": ms,
		}, "  "))
		f.close()
	quit(0)


func _check_step(board: Board, d: Dictionary) -> void:
	_box.steps += 1
	var size := board.grid.size()
	var revealed := {}
	var known_mines: Array[Vector2i] = []
	for y in size.y:
		for x in size.x:
			var p := Vector2i(x, y)
			var c := board.grid.get_cell(p)
			if c.state == Cell.State.FLAGGED:
				known_mines.append(p)
			elif c.state == Cell.State.REVEALED:
				revealed[p] = board.get_player_constraint(p)
	var remaining: int = board.total_mines - known_mines.size()
	var verdict := _oracle.query(size, revealed, remaining, Callable(), known_mines)
	if verdict.is_empty():
		_box.oracle_skipped += 1
		return

	for m in (d["mine"] as Array):
		_box.checks += 1
		if verdict.get(m, "") != "mine":
			_box.violations += 1
			if _box.worst == "":
				_box.worst = "mine@%s oracle=%s" % [str(m), str(verdict.get(m, "?"))]
	for s in (d["safe"] as Array):
		_box.checks += 1
		if verdict.get(s, "") != "safe":
			_box.violations += 1
			if _box.worst == "":
				_box.worst = "safe@%s oracle=%s" % [str(s), str(verdict.get(s, "?"))]


func _build(mines_rc: Array) -> Board:
	var level := {
		"size": {"rows": ROWS, "cols": COLS},
		"total_mines": mines_rc.size(),
		"mines": [],
		"revealed": [],
	}
	for m in mines_rc:
		(level["mines"] as Array).append({"r": m[0], "c": m[1]})
	var b := Board.new()
	b.load_level(level)
	return b
