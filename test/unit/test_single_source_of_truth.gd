extends GutTest
## 单一事实源守卫（2026-09-19 架构审计）。
##
## 审计发现多处「同一份事实各写一份、靠注释约定『两处必须一起改』」。本项目历史上**真实**
## 因此出过事故：
##   · 组合 id 前缀漂移（量产 `c_o1` vs 选关页 `o1`）→ 关卡进库了也永远点不到；
##   · `tools/batch_merge.gd` 的档位表漏 `intro` → 入门档关卡在合并阶段被静默丢弃。
##
## 这里钉住**可引用**的副本：任何一处改了而另一处没跟，立刻红。
## 覆盖不到的部分（散落在各脚本内部的私有常量，如 `tools/*` 里的 `TIER_ORDER`）只能靠评审，
## 故本文件不假装全面 —— 它守的是已经能引用的那几条关键线。


func test_variant_catalog_orders_match_axes() -> void:
	## CLUE_ORDER / GLOBAL_ORDER 是展示顺序表，成员必须等于唯一事实源 VariantAxes
	assert_eq(VariantCatalog.CLUE_ORDER, ["classic"] + VariantAxes.OBS,
		"CLUE_ORDER 与 VariantAxes.OBS 漂移（core/variant_axes.gd 是唯一事实源）")
	assert_eq(VariantCatalog.GLOBAL_ORDER, VariantAxes.STRUCT + VariantAxes.CONSERVE + ["dt"],
		"GLOBAL_ORDER 与三轴漂移（dt 是唯一保留的旧单算子，按约定排最后）")


func test_official_rule_ids_match_axes() -> void:
	assert_eq(VariantCatalog.OFFICIAL_RULE_IDS,
		VariantAxes.OBS + VariantAxes.STRUCT + VariantAxes.CONSERVE,
		"OFFICIAL_RULE_IDS 与三轴漂移（它决定「哪些算官方算子」，漂移会误判 Mod 来源）")


func test_mine_counts_match_feasibility() -> void:
	## UI 侧曾留第二份雷数表；工具侧两处注释明令「禁止手写第二份雷数表」
	for side in LevelSequence.MINE_COUNTS:
		assert_eq(int(LevelSequence.MINE_COUNTS[side]), RuleFeasibility.standard_mines(int(side)),
			"雷数表与 RuleFeasibility 漂移（%d×%d）" % [int(side), int(side)])


func test_tier_order_matches_difficulty_tiers() -> void:
	## 档位名单漂移的直接后果见文件头（batch_merge 漏 intro 静默丢档）
	assert_eq(LevelLibrary.TIER_ORDER, Difficulty.TIERS.keys(),
		"TIER_ORDER 与 Difficulty.TIERS 漂移（档位名单应与 core/difficulty.gd 同源）")
