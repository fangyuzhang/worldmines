extends SceneTree

## O1 生成全灭诊断：编码一致性（已知解可行？）→ 解数 → 玩家视角可解性。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var reg := RuleRegistry.default()
	var rule: Object = reg.resolve(&"o1")
	var side := 5
	var mines_n := 10
	# 1) 随机造盘（确定性 seed）
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var mine_set := {}
	while mine_set.size() < mines_n:
		mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true
	print("盘: %d 雷" % mine_set.size())
	var mines_arr: Array = []
	for p in mine_set:
		mines_arr.append({"r": p.y, "c": p.x})

	# 2) active = 全部内部格线索
	var active := {}
	for r in range(1, side - 1):
		for c in range(1, side - 1):
			active[Vector2i(c, r)] = rule.call("compute_clue", mine_set, Vector2i(c, r), Vector2i(side, side))
	print("active: %d 条线索" % active.size())

	# 3) 编码一致性：已知解在「全线索约束」下应可行
	var oracle := RuleOracle.new(rule, [], Vector2i(side, side), mines_n, null)
	var spec := oracle.build_spec(active, [], {})
	var feas: bool = RuleCpSat.is_feasible(spec)
	print("已知解可行（含全线索约束）: %s ← 期望 true" % str(feas))
	if RuleCpSat.available():
		var cnt: int = RuleCpSat.count_solutions(spec)
		print("解数（截断上限）: %d ← 期望 1" % cnt)

	# 4) 玩家视角：全线索翻开的关卡能否序贯推出
	var level := {
		"rule_level": true, "clue_rule": "o1", "global_rules": [],
		"size": {"rows": side, "cols": side}, "total_mines": mines_n,
		"mines": mines_arr, "seed": 1,
	}
	var revealed: Array = []
	for pos in active:
		revealed.append({"r": pos.y, "c": pos.x})
	level["revealed"] = revealed
	var log: Dictionary = ProofLog.build(level)
	print("全线索玩家视角序贯可解: %s（%s）" % [str(log.get("solved", false)), str(log.get("reason", ""))])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
