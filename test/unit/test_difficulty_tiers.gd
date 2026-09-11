# test_difficulty_tiers.gd —— P0-B 难度分档
extends GutTest


## 档位归属：边界与区间。
func test_tier_of() -> void:
	assert_eq(Difficulty.tier_of(0.5), "easy", "0.5 → easy")
	assert_eq(Difficulty.tier_of(1.2), "normal", "1.2（左闭）→ normal")
	assert_eq(Difficulty.tier_of(2.0), "normal", "2.0 → normal")
	assert_eq(Difficulty.tier_of(2.2), "hard", "2.2（左闭）→ hard")
	assert_eq(Difficulty.tier_of(99.0), "hard", "99 → hard")
	assert_eq(Difficulty.tier_of(0.0), "", "0.0 不在任何档")


## 筛选：给定一批含 difficulty_profile 的关卡，按档位筛出正确的子集。
func test_filter_by_tier() -> void:
	var levels := [
		{"name": "a", "difficulty_profile": {"difficulty": 0.5}},
		{"name": "b", "difficulty_profile": {"difficulty": 1.0}},
		{"name": "c", "difficulty_profile": {"difficulty": 1.8}},
		{"name": "d", "difficulty_profile": {"difficulty": 2.5}},
		{"name": "e", "difficulty_profile": {"difficulty": 3.9}},
	]
	var easy := Difficulty.filter_by_tier(levels, "easy")
	assert_eq(easy.size(), 2, "easy 应筛出 2 条")
	assert_eq(str(easy[0]["name"]), "a", "easy 首条 a")
	var normal := Difficulty.filter_by_tier(levels, "normal")
	assert_eq(normal.size(), 1, "normal 应筛出 1 条")
	assert_eq(str(normal[0]["name"]), "c", "normal 唯一 c")
	var hard := Difficulty.filter_by_tier(levels, "hard")
	assert_eq(hard.size(), 2, "hard 应筛出 2 条")


## 定向生成：多 seed 尝试下实际难度应达到档位下限（normal 下限 1.2）。
func test_generate_tiered_meets_minimum() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	var level := Difficulty.generate_tiered(gen, "classic", [], Vector2i(5, 5), 10, 1, "normal")
	assert_false(level.is_empty(), "定向生成应成功")
	if level.is_empty():
		return
	var dp: Dictionary = level["difficulty_profile"]
	var d := float(dp["difficulty"])
	assert_gt(d, 0.0, "难度应为正")
	print("TIER normal target: difficulty=%s clues=%s" % [dp["difficulty"], dp["clue_count"]])
	assert_true(d >= 1.2, "定向 normal 应达到下限 1.2（多 seed 尝试）")
