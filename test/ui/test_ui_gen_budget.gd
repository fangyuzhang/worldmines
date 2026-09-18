extends GutTest

## UI 自由模式生成预算实测：level_select 的超时口径（≥9 尺寸 15s、其余 3s）下，
## 15 单变体 × 5 尺寸 是否都能出关。出关 = 玩家点「生成」能得到关（哪怕线索偏多偏简单）。
## 失败组合清单 = UI 需要按变体/尺寸加大预算的真实证据。

const CLUES := ["classic", "4n", "clock", "hv", "fr", "loopruns", "distsum", "sc"]
const GLOBALS := ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]
const MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _ui_timeout(size: int) -> int:
	# 与 ui/level_select.gd 的 _gen_timeout 同口径
	return 15_000 if size >= 9 else 3_000


## 数学 UNSAT 规则（与 ui/level_select._mode_feasible 同口径）：不可行组合生成器必须返回空。
func _feasible(globals: Array, side: int) -> bool:
	if globals.has("rl") and side == 6:
		return false
	if globals.has("qd") and (side == 6 or side == 8):
		return false
	if globals.has("rl") and globals.has("qd") and side == 5:
		return false
	return true


func _probe(clue: String, globals: Array, side: int, fails: Array[String]) -> void:
	# 写死的 id 列表会随变体池收敛而过期（2026-09-18 旧算子移出主项目、改由 legacy_rules 提供）：
	# 未加载的算子不算「预算失败」——否则失败清单会变成「规则没注册」的假信号。
	if not VariantCatalog.is_available(clue):
		return
	for g in globals:
		if not VariantCatalog.is_available(str(g)):
			return
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
		clue, globals, Vector2i(side, side), MINES[side], 201000, 0, 50, null,
		_ui_timeout(side))
	if level.is_empty():
		fails.append("%s%s %dx%d" % [clue, "" if globals.is_empty() else "+" + str(globals[0]), side, side])


func test_ui_budget_clues_9x9() -> void:
	var fails: Array[String] = []
	for c in CLUES:
		_probe(c, [], 9, fails)
	assert_eq(fails.size(), 0, "9×9 C 线索 UI 预算 15s 内出关失败: " + ", ".join(fails))


func test_ui_budget_globals_9x9() -> void:
	var fails: Array[String] = []
	for g in GLOBALS:
		_probe("classic", [g], 9, fails)
	assert_eq(fails.size(), 0, "9×9 G 全局 UI 预算 15s 内出关失败: " + ", ".join(fails))


func test_ui_budget_all_variants_small() -> void:
	# 5×5~8×8 × 15 变体，预算 3s。UNSAT 组合（rl 6×6 / qd 6×6、8×8）单独核对「必返回空」。
	var fails: Array[String] = []
	for side in [5, 6, 7, 8]:
		for c in CLUES:
			_probe(c, [], side, fails)
		for g in GLOBALS:
			if not _feasible([g], side):
				var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
					"classic", [g], Vector2i(side, side), MINES[side], 201000, 0, 50, null, 3000)
				assert_true(level.is_empty(), "%s %dx%d 数学不可行，生成器应返回空" % [g, side, side])
				continue
			_probe("classic", [g], side, fails)
	assert_eq(fails.size(), 0, "5×5~8×8 UI 预算 3s 内出关失败: " + ", ".join(fails))
