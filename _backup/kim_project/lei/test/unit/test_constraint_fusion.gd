# test_constraint_fusion.gd —— ConstraintFusion 测试（22 号 K14 / 21 号 R22）
extends GutTest


func test_fuse_single_cells() -> void:
	# (0,0) 镜像 (3,0)、(1,0) 镜像 (2,0) 均不在 cells，故各自独立
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), [])
	assert_eq(groups.size(), 2, "无镜像对/骨牌时每个格独立成组")
	for g in groups:
		assert_eq((g["cells"] as Array).size(), 1, "每组合 1 格")
		assert_eq((g["mine_count"] as Array), [0, 1], "普通格贡献 0/1")


func test_fuse_mx_pair() -> void:
	# 4 列，镜像对 (0,0)<->(3,0)、(1,0)<->(2,0)
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(3, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), [])
	assert_eq(groups.size(), 1, "镜像对融合成 1 组")
	assert_eq((groups[0]["cells"] as Array).size(), 2, "组合 2 格")
	assert_eq((groups[0]["mine_count"] as Array), [0, 2], "镜像对贡献 0/2")


func test_fuse_no_mx_when_disabled() -> void:
	# use_mx=false 时，镜像对不应融合（DT 关卡绝不能套 MX）
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(3, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), [], false, false)
	assert_eq(groups.size(), 2, "use_mx=false 时镜像对不融合，两格独立")
	for g in groups:
		assert_eq((g["mine_count"] as Array), [0, 1], "独立格贡献 0/1")


func test_fuse_mx_center_free() -> void:
	# 3 列（奇数宽），中央列 (1,0) 的镜像是自己，不融合
	var cells: Array[Vector2i] = [Vector2i(1, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(3, 1), [])
	assert_eq(groups.size(), 1, "中央列不融合，独立成组")
	assert_eq((groups[0]["mine_count"] as Array), [0, 1], "中央列贡献 0/1（自由）")


func test_fuse_dt_pair() -> void:
	var dominoes := [[Vector2i(0, 0), Vector2i(1, 0)]]
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), dominoes)
	assert_eq(groups.size(), 1, "骨牌对融合成 1 组")
	assert_eq((groups[0]["mine_count"] as Array), [1, 1], "骨牌对恒贡献 1 雷")
	# 两种排布：a 雷 或 b 雷
	assert_eq((groups[0]["choices"] as Array).size(), 2, "两种排布")


func test_enumerate_simple() -> void:
	# 两个格，一条线索 need=1，窗口覆盖两格，恰好 1 雷
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), [])
	var cell_hits := {Vector2i(0, 0): [0], Vector2i(1, 0): [0]}
	var need := [1]
	var f := ConstraintFusion.new()
	var r := f.enumerate_groups(groups, cell_hits, need, 1, 1, 100, 1000)
	assert_eq(r["sols"].size(), 2, "两格恰一雷应有 2 解")
	assert_false(r["budget_exceeded"], "不应超预算")


func test_enumerate_mx_weighted() -> void:
	# 镜像对，一条线索 need=2，窗口覆盖两格，lo=hi=2（恰 2 雷）
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(3, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), [])
	var cell_hits := {Vector2i(0, 0): [0], Vector2i(3, 0): [0]}
	var need := [2]
	var f := ConstraintFusion.new()
	var r := f.enumerate_groups(groups, cell_hits, need, 2, 2, 100, 1000)
	assert_eq(r["sols"].size(), 1, "镜像对 need=2 应只有 1 解（两格都雷）")
	# 唯一解的雷位应含两格
	assert_true(r["sols"][0].has(Vector2i(0, 0)), "解含左格")
	assert_true(r["sols"][0].has(Vector2i(3, 0)), "解含右格")


func test_enumerate_dt_always_one_mine() -> void:
	# 骨牌对，一条线索 need=1，窗口覆盖两格
	var dominoes := [[Vector2i(0, 0), Vector2i(1, 0)]]
	var cells: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var groups := ConstraintFusion.fuse_groups(cells, Vector2i(4, 1), dominoes)
	var cell_hits := {Vector2i(0, 0): [0], Vector2i(1, 0): [0]}
	var need := [1]
	var f := ConstraintFusion.new()
	var r := f.enumerate_groups(groups, cell_hits, need, 1, 1, 100, 1000)
	assert_eq(r["sols"].size(), 2, "骨牌恰一雷应有 2 种排布")
	for sol in r["sols"]:
		var count := 0
		if sol.has(Vector2i(0, 0)):
			count += 1
		if sol.has(Vector2i(1, 0)):
			count += 1
		assert_eq(count, 1, "每解恰 1 雷")
