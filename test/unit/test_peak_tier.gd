extends GutTest

# 深度窗口判据（v4.1 三档，对齐《14 Minesweeper Variants 2》常量矩阵）：peak → 档位。
# 窗口：普通 [2,3] / 困难 [4,5] / 噩梦 [6,20]；peak ≤1（纯一眼盘）与 ≥21（超纲）不进任何档。
func test_window_boundaries() -> void:
	assert_eq(Difficulty.tier_of_peak(0), "")
	assert_eq(Difficulty.tier_of_peak(1), "", "纯一眼盘被淘汰（对方普通档 MIN=2 同语义）")
	assert_eq(Difficulty.tier_of_peak(2), "easy")
	assert_eq(Difficulty.tier_of_peak(3), "easy")
	assert_eq(Difficulty.tier_of_peak(4), "normal")
	assert_eq(Difficulty.tier_of_peak(5), "normal")
	assert_eq(Difficulty.tier_of_peak(6), "hard")
	assert_eq(Difficulty.tier_of_peak(20), "hard")
	assert_eq(Difficulty.tier_of_peak(21), "")      # 超纲
	assert_eq(Difficulty.tier_of_peak(-1), "")      # 无画像

func test_tier_of_profile() -> void:
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 6}), "hard")
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 5}), "normal")
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 3}), "easy")
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 1}), "")  # 一眼盘无档
	assert_eq(Difficulty.tier_of_profile({}), "")
	assert_eq(Difficulty.tier_of_profile({"difficulty": 3.0}), "")  # 只有标量不算

func test_window_predicate_and_range() -> void:
	assert_true(Difficulty.in_window(6, 6, 20))
	assert_false(Difficulty.in_window(5, 6, 20))
	assert_eq(Difficulty.tier_range("hard"), Vector2i(6, 20))
	assert_eq(Difficulty.tier_range("normal"), Vector2i(4, 5))
	assert_eq(Difficulty.tier_range("easy"), Vector2i(2, 3))

func test_filter_by_tier_uses_peak() -> void:
	var lv := [
		{"difficulty_profile": {"max_complexity": 1, "difficulty": 2.5}},   # 淘汰：peak≤1 无档
		{"difficulty_profile": {"max_complexity": 10, "difficulty": 0.2}},  # hard
	]
	assert_eq(Difficulty.filter_by_tier(lv, "hard").size(), 1)
	assert_eq(int(Difficulty.filter_by_tier(lv, "hard")[0]["difficulty_profile"]["max_complexity"]), 10)
	for t in ["easy", "normal"]:
		assert_eq(Difficulty.filter_by_tier(lv, t).size(), 0,
			"peak=1 的盘不属于任何玩家档（%s）——淘汰语义" % t)

func test_more_boundaries() -> void:
	assert_eq(Difficulty.tier_range("nope"), Vector2i(-1, -1))       # 未知档位
	assert_false(Difficulty.in_window(21, 6, 20))                    # 上界外侧
	assert_eq(Difficulty.filter_by_tier([{"difficulty_profile": {}}], "nope").size(), 1)  # 未知 tier → 原样返回


## 档位文案（唯一事实源）：UI 各处都从这里取，含峰值窗口提示。
func test_tier_text() -> void:
	assert_eq(Difficulty.tier_text("hard"), "噩梦（6–20 条线索）")
	assert_eq(Difficulty.tier_text("easy"), "普通（2–3 条线索）")
	assert_eq(Difficulty.tier_text("nope"), "nope")  # 未知档位回退原样，不崩


## 玩家档位是三档（v4.1）：intro 退役。防"第四档"以任何形式回流。
func test_three_tiers_exactly() -> void:
	assert_eq(Difficulty.PEAK_WINDOWS.keys(), ["easy", "normal", "hard"],
		"玩家档位必须是三档（对齐 14MV2），键序即 UI 展示序")
