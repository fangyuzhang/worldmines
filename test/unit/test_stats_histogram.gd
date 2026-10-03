# test_stats_histogram.gd —— StatsHistogram 门禁（缺口 #16 第一块）
#
# 钉四件事：① 常规请求桶数 == 请求值；② 超上限被钳且可看出被钳；
# ③ 空数组 / 区间非法 ⇒ 可读 reason；④ 桶内计数总和 == 有效样本数（守恒，防丢样本）。
# 用 preload 而非 class_name 引用：headless `-s` 下新全局类可能不在 .godot 缓存里（坑表 #26）。
extends GutTest

const H := preload("res://core/stats_histogram.gd")


func test_bucket_count_matches_request_when_within_cap() -> void:
	var vals := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
	var h := H.histogram(vals, 5, 0.0, 10.0)
	assert_eq((h["buckets"] as Array).size(), 5, "常规区间：桶数应等于请求值")
	assert_eq(int(h["n"]), 10, "10 个样本都在区间内 ⇒ n=10")
	var sum := 0
	for b in h["buckets"]:
		sum += int(b)
	assert_eq(sum, int(h["n"]), "均匀分布下桶内计数总和 == 有效样本数")
	assert_eq(str(h["reason"]), "", "无问题时 reason 应为空")


func test_requested_over_cap_is_clamped_and_visible() -> void:
	var h := H.histogram([1.0, 2.0], 1000, 0.0, 3.0)
	assert_eq((h["buckets"] as Array).size(), H.MAX_BUCKETS, "超上限请求应被钳到 MAX_BUCKETS")
	assert_true(bool(h["clamped"]), "clamped 标记应给出被钳信号")
	assert_ne(str(h["reason"]).find("上限"), -1, "reason 应说明被钳到上限")
	assert_eq(int(h["requested_buckets"]), 1000, "保留原始请求值供排查")


func test_empty_and_illegal_range_have_readable_reason() -> void:
	var e := H.histogram([], 4, 0.0, 1.0)
	assert_ne(str(e["reason"]).find("空数组"), -1, "空数组应给出可读 reason")
	assert_eq((e["buckets"] as Array).size(), 4, "空数组仍返回合法形状（面板无需特判）")
	assert_eq(int(e["n"]), 0, "空数组 n=0")

	var equal_range := H.histogram([1.0, 2.0], 4, 5.0, 5.0)
	assert_ne(str(equal_range["reason"]).find("min"), -1, "min==max 应给出可读 reason")
	assert_eq(int(equal_range["n"]), 0, "区间非法时 n=0")

	var inverted := H.histogram([1.0], 4, 3.0, 1.0)
	assert_ne(str(inverted["reason"]).find("min"), -1, "min>max 同样拒绝")


func test_bucket_sum_equals_valid_sample_count_conservation() -> void:
	# 有效：0.5 / 1.5 / 2.5；被忽略：9.9、-1.0（越界）+ "x"、true（非数值）。
	var vals := [0.5, 1.5, 2.5, 9.9, -1.0, "x", true]
	var h := H.histogram(vals, 3, 0.0, 3.0)
	var sum := 0
	for b in h["buckets"]:
		sum += int(b)
	assert_eq(sum, int(h["n"]), "桶内计数总和必须 == 有效样本数（不丢样本）")
	assert_eq(int(h["n"]), 3, "0.5/1.5/2.5 是 3 个有效样本")
	assert_eq(int(h["skipped"]), 4, "2 个越界 + 2 个非数值 = 4 个被忽略")
	assert_ne(str(h["reason"]).find("超出区间"), -1, "越界样本应在 reason 里报数")


func test_density_and_numbers_entries() -> void:
	# 5x5，10 雷（密度 0.4）
	var lv_a := {
		"size": {"rows": 5, "cols": 5},
		"mines": [[0, 0], [0, 1], [1, 0], [1, 1], [2, 2], [3, 3], [4, 4], [0, 4], [4, 0], [2, 4]],
	}
	# 5x5，5 雷（密度 0.2）
	var lv_b := {"size": {"rows": 5, "cols": 5}, "mines": [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4]]}

	var dh := H.density_histogram([lv_a, lv_b], 2)
	assert_eq(int(dh["n"]), 2, "两个合法关卡都应计入密度直方图")
	var dsum := 0
	for b in dh["buckets"]:
		dsum += int(b)
	assert_eq(dsum, 2, "密度直方图同样守恒")

	var nh := H.numbers_histogram([lv_a])
	assert_eq(int(nh["n"]), 15, "5x5 有 10 雷 ⇒ 15 个非雷格的数字")

	# 非法关卡被跳过并报数
	var bad := H.density_histogram([lv_a, 123, {}], 2)
	assert_eq(int(bad["n"]), 1, "非法关卡不应进入直方图")
	assert_ne(str(bad["reason"]).find("不合法"), -1, "被跳过的非法关卡应在 reason 里报数")
