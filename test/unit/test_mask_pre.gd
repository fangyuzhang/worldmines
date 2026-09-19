extends GutTest

## 遮蔽前置（方向 1，2026-09-16 实装）测试：兼容性 / 结构 / 载盘契约。
## 覆盖：mask_count=0 逐位一致（产线零影响前提）；前置盘线索数 ≥ 基线（遮蔽格不许删）；
##       前置盘载盘（Board.load_level）后 ProofLog 序贯可解（R01 交付契约）。

const MASK_N := 3
## 盘面口径（v4.0 调整）：原 5×5/10 雷 + 遮蔽 3 在「开局即胜门禁」下**结构性被拒**
## ——遮蔽格不许删 ⇒ 必须给全线索 ⇒ 全非雷格皆线索 ⇒ 死盘（实测 12 个 seed 全空）。
## 7×7/14 雷起有剪枝空间，可正常产出前置盘。
const SIDE := 7
const MINES := 14


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


func _gen_on(seed_v: int, mask_n: int, pre: bool, side: int, mines: int) -> Dictionary:
	return PuzzleGenerator.new().generate_with_rules(
		"o5", [], Vector2i(side, side), mines, seed_v, mask_n, 50, null, 120_000, 0.0, 1, 0, pre)


## 找一个「基线（无遮蔽）与前置（遮蔽）都能生成」的 seed。
## 为什么不钉死单个 seed：v4.0 门禁会拒收「全非雷格皆线索」的死盘，某些 seed 因此变空——
## 这是预期行为（那种盘不该产出）。扫不到可用 seed 说明盘面配置需再换大。
func _usable_seed(side: int, mines: int, mask_n: int) -> int:
	for s in range(1, 13):
		if not _gen_on(s, 0, false, side, mines).is_empty() \
				and not _gen_on(s, mask_n, true, side, mines).is_empty():
			return s
	return 0


func test_mask_pre_zero_is_bitwise_identical() -> void:
	# mask_count=0：前置开关不得改变任何产出（兼容性——全量产线/存量零影响的前提）
	var a := _gen_on(3, 0, false, SIDE, MINES)
	var b := _gen_on(3, 0, true, SIDE, MINES)
	assert_false(a.is_empty(), "基线应可生成")
	assert_false(b.is_empty(), "mask=0+pre 应可生成")
	assert_eq(_cells(a), _cells(b), "mask=0 时前置/后置产出应逐位一致")


func test_mask_pre_keeps_at_least_as_many_clues() -> void:
	# 前置：遮蔽格不许被删 → 保留线索数 ≥ 基线
	var s := _usable_seed(SIDE, MINES, MASK_N)
	assert_gt(s, 0, "应存在「基线与前置都能生成」的 seed（否则盘面配置需再换大）")
	var base := _gen_on(s, 0, false, SIDE, MINES)
	var pre := _gen_on(s, MASK_N, true, SIDE, MINES)
	assert_false(base.is_empty(), "基线应可生成")
	assert_false(pre.is_empty(), "前置应可生成")
	assert_true((pre.get("revealed", []) as Array).size() >= (base.get("revealed", []) as Array).size(),
		"前置保留线索数应 ≥ 基线（遮蔽格不许删）")


func test_mask_pre_loadable_and_solvable() -> void:
	# 交付契约：前置盘载盘后序贯可解（ProofLog → Board.load_level 全链路）
	var pre := _gen_on(3, MASK_N, true, SIDE, MINES)
	assert_false(pre.is_empty(), "前置应可生成（7×7/14 雷 + 遮蔽 3）")
	var solved := bool((ProofLog.build(pre) as Dictionary).get("solved", false))
	assert_true(solved, "前置盘载盘后应序贯可解（R01）")


func test_mask_post_still_works() -> void:
	# 后置路径（默认）回归：mask 盘可生成且载盘可解（不动旧行为）
	var post := _gen_on(3, MASK_N, false, SIDE, MINES)
	assert_false(post.is_empty(), "后置应可生成")
	var solved := bool((ProofLog.build(post) as Dictionary).get("solved", false))
	assert_true(solved, "后置盘载盘后应序贯可解")
