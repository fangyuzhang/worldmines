extends GutTest

## RuleFeasibility 真值查询回归：已知 UNSAT 清单必须为 false、已知可行样本为 true。
## 这些结论由 CP-SAT 数学保证（非手写规则），本测试同时钉住「UI/批量预筛共用的唯一入口」。

const R07 := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func before_each() -> void:
	RuleFeasibility.clear_cache()


func _q(clue: String, globals: Array, side: int) -> bool:
	return RuleFeasibility.query(clue, globals, side, R07[side])


# ===== 已知 UNSAT（数学论证见 v2.9.3 可行性矩阵审计）=====

func test_rl_6x6_unsat() -> void:
	# 6 项 ±1 序列总和恒奇，14 为偶 → 矛盾
	assert_false(_q("classic", ["rl"], 6), "RL 6×6 应 UNSAT")


func test_qd_even_sizes_unsat() -> void:
	# 四象限雷数须为 4 的倍数，14/26 不是
	assert_false(_q("classic", ["qd"], 6), "QD 6×6 应 UNSAT")
	assert_false(_q("classic", ["qd"], 8), "QD 8×8 应 UNSAT")


func test_rl_qd_5x5_unsat() -> void:
	assert_false(_q("classic", ["rl", "qd"], 5), "rl+qd 5×5 应 UNSAT（双重叠加矛盾）")


func test_mx_rl_even_unsat() -> void:
	# mx 偶数列盘无中轴 → 每行雷数必偶 → 行差必偶 ≠ 1
	assert_false(_q("classic", ["mx", "rl"], 6), "mx+rl 6×6 应 UNSAT")
	assert_false(_q("classic", ["mx", "rl"], 8), "mx+rl 8×8 应 UNSAT")


# ===== 已知可行样本 =====

func test_all_sizes_feasible_for_plain_variants() -> void:
	for side in [5, 6, 7, 8, 9]:
		assert_true(_q("classic", [], side), "classic %dx%d 应可行" % [side, side])
		assert_true(_q("loopruns", [], side), "loopruns %dx%d 应可行" % [side, side])
		assert_true(_q("clock", [], side), "clock %dx%d 应可行" % [side, side])


func test_rl_feasible_outside_6x6() -> void:
	assert_true(_q("classic", ["rl"], 5), "RL 5×5 应可行")
	assert_true(_q("classic", ["rl"], 7), "RL 7×7 应可行")
	assert_true(_q("classic", ["rl"], 9), "RL 9×9 应可行")


func test_dt_resample_optimistic_for_known_feasible() -> void:
	# mx+dt：单次骨牌划分 ~72% 可行，重采样 OR 后应判可行（不误杀）
	assert_true(_q("classic", ["mx", "dt"], 5), "mx+dt 5×5 应可行（重采样 OR）")
	assert_true(_q("classic", ["mx", "dt"], 9), "mx+dt 9×9 应可行")


func test_mx_pf_feasible() -> void:
	assert_true(_q("classic", ["mx", "pf"], 8), "mx+pf 8×8 应可行")


# ===== 缓存与确定性 =====

func test_cache_consistency() -> void:
	var a := _q("classic", ["qd"], 6)
	assert_true(RuleFeasibility._cache.size() > 0, "查询后应有缓存")
	var b := _q("classic", ["qd"], 6)
	assert_eq(a, b, "同 key 两次查询结果一致（缓存命中）")
