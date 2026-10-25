extends GutTest
## level_artifact.gd 盲区补测（2026-10-25 技术债清偿；方案 D 的产物容器此前零直接测试）。
## LevelArtifact = seed 配方 + 生成结果成对落盘的最小载体，测默认值与赋值往返。


func test_defaults() -> void:
	var a := LevelArtifact.new()
	assert_null(a.recipe, "默认无配方")
	assert_eq(a.level, {}, "默认空关卡")


func test_assignment_roundtrip() -> void:
	var a := LevelArtifact.new()
	var r := SeedRecipe.new()
	a.recipe = r
	a.level = {"clue_rule": "4n", "mines": [[1, 1]], "size": {"cols": 5, "rows": 5}, "total_mines": 1}
	assert_same(a.recipe, r, "配方应持有同一 SeedRecipe 实例")
	assert_eq(str(a.level["clue_rule"]), "4n", "关卡字典原样持有")
	assert_eq(int(a.level["total_mines"]), 1, "雷数往返")


func test_artifacts_are_independent() -> void:
	# RefCounted 容器不得共享内部状态（两个产物各改各的）
	var a1 := LevelArtifact.new()
	var a2 := LevelArtifact.new()
	a1.level["k"] = 1
	assert_false(a2.level.has("k"), "实例间不得串数据")
