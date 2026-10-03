# gen_common.gd —— 关卡生成工具的「全局约束门控落盘」统一收口（2026-10-03）
#
# 【要治的缺陷】core/puzzle_generator.gd 已对异形盘上的 GEO_RECT_ONLY 全局约束做门控
# （丢弃该约束 + push_warning + last_call_stats.gated_globals 记录可读原因，见
# puzzle_generator.gd:473-498）。但生成工具若把 **SPEC 原始请求** 回写成产物字段
# `global_rules`，产出的关卡 JSON 就会「自称带 s2/dt 等约束、实际没建」——复用 / 工坊 /
# 规则图例都会按自述走 ⇒ 关卡自述与实际语义分叉，且现有 SPEC↔产物门禁抓不到
# （它比的是 SPEC 与 SPEC 派生的期望，两边都仍是原始 id）。
#
# 【本模块】读生成器 last_call_stats.gated_globals，返回「实际生效」的全局规则列表，
# 并在被拦时**打一行明确警告**（规则 id + 原因，人话）。四个生成工具共用这一处逻辑，
# 避免各写一份而各自演化（门禁只能按名字抽查、抄不进规则）。
#
# 用法（每个生成工具在 generate_with_rules 返回成功后调用一次）：
#     var eff := GenCommon.writeback_globals(gen, globals, file_name)
#     level["global_rules"] = eff["global_rules"]
# 调用点必须紧接**成功那次**生成：各工具的搜索循环在成功候选后立即 break
# ⇒ last_call_stats 即那一次（否则会读到上一个候选的 gated_globals）。
#
# ⚠️ 【成对提交策略（team-lead 决策，2026-10-03）】本回写让产物变诚实（被门控的约束从
# global_rules 里消失）。但 `levels/` 里现有的 va_/vg_/sty_var_/ani_* 是**门控落地前的旧数据**
# （仍自称带 s2/s5…），而库内门禁按「产物带原始 globals」断言：
#   · test/unit/test_geo_levels.gd:103          （vg_* 必须 ≥1 条 global_rules）
#   · test/unit/test_shape_mask_contract.gd:188 （ani_* SPEC globals == 产物 global_rules）
# 故**不得单独改这两处期望**（改空集会被上面的旧数据判红）。规则：
#   **当且仅当有人真要重跑并提交这些关卡包时**，在同一次改动里把「产物 + SPEC/期望 +
#   上述两条断言」一起更新为「生效集」口径；在那之前门禁保持现状绿。
# 探测旧数据的哨兵见 test/unit/test_gen_global_rules_writeback.gd（用例 ④）。
# （行号纠正：真·回写 bug 只有 gen_shape_levels.gd:995；gen_variant_shape_levels.gd:398 /
#   gen_style_shape_levels.gd:400 / gen_geo_levels.gd:356 是 generate_with_rules 调用点，
#   不是回写点；SPEC↔产物比较在 test_shape_mask_contract.gd:188 而非 :126。）
extends RefCounted


## 读 gen.last_call_stats.gated_globals 并返回回写口径：
##   { "global_rules": 实际生效列表, "gated": {规则 id: 原因} }
## 被拦（gated 非空）⇒ 打一行警告 + 返回 requested 去掉被拦项后的列表；
## 未被拦 ⇒ 返回 requested 的副本（行为与现状逐位一致，不改动别的字段）。
static func writeback_globals(gen, requested: Array, label: String = "") -> Dictionary:
	var gated: Dictionary = {}
	if gen != null:
		var stats: Dictionary = gen.last_call_stats
		gated = (stats.get("gated_globals", {}) as Dictionary).duplicate()
	if gated.is_empty():
		return {"global_rules": requested.duplicate(), "gated": {}}
	# 不许静默：被拦时必须能看见（规则 id + 原因）。
	for gid in gated.keys():
		push_warning("%s: 异形盘门控生效 —— 全局约束 %s **未生效**（原因：%s）；产物 global_rules 已写实际生效集，不再声称该约束生效" % [
			label, str(gid), str(gated[gid])])
	var kept: Array = []
	for gid in requested:
		if not gated.has(str(gid)):
			kept.append(gid)
	return {"global_rules": kept, "gated": gated}
