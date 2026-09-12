extends GutTest

## QD（四象）偶数盘雷数非 4 倍数 → UNSAT（v2.9.3 修复）。
##
## 旧 bug：QdRule.place_mines 对全偶盘执行 `count -= count % 4` 偷偷调平（14→12、26→24），
## 会产出「雷数不符 R07」的关卡（实测 6×6 出 12 雷关，声称 6×6 却只有 12 雷）。
## 修复：偶数盘 count % 4 != 0 直接返回空（数学 UNSAT，交给批量脚本跳过该尺寸）。


func test_qd_even_board_non_multiple_of_4_is_unsat() -> void:
	# 6×6=14：偶数盘无中央行列，四象限各 k 雷 → 总雷数 = 4k，14 非 4 倍数 → 数学不可行。
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"classic", ["qd"], Vector2i(6, 6), 14, 1, 0, 50, null, 20_000)
	assert_true(level.is_empty(), "QD 6×6=14（非4倍数）应判不可行，而非产出 12 雷的关")


func test_qd_odd_board_is_feasible_with_exact_mine_count() -> void:
	# 7×7=20：奇数盘有中央行列，四象限各 k 雷可解，雷数必须精确等于 R07 的 20。
	var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"classic", ["qd"], Vector2i(7, 7), 20, 1, 0, 50, null, 20_000)
	assert_false(level.is_empty(), "QD 7×7=20 应可行")
	if not level.is_empty():
		assert_eq(int(level.get("total_mines", -1)), 20, "QD 生成雷数必须精确等于 R07 固定值 20（不得偷偷调平）")
