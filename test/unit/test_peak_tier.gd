extends GutTest

# 深度窗口判据（v4.0）：peak → 档位；超纲过滤。
func test_window_boundaries() -> void:
	assert_eq(Difficulty.tier_of_peak(0), "intro")
	assert_eq(Difficulty.tier_of_peak(2), "intro")
	assert_eq(Difficulty.tier_of_peak(3), "easy")
	assert_eq(Difficulty.tier_of_peak(4), "easy")
	assert_eq(Difficulty.tier_of_peak(5), "normal")
	assert_eq(Difficulty.tier_of_peak(8), "normal")
	assert_eq(Difficulty.tier_of_peak(9), "hard")
	assert_eq(Difficulty.tier_of_peak(20), "hard")
	assert_eq(Difficulty.tier_of_peak(21), "")      # 超纲
	assert_eq(Difficulty.tier_of_peak(-1), "")      # 无画像

func test_tier_of_profile() -> void:
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 9}), "hard")
	assert_eq(Difficulty.tier_of_profile({"max_complexity": 3}), "easy")
	assert_eq(Difficulty.tier_of_profile({}), "")
	assert_eq(Difficulty.tier_of_profile({"difficulty": 3.0}), "")  # 只有标量不算

func test_window_predicate_and_range() -> void:
	assert_true(Difficulty.in_window(9, 9, 20))
	assert_false(Difficulty.in_window(8, 9, 20))
	assert_eq(Difficulty.tier_range("hard"), Vector2i(9, 20))
	assert_eq(Difficulty.tier_range("easy"), Vector2i(3, 4))

func test_filter_by_tier_uses_peak() -> void:
	var lv := [
		{"difficulty_profile": {"max_complexity": 1, "difficulty": 2.5}},  # 旧口径会判 hard
		{"difficulty_profile": {"max_complexity": 10, "difficulty": 0.2}}, # 旧口径会判 intro
	]
	assert_eq(Difficulty.filter_by_tier(lv, "hard").size(), 1)
	assert_eq(int(Difficulty.filter_by_tier(lv, "hard")[0]["difficulty_profile"]["max_complexity"]), 10)
