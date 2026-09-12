extends GutTest

## 跨 seed 盘多样性回归（v2.9.3 mod 试验修复）：
## CP-SAT find_solution 对简单模型曾「不同 random_seed 同一解」（presolve 定解）——
## qd_sc 5×5 实测 5 个不同 seed 只出 1 种解，批量生成这些单元只能出同一张盘。
## 修复（_find_solution_best 扰动采样）后断言：跨 seed 应产出不同盘。


func _fp(level: Dictionary) -> String:
	var ms: Array = []
	for m in level.get("mines", []):
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	return "|".join(ms)


func test_cross_seed_diversity_simple_model() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	# qd_sc 5×5 是「简单模型」代表（修复前：不同 seed 恒同解）
	var fps := {}
	var ok := 0
	for seed in [1, 2, 3]:
		var level: Dictionary = PuzzleGenerator.new().generate_with_rules(
			"sc", ["qd"], Vector2i(5, 5), 10, seed, 0, 50, null, 60_000)
		if level.is_empty():
			continue
		ok += 1
		fps[_fp(level)] = true
	assert_gt(ok, 0, "至少应能出关（规则可行）")
	assert_gt(fps.size(), 1, "跨 seed 应产出不同盘（修复前恒 1——同盘重复）")
