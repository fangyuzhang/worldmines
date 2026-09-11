extends GutTest

## 「0 值 ⟹ 邻域全安全」语义的单点规格（v2.9.3 收敛）
##
## 这条语义曾散落 4 处（board 扩散 / hint 零值特判 / 规则 zero_safe_neighbors /
## clue_engine 各写一套），新增变体极易漏改一处导致漂移。
## 现内置变体路径统一到 `ClueEngine.zero_safe_dirs`，本测试把它钉成**可执行规格**。

const V := ClueEngine.Variant


func _dir_set(variant: int, value: Variant) -> Dictionary:
	var s := {}
	for d in ClueEngine.zero_safe_dirs(variant, value):
		s[d] = true
	return s


func test_ring_variants_zero_means_eight_neighbors_safe() -> void:
	# CLASSIC / CLOCK / LOOP_RUNS / DIST_SUM：值 0 ⟹ 8 邻无雷
	for v in [V.CLASSIC, V.CLOCK, V.LOOP_RUNS, V.DIST_SUM]:
		assert_eq(_dir_set(v, 0).size(), 8, "变体 %d 的值 0 应扩散 8 邻" % v)
		assert_eq(ClueEngine.zero_safe_dirs(v, 1).size(), 0, "变体 %d 的值 1 不应扩散" % v)


func test_4n_and_sc_use_their_own_windows() -> void:
	assert_eq(_dir_set(V.N4, 0).size(), 4, "4N 的值 0 应只扩散 4 个正交邻")
	assert_eq(_dir_set(V.SAME_COLOR, 0).size(), 4, "SC 的值 0 应只扩散 4 个对角邻")
	# 正交与对角必须互不重叠（4+4=8）
	var orth := _dir_set(V.N4, 0)
	for d in ClueEngine.zero_safe_dirs(V.SAME_COLOR, 0):
		assert_false(orth.has(d), "正交与对角方向不应重叠")


func test_fr_never_spreads() -> void:
	# FR 的值 0 表示「右邻必雷」，与雷数无关 → 永不扩散
	assert_eq(ClueEngine.zero_safe_dirs(V.FR, 0).size(), 0, "FR 任何值都不扩散")
	assert_eq(ClueEngine.zero_safe_dirs(V.FR, "inf").size(), 0, "FR 的 inf 也不扩散")


func test_hv_spreads_per_component() -> void:
	assert_eq(_dir_set(V.HV, [0, 0]).size(), 8, "HV 双分量都 0 → 8 邻")
	assert_eq(_dir_set(V.HV, [0, 1]).size(), 4, "HV 仅正交分量为 0 → 4 正交")
	assert_eq(_dir_set(V.HV, [1, 0]).size(), 4, "HV 仅对角分量为 0 → 4 对角")
	assert_eq(ClueEngine.zero_safe_dirs(V.HV, [1, 1]).size(), 0, "HV 双分量都非 0 → 不扩散")
	# 畸形值不应崩溃（防御）
	assert_eq(ClueEngine.zero_safe_dirs(V.HV, 0).size(), 0, "HV 收到非数组值应安全返回空")


## board 的 0 值扩散邻域必须与单点规格一致。
## 注意：断言「扩散邻域」而非「最终翻开的格数」——邻格自身也是 0 值时会继续
## 链式扩散（3×3 无雷盘最终必然全翻，那是正确行为，不是规格差异）。
func test_board_flood_matches_spec() -> void:
	for pair in [[V.CLASSIC, 8], [V.N4, 4], [V.SAME_COLOR, 4], [V.FR, 0]]:
		var variant: int = pair[0]
		var expect: int = pair[1]
		var level := {
			"size": {"rows": 3, "cols": 3},
			"total_mines": 0,
			"mines": [],
			"revealed": [],
		}
		var b := Board.new()
		b.load_level(level)
		# level 的 "variant" 字段走注册表码解析，此处直接设枚举以聚焦「board → 单点」的接线
		b.clue_variant = variant
		var nbs: Array[Vector2i] = b._flood_neighbors(Vector2i(1, 1))
		assert_eq(nbs.size(), expect, "变体 %d 的 0 值扩散邻域应为 %d 格" % [variant, expect])
