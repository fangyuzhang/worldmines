# spike_b_run.gd —— Spike B（GDScript 侧）：3×3 全穷举模拟结果导出
#
# 运行： godot --headless --path "E:\Porject\kim project\lei" -s res://spike/spike_b_run.gd
# 产出： user://spike_b_sim.json（供 tools/certify/verify.py 做 z3 交叉验证）
#
# 枚举：3×3 全部 512 种雷分布 × 每个非雷格作为 S₀
#       用例总数 = Σ_M C(9,M)·(9−M) = 2304
# 导出 schema 遵循 plan1.8 §2.3.3（坐标一律 [row, col]）。
# 关键：Python 侧独立重算线索值（不信任本侧引擎）⇒ 双向交叉验证。

extends SceneTree

const ROWS := 3
const COLS := 3
const CASE_CAP := -1        # -1 = 全跑；>0 只跑前 N 个用例（调试用）

var _solver := SpikeASolver.new()


func _initialize() -> void:
	var cases: Array = []
	var t0 := Time.get_ticks_usec()
	var case_id := 0

	for mask in (1 << (ROWS * COLS)):
		var mines_rc: Array = []
		for r in ROWS:
			for c in COLS:
				var bit: int = r * COLS + c
				if mask & (1 << bit):
					mines_rc.append([r, c])
		var M: int = mines_rc.size()
		var safes: Array = []
		for r in ROWS:
			for c in COLS:
				if not mines_rc.has([r, c]):
					safes.append([r, c])
		if safes.is_empty():
			continue                       # 全盘皆雷，无 S₀ 可选

		for s0 in safes:
			case_id += 1
			if CASE_CAP > 0 and case_id > CASE_CAP:
				break
			var board := _build(mines_rc)
			var res := _solver.simulate(board, [Vector2i(s0[1], s0[0])])
			cases.append({
				"case_id": "b3_m%d_s0_%d_%d" % [M, s0[0], s0[1]],
				"mines": mines_rc,
				"mine_count": M,
				"s0": s0,
				"clue_visibility": 1.0,
				"sparse_mask": [],
				"hidden": [],
				"variants": {"layout": null, "clue": "Classic8"},
				"success": res["success"],
				"reason": res["reason"],
				"rounds": res["rounds"],
				"revealed": res["revealed"],
				"target": res["target"],
				"opened": [],
				"determined_mine": [],
				"D": 0, "G": 0.0, "C": 0.0,
			})
		if CASE_CAP > 0 and case_id > CASE_CAP:
			break

	var out := {
		"schema_version": "1.0",
		"engine_version": Engine.get_version_info().get("string", ""),
		"generator_version": "1.0.0",
		"grid": {"rows": ROWS, "cols": COLS},
		"note": "3x3 exhaustive; coords are [row, col]; Python side recomputes clues independently",
		"cases": cases,
	}

	var f := FileAccess.open("user://spike_b_sim.json", FileAccess.WRITE)
	if f == null:
		push_error("无法写入 user://spike_b_sim.json")
		quit(1)
		return
	f.store_string(JSON.stringify(out))
	f.close()

	var ms := (Time.get_ticks_usec() - t0) / 1000
	print("[spike_b] cases=%d  elapsed=%dms  -> user://spike_b_sim.json" % [cases.size(), ms])
	quit(0)


func _build(mines_rc: Array) -> Board:
	var level := {
		"size": {"rows": ROWS, "cols": COLS},
		"total_mines": mines_rc.size(),
		"mines": [],
		"revealed": [],
	}
	for m in mines_rc:
		(level["mines"] as Array).append({"r": m[0], "c": m[1]})
	var b := Board.new()
	b.load_level(level)
	return b
