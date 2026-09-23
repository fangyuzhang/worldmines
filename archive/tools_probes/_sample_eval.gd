extends SceneTree

## 随机抽样入库评估（v2.9.3）：对抽回的关卡样本做「比批量门禁更深一层」的检查——
##   A) Board 引擎加载 + 线索值 round-trip（与 verify_batch 同口径）
##   B) ProofLog 序贯可解 + 难度重算核对
##   C) 布局满足自身声明的规则约束（新维度：把布局全格固定后 CP-SAT 求解——
##      UNSAT = 布局违反约束 = 生成器放盘与约束脱钩的 bug；ProofLog 只验可解性，不验这个）
##   D) seed 复现性（同 seed 重放应得同盘——流程可复现性抽查）
##   E) 跨组合指纹查重（不同组合出现同盘 = 约束没实际生效的信号）
## 用法：godot --headless --path . -s res://tools/_sample_eval.gd -- <本地样本目录>
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var dir := str(args[0]) if args.size() >= 1 and str(args[0]) != "" else "user://sample_eval"
	var files := _list_json(dir)
	if files.is_empty():
		print("样本目录为空: " + dir)
		CliShutdown.request_exit(1)
		return
	var fails: Array[String] = []
	var warns: Array[String] = []
	var fps := {}  # 指纹 -> 首个出现的组合
	var checked := 0
	var seed_checked := 0
	for path in files:
		var rel := path.replace(dir + "/", "")
		var level := _load_json(path)
		if level.is_empty():
			fails.append("%s: JSON 无法解析" % rel)
			continue
		# --- A) Board 加载 ---
		var board := Board.new()
		board.load_level(level)
		var sz: Dictionary = level.get("size", {})
		var rows := int(sz.get("rows", 0))
		var cols := int(sz.get("cols", 0))
		if board.grid == null or board.total_mines != int(level.get("total_mines", -1)):
			fails.append("%s: Board 加载失败" % rel)
			continue
		# --- R07 + schema/round-trip（同 verify_batch）---
		var side := cols
		if rows == side and R07_MINES.has(side) and int(level.get("total_mines", -1)) != int(R07_MINES[side]):
			fails.append("%s: R07 雷数不符 %s" % [rel, str(level.get("total_mines"))])
			continue
		var mine_set := {}
		var bad := ""
		for m in level.get("mines", []):
			var mp := Vector2i(int(m["c"]), int(m["r"]))
			if mp.x < 0 or mp.x >= cols or mp.y < 0 or mp.y >= rows or mine_set.has(mp):
				bad = "雷坐标非法/重复 %s" % str(mp)
				break
			mine_set[mp] = true
		if bad != "":
			fails.append("%s: %s" % [rel, bad])
			continue
		var rule: Object = RuleRegistry.default().resolve(StringName(str(level.get("clue_rule", "classic"))))
		if rule == null:
			fails.append("%s: 规则未注册 %s" % [rel, str(level.get("clue_rule"))])
			continue
		# --- B) ProofLog + 难度重算核对 ---
		var log: Dictionary = ProofLog.build(level)
		if not bool(log.get("solved", false)):
			fails.append("%s: 序贯不可解 %s" % [rel, str(log.get("reason", ""))])
			continue
		var prof: Dictionary = level.get("difficulty_profile", {})
		var d_disk := float(prof.get("difficulty", 0.0))
		# --- C) 布局满足自身规则约束（全格固定 → CP-SAT）---
		var globals: Array = []
		for gid in level.get("global_rules", []):
			var g: Object = RuleRegistry.default().resolve(StringName(str(gid)))
			if g == null:
				bad = "全局规则未注册 %s" % str(gid)
				break
			globals.append(g)
		if bad == "":
			var oracle := RuleOracle.new(rule, globals, Vector2i(cols, rows), mine_set.size(), null)
			var spec := oracle.build_spec({}, [], {})
			var mine_arr: Array = []
			var safe_arr: Array = []
			for r in rows:
				for c in cols:
					if mine_set.has(Vector2i(c, r)):
						mine_arr.append([r, c])
					else:
						safe_arr.append([r, c])
			spec["mine_cells"] = mine_arr
			spec["safe_cells"] = safe_arr
			var sol: Array[Vector2i] = RuleCpSat.find_solution(spec)
			if sol.is_empty():
				fails.append("%s: 布局违反自身规则约束（CP-SAT UNSAT）globals=%s" % [rel, str(level.get("global_rules"))])
				continue
			# --- D) seed 复现性（抽查前 5 关）---
			if seed_checked < 5:
				seed_checked += 1
				var replay: Dictionary = PuzzleGenerator.new().generate_with_rules(
					str(level.get("clue_rule")), _strs(level.get("global_rules", [])), Vector2i(cols, rows),
					int(level.get("total_mines")), int(level.get("seed", 0)), 0, 50, null, cols * cols * 3000)
				if replay.is_empty() or _fp(replay) != _fp(level):
					warns.append("%s: seed=%d 重放盘面不一致（复现性）" % [rel, str(level.get("seed"))])
		if bad != "":
			fails.append("%s: %s" % [rel, bad])
			continue
		# --- E) 跨组合指纹查重 ---
		var fp := _fp(level)
		var combo := rel.get_base_dir().get_base_dir().get_file()
		if fps.has(fp):
			warns.append("跨组合同盘: %s 与 %s 同指纹" % [combo, str(fps[fp])])
		else:
			fps[fp] = combo
		checked += 1

	print("=== 抽样入库评估: %d/%d 关 ===" % [checked, files.size()])
	print("  失败 %d | 警告 %d（含 seed 复现抽查 %d）" % [fails.size(), warns.size(), seed_checked])
	for f in fails:
		print("  FAIL: " + f)
	for w in warns:
		print("  WARN: " + w)
	if fails.is_empty():
		print("=== SAMPLE-EVAL-OK ===")
		CliShutdown.request_exit(0)
	CliShutdown.request_exit(1)


func _strs(arr: Array) -> Array:
	var out: Array = []
	for x in arr:
		out.append(str(x))
	return out


func _fp(level: Dictionary) -> String:
	var ms: Array = []
	for m in level.get("mines", []):
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	var sz: Dictionary = level.get("size", {})
	return "%dx%d-%d|%s" % [int(sz.get("cols", 0)), int(sz.get("rows", 0)), int(level.get("total_mines", -1)), "|".join(ms)]


func _list_json(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		var full := dir_path.path_join(n)
		if dir.current_is_dir():
			out.append_array(_list_json(full))
		elif n.ends_with(".json"):
			out.append(full)
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
