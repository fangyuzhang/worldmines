extends SceneTree

## mod_selfcheck.gd —— Mod 变体自检工具（v2.9.3）
##
## 用途：Mod 作者为自己的变体（已注册进 RuleRegistry）跑一遍「上架前体检」，
## 输出每个尺寸（5×5~9×9 × R07 固定雷数）的：
##   ① 数学可行性（RuleFeasibility 真值查询——不可行的尺寸应在 UI/发布时禁用）；
##   ② 试生成 1 关（全管线：布雷硬校验 → 删线索 → 序贯可解 → 难度分档）；
##   ③ 生成关的 ProofLog 复核（玩家视角可推出全盘）。
##
## 用法：
##   godot --headless --path . -s res://tools/mod_selfcheck.gd -- <clue_id> [globals逗号分隔]
##   例：mod_selfcheck.gd -- knight  mx,dt
##
## 退出码：0 = 全部尺寸通过（或有明确 UNSAT 标注）；1 = 存在「可行但生成失败」的问题尺寸。
##
## 设计原则（对应 GDD T13/T14「Mod 输出必须经过验证层」）：
## 作者拿工具自查，核心不替作者改代码；生成器的雷数硬校验 + 序贯验证是最终防线，
## 违规变体只会「生成失败」被这里如实报出，永远不会静默产出坏关。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 1 or str(args[0]) == "":
		print("用法: mod_selfcheck.gd -- <clue_id> [globals逗号分隔]")
		CliShutdown.request_exit(1)
		return
	var clue_id := str(args[0])
	var globals: Array = []
	if args.size() >= 2 and str(args[1]) != "" and str(args[1]) != "-":
		for g in str(args[1]).split(",", false):
			globals.append(g.strip_edges())
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(StringName(clue_id))
	if clue_rule == null or clue_rule.get_kind() != RulePlugin.KIND_CLUE:
		print("误: 线索规则 '%s' 未注册（Mod 应先完成注册再自检）" % clue_id)
		CliShutdown.request_exit(1)
		return
	print("=== Mod 变体自检: %s + %s ===" % [clue_id, str(globals)])
	var problems := 0
	var feasible_sizes: Array = []
	var unsat_sizes: Array = []
	for side in [5, 6, 7, 8, 9]:
		# v3.0：候选雷数回退——标准值不可行时按 GDD §8.1 候选列表回退（守恒算子整除/奇偶要求）。
		var rres := RuleFeasibility.resolve_mines(clue_id, globals, side)
		if int(rres["mines"]) < 0:
			unsat_sizes.append("%dx%d" % [side, side])
			print("  %dx%d: 数学不可行（全候选 %s 均 UNSAT）——发布时应禁用该尺寸/提示换组合" % [
				side, side, str(RuleFeasibility.CANDIDATES.get(side, []))])
			continue
		var mines: int = int(rres["mines"])
		if not bool(rres["standard"]):
			print("  %dx%d: 标准 %d 雷不可行 → 候选回退 %d 雷（合法，生成侧自动采用）" % [
				side, side, R07_MINES[side], mines])
		var feas := true
		var t0 := Time.get_ticks_msec()
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
			clue_id, globals, Vector2i(side, side), mines, 1, 0, 50, null,
			maxi(30_000, side * side * 1500))
		var cost := float(Time.get_ticks_msec() - t0) / 1000.0
		if level.is_empty():
			problems += 1
			print("  %dx%d=%d雷: 可行但生成失败（%.1fs）——检查 place_mines 是否满足雷数/约束契约、compile 是否报错" % [side, side, mines, cost])
			continue
		# 雷数硬契约
		if int(level.get("total_mines", -1)) != mines:
			problems += 1
			print("  %dx%d: 生成雷数 %d ≠ R07 %d——place_mines 违约（生成器应已拦截，请上报）" % [side, side, int(level["total_mines"]), mines])
			continue
		# ProofLog 复核（玩家视角序贯可解）
		var log: Dictionary = ProofLog.build(level)
		if not bool(log.get("solved", false)):
			problems += 1
			print("  %dx%d: 生成成功但 ProofLog 复核不过（%s）" % [side, side, str(log.get("reason", "?"))])
			continue
		var diff := float(level.get("difficulty_profile", {}).get("difficulty", -1.0))
		var tier := Difficulty.tier_of(diff)
		feasible_sizes.append("%dx%d" % [side, side])
		print("  %dx%d=%d雷: OK（%.1fs，difficulty=%.2f tier=%s）" % [
			side, side, mines, cost, diff, tier if tier != "" else "未进档"])
	print("=== 结论 ===")
	print("  可生成尺寸: %s" % (", ".join(feasible_sizes) if feasible_sizes.size() > 0 else "无"))
	print("  数学不可行尺寸: %s" % (", ".join(unsat_sizes) if unsat_sizes.size() > 0 else "无"))
	print("  问题尺寸（可行但生成失败）: %d" % problems)
	print("=== MOD-SELFCHECK-%s ===" % ("OK" if problems == 0 else "FAILED"))
	CliShutdown.request_exit(0 if problems == 0 else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
