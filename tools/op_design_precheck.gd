extends SceneTree

## op_design_precheck.gd —— 新算子「设计预检」哨（v3.0 换血流程固化）
##
## 用途：每个新算子（观测型）开工量产前，快速验证「线索体系是否有足够信息量支撑序贯无猜」。
## 背景：O1 对穿试点实测——纯随机布雷下全尺寸序贯可解率 ≈ 0%（内部线索格少 + 值域低 +
## 外圈无线索 → 推不出全盘；GDD §8.2 仅预警「欠产」，实测是「零产」）。
## 若此处判不合格：需要构造式布雷 / 线索布局设计修正，而不是进入量产白跑。
##
## 方法：每尺寸 N 个随机盘，按生成器语义（非雷且 applies_to 的格铺线索）构造全线索盘，
## 跑序贯可解（ProofLog）+ 编码一致性（is_feasible）双重统计。
##
## 用法：
##   godot --headless --path . -s res://tools/op_design_precheck.gd -- <clue_id> [globals_csv] [trials]
##   例：... -- o1 "" 20
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var clue_id := str(args[0]) if args.size() >= 1 and str(args[0]) != "" else "o1"
	var globals: Array = []
	var trials := 20
	# 宽容解析：空字符串参数会被引擎吞掉（`-- o1 "" 10` 变成 [o1, 10]），
	# 故 args[1] 是纯数字时视为 trials 而非 globals。
	if args.size() >= 2 and str(args[1]) != "" and not str(args[1]).is_valid_int():
		for g in str(args[1]).split(",", false):
			globals.append(str(g))
		trials = int(args[2]) if args.size() >= 3 and str(args[2]) != "" else 20
	elif args.size() >= 2 and str(args[1]).is_valid_int():
		trials = int(args[1])
	# 兜底：加载全部 demo/mods 试验 Mod（-s 环境无 ModAPI autoload，直接走 on_load 注册）
	var mods_dir := DirAccess.open("res://demo/mods")
	if mods_dir != null:
		for sub in mods_dir.get_directories():
			var entry := "res://demo/mods/%s/entry.gd" % sub
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
	var rule: Object = RuleRegistry.default().resolve(StringName(clue_id))
	if rule == null:
		print("规则未注册: %s（内置或 Mod 需先加载）" % clue_id)
		CliShutdown.request_exit(1)
		return
	var gs: Array = []
	for gid in globals:
		var g: Object = RuleRegistry.default().resolve(StringName(str(gid)))
		if g != null:
			gs.append(g)
	# 隐藏态规则检测（第三轮修正，2026-09-16）：
	# ① 首轮用 get_script_method_list() 推断「是否覆写」——**错**（该列表含继承方法 → 所有规则
	#    都被判为隐藏态规则）→ o10（无构造式布雷）走 place_mines 得空布雷 → 空盘零产（已修）。
	# ② 现行判据：**declares() 声明优先**（能力契约，评审 C3），无声明时用已知名单兜底。
	const HIDDEN_CAPABLE := ["o4", "o5x", "o5b"]
	var has_hidden := false
	if rule.has_method("declares"):
		has_hidden = bool((rule.call("declares") as Dictionary).get("hidden_state", false))
	if not has_hidden:
		has_hidden = str(clue_id) in HIDDEN_CAPABLE
	print("=== 设计预检: %s + %s（%d 盘/尺寸，%s）===" % [clue_id, str(globals), trials,
		"place_mines 真实布雷【隐藏态规则】" if has_hidden else "随机布雷"])
	for side in [5, 6, 7, 8, 9]:
		var mines_n: int = int(R07_MINES[side])
		var feas_n := 0
		var solved_n := 0
		var clue_total := 0
		for t in trials:
			var rng := RandomNumberGenerator.new()
			rng.seed = 1000 + t
			var mine_set := {}
			if has_hidden:
				# 隐藏态规则：place_mines 同时产出布雷与隐藏态（与生产路径一致）
				for p in rule.call("place_mines", rng, side, side, mines_n):
					mine_set[p] = true
			# 防御（第三轮修正）：place_mines 返回空（规则无构造式布雷/异常）→ 回退随机布雷，
			# 避免产出「零雷空盘」（其指纹 = 线索数等于盘面格数、序贯必然零产）。
			if mine_set.is_empty():
				while mine_set.size() < mines_n:
					mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true
			var active := {}
			var revealed: Array = []
			for r in side:
				for c in side:
					var pos := Vector2i(c, r)
					if mine_set.has(pos) or not bool(rule.call("applies_to", pos, Vector2i(side, side))):
						continue
					active[pos] = rule.call("compute_clue", mine_set, pos, Vector2i(side, side))
					revealed.append({"r": r, "c": c})
			if active.is_empty():
				continue
			clue_total += active.size()
			var mines_arr: Array = []
			for p in mine_set:
				mines_arr.append({"r": p.y, "c": p.x})
			var level := {
				"rule_level": true, "clue_rule": clue_id, "global_rules": globals,
				"size": {"rows": side, "cols": side}, "total_mines": mines_n,
				"mines": mines_arr, "seed": t, "revealed": revealed,
			}
			if has_hidden:
				# 载盘复现：与生产落盘同契约（ProofLog→Board.load_level 读取后 import）
				level["hidden_state"] = {clue_id: rule.call("export_hidden_state")}
			var oracle := RuleOracle.new(rule, gs, Vector2i(side, side), mines_n, null)
			if RuleCpSat.is_feasible(oracle.build_spec(active, [], {})):
				feas_n += 1
			var log: Dictionary = ProofLog.build(level)
			if bool(log.get("solved", false)):
				solved_n += 1
		var avg_clues := float(clue_total) / float(maxi(1, trials))
		var verdict := "合格" if solved_n >= trials * 6 / 10 else ("欠产（需构造式布雷）" if solved_n > 0 else "零产（设计需修正）")
		print("  %dx%d @%d雷: 线索%.1f条/盘, 编码可行 %d/%d, 全线索序贯可解 %d/%d → %s" % [
			side, side, mines_n, avg_clues, feas_n, trials, solved_n, trials, verdict])
	print("=== 判读：序贯可解率 <60% 即需构造式布雷设计；=0 需修订线索布局方案 ===")
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
