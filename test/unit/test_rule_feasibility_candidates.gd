extends GutTest

## 候选雷数回退回归（v3.0，GDD 终版 §8.1）：标准值首选 / 可行回退 / 全不可行 三分支。
## 守恒算子的整除/奇偶要求与 R07 标准雷数互斥时，resolve_mines 按候选列表回退；
## 该机制被视为「必需关卡」的标准值选点基准（28 个必需关卡全部按标准值预选）。


func before_each() -> void:
	RuleFeasibility.clear_cache()


func test_standard_mines_list() -> void:
	assert_eq(RuleFeasibility.standard_mines(5), 10)
	assert_eq(RuleFeasibility.standard_mines(6), 14)
	assert_eq(RuleFeasibility.standard_mines(7), 20)
	assert_eq(RuleFeasibility.standard_mines(8), 26)
	assert_eq(RuleFeasibility.standard_mines(9), 32)


func test_standard_preferred_when_feasible() -> void:
	var r := RuleFeasibility.resolve_mines("classic", [], 6)
	assert_eq(int(r["mines"]), 14, "标准值可行时优先标准值")
	assert_true(bool(r["standard"]))


func test_rl_6x6_falls_back_to_odd() -> void:
	# 行锁 ±1 差序列总和恒奇（6 行）；标准 14 偶不可行 → 回退首个可行奇数 15。
	var r := RuleFeasibility.resolve_mines("classic", ["rl"], 6)
	assert_eq(int(r["mines"]), 15, "rl 6×6 应回退到 15（奇）")
	assert_false(bool(r["standard"]))


func test_qd_6x6_falls_back_to_multiple_of_four() -> void:
	# 四象限相等需 4 的倍数；候选序 [14,12,15,16,18,13] → 首个可行 12。
	var r := RuleFeasibility.resolve_mines("classic", ["qd"], 6)
	assert_eq(int(r["mines"]), 12, "qd 6×6 应回退到 12（4 的倍数）")


func test_qd_8x8_falls_back_to_24() -> void:
	var r := RuleFeasibility.resolve_mines("classic", ["qd"], 8)
	assert_eq(int(r["mines"]), 24, "qd 8×8 应回退到 24（4 的倍数）")


func test_all_candidates_unsat_reports_minus_one() -> void:
	# 镜像+行锁 6×6：偶数列镜像与行锁奇偶要求在全部候选雷数下均矛盾 → -1。
	var r := RuleFeasibility.resolve_mines("classic", ["mx", "rl"], 6)
	assert_eq(int(r["mines"]), -1, "全候选不可行应报 -1")
	assert_false(bool(r["standard"]))
