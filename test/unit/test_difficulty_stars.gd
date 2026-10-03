# test_difficulty_stars.gd —— 1~5 星评分（W5）自证
#
# 钉住的不变量：
#   1) `stars_of_steps` **单调不减**且恒在 [1,5]（基于推理步骤数，与雷数无关）；
#   2) 边界逐点写死（防后人改阈值改错）：0/1→1★ 2→2★ 4→3★ 7→4★ 11→5★；
#   3) 三档桥接（stars_of_tier / stars_of_profile）与旧口径共存，未知档给 0（不给假星）；
#   4) `with_stars` 只**新增** stars 字段，旧字段原样保留；
#   5) 旧三档口径（PEAK_WINDOWS / tier_of_peak / tier_of）行为不变。
extends GutTest


# ==================== 1. 单调性 + 值域 ====================

func test_stars_are_monotonic_and_bounded() -> void:
	var prev := 0
	for steps in range(-3, 41):
		var s := Difficulty.stars_of_steps(steps)
		assert_true(s >= 1 and s <= 5, "steps=%d 的星级必须在 [1,5]：%d" % [steps, s])
		assert_true(s >= prev, "星级必须随步骤数单调不减：steps=%d → %d < %d" % [steps, s, prev])
		prev = s


# ==================== 2. 边界逐点 ====================

func test_star_boundaries() -> void:
	assert_eq(Difficulty.stars_of_steps(-1), 1, "负数步骤也至少 1 星（绝不给 0 星）")
	assert_eq(Difficulty.stars_of_steps(0), 1, "0 步 = 1 星")
	assert_eq(Difficulty.stars_of_steps(1), 1, "1 步 = 1 星")
	assert_eq(Difficulty.stars_of_steps(2), 2, "≥2 步 = 2 星")
	assert_eq(Difficulty.stars_of_steps(3), 2, "3 步仍是 2 星")
	assert_eq(Difficulty.stars_of_steps(4), 3, "≥4 步 = 3 星")
	assert_eq(Difficulty.stars_of_steps(6), 3, "6 步仍是 3 星")
	assert_eq(Difficulty.stars_of_steps(7), 4, "≥7 步 = 4 星")
	assert_eq(Difficulty.stars_of_steps(10), 4, "10 步仍是 4 星")
	assert_eq(Difficulty.stars_of_steps(11), 5, "≥11 步 = 5 星")
	assert_eq(Difficulty.stars_of_steps(9999), 5, "超大步骤数夹在 5 星")


# ==================== 3. 文案 ====================

func test_stars_text() -> void:
	for n in range(1, 6):
		var t := Difficulty.stars_text(n)
		assert_eq(t.length(), 5, "%d 星的文案长度应为 5：%s" % [n, t])
		assert_eq(t.count("★"), n, "%d 星应恰好有 %d 个实心星：%s" % [n, n, t])
	assert_eq(Difficulty.stars_text(0), "☆☆☆☆☆", "0 星（未知）应全空心")


# ==================== 4. 三档桥接 + 画像 ====================

func test_tier_bridge_and_profile() -> void:
	assert_eq(Difficulty.stars_of_tier("easy"), 2, "普通档桥接 2 星起")
	assert_eq(Difficulty.stars_of_tier("normal"), 3, "困难档桥接 3 星起")
	assert_eq(Difficulty.stars_of_tier("hard"), 4, "噩梦档桥接 4 星起")
	assert_eq(Difficulty.stars_of_tier(""), 0, "未知档给 0（不假装 1 星）")
	# 画像优先按 inference_steps；没有则回落三档
	assert_eq(Difficulty.stars_of_profile({"inference_steps": 7}), 4, "有步骤数就按步骤数")
	assert_eq(Difficulty.stars_of_profile({"max_complexity": 2}), 2, "没有步骤数时按峰值档桥接")
	assert_eq(Difficulty.stars_of_profile({}), 0, "空画像给 0")


func test_with_stars_only_adds_field() -> void:
	var dp := {"difficulty": 0.88, "max_complexity": 5, "inference_steps": 11}
	var out := Difficulty.with_stars(dp)
	assert_eq(int(out["stars"]), 5, "11 步应给 5 星")
	assert_eq(int(out["max_complexity"]), 5, "旧字段必须原样保留")
	assert_false(dp.has("stars"), "不得改动传入的画像（返回的是副本）")
	# 显式步骤数覆盖画像里的 inference_steps
	assert_eq(int(Difficulty.with_stars({"max_complexity": 2}, 1)["stars"]), 1, "显式步骤数优先于档桥接")


# ==================== 5. 旧三档口径不变 ====================

func test_legacy_tiers_unchanged() -> void:
	assert_eq(Difficulty.tier_of_peak(1), "", "peak<=1 不进任何档（v4.1 淘汰一眼盘）")
	assert_eq(Difficulty.tier_of_peak(2), "easy", "peak 2 仍是普通档")
	assert_eq(Difficulty.tier_of_peak(3), "easy")
	assert_eq(Difficulty.tier_of_peak(4), "normal", "peak 4 仍是困难档")
	assert_eq(Difficulty.tier_of_peak(5), "normal")
	assert_eq(Difficulty.tier_of_peak(6), "hard", "peak 6 仍是噩梦档")
	assert_eq(Difficulty.tier_of_peak(20), "hard")
	assert_eq(Difficulty.tier_of_peak(21), "", "peak>=21 超纲")
	assert_eq(Difficulty.tier_of(0.5), "easy", "标量旧口径 tier_of 行为不变")
	assert_eq(Difficulty.tier_range("normal"), Vector2i(4, 5), "档位窗口不变")
