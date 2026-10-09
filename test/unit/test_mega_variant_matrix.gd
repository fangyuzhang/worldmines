# test_mega_variant_matrix.gd —— 变体 × 复合格（Mega Cell）兼容门禁的用例（2026-10-09）
#
# 背景：文档「五、变体规则配置 · ⚠ 复合格 × 变体」要求「骨牌不允许跨复合格、镜像轴上的复合格
# 必须成对、染色按复合格中心点判定——这些未定义组合必须进兼容门禁，否则运行期出错」。
# 骨牌那条已由 core/domino_model.gd 硬拒绝；本文件钉的是新落地的
# core/mega_variant_matrix.gd（唯一事实源）+ core/editor_verify.gd 的消费（用户可见）。
#
# 覆盖：
#   A. 表覆盖全部内置变体（漏登记必红）+ 唯一被建模的是 classic；
#   B. 无复合格 ⇒ 一律不判（不产噪音）；表外 id ⇒ 不臆造；
#   C. 三态契约（与 VariantGridMatrix 同值；DISABLED ⇔ 有可读理由；DEGRADED ⇔ 非空退化清单）；
#   D. 理由必须点名可查证的 file:line（不凭想象）；
#   E. 文档点名的「镜像轴上的复合格必须成对」逐格检查（成对 / 不成对 / 跨出轴 / 空输入）；
#   F. 验证器消费：并入 issues 且**幂等**（单岛路径会二次挂载，不许出现两遍）。
extends GutTest

const MM := preload("res://core/mega_variant_matrix.gd")
const VGM := preload("res://core/variant_grid_matrix.gd")
const ER := preload("res://core/editor_verify.gd")


# ==================== 装置 ====================

func _mega_of(groups: Array) -> MegaCell:
	var m := MegaCell.new()
	for g: Variant in groups:
		var r: Dictionary = m.merge(g as Array)
		assert_true(bool(r.get("ok", false)), "装置：合并 %s 应成功（%s）" % [str(g), str(r)])
	return m


func _doc_with_mega(mega: MegaCell, rows := 9, cols := 9) -> EditorDoc:
	var d := EditorDoc.new(rows, cols)
	d.mega_cells = mega
	return d


# ==================== A. 表覆盖 + 唯一被建模者 ====================

func test_only_classic_is_modeled_on_mega_cells() -> void:
	assert_eq(MM.status("classic", true), MM.OK, "classic 是唯一在复合格上被建模的变体")
	assert_eq(MM.reason("classic", true).strip_edges(), "", "OK 不给理由文字")
	assert_eq(MM.degradations("classic", true).size(), 0, "OK 不给退化清单")


func test_every_other_builtin_variant_is_disabled_on_mega_cells() -> void:
	var all := MM.variant_ids()
	assert_true(all.size() >= 15, "内置变体应至少 15 个（实际 %d）——少了说明注册表变了" % all.size())
	var seen := 0
	for vid in all:
		assert_true(MM.is_known_variant(vid), "%s 应在内置名单里" % vid)
		if vid == "classic":
			continue
		seen += 1
		assert_eq(MM.status(vid, true), MM.DISABLED,
				"%s 在含复合格的盘上必须禁用（漏登记 = 用户勾了却按另一个口径算）" % vid)
		assert_ne(MM.reason(vid, true).strip_edges(), "", "%s 必须给可读理由" % vid)
	assert_eq(seen, all.size() - 1, "除 classic 外每个内置变体都必须被本表判过（防漏登记）")


func test_table_covers_exactly_the_registry_names() -> void:
	# 表与注册表同源：逐项互相包含，多一个/少一个都红。
	var reg := VariantRegistry.all_codes()
	assert_eq(MM.variant_ids(), reg, "本表名单必须 == VariantRegistry.all_codes()")
	for vid in reg:
		assert_true(MM.is_known_variant(str(vid)), "注册表里的 %s 必须被表认识" % str(vid))


# ==================== B. 不产噪音 / 不臆造 ====================

func test_no_mega_cells_means_no_judgement() -> void:
	for vid in MM.variant_ids():
		assert_eq(MM.status(vid, false), MM.OK, "%s：盘上没有复合格 ⇒ 不判（OK）" % vid)
		assert_eq(MM.reason(vid, false).strip_edges(), "", "%s：不判就不给理由" % vid)


func test_unknown_variant_is_not_judged() -> void:
	for bad in ["", "my_ai_spec_xxx", "hyperbolic", "classic_x", "mx2"]:
		assert_eq(MM.status(bad, true), "", "表外 id「%s」⇒ 返回空串（不判，宁缺勿错）" % bad)
		assert_eq(MM.reason(bad, true).strip_edges(), "", "表外 id「%s」不给理由" % bad)


# ==================== C. 三态契约 ====================

func test_three_state_constants_match_variant_grid_matrix() -> void:
	assert_eq(MM.OK, VGM.OK, "OK 必须与 VariantGridMatrix 同值")
	assert_eq(MM.DEGRADED, VGM.DEGRADED, "DEGRADED 必须与 VariantGridMatrix 同值")
	assert_eq(MM.DISABLED, VGM.DISABLED, "DISABLED 必须与 VariantGridMatrix 同值")


func test_status_reason_and_degradations_are_mutually_consistent() -> void:
	for vid in MM.variant_ids():
		for has_mega in [true, false]:
			var st := MM.status(vid, has_mega)
			var why := MM.reason(vid, has_mega)
			var deg := MM.degradations(vid, has_mega)
			assert_true([MM.OK, MM.DEGRADED, MM.DISABLED].has(st),
					"%s(has_mega=%s)：三态非法 %s" % [vid, str(has_mega), st])
			if st == MM.OK:
				assert_eq(why.strip_edges(), "", "%s：OK 不给理由" % vid)
			else:
				assert_ne(why.strip_edges(), "", "%s：非 OK 必须给理由" % vid)
			if st == MM.DEGRADED:
				assert_gt(deg.size(), 0, "%s：DEGRADED 必须带非空退化清单" % vid)
			else:
				assert_eq(deg.size(), 0, "%s：非 DEGRADED 不给退化清单" % vid)


# ==================== D. 理由可查证 ====================

func test_disabled_reason_cites_verifiable_evidence() -> void:
	# 线索型 → 指向 mega_solver 的线索窗口拒绝；全局约束型 → 指向全局约束拒绝；dt 另指 domino_model。
	var clue_reason := MM.reason("sc", true)
	assert_true(clue_reason.contains("mega_solver.gd"), "线索型理由要点名 mega_solver.gd：%s" % clue_reason)
	var global_reason := MM.reason("4c", true)
	assert_true(global_reason.contains("mega_solver.gd"), "全局型理由要点名 mega_solver.gd：%s" % global_reason)
	var dt_reason := MM.reason("dt", true)
	assert_true(dt_reason.contains("domino_model.gd"),
			"dt 理由还要点名骨牌那条硬拒绝（core/domino_model.gd）：%s" % dt_reason)
	for vid in MM.variant_ids():
		var why := MM.reason(vid, true)
		if why.is_empty():
			continue
		assert_true(why.contains(".gd:"), "%s 的理由必须带 file:line（可查证，不凭想象）：%s" % [vid, why])


# ==================== E. 镜像轴上的复合格必须成对 ====================

func test_mirror_pairs_accept_symmetric_layouts() -> void:
	# cols = 9（轴在 x=4）：两组互为镜像 ⇒ 零条目。
	var m := _mega_of([
		[Vector2i(0, 0), Vector2i(1, 0)],
		[Vector2i(8, 0), Vector2i(7, 0)],
	])
	assert_eq(MM.mirror_pair_issues(m, 9).size(), 0, "互为镜像的两组必须判成对")


func test_mirror_pairs_accept_self_mirroring_group() -> void:
	# 跨轴自对称的一组（左半 + 右半在同一复合格里）也是成对。
	var m := _mega_of([[Vector2i(0, 0), Vector2i(8, 0)], [Vector2i(3, 0), Vector2i(5, 0)]])
	assert_eq(MM.mirror_pair_issues(m, 9).size(), 0, "自镜像（左半+右半同组）必须判成对")


func test_mirror_pairs_flag_unpaired_mega() -> void:
	var m := _mega_of([[Vector2i(0, 0), Vector2i(1, 0)]])
	var issues := MM.mirror_pair_issues(m, 9)
	assert_eq(issues.size(), 1, "没有镜像搭档的复合格必须报出来（实际：%s）" % str(issues))
	if issues.size() == 1:
		var it: Dictionary = issues[0]
		assert_eq(str(it["code"]), "mega_mirror_unpaired", "条目 code 应可被 UI 归类")
		assert_eq(it["pos"], Vector2i(0, 0), "pos 必须是该复格的首格（规范序），供 UI 跳转")
		assert_true(str(it["text"]).contains("成对"), "文字要说清是「必须成对」这条：%s" % str(it["text"]))


func test_mirror_pairs_flag_mega_outside_the_axis() -> void:
	# cols = 8 时 x=9 的格镜像到 -2，镜像轴对它无定义 ⇒ 也要报（不许静默放过）。
	var m := _mega_of([[Vector2i(9, 0)]])
	var issues := MM.mirror_pair_issues(m, 8)
	assert_eq(issues.size(), 1, "越出镜像轴的复合格必须报出来（实际：%s）" % str(issues))
	if issues.size() == 1:
		assert_true(str(issues[0]["text"]).contains("无定义"), "文字要说清是「轴无定义」：%s" % str(issues[0]["text"]))


func test_mirror_pairs_are_silent_on_empty_input() -> void:
	assert_eq(MM.mirror_pair_issues(MegaCell.new(), 9).size(), 0, "没有复合格 ⇒ 不产条目")
	assert_eq(MM.mirror_pair_issues(null, 9).size(), 0, "null ⇒ 不产条目")
	var m := _mega_of([[Vector2i(0, 0)]])
	assert_eq(MM.mirror_pair_issues(m, 0).size(), 0, "cols <= 0 ⇒ 不猜（不产条目）")
	assert_eq(MM.mirror_pair_issues(m, -3).size(), 0, "cols < 0 ⇒ 不产条目")


# ==================== F. 验证器消费（用户可见的那一层） ====================

func test_verify_reports_nothing_without_mega_cells() -> void:
	var d := EditorDoc.new(9, 9)
	d.clue_rule_id = "sc"          # 即便勾了「在复合格上不生效」的变体，没有复合格就不该被念
	assert_eq(ER.mega_variant_issues(d).size(), 0, "盘上无复合格 ⇒ 零条目（不产噪音）")


func test_verify_flags_unsupported_variant_with_mega_cells() -> void:
	var d := _doc_with_mega(_mega_of([[Vector2i(0, 0), Vector2i(1, 0)]]))
	d.clue_rule_id = "sc"
	var issues := ER.mega_variant_issues(d)
	assert_eq(issues.size(), 1, "sc × 复合格 应恰产 1 条（实际：%s）" % str(issues))
	if issues.size() == 1:
		var it: Dictionary = issues[0]
		assert_eq(str(it["code"]), "mega_variant_disabled", "code 应带矩阵前缀，便于幂等剔除")
		assert_eq(str(it["level"]), EditorDoc.ISSUE_ERROR, "未定义组合必须给 error（会阻止导出）")
		assert_true(str(it["text"]).contains("复合格"), "文字要点出复合格：%s" % str(it["text"]))


func test_verify_flags_unpaired_mega_only_when_mirror_active() -> void:
	var m := _mega_of([[Vector2i(0, 0), Vector2i(1, 0)]])
	var d := _doc_with_mega(m)
	d.clue_rule_id = "classic"
	assert_eq(_mirror_entries(ER.mega_variant_issues(d)).size(), 0,
			"没勾镜像就不该念「成对」这条")
	d.global_rule_ids = ["mx"]
	var mirror := _mirror_entries(ER.mega_variant_issues(d))
	assert_eq(mirror.size(), 1, "勾了镜像 + 复合格不成对 ⇒ 应恰报 1 条（实际：%s）" % str(mirror))
	if mirror.size() == 1:
		assert_eq(str(mirror[0]["level"]), EditorDoc.ISSUE_WARN, "这条是「怎么修」的提示级")
		assert_ne(mirror[0]["pos"], Vector2i(-1, -1), "必须带可跳转的位置")


## 取出条目里「镜像成对」那一类（code = mega_mirror_unpaired）。
func _mirror_entries(issues: Array) -> Array:
	var out: Array = []
	for it: Variant in issues:
		if str((it as Dictionary).get("code", "")) == "mega_mirror_unpaired":
			out.append(it)
	return out


func test_verify_merges_mega_issues_exactly_once() -> void:
	# 单岛路径内部会调一次 verify()（已挂过矩阵条目），外层 verify_islands() 再挂一次
	# ⇒ 不去重就会同一问题出现两遍。这条把幂等钉死。
	var d := _doc_with_mega(_mega_of([[Vector2i(0, 0), Vector2i(1, 0)]]))
	d.clue_rule_id = "sc"
	var r := ER.verify_islands(d)
	var vg: Array = r.get("mega_variant_issues", [])
	assert_eq(vg.size(), 1, "单独键里应恰 1 条")
	var n := 0
	for it: Variant in (r["issues"] as Array):
		if str((it as Dictionary).get("code", "")).begins_with("mega_variant_"):
			n += 1
	assert_eq(n, 1, "合并进 issues 的矩阵条目必须恰 1 条（重复 = 幂等坏了）：%s" % str(r["issues"]))
