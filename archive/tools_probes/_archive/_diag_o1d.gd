extends SceneTree

## O1 诊断 v4：全格固定（真解唯一）→ 逐步加线索 → C# is_feasible 必须恒 true。
## 若出现 false：C# 翻译与 IR 语义在「aux 组合」上存在 bug（最小重现）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o1_duichuan")
	var rule: Object = RuleRegistry.default().resolve(&"o1")
	var side := 5
	var mines_n := 10
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var mine_set := {}
	while mine_set.size() < mines_n:
		mine_set[Vector2i(rng.randi_range(0, side - 1), rng.randi_range(0, side - 1))] = true

	var safe_arr: Array = []
	var mine_arr: Array = []
	for r in side:
		for c in side:
			if mine_set.has(Vector2i(c, r)):
				mine_arr.append([r, c])
			else:
				safe_arr.append([r, c])

	var ordered: Array = []
	for r in range(1, side - 1):
		for c in range(1, side - 1):
			ordered.append(Vector2i(c, r))
	ordered.sort()

	var clues: Array = []
	var auxall: Array = []
	var next_base := 0
	for i in ordered.size():
		var pos: Vector2i = ordered[i]
		var val: int = int(rule.call("compute_clue", mine_set, pos, Vector2i(side, side)))
		var bb := RuleBuilder.new(side, side, mines_n, next_base)
		rule.call("build_clue_constraints", bb, pos, val)
		auxall.append_array(bb.aux_vars)
		next_base = bb.next_aux_index()
		clues.append({"r": pos.y, "c": pos.x, "ir": bb.constraints})
		# 逐步测：前 i+1 条
		var sp := {
			"rows": side, "cols": side, "total_mines": mines_n,
			"safe_cells": safe_arr, "mine_cells": mine_arr,
			"clues": clues, "aux": auxall,
		}
		if not RuleCpSat.is_feasible(sp):
			print("!! 全固定下第 %d 条线索（%s value=%d）起 infeasible" % [i, str(pos), val])
			var last_ir: Array = clues[clues.size() - 1]["ir"]
			print("  IR: " + JSON.stringify(last_ir))
			CliShutdown.request_exit(0)
			return
	print("全固定 + 全 %d 条线索：全部 feasible ✓" % ordered.size())
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
