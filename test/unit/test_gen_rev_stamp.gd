extends GutTest

## 生成管线版本戳守卫（2026-09-24）
##
## 为什么需要：历史集里混着多代生成器产物（实测**同一 peak 组内** clue_ratio 仍离散 0.09–0.82，
## 见 `关卡集供给对账.md`「混版集量化」），而此前没有任何字段能区分版本——只能用 clue_ratio 近似，
## 无法精确做「版本优选」。加戳后：① 优选可精确执行；② 可回归（新盘必带最新戳）。
##
## 约定：**生成/删线索逻辑一改，必须递增 `PuzzleGenerator.GEN_REV`**（本测试会同步校验）。
## 兼容：老盘无此字段 = 2026-09-24 之前的多代混产，读取方一律按「缺字段 = 老管线」处理。


func test_generated_level_carries_gen_rev() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用 —— 生成器冒烟跳过（同 test_level_proof_coverage 说明）")
		return
	var gen := PuzzleGenerator.new()
	var lv: Dictionary = gen.generate_with_rules("classic", [], Vector2i(5, 5), 6, 20260924, 0, 20)
	assert_false(lv.is_empty(), "5×5 经典盘应能生成")
	assert_true(lv.has("gen_rev"), "新生成的关卡必须带 gen_rev 版本戳")
	assert_eq(str(lv.get("gen_rev", "")), PuzzleGenerator.GEN_REV,
	"gen_rev 必须等于 PuzzleGenerator.GEN_REV（改生成逻辑就要递增它）")


func test_gen_rev_is_not_empty_and_dated() -> void:
	# 值形如 "v4.1-0924"：前缀=难度体系口径，后缀=日期。不强制格式，只防「空串/占位」漂移。
	assert_ne(PuzzleGenerator.GEN_REV.strip_edges(), "", "GEN_REV 不能为空")
	assert_true(PuzzleGenerator.GEN_REV.length() >= 4, "GEN_REV 应是一个可读的版本串")
