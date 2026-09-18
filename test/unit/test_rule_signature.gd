# test_rule_signature.gd —— 算子代数签名与组合判据（RuleSignature）
#
# 背景（2026-09-18）：签名表原先只有旧 id（`classic/4n/sc/…` + `mx/rl/qd/…`），官方 22 席
# 一个都不在 → `compat()` 一律回退 `warn`（R0）→ 混合档格子的 tooltip 只能写泛化文案，
# 且 R4 蕴含 / R5 整除这两类**真正该禁止**的组合推导不出来。本文件锁住补签名的成果。
extends GutTest


## 官方三轴 22 席（GDD §4）：观测 10 + 结构 7 + 守恒 5。
const OFFICIAL_IDS := [
	"o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10",
	"s1", "s2", "s3", "s4", "s5", "s6", "s7",
	"z1", "z2", "z3", "z4", "z5",
]


# RS1：22 席全部入表，且五元组字段齐备
func test_rs1_official_ids_are_in_table() -> void:
	assert_eq(OFFICIAL_IDS.size(), 22, "官方三轴应为 22 席（结构契约）")
	var t := RuleSignature.table()
	for id in OFFICIAL_IDS:
		assert_true(t.has(id), "官方席位 %s 应已入签名表" % id)
		if not t.has(id):
			continue
		var sig: Dictionary = t[id]
		for key in ["obj", "scope", "win", "sym", "div", "implies"]:
			assert_true(sig.has(key), "%s 的签名缺字段 %s" % [id, key])


# RS2：与旧席位同规则的 5 席必须与旧签名**完全一致**
# （同一条规则的两份实现，代数身份必须一致，否则同一规则会有两套判据）
func test_rs2_equivalent_seats_share_signature() -> void:
	var t := RuleSignature.table()
	for pair in [["o8", "clock"], ["o10", "loopruns"], ["z1", "mx"], ["z2", "rl"], ["z3", "qd"]]:
		assert_eq(t[str(pair[0])], t[str(pair[1])],
				"%s 与 %s 同规则，签名必须完全一致" % [pair[0], pair[1]])


# RS3：判据按 R1~R5 推导，而不是回退 R0 —— 这是补签名的全部意义
func test_rs3_verdicts_are_derived_not_fallback() -> void:
	var size := Vector2i(7, 7)
	var mines := LevelSequence.mine_count(7)

	# 跨轴（结构 × 观测）：作用对象不同 → R1 正交
	var cross := RuleSignature.compat("s1", "o1", size, mines)
	assert_eq(str(cross["verdict"]), RuleSignature.OK, "结构 × 观测应判 ok（R1 跨轴正交）")
	assert_false(str(cross["reason"]).contains("未知算子签名"),
			"不应再回退「未知算子签名」（实际理由：%s）" % str(cross["reason"]))
	assert_true((cross["rules"] as Array).has("R1"), "理由应引用 R1")

	# 同轴同作用域（无环 × 分量数K）：GDD §5.3 明确是 J2 警告 → R2
	var same_scope := RuleSignature.compat("s3", "s7", size, mines)
	assert_eq(str(same_scope["verdict"]), RuleSignature.WARN,
			"无环 × 分量数K 应判 warn（GDD §5.3 的 J2）")
	assert_true((same_scope["rules"] as Array).has("R2"), "理由应引用 R2（同作用域叠加）")

	# 全部 22 席两两判定都不得再回退 R0
	for i in OFFICIAL_IDS.size():
		for j in range(i + 1, OFFICIAL_IDS.size()):
			var v := RuleSignature.compat(OFFICIAL_IDS[i], OFFICIAL_IDS[j], size, mines)
			assert_false((v["rules"] as Array).has("R0"),
					"%s+%s 仍回退 R0（未知签名）：%s" % [OFFICIAL_IDS[i], OFFICIAL_IDS[j],
						str(v["reason"])])


# RS4：混合档的 verdict 真的来自签名表 —— 结构 × 结构里应同时存在 ok 与 warn 两类
# （若签名表没生效，所有格子会退化成同一种 warn，tooltip 千篇一律）
func test_rs4_mixed_tables_use_derived_verdicts() -> void:
	var size := Vector2i(7, 7)
	var mines := LevelSequence.mine_count(7)
	var kinds := {}
	for p in VariantCatalog.gg_all(size, mines):
		kinds[str((p as Dictionary)["verdict"])] = true
	assert_true(kinds.has(RuleSignature.OK),
			"结构 × 结构里应存在判 ok 的组合（跨 obj / 作用域相容）")
	assert_true(kinds.has(RuleSignature.WARN),
			"结构 × 结构里应存在判 warn 的组合（同作用域，即 GDD §5.3 的 J2）")
