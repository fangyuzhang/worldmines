# gen_seed_golden.gd —— 生成/重建「固定 seed 回归」黄金快照（验证资产④）
#
# 用途：生成器/求解器发生**有意**的行为变更后，用本脚本重建黄金快照并重新提交。
# 用法：.\tools\run_batch.ps1 -Script res://tools/gen_seed_golden.gd -SuccessMark "wrote"
#
# 警告：只有在**确认变更是有意的**时才重建——否则会把回归当成新基线吞掉。
# SEED_COUNT 当前 50（每次全量回归约 10s）；夜跑可临时调大，但需同步 test_seed_regression.gd。
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")

const RULE := "classic"
const GLOBALS: Array = []
const COLS := 5
const ROWS := 5
const MINES := 4
const SEED_BASE := 1000
const SEED_COUNT := 50
const OUT_PATH := "res://test/golden/seed_regression_classic_5x5.json"


func _initialize() -> void:
	var gen := PuzzleGenerator.new()
	var entries := {}
	var t0 := Time.get_ticks_msec()
	var failures := 0
	var slowest := 0
	for seed in range(SEED_BASE, SEED_BASE + SEED_COUNT):
		var t := Time.get_ticks_msec()
		var level: Dictionary = gen.generate_with_rules(RULE, GLOBALS, Vector2i(COLS, ROWS), MINES, seed)
		var dt := Time.get_ticks_msec() - t
		slowest = maxi(slowest, dt)
		if level.is_empty():
			entries[str(seed)] = {"empty": true, "ms": dt}
			failures += 1
		else:
			entries[str(seed)] = {
				"h": _fingerprint(level),
				"mines": int(level.get("total_mines", 0)),
				"revealed": (level.get("revealed", []) as Array).size(),
				"difficulty": _difficulty(level),
				"ms": dt,
			}
	var total := Time.get_ticks_msec() - t0
	var doc := {
		"note": "验证资产④：固定 seed 回归黄金快照。由已核实的生成器一次性产出；提交后不得随意改动，改动前必须确认是有意的行为变更（并用 tools/gen_seed_golden.gd 重建）。",
		"rule": RULE,
		"globals": GLOBALS,
		"cols": COLS,
		"rows": ROWS,
		"mines": MINES,
		"seed_base": SEED_BASE,
		"seed_count": SEED_COUNT,
		"entries": entries,
	}
	var d := DirAccess.open("res://")
	if d != null:
		d.make_dir_recursive("test/golden")
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		print("FAILED to open %s" % OUT_PATH)
		CliShutdown.request_exit(1)
		return
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	print("wrote %s  total=%dms  failures=%d  slowest=%dms" % [OUT_PATH, total, failures, slowest])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


func _fingerprint(level: Dictionary) -> String:
	# 只取决定盘面的稳定字段，排序后序列化，保证跨运行字节一致
	var mines: Array = []
	for m in level.get("mines", []):
		mines.append([int(m["c"]), int(m["r"])])
	mines.sort()
	var revealed: Array = []
	for rc in level.get("revealed", []):
		revealed.append([int(rc["c"]), int(rc["r"])])
	revealed.sort()
	var canon := {
		"mines": mines,
		"revealed": revealed,
		"total_mines": int(level.get("total_mines", 0)),
	}
	if level.has("dominoes"):
		canon["dominoes"] = level["dominoes"]
	return JSON.stringify(canon).sha256_text()


func _difficulty(level: Dictionary) -> float:
	var prof: Dictionary = level.get("difficulty_profile", {})
	return float(level.get("difficulty", prof.get("difficulty", -1.0)))
