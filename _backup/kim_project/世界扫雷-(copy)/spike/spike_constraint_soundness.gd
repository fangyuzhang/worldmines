# spike_constraint_soundness.gd —— 约束关 soundness 回归（MX/DT 融合消费层的正确性闸门）
#
# 运行： godot --headless --path "E:\Porject\kim project\lei" -s res://spike/spike_constraint_soundness.gd --quit
#
# 对含 MX/DT 全局约束的关卡，跑 SpikeASolver（已接入融合枚举），逐步用「带约束的」Oracle 比对结论：
#   求解器推出的结论 ⊆ Oracle（含约束）结论 ⇒ sound；⊄ ⇒ UNSOUND，必须停下来排查。
# 与 spike_a_run 的区别：这里给 Oracle 传了 constraint_variant/dominoes（否则无约束 Oracle 会误报）。
extends SceneTree

const BATCH := 50
const LEVELS_DIR := "res://levels"

var _solver := SpikeASolver.new()
var _oracle := BruteForceOracle.new()
var _oracle_empty := 0
var _oracle_empty_info := ""


func _initialize() -> void:
	print("=== start constraint soundness ===")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260907

	var paths := _collect_levels()
	push_error("DEBUG: collected %d levels" % paths.size())
	# 确定性洗牌（Fisher-Yates）
	for i in range(paths.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp = paths[i]
		paths[i] = paths[j]
		paths[j] = tmp

	var batch: Array = paths.slice(0, mini(BATCH, paths.size()))

	var total_checks := 0
	var total_violations := 0
	var solved := 0
	var worst := ""

	for p in batch:
		var r := _run_one(p)
		total_checks += r["checks"]
		total_violations += r["violations"]
		if r["success"]:
			solved += 1
		if r["violations"] > 0 and worst == "":
			worst = str(r["name"])
		push_error("DEBUG: %s checks=%d bad=%d" % [r["name"], r["checks"], r["violations"]])

	push_error("RESULT: 解出 %d/%d | 断言 %d | 违例 %d" % [solved, batch.size(), total_checks, total_violations])
	push_error("RESULT: soundness=%s" % ("OK" if total_violations == 0 else "*** UNSOUND ***"))
	if total_violations > 0:
		push_error("RESULT: 首个违例关=%s" % worst)

	var f := FileAccess.open("user://spike_constraint_soundness.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"batch": batch.size(), "solved": solved,
			"checks": total_checks, "violations": total_violations, "worst": worst,
			"oracle_empty": _oracle_empty, "oracle_empty_info": _oracle_empty_info,
		}, "  "))
		f.close()
	quit(0)


func _run_one(path: String) -> Dictionary:
	push_error("DEBUG: run %s" % path.get_file())
	var jf := FileAccess.open(path, FileAccess.READ)
	if jf == null:
		return {"name": path, "checks": 0, "violations": 0, "success": false}
	var level: Variant = JSON.parse_string(jf.get_as_text())
	jf.close()
	if not (level is Dictionary):
		return {"name": path, "checks": 0, "violations": 0, "success": false}

	# 初始翻开格 s0（revealed 里的安全格）
	var s0: Array[Vector2i] = []
	for r in level.get("revealed", []):
		s0.append(Vector2i(int(r["c"]), int(r["r"])))

	# 构造「未翻开」的 board（revealed 空，但保留 mines/variant/dominoes）
	var bare: Dictionary = level.duplicate(true)
	bare["revealed"] = []
	var b := Board.new()
	b.load_level(bare)

	var box := {"checks": 0, "bad": 0}
	var verify := func(bd: Board, d: Dictionary) -> bool:
		var verdict := _oracle_query(bd)
		if verdict.is_empty():
			return true  # Oracle 超限/无解，跳过本轮
		box["checks"] += 1
		for m in (d["mine"] as Array):
			if verdict.get(m, "") != "mine":
				box["bad"] += 1
		for s in (d["safe"] as Array):
			if verdict.get(s, "") != "safe":
				box["bad"] += 1
		return box["bad"] == 0

	push_error("DEBUG: simulate %s (s0=%d)" % [path.get_file(), s0.size()])
	var r := _solver.simulate(b, s0, verify)
	push_error("DEBUG: done %s" % path.get_file())
	return {"name": path.get_file(), "checks": box["checks"], "violations": box["bad"], "success": r["success"]}


## 带约束的 Oracle 查询（传 constraint_variant / dominoes，让 Oracle 构造 leaf_check）。
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
	# 通用变体查询：VariantConstraint 支持任意线索型（计数/DIST_SUM/HV/FR/Clock）+ 全局约束
	var vc := VariantConstraint.new(board.clue_variant, board.constraint_variant, board.dominoes, board.constraint_variant2, board.clue_variant2)
	var verdict := _oracle.query_variant(size, revealed, remaining, vc.check, known_mines)
	if verdict.is_empty():
		_oracle_empty += 1
		if _oracle_empty_info == "":
			_oracle_empty_info = "revealed=%d known=%d remaining=%d constraint=%d" % [revealed.size(), known_mines.size(), remaining, board.constraint_variant]
	return verdict


## 收集「计数型线索 + MX/DT 单约束」的关卡（排除双约束与非计数线索组合）。
func _collect_levels() -> Array:
	var out: Array = []
	# 7 个全局约束码 / 线索码 / SpikeASolver 支持的计数型线索
	var cons_codes := ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]
	var clue_codes := ["classic", "4n", "sc", "clock", "distsum", "hv", "loopruns", "fr"]
	var supported_clues := ["classic", "4n", "sc", "distsum", "hv", "clock", "fr", "loopruns"]
	var dir := DirAccess.open(LEVELS_DIR)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var base: String = fname.get_basename()
			var parts: PackedStringArray = base.split("_")
			var n_cons := 0
			var n_clue := 0
			var clue_ok := true
			# 前两段为「约束码 / 线索码」，末段为编号
			for i in mini(2, parts.size()):
				var c: String = parts[i]
				if c in cons_codes:
					n_cons += 1
				elif c in clue_codes:
					n_clue += 1
					if not (c in supported_clues):
						clue_ok = false
			# 至多 2 个约束（双约束 F 类）+ 至多 1 个线索（排除 E 类双线索 4n+hv 等）
			if n_cons <= 2 and n_clue <= 1 and clue_ok:
				out.append(LEVELS_DIR.path_join(fname))
		fname = dir.get_next()
	dir.list_dir_end()
	return out
