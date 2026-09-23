extends SceneTree

## O1 诊断 v5（修正）：按生成器语义（只对非雷内部格铺线索）扫描 20 个随机盘，
## 量化「全线索盘是否序贯可解」的真实成功率（GDD §8.2 预警对穿欠产）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var rule: Object = RuleRegistry.default().resolve(&"o1")
	var mine_counts := {5: 10, 6: 14, 7: 20}
	for side in [5, 6, 7]:
		var mines_n: int = int(mine_counts[side])
		var solved_n := 0
		var feas_n := 0
		var trials := 20
		for t in trials:
			var rng := RandomNumberGenerator.new()
			rng.seed = 1000 + t
			var mine_set := {}
			while mine_set.size() < mines_n:
				mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true
			# 生成器语义：非雷的内部格才铺线索
			var revealed: Array = []
			var active := {}
			var any_clue := false
			for r in range(1, side - 1):
				for c in range(1, side - 1):
					var pos := Vector2i(c, r)
					if mine_set.has(pos):
						continue
					var v: int = int(rule.call("compute_clue", mine_set, pos, Vector2i(side, side)))
					active[pos] = v
					revealed.append({"r": r, "c": c})
					any_clue = true
			var mines_arr: Array = []
			for p in mine_set:
				mines_arr.append({"r": p.y, "c": p.x})
			var level := {
				"rule_level": true, "clue_rule": "o1", "global_rules": [],
				"size": {"rows": side, "cols": side}, "total_mines": mines_n,
				"mines": mines_arr, "seed": t, "revealed": revealed,
			}
			# 可行性（已知解在约束下应可行）
			var oracle := RuleOracle.new(rule, [], Vector2i(side, side), mines_n, null)
			if RuleCpSat.is_feasible(oracle.build_spec(active, [], {})):
				feas_n += 1
			# 玩家视角序贯可解（全线索）
			var log: Dictionary = ProofLog.build(level)
			if bool(log.get("solved", false)):
				solved_n += 1
		print("%dx%d @%d雷: 编码可行 %d/%d, 全线索序贯可解 %d/%d" % [
			side, side, mines_n, feas_n, trials, solved_n, trials])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
