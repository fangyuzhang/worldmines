# test_constraint_fusion.gd —— 变量融合（constraint_fusion.gd）单元测试
# 模块纯函数式（不依赖 Board，头注释明确「可独立单元测试」），此前 20KB 零测试覆盖。
# 本套验证 fuse_groups 的三类融合行为：DT 骨牌对 / MX 镜像对 / 开关禁用回退。
extends GutTest


func test_dt_pair_fuses_into_group() -> void:
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var dominoes := [[Vector2i(0, 0), Vector2i(1, 0)]]
	var groups: Array = ConstraintFusion.fuse_groups(cells, Vector2i(5, 5), dominoes, false, true)
	assert_eq(groups.size(), 1, "一对骨牌融合为 1 组")
	assert_eq(groups[0]["cells"], [Vector2i(0, 0), Vector2i(1, 0)], "组内两格")
	assert_eq(groups[0]["choices"].size(), 2, "两种排布（a 雷 / b 雷）")
	assert_eq(groups[0]["mine_count"], [1, 1], "每排布恒贡献 1 雷")


func test_mx_pair_fuses_into_group() -> void:
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(4, 0)]
	var groups: Array = ConstraintFusion.fuse_groups(cells, Vector2i(5, 5), [], true, false)
	assert_eq(groups.size(), 1, "镜像对融合为 1 组")
	assert_eq(groups[0]["choices"].size(), 2, "同安全 / 同雷两种取值")
	assert_eq(groups[0]["mine_count"], [0, 2], "贡献 0 或 2 雷")


func test_mirror_outside_cells_stays_single() -> void:
	# (1,1) 的镜像 (3,1) 不在分量内 → 不成组，按普通格单独输出
	var cells: Array[Vector2i] = [Vector2i(1, 1)]
	var groups: Array = ConstraintFusion.fuse_groups(cells, Vector2i(5, 5), [], true, false)
	assert_eq(groups.size(), 1, "无镜像伙伴 → 普通单格组")
	assert_eq(groups[0]["cells"], [Vector2i(1, 1)])
	assert_eq(groups[0]["mine_count"], [0, 1])


func test_switches_disable_fusion() -> void:
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(4, 0)]
	var dominoes := [[Vector2i(0, 0), Vector2i(1, 0)]]
	# 双开关全关 → 融合全部禁用，每格独立成组（sound：少推但不错）
	var groups: Array = ConstraintFusion.fuse_groups(cells, Vector2i(5, 5), dominoes, false, false)
	assert_eq(groups.size(), 3, "关掉融合后每格独立成组")
	for g in groups:
		assert_eq(g["cells"].size(), 1, "普通格为单格组")


func test_dt_pair_requires_both_cells_in_frontier() -> void:
	# 骨牌只有一半落在 frontier → 不融合（跨分量配对保持原样）
	var cells: Array[Vector2i] = [Vector2i(0, 0)]
	var dominoes := [[Vector2i(0, 0), Vector2i(1, 0)]]
	var groups: Array = ConstraintFusion.fuse_groups(cells, Vector2i(5, 5), dominoes, false, true)
	assert_eq(groups.size(), 1)
	assert_eq(groups[0]["cells"].size(), 1, "缺对侧格 → 不融合")
