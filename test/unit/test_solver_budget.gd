extends GutTest

## 求解累计预算回归（v4.0 挂死治理）：
## 单次 Solve 有 max_time_in_seconds 上限，但 FindForcedCells 一次调用要做 O(自由格数) 次
## assumption 探测 —— **单次有界 ≠ 累计有界**（9×9 约 40 自由格 × 8s = 理论 320s/次调用，
## 而删线索是 O(n) 条 × 序贯 O(轮) 次调用 ⇒ 墙钟可被拖到小时级，进程外看门狗只能事后杀）。
##
## 测试盘面选「5×5 / 1 雷 + 中腹线索 1」：8 邻域恰 1 雷 ⇒ 邻域外 16 格**必为安全格**，
## 结论确定且非空（避免空对空的空泛断言）。钉住三条：
##   ① 默认预算必须报出全部 16 格（预算不得吃掉该有的结论）；
##   ② 收紧预算的结论必须是默认结论的**子集**，且数量不多于默认（保守方向，绝不产坏关）；
##   ③ 显式下发默认值与缺键默认必须逐格一致（防两条路径分叉）。
##
## 不断言「预算极小 → 恰好 0 格」：探测是逐格推进的，预算耗尽点取决于单格探测耗时
## （实测 1ms 预算在 5×5 上停在第 3 格），把机器速度写进断言必然 flaky。

const CENTER := Vector2i(2, 2)
const OUTSIDE_COUNT := 16  # 25 格 - 中央 1 格 - 8 邻域


func _spec(budget_ms: int) -> Dictionary:
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(&"classic")
	var oracle := RuleOracle.new(clue_rule, [], Vector2i(5, 5), 1, null)
	var spec := oracle.build_spec({CENTER: 1}, [], {})
	spec["probe_budget_ms"] = budget_ms
	return spec


func _cells(forced: Dictionary, kind: String) -> Array:
	var out: Array = []
	for c in forced.get(kind, []):
		out.append("%d,%d" % [int(c[0]), int(c[1])])
	out.sort()
	return out


func test_default_budget_finds_all_forced_safe_cells() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var f := RuleCpSat.find_forced_cells(_spec(8000))
	assert_eq(_cells(f, "safe").size(), OUTSIDE_COUNT, "邻域外 16 格应全部被判为强制安全")
	assert_eq(_cells(f, "mine").size(), 0, "该盘面无强制雷格")


func test_tight_budget_only_reports_fewer() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var full := _cells(RuleCpSat.find_forced_cells(_spec(8000)), "safe")
	var tight := _cells(RuleCpSat.find_forced_cells(_spec(1)), "safe")
	assert_eq(full.size(), OUTSIDE_COUNT, "默认预算须报满 16 格（基准）")
	assert_true(tight.size() <= full.size(), "收紧预算的结论数不得多于默认预算（实测 ≤ 3）")
	for c in tight:
		assert_true(full.has(c), "收紧预算不得多报强制格：%s" % c)


func test_explicit_default_matches_implicit_default() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var explicit := _cells(RuleCpSat.find_forced_cells(_spec(8000)), "safe")
	var spec := _spec(8000)
	spec.erase("probe_budget_ms")  # 缺键 = C# 侧默认
	var implicit := _cells(RuleCpSat.find_forced_cells(spec), "safe")
	assert_eq(explicit, implicit, "显式默认预算与缺键默认必须逐格一致")
	assert_eq(explicit.size(), OUTSIDE_COUNT, "两种路径都该报出全部 16 格")
