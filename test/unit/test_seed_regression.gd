extends GutTest

## 验证资产④：固定 seed 回归。
##
## 目的（GDD 14.5.3）：固定 seed 生成关卡，与提交时记录的黄金快照逐项比对——
## 任何生成器/求解器改动导致输出漂移（哪怕只是多删/少删一条线索），这里都会失败。
##
## 意义不是「独立验证正确性」（那由 test_cpsat_oracle_crosscheck 的穷举对拍负责），
## 而是「检测漂移」：黄金快照是**已核实版本**的确定性输出，改动必须有意为之并重建。
##
## 注意：_fingerprint / _difficulty 与 tools/gen_seed_golden.gd **必须保持同构**；
## 若改口径，两边一起改并重建快照。

const GOLDEN_PATH := "res://test/golden/seed_regression_classic_5x5.json"
const RULE := "classic"
const GLOBALS: Array = []
const COLS := 5
const ROWS := 5
const MINES := 4


func test_fixed_seed_regression() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var golden := _read_golden()
	assert_false(golden.is_empty(),
		"黄金快照缺失：%s（用 tools/gen_seed_golden.gd 重建）" % GOLDEN_PATH)
	if golden.is_empty():
		return

	var entries: Dictionary = golden.get("entries", {})
	var seed_base: int = int(golden.get("seed_base", 1000))
	var seed_count: int = int(golden.get("seed_count", 0))
	assert_gt(seed_count, 0, "黄金快照应含 seed_count")

	var gen := PuzzleGenerator.new()
	var mismatches: Array[String] = []
	var checked := 0
	for i in seed_count:
		var seed: int = seed_base + i
		var level: Dictionary = gen.generate_with_rules(RULE, GLOBALS, Vector2i(COLS, ROWS), MINES, seed)
		var ent: Dictionary = entries.get(str(seed), {})
		checked += 1
		if ent.is_empty():
			if not level.is_empty():
				mismatches.append("seed %d：黄金为空但实际生成了关卡" % seed)
			continue
		if level.is_empty():
			mismatches.append("seed %d：黄金非空但实际生成失败" % seed)
			continue
		if str(ent.get("h", "")) != _fingerprint(level):
			mismatches.append("seed %d：关卡内容漂移（mines/revealed 变了）" % seed)
		if int(ent.get("mines", -1)) != int(level.get("total_mines", 0)):
			mismatches.append("seed %d：雷数漂移" % seed)
		if int(ent.get("revealed", -1)) != (level.get("revealed", []) as Array).size():
			mismatches.append("seed %d：翻开数漂移" % seed)
		if absf(float(ent.get("difficulty", 0.0)) - _difficulty(level)) > 0.001:
			mismatches.append("seed %d：难度漂移" % seed)

	assert_gt(checked, 0, "应至少核对一个 seed")
	assert_eq(mismatches.size(), 0,
		"固定 seed 输出漂移（生成器/求解器行为变更？确认有意的用 tools/gen_seed_golden.gd 重建）：%s" % str(mismatches))


func _read_golden() -> Dictionary:
	if not FileAccess.file_exists(GOLDEN_PATH):
		return {}
	var f := FileAccess.open(GOLDEN_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _fingerprint(level: Dictionary) -> String:
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
