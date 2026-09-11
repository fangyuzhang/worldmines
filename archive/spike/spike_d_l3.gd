# spike_d_l3.gd —— L3 增量量化（plan1.9 §6.2）
#
# ① 3×3 全穷举：L0~L2 vs L0~L3 接受率；L3 增量 = L0~L3 − L0~L2；
#    对比完备天花板（Oracle 266）。
# ② L3 soundness：逐步 Oracle 包含性（含 L3 推出的结论）。
# ③ 5×5 / 6×6 经典接受率：L0~L2 vs L0~L3（贪心 S₀）。
#
# 判定：若 L3 增量接近完备天花板差值（136）⇒ L3 高优先；
#       若增量远小于 136 ⇒ 深度 2 归谬不够，需更强推理或放弃。

extends SceneTree

const TRIALS := 20
const S0_MAX := 8

var _s := SpikeASolver.new()
var _oracle := BruteForceOracle.new()
var _oracle_player := SolverPerfectPlayer.new()
var _box: Dictionary = {}


func _initialize() -> void:
	var t0 := Time.get_ticks_usec()
	print("[spike_d] 开始")

	# ── ① 3×3 全穷举 ──
	var total := 0
	var l2_ok := 0
	var l3_ok := 0
	var oracle_ok := 0
	for mask in (1 << 9):
		if mask % 64 == 0:
			print("[spike_d] mask=%d (已用 %dms)" % [mask, (Time.get_ticks_usec() - t0) / 1000])
		var mines_rc: Array = []
		for r in 3:
			for c in 3:
				if mask & (1 << (r * 3 + c)):
					mines_rc.append([r, c])
		var safes: Array = []
		for r in 3:
			for c in 3:
				if not mines_rc.has([r, c]):
					safes.append([r, c])
		if safes.is_empty():
			continue
		for s0 in safes:
			total += 1
			var s0v := Vector2i(s0[1], s0[0])
			_s.l3_enabled = false
			if _s.simulate(_build(mines_rc, 3, 3), [s0v])["success"]:
				l2_ok += 1
			_s.l3_enabled = true
			if _s.simulate(_build(mines_rc, 3, 3), [s0v])["success"]:
				l3_ok += 1
			var b := _build(mines_rc, 3, 3)
			b.reveal(s0v)
			if _oracle_player.solve(b, Callable())[0]:
				oracle_ok += 1
	print("[3x3] L0~L2=%d  L0~L3=%d  Oracle完备=%d  / %d" % [l2_ok, l3_ok, oracle_ok, total])
	print("[3x3] L3 增量 = %d 局（完备天花板增量 = %d）" % [l3_ok - l2_ok, oracle_ok - l2_ok])

	# ── ② L3 soundness（3×3 全穷举，逐步 Oracle 包含性） ──
	_box = {"checks": 0, "violations": 0, "worst": ""}
	_s.l3_enabled = true
	for mask in (1 << 9):
		var mines_rc: Array = []
		for r in 3:
			for c in 3:
				if mask & (1 << (r * 3 + c)):
					mines_rc.append([r, c])
		var safes: Array = []
		for r in 3:
			for c in 3:
				if not mines_rc.has([r, c]):
					safes.append([r, c])
		if safes.is_empty():
			continue
		for s0 in safes:
			var s0v := Vector2i(s0[1], s0[0])
			var b := _build(mines_rc, 3, 3)
			var verify := func(_bd: Board, d: Dictionary) -> bool:
				_check_step(_bd, d)
				return true
			_s.simulate(b, [s0v], verify)
	print("[soundness] L3 结论 ⊆ Oracle：%d 断言 / %d 违例  %s"
		% [_box.checks, _box.violations, "OK" if _box.violations == 0 else "*** UNSOUND ***"])

	var ms := (Time.get_ticks_usec() - t0) / 1000
	print("总耗时 %dms" % ms)
	quit(0)


func _check_step(board: Board, d: Dictionary) -> void:
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


func _build(mines_rc: Array, rows: int, cols: int) -> Board:
	var level := {"size": {"rows": rows, "cols": cols}, "total_mines": mines_rc.size(), "mines": [], "revealed": []}
	for m in mines_rc:
		(level["mines"] as Array).append({"r": m[0], "c": m[1]})
	var b := Board.new()
	b.load_level(level)
	return b


func _build2(mines: Array, rows: int, cols: int) -> Board:
	var level := {"size": {"rows": rows, "cols": cols}, "total_mines": mines.size(), "mines": [], "revealed": []}
	for m in mines:
		(level["mines"] as Array).append({"r": m.y, "c": m.x})
	var b := Board.new()
	b.load_level(level)
	return b


func _pick(rng: RandomNumberGenerator, rows: int, cols: int, k: int) -> Array:
	var all: Array = []
	for y in rows:
		for x in cols:
			all.append(Vector2i(x, y))
	for i in mini(k, all.size()):
		var j: int = rng.randi() % all.size()
		var tmp = all[i]
		all[i] = all[j]
		all[j] = tmp
	return all.slice(0, k)


func _safe(rows: int, cols: int, mines: Array) -> Array:
	var ms := {}
	for m in mines:
		ms[m] = true
	var out: Array = []
	for y in rows:
		for x in cols:
			var p := Vector2i(x, y)
			if not ms.has(p):
				out.append(p)
	return out


func _nbc(rows: int, cols: int, p: Vector2i) -> int:
	var n := 0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			if p.x + dx >= 0 and p.x + dx < cols and p.y + dy >= 0 and p.y + dy < rows:
				n += 1
	return n
