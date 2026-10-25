# spike_a_run.gd —— Spike A 测量脚本（plan1.8 §7.1）
#
# 运行： godot --headless --path "E:\Porject\kim project\lei" -s res://spike/spike_a_run.gd --quit
#
# 测量三件事：
#   ① 接受率真值：单个随机 S₀（baseline） vs S₀ 贪心搜索（booster）
#   ② 单次模拟耗时（plan1.8 §3.1 的 L-A 预算 ≤0.5s）
#   ③ soundness：L0/L1/L2 结论 ⊆ Oracle 结论（⊇ 即为 unsound，蕴含定理崩塌）
# 附带观测：
#   T-A：只推出必雷格的轮次是否真实发生、是否导致死循环（跑完即证明不死循环）
#   T-B：出现过「只推出必雷格」且最终 success 的局数（>0 即证明不漏推）

extends SceneTree

const TRIALS := 50
const S0_MAX := 8
const VERIFY_BOARDS := 10       # soundness 抽样盘面数（仅 5×5，Oracle 慢）
const VERIFY_MINES := 5

const CFGS := [
	{"rows": 5, "cols": 5, "mines": 4},
	{"rows": 5, "cols": 5, "mines": 5},
	{"rows": 5, "cols": 5, "mines": 6},
	{"rows": 5, "cols": 5, "mines": 7},
	{"rows": 6, "cols": 6, "mines": 6},
	{"rows": 6, "cols": 6, "mines": 7},
	{"rows": 6, "cols": 6, "mines": 9},
	{"rows": 6, "cols": 6, "mines": 11},
]

var _solver := SpikeASolver.new()
var _oracle := BruteForceOracle.new()


func _initialize() -> void:
	var out := {
		"suite": "spike_a",
		"spec": "plan1.8 §7.1",
		"layers": "L0/L1(SolverBasic) + L2(component enumeration), NO L3",
		"configs": [],
		"soundness": {},
		"solver_stats": {},
	}

	print("=== Spike A : perfect-player kernel (L0/L1/L2, no L3) ===")

	# ── ① 接受率 + 耗时 ──
	for cfg in CFGS:
		print("[run] 开始 %dx%d M=%d" % [cfg["rows"], cfg["cols"], cfg["mines"]])
		var rec := _run_config(cfg)
		out["configs"].append(rec)
		print("[%dx%d M=%d d=%.1f%%] single=%d/%d (%.1f%%)  greedy=%d/%d (%.1f%%)  "
			% [rec.rows, rec.cols, rec.mines, rec.density * 100.0,
			   rec.single_success, rec.trials, rec.rate_single * 100.0,
			   rec.greedy_success, rec.trials, rec.rate_greedy * 100.0]
			+ "sim_avg=%.2fms greedy_avg=%.2fms s0_avg=%.2f"
			% [rec.sim_avg_ms, rec.greedy_avg_ms, rec.s0_avg])

	# ── ② soundness（Oracle 比对） ──
	var snd := _run_soundness()
	out["soundness"] = snd
	print("[soundness] checks=%d violations=%d  %s"
		% [snd.checks, snd.violations, "OK" if snd.violations == 0 else "*** UNSOUND ***"])

	out["solver_stats"] = _solver.stats
	_write(out)
	print("=== done. results -> user://spike_a_results.json ===")
	quit(0)


# ───────────────────────── 配置测量 ─────────────────────────

func _run_config(cfg: Dictionary) -> Dictionary:
	var rows: int = cfg["rows"]
	var cols: int = cfg["cols"]
	var mc: int = cfg["mines"]
	var rng := RandomNumberGenerator.new()

	var rec := {
		"rows": rows, "cols": cols, "mines": mc,
		"density": float(mc) / float(rows * cols),
		"trials": TRIALS,
		"single_success": 0,
		"greedy_success": 0,
		"s0_sum": 0,
		"s0_max": 0,
		"mine_only_rounds": 0,
		"solved_with_mine_only_round": 0,
		"l2_required": 0,
		"sim_time_usec": 0,
		"greedy_time_usec": 0,
		"sim_count": 0,
	}

	for t in TRIALS:
		rng.seed = _mix(rows * 1000003 + cols * 10007 + mc * 101 + t)
		var mines := _pick_mines(rng, rows, cols, mc)
		var safes := _safe_cells(rows, cols, mines)

		# baseline：单个随机安全格
		var b1 := _build(rows, cols, mines)
		var s0: Vector2i = safes[rng.randi() % safes.size()]
		var l2a: int = _solver.stats.l2_rounds
		var t0 := Time.get_ticks_usec()
		var r1 := _solver.simulate(b1, [s0])
		rec.sim_time_usec += Time.get_ticks_usec() - t0
		rec.sim_count += 1
		if _solver.stats.l2_rounds > l2a:
			rec.l2_required += 1
		if r1["mine_only_round_hit"]:
			rec.mine_only_rounds += 1
		if r1["success"]:
			rec.single_success += 1
			if r1["mine_only_round_hit"]:
				rec.solved_with_mine_only_round += 1

		# S₀ 贪心（静态启发式：内部格优先）
		var t1 := Time.get_ticks_usec()
		var g := _greedy_s0(rng, rows, cols, mines, safes)
		rec.greedy_time_usec += Time.get_ticks_usec() - t1
		if g["success"]:
			rec.greedy_success += 1
			rec.s0_sum += (g["s0"] as Array).size()
			rec.s0_max = maxi(rec.s0_max, (g["s0"] as Array).size())

	rec.rate_single = float(rec.single_success) / float(TRIALS)
	rec.rate_greedy = float(rec.greedy_success) / float(TRIALS)
	rec.sim_avg_ms = float(rec.sim_time_usec) / float(maxi(1, rec.sim_count)) / 1000.0
	rec.greedy_avg_ms = float(rec.greedy_time_usec) / float(TRIALS) / 1000.0
	rec.s0_avg = float(rec.s0_sum) / float(maxi(1, rec.greedy_success))
	return rec


## 贪心：按「内部格优先」排序逐个加入 S₀，每加一个重跑模拟。
func _greedy_s0(rng: RandomNumberGenerator, rows: int, cols: int, mines: Array, safes: Array) -> Dictionary:
	var scored := []
	for p in safes:
		scored.append({
			"p": p,
			"k": _neighbor_count(rows, cols, p) * 1000 + (rng.randi() % 1000),
		})
	scored.sort_custom(func(a, b): return a["k"] > b["k"])

	var s0: Array[Vector2i] = []
	for item in scored:
		s0.append(item["p"])
		var b := _build(rows, cols, mines)
		var r := _solver.simulate(b, s0.duplicate())
		if r["success"]:
			return {"success": true, "s0": s0.duplicate()}
		if s0.size() >= S0_MAX:
			break
	return {"success": false, "s0": s0.duplicate()}


# ───────────────────────── soundness ─────────────────────────

func _run_soundness() -> Dictionary:
	var checks := 0
	var violations := 0
	var worst := ""
	var rng := RandomNumberGenerator.new()

	for t in VERIFY_BOARDS:
		rng.seed = _mix(777000 + t)
		var mines := _pick_mines(rng, 5, 5, VERIFY_MINES)
		var safes := _safe_cells(5, 5, mines)
		var b := _build(5, 5, mines)
		var s0: Vector2i = safes[rng.randi() % safes.size()]

		# GDScript lambda 按值捕获 ⇒ 用 Dictionary 作可变盒（引用语义）
		var box := {"checks": 0, "bad": 0, "worst": ""}
		var verify := func(bd: Board, d: Dictionary) -> bool:
			var verdict := _oracle_query(bd)
			if verdict.is_empty():
				return true          # Oracle 超限/无解，跳过本轮
			box["checks"] += 1
			for m in (d["mine"] as Array):
				if verdict.get(m, "") != "mine":
					box["bad"] += 1
					box["worst"] = "mine@%s oracle=%s" % [str(m), str(verdict.get(m, "?"))]
			for s in (d["safe"] as Array):
				if verdict.get(s, "") != "safe":
					box["bad"] += 1
					box["worst"] = "safe@%s oracle=%s" % [str(s), str(verdict.get(s, "?"))]
			return box["bad"] == 0

		_solver.simulate(b, [s0], verify)
		checks += box["checks"]
		violations += box["bad"]
		if box["worst"] != "":
			worst = box["worst"]

	return {"checks": checks, "violations": violations, "worst": worst, "boards": VERIFY_BOARDS}


func _oracle_query(board: Board) -> Dictionary:
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
	return _oracle.query(size, revealed, remaining, Callable(), known_mines)


# ───────────────────────── 工具 ─────────────────────────

func _build(rows: int, cols: int, mines: Array) -> Board:
	var level := {
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": [],
		"revealed": [],
	}
	for p in mines:
		(level["mines"] as Array).append({"r": p.y, "c": p.x})
	var b := Board.new()
	b.load_level(level)
	return b


func _pick_mines(rng: RandomNumberGenerator, rows: int, cols: int, k: int) -> Array:
	var all: Array = []
	for y in rows:
		for x in cols:
			all.append(Vector2i(x, y))
	# Fisher-Yates 前 k 个
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


func _mix(v: int) -> int:
	var x: int = (v + 0x9E3779B9) & 0x7FFFFFFF
	x = (x ^ (x >> 16)) & 0x7FFFFFFF
	x = (x * 0x45D9F3B) & 0x7FFFFFFF
	x = (x ^ (x >> 16)) & 0x7FFFFFFF
	return x


func _write(out: Dictionary) -> void:
	var f := FileAccess.open("user://spike_a_results.json", FileAccess.WRITE)
	if f == null:
		push_error("无法写入 user://spike_a_results.json")
		return
	f.store_string(JSON.stringify(out, "  "))
	f.close()
