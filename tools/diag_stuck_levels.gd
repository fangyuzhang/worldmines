extends SceneTree

# 判定「卡住」的根因：关卡信息不足 vs 提示能力不足。
# 做法：复现 ProofLog.build 的卡住状态，然后用 CP-SAT 数该状态下还剩几个模型——
#   模型数 == 1 → 信息足够、只是没被判成 forced（提示能力缺口）
#   模型数 >= 2 →  действительно 存在二义性（关卡本身推不到底）
#
# 用法：`-s res://tools/diag_stuck_levels.gd [-- <关卡路径> ...]`（不传参 = 下面两关）。
#   · 先给「门禁口径」一行（ProofLog.build 的 solved/轮数/步数，与 test_level_proof_coverage.gd 同口径），
#     再看模型数判定根因——两条一起看，避免把"门禁能不能过"和"为什么过不了"混为一谈。
#
# 为什么必须在**首帧之后**跑（本工具与 test 的门禁同款坑，两个方向都踩过）：
#   `_initialize()` 早于 autoload 装载，此时 S/Z 轴变体规则**还没进 RuleRegistry**——
#   带 global_rules 的关卡会被判「推不到底」（假红）；反过来，环境里 C# 后端不可用时
#   测试的 `pending()` 会让门禁静默跳过（假绿）。故这里显式打印后端可用性。
const CliShutdown := preload("res://tools/cli_shutdown.gd")
const ProofLogScript := preload("res://core/proof_log.gd")

const DEFAULT_PATHS := [
	"res://levels/classic_07.json",
	"res://levels/generated_07.json",
]

var _started := false


func _process(_delta: float) -> bool:
	# 首帧后才跑：等 autoload 把 S/Z 轴变体规则装进 RuleRegistry（见文件头说明）
	if not _started:
		_started = true
		_run(_selected_paths())
	return CliShutdown.poll(self)


## 命令行关卡路径；不传 = DEFAULT_PATHS。
func _selected_paths() -> Array:
	var picked: Array = []
	for a in OS.get_cmdline_user_args():
		var s := str(a).strip_edges()
		if s != "":
			picked.append(s)
	return picked if not picked.is_empty() else DEFAULT_PATHS


func _run(paths: Array) -> void:
	print("=== 后端可用性 ===")
	print("  RuleCpSat.available() = %s（false ⇒ 模型数走 GDScript 回退，且测试门禁会静默跳过）"
		% RuleCpSat.available())
	for path in paths:
		var level := _read_json(path)
		if level.is_empty():
			print("%s: 读取失败" % path)
			continue
		# 门禁口径先行（与 test_level_proof_coverage.gd 同口径）：
		# 「能不能推到底」看这一行；「为什么推不到底」看下面的模型数。
		var proof: Dictionary = ProofLogScript.build(level)
		print("%s  门禁：solved=%s 轮数=%s 步数=%s" % [
			path.get_file(), proof.get("solved"), proof.get("rounds"),
			(proof["steps"] as Array).size() if proof.has("steps") else "-"])
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
		if globals.size() < b.rule_global_ids.size():
			# 典型原因：跑在 autoload 之前 / 规则未注册 → 模型数会系统性偏大，不可作判定依据
			print("   → ⚠ 全局规则未全部解析（%d/%d）：本行以下结论不可信（规则未注册？）" % [
				globals.size(), b.rule_global_ids.size()])
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


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}
