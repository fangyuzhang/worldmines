# spike_c_ceiling.gd —— L3 优先级判定：完备推理（Oracle）天花板
#
# 问题：Spike B 测得 264 个「S* 唯一但 L0/L1/L2 解不出」的用例。
#       其中有多少能被「任意强度的无猜推理」救回？
# 方法：用 Oracle 作 judge 的完备完美玩家（core/solver_perfect_player.gd）
#       与 L0~L2 完美玩家（spike_a_solver.gd）逐局对比。
#       Oracle 完备 ⇒ 它解不出的局，任何 L3/深度归谬也解不出。
#       ⇒ (oracle_ok − l012_ok) 就是 L3 的「理论最大增量」。
#
# 若增量小 ⇒ L3 优先级低，应把力气放在 S₀ 贪心与接受率标定；
# 若增量大 ⇒ L3 高优先，且本脚本给出其价值的定量上界。
#
# 范围：3×3 全穷举（廉价、决定性）。

extends SceneTree

const ROWS := 3
const COLS := 3

var _l012 := SpikeASolver.new()
var _oracle_player := SolverPerfectPlayer.new()


func _initialize() -> void:
	var total := 0
	var l012_ok := 0
	var oracle_ok := 0
	var gap_rescued := 0      # L0~L2 失败 但 Oracle 成功
	var gap_lost := 0         # L0~L2 失败 且 Oracle 也失败（= 需猜）
	var both_fail := 0

	var t0 := Time.get_ticks_usec()

	for mask in (1 << (ROWS * COLS)):
		var mines_rc: Array = []
		for r in ROWS:
			for c in COLS:
				if mask & (1 << (r * COLS + c)):
					mines_rc.append([r, c])
		var safes: Array = []
		for r in ROWS:
			for c in COLS:
				if not mines_rc.has([r, c]):
					safes.append([r, c])
		if safes.is_empty():
			continue
		for s0 in safes:
			total += 1
			var s0v := Vector2i(s0[1], s0[0])

			var b1 := _build(mines_rc)
			var r := _l012.simulate(b1, [s0v])
			if r["success"]:
				l012_ok += 1

			var b2 := _build(mines_rc)
			b2.reveal(s0v)
			var s := _oracle_player.solve(b2, Callable())
			if s[0]:
				oracle_ok += 1
			if s[0] and not r["success"]:
				gap_rescued += 1
			if not s[0] and not r["success"]:
				gap_lost += 1

	var ms := (Time.get_ticks_usec() - t0) / 1000
	print("=== Spike C-1 : 完备推理天花板（3×3 全穷举） ===")
	print("对局 %d / L0~L2 成功 %d (%.1f%%) / Oracle 完备成功 %d (%.1f%%)"
		% [total, l012_ok, 100.0 * l012_ok / total, oracle_ok, 100.0 * oracle_ok / total])
	print("L3 理论最大增量 = %d 局（= oracle_ok - l012_ok）" % (oracle_ok - l012_ok))
	print("  - L0~L2 失败但完备推理可救 = %d" % gap_rescued)
	print("  - L0~L2 失败且完备推理也救不了（真需猜）= %d" % gap_lost)
	print("耗时 %dms" % ms)

	var f := FileAccess.open("user://spike_c_ceiling.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"suite": "spike_c_ceiling",
			"total": total, "l012_ok": l012_ok, "oracle_ok": oracle_ok,
			"l3_max_gain": oracle_ok - l012_ok,
			"gap_rescued": gap_rescued, "gap_lost": gap_lost,
			"elapsed_ms": ms,
		}, "  "))
		f.close()
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
