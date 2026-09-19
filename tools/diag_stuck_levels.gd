extends SceneTree

# 判定「卡住」的根因：关卡信息不足 vs 提示能力不足。
# 做法：复现 ProofLog.build 的卡住状态，然后用 CP-SAT 数该状态下还剩几个模型——
#   模型数 == 1 → 信息足够、只是没被判成 forced（提示能力缺口）
#   模型数 >= 2 →  действительно 存在二义性（关卡本身推不到底）
const CliShutdown := preload("res://tools/cli_shutdown.gd")
const ProofLogScript := preload("res://core/proof_log.gd")

const PATHS := [
	"res://levels/classic_07.json",
	"res://levels/generated_07.json",
]


func _initialize() -> void:
	for path in PATHS:
		var level := _read_json(path)
		if level.is_empty():
			print("%s: 读取失败" % path)
			continue
		var b := Board.new()
		b.load_level(level)
		var solver := HintSolver.new()
		var rounds := 0
		while b.state == Board.GameState.PLAYING and rounds < 200:
			var steps: Array = solver.hint(b)
			if steps.is_empty():
				break
			var applied := 0
			for st in steps:
				var step := st as ReasoningStep
				var c: Cell = b.grid.get_cell(step.pos)
				if c == null or c.state != Cell.State.HIDDEN:
					continue
				if step.state == "safe":
					b.reveal(step.pos)
				else:
					# 同 proof_log
					# 不允许进入
					b.toggle_flag(step.pos, false)
				applied += 1
			rounds += 1
			if applied == 0:
				break
		# 统计当前状态
		var hidden := 0
		var flagged := 0
		var revealed := 0
		for p in b.grid.all_positions():
			var c: Cell = b.grid.get_cell(p)
			match c.state:
				Cell.State.REVEALED: revealed += 1
				Cell.State.HIDDEN: hidden += 1
				Cell.State.FLAGGED: flagged += 1
		var total: int = b.grid.size().x * b.grid.size().y
		print("%s  state=%d  轮数=%d  已翻开=%d/%d  插旗=%d  仍隐藏=%d" % [
			path.get_file(), b.state, rounds, revealed, total, flagged, hidden])
		if b.state != Board.GameState.PLAYING:
			print("   → 已终局，无需判定")
			continue
		# 卡住状态下：用 hint_rule 的同一套 spec 数模型数
		var reg := RuleRegistry.default()
		var clue_id: String = b.rule_clue_id
		if clue_id == "":
			clue_id = str(HintSolver.VARIANT_TO_RULE.get(b.clue_variant, ""))
		var clue_rule: Object = reg.resolve(StringName(clue_id))
		var globals: Array = []
		for gid in b.rule_global_ids:
			var g: Object = reg.resolve(StringName(str(gid)))
			if g != null:
				globals.append(g)
		if clue_rule == null:
			print("   → 线索规则未解析到，无法判定")
			continue
		var oracle := RuleOracle.new(clue_rule, globals, b.grid.size(), b.total_mines, null)
		var active := {}
		for p in b.grid.all_positions():
			var c: Cell = b.grid.get_cell(p)
			if c.state != Cell.State.REVEALED:
				continue
			var con := b.get_player_constraint(p)
			match str(con.get("type", "")):
				"interval": active[p] = null
				"equality": active[p] = con["value"]
				"equality_pair": active[p] = [int(con["a"]), int(con["b"])]
				_: pass
		# 已确立的雷（我们插的旗，用于「演绎确证」口径）不作为已知条件——这正是要看的：
		#  只剩多少自由度。若 ==1 说明信息足够。
		var spec0 := oracle.build_spec(active, [], {})
		var n0: int = RuleCpSat.count_solutions(spec0)
		var proven: Array[Vector2i] = []
		for p in b.proven_mines:
			proven.append(p)
		var spec1 := oracle.build_spec(active, proven, {})
		var n1: int = RuleCpSat.count_solutions(spec1)
		# ASCII 输出避开控制台编码问题
		print("  ASCII total_mines=%d proven=%d models_zero_trust=%d models_with_proven=%d" % [
			b.total_mines, proven.size(), n0, n1])
	CliShutdown.request_exit(0)


func _process(delta: float) -> bool:
	return CliShutdown.poll(self)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}
