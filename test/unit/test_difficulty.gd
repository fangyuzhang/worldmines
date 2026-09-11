# test_difficulty.gd —— P0 难度量化（演绎批量分布 → 难度画像）
extends GutTest


## 纯函数：逐格抠 vs 雪崩 的区分度。
func test_difficulty_from_stats() -> void:
	# 逐格硬抠：8 轮每轮 1 格 → 难度 8
	var d1: Dictionary = PuzzleGenerator.difficulty_from_stats({"rounds": [1, 1, 1, 1, 1, 1, 1, 1]})
	assert_eq(d1["difficulty"], 8.0, "8 轮每轮 1 格 → 难度 8")
	assert_eq(d1["rounds"], 8, "轮数应为 8")
	assert_eq(d1["max_batch"], 1, "最大批量应为 1")
	assert_eq(str(d1["profile"]), "1x8", "直方图应为 1x8")
	# 雪崩：3 轮（10/5/3）→ 1/10 + 1/5 + 1/3 = 0.63
	var d2: Dictionary = PuzzleGenerator.difficulty_from_stats({"rounds": [10, 5, 3]})
	assert_almost_eq(float(d2["difficulty"]), 0.63, 0.01, "雪崩题难度应显著低")
	assert_eq(d2["max_batch"], 10, "最大批量应为 10")
	assert_eq(str(d2["profile"]), "10x1,5x1,3x1", "直方图批量降序")
	# 空统计
	var d3: Dictionary = PuzzleGenerator.difficulty_from_stats({"rounds": []})
	assert_eq(d3["difficulty"], 0.0, "空统计难度 0")


## 生成流程应落盘难度画像，且指标自洽。
func test_difficulty_profile_recorded() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	var level := gen.generate_with_rules("classic", [], Vector2i(5, 5), 10, 1)
	assert_false(level.is_empty(), "应生成")
	if level.is_empty():
		return
	assert_true(level.has("difficulty_profile"), "应落盘 difficulty_profile")
	var dp: Dictionary = level["difficulty_profile"]
	assert_gt(float(dp["difficulty"]), 0.0, "难度分应 > 0")
	assert_gt(int(dp["rounds"]), 0, "轮数应 > 0")
	assert_ne(str(dp["profile"]), "", "直方图字符串应非空")
	# 一致性：轮数 == 直方图各类计数之和
	var total := 0
	for part in str(dp["profile"]).split(","):
		var seg := part.split("x")
		if seg.size() == 2:
			total += int(seg[1])
	assert_eq(total, int(dp["rounds"]), "直方图计数之和应等于轮数")


## 区分度验证：同配置不同 seed 的指标分布（打印观察）。
func test_difficulty_discriminates() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	for seed in range(1, 6):
		var lv := gen.generate_with_rules("classic", [], Vector2i(5, 5), 10, seed)
		if lv.is_empty():
			continue
		var dp: Dictionary = lv["difficulty_profile"]
		print("DIFF 5x5 10雷 s%d: dif=%s rounds=%s max_b=%s clues=%s ratio=%s profile=%s" % [
			seed, dp["difficulty"], dp["rounds"], dp["max_batch"],
			dp["clue_count"], dp["clue_ratio"], dp["profile"]])
		assert_gt(float(dp["difficulty"]), 0.0, "难度分应为正")
		assert_gt(int(dp["clue_count"]), 0, "线索数应为正")
