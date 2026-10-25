# spike_c_run.gd —— Spike C：端到端生成器（4N × 5×5）+ N4 soundness
#
# plan1.9 §6.1：s0_greedy_search + construct_one 端到端，跑 1 个真实变体（4N）。
# 验证三件事：
#   ① 产出 15 关且全部 simulate().success
#   ② 接受率（贪心 S₀ 在 N4 下的实测值）
#   ③ N4 求解器 soundness（Oracle query_variant + N4 check 回调，逐步包含性）

extends SceneTree

const S0_MAX := 8
const N_TRIALS := 100        # 接受率样本
const N_LEVELS := 15         # 目标产出关数
const SOUND_BOARDS := 20     # soundness 抽样盘面数

var _solver := SpikeASolver.new()
var _oracle := BruteForceOracle.new()
var _box: Dictionary = {}


func _initialize() -> void:
	_solver.clue_variant = ClueEngine.Variant.N4
	var t0 := Time.get_ticks_usec()

	# ── ① 产出 15 关 ──
	var produced := 0
	var tries := 0
	var s0_sizes: Array = []
	while produced < N_LEVELS and tries < 400:
		tries += 1
		var g := _gen_level(1000 + tries, 5, 5, 5)
		if g["success"]:
			produced += 1
			s0_sizes.append((g["s0"] as Array).size())
	print("[spike_c] 产出 %d 关（构造尝试 %d 次，接受率 %.1f%%）  平均 |S0|=%.2f"
		% [produced, tries, 100.0 * produced / tries, _avg(s0_sizes)])

	# ── ② 接受率（贪心 S₀，按密度） ──
	for mc in [4, 5, 6]:
		var ok := 0
		for t in N_TRIALS:
			var g2 := _gen_level(5000 + mc * 1000 + t, 5, 5, mc)
			if g2["success"]:
				ok += 1
		print("[spike_c] 4N 5x5 M=%d 贪心接受率 = %d/%d (%.1f%%)"
			% [mc, ok, N_TRIALS, 100.0 * ok / N_TRIALS])

	# ── ③ N4 soundness（逐步 Oracle 包含性） ──
	_box = {"checks": 0, "violations": 0, "worst": ""}
	for t in SOUND_BOARDS:
		var rng := RandomNumberGenerator.new()
		rng.seed = 9000 + t
		var mines := _pick_mines(rng, 5, 5, 5)
		var safes := _safe_cells(5, 5, mines)
		var b := _build_n4(5, 5, mines)
		var s0: Vector2i = safes[rng.randi() % safes.size()]
		var verify := func(bd: Board, d: Dictionary) -> bool:
			_check_step(bd, d)
			return true
		_solver.simulate(b, [s0], verify)
	print("[spike_c] N4 soundness：%d 断言 / %d 违例  %s"
		% [_box.checks, _box.violations, "OK" if _box.violations == 0 else "*** UNSOUND ***"])

	var ms := (Time.get_ticks_usec() - t0) / 1000
	print("[spike_c] 总耗时 %dms" % ms)

	var f := FileAccess.open("user://spike_c_result.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"suite": "spike_c", "variant": "N4", "grid": "5x5",
			"levels_produced": produced, "construct_tries": tries,
			"s0_avg": _avg(s0_sizes),
			"soundness_checks": _box.checks, "soundness_violations": _box.violations,
			"elapsed_ms": ms,
		}, "  "))
		f.close()
	quit(0)


# ───────────────────────── 生成器 ─────────────────────────

## construct_one（简化：布雷 + S₀ 贪心，不含遮蔽——遮蔽只减线索、降低接受率，方向明确）
func _gen_level(seed: int, rows: int, cols: int, M: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var mines := _pick_mines(rng, rows, cols, M)
	var safes := _safe_cells(rows, cols, mines)

	# 静态启发式排序：内部格优先（邻格数多），tie-break 用 rng
	var scored := []
	for p in safes:
		scored.append({"p": p, "k": _neighbor_count(rows, cols, p) * 1000 + (rng.randi() % 1000)})
	scored.sort_custom(func(a, b): return a["k"] > b["k"])

	var s0: Array[Vector2i] = []
	for item in scored:
		s0.append(item["p"])
		var b := _build_n4(rows, cols, mines)
		var r := _solver.simulate(b, s0.duplicate())
		if r["success"]:
			return {"success": true, "mines": mines, "s0": s0.duplicate()}
		if s0.size() >= S0_MAX:
			break
	return {"success": false, "mines": mines, "s0": s0.duplicate()}


# ───────────────────────── N4 soundness ─────────────────────────

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
	var verdict := _oracle.query_variant(size, revealed, remaining, _n4_check, known_mines)
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


## N4 约束检查（Oracle query_variant 的回调）：候选雷集 vs 已翻开线索值。
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


# ───────────────────────── 工具 ─────────────────────────

func _build_n4(rows: int, cols: int, mines: Array) -> Board:
	var level := {
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": [],
		"revealed": [],
	}
	for m in mines:
		(level["mines"] as Array).append({"r": m.y, "c": m.x})
	var b := Board.new()
	b.clue_variant = ClueEngine.Variant.N4    # 必须在 load_level 之前设，_compute_clues 才会用 N4
	b.load_level(level)
	return b


func _pick_mines(rng: RandomNumberGenerator, rows: int, cols: int, k: int) -> Array:
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


func _safe_cells(rows: int, cols: int, mines: Array) -> Array:
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


func _neighbor_count(rows: int, cols: int, p: Vector2i) -> int:
	var n := 0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var nx: int = p.x + dx
			var ny: int = p.y + dy
			if nx >= 0 and nx < cols and ny >= 0 and ny < rows:
				n += 1
	return n


func _avg(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var s := 0
	for v in arr:
		s += int(v)
	return float(s) / arr.size()
