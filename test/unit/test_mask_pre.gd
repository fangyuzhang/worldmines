extends GutTest

## 遮蔽前置（方向 1，2026-09-16 实装）测试：兼容性 / 结构 / 载盘契约。
## 覆盖：mask_count=0 逐位一致（产线零影响前提）；前置盘线索数 ≥ 基线（遮蔽格不许删）；
##       前置盘载盘（Board.load_level）后 ProofLog 序贯可解（R01 交付契约）。

const MASK_N := 3


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o5_sanjiao/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")


static func _cells(lv: Dictionary) -> Array:
	var s: Array = []
	for rv in lv.get("revealed", []):
		s.append("%d,%d" % [int(rv["c"]), int(rv["r"])])
	s.sort()
	return s


func _gen(seed_v: int, mask_n: int, pre: bool) -> Dictionary:
	return PuzzleGenerator.new().generate_with_rules(
		"o5", [], Vector2i(5, 5), 10, seed_v, mask_n, 50, null, 120_000, 0.0, 1, 0, pre)


func test_mask_pre_zero_is_bitwise_identical() -> void:
	# mask_count=0：前置开关不得改变任何产出（兼容性——全量产线/存量零影响的前提）
	var a := _gen(7, 0, false)
	var b := _gen(7, 0, true)
	assert_false(a.is_empty(), "基线应可生成")
	assert_false(b.is_empty(), "mask=0+pre 应可生成")
	assert_eq(_cells(a), _cells(b), "mask=0 时前置/后置产出应逐位一致")


func test_mask_pre_keeps_at_least_as_many_clues() -> void:
	# 前置：遮蔽格不许被删 → 保留线索数 ≥ 基线
	var base := _gen(7, 0, false)
	var pre := _gen(7, MASK_N, true)
	assert_false(base.is_empty(), "基线应可生成")
	assert_false(pre.is_empty(), "前置应可生成")
	assert_true((pre.get("revealed", []) as Array).size() >= (base.get("revealed", []) as Array).size(),
		"前置保留线索数应 ≥ 基线（遮蔽格不许删）")


func test_mask_pre_loadable_and_solvable() -> void:
	# 交付契约：前置盘载盘后序贯可解（ProofLog → Board.load_level 全链路）
	var pre := _gen(11, MASK_N, true)
	assert_false(pre.is_empty(), "前置应可生成")
	var solved := bool((ProofLog.build(pre) as Dictionary).get("solved", false))
	assert_true(solved, "前置盘载盘后应序贯可解（R01）")


func test_mask_post_still_works() -> void:
	# 后置路径（默认）回归：mask 盘可生成且载盘可解（不动旧行为）
	var post := _gen(11, MASK_N, false)
	assert_false(post.is_empty(), "后置应可生成")
	var solved := bool((ProofLog.build(post) as Dictionary).get("solved", false))
	assert_true(solved, "后置盘载盘后应序贯可解")
