# test_template_library.gd —— 模板库（core/template_library.gd）自证。
#
# 钉住的不变量：
#   1) 文档点名的三个官方模板（甜甜圈/双岛/护城河）都在，且 doc_build 的字段名与
#      `EditorDoc` 真实字段逐字一致（断言字段存在，不靠猜）；
#   2) 简单模式隐藏 DAG / 精度 / 复合格（文档十.6），专家模式可见；
#   3) 未知模板 id 有兜底（ok=false + 人话原因，不崩）；
#   4) 每条模板的 doc_build 都能被 `EditorDoc` 接受（只读构造 + 往返，**不写盘**）。
#
# 引用纪律：template_library.gd **刻意不写 class_name**（坑表 #26：headless 新全局类不在缓存里），
# 因此这里走 preload；EditorDoc 是既有全局类，可直接按类名引用。
extends GutTest

const TL := preload("res://core/template_library.gd")

## 文档点名的三个官方模板 → 本仓真实形状族（以 core/shape_generator.gd 为准）。
const NAMED := {
	"official_donut_ring": "ring",
	"official_double_island": "holed_grid",
	"official_moat": "holed_grid",
}


# ==================== 1. 点名模板 + 真实字段 ====================

func test_named_official_templates_exist_with_real_shape_kinds() -> void:
	var ids := TL.ids()
	for id: String in NAMED.keys():
		assert_true(ids.has(id), "文档点名的模板必须在库中：%s" % id)
		var t: Dictionary = TL.find_template(id)
		assert_eq(str(t.get("tier", "")), TL.TIER_OFFICIAL, "%s 应为 official 档" % id)
		assert_ne(str(t.get("name", "")), "", "%s 应有名字" % id)
		assert_ne(str(t.get("desc", "")), "", "%s 应有说明" % id)
		var b: Dictionary = t["doc_build"]
		assert_eq(str(b.get("shape_kind", "")), str(NAMED[id]),
				"%s 的形状族应与代码实际支持的一致：%s" % [id, str(NAMED[id])])
		assert_true(b.has("shape_params") and b["shape_params"] is Dictionary,
				"%s 的 shape_params 应为字典" % id)


func test_doc_build_keys_are_real_editor_doc_fields() -> void:
	var probe := EditorDoc.new()
	for t: Dictionary in TL.all_templates():
		var id := str(t["id"])
		var b: Dictionary = t["doc_build"]
		assert_true(b.has("rows") and b.has("cols"), "%s 的 doc_build 必须带 rows/cols" % id)
		for k: String in b.keys():
			# `Object.get()` 对不存在的属性返回 null ⇒ 这就是「字段真实存在」的机器判据。
			assert_not_null(probe.get(k),
					"模板 %s 的 doc_build 字段「%s」在 EditorDoc 上不存在（字段名必须逐字一致）" % [id, k])


func test_template_ids_are_unique_and_tiers_valid() -> void:
	var seen := {}
	for t: Dictionary in TL.all_templates():
		var id := str(t["id"])
		assert_false(seen.has(id), "模板 id 不得重复：%s" % id)
		seen[id] = true
		assert_true(TL.TIER_ORDER.has(str(t["tier"])), "%s 的 tier 非法：%s" % [id, str(t["tier"])])
	assert_gt(seen.size(), 0, "模板库不应为空")
	# 至少各有一个新手教程 / 官方示例（文档要求模板库作为主要入门路径）。
	assert_gt(TL.templates_of_tier(TL.TIER_TUTORIAL).size(), 0, "应有新手教程级模板")
	assert_gt(TL.templates_of_tier(TL.TIER_OFFICIAL).size(), 0, "应有官方示例模板")


# ==================== 2. 简单 / 专家概念可见性 ====================

func test_simple_mode_hides_advanced_concepts() -> void:
	var c := TL.concepts_for(TL.MODE_SIMPLE)
	assert_eq(str(c["mode"]), TL.MODE_SIMPLE)
	var hidden: Array = c["hidden"]
	var visible: Array = c["visible"]
	for key: String in [TL.CONCEPT_SHAPE_DAG, TL.CONCEPT_RASTER_PRECISION, TL.CONCEPT_MEGA_CELL]:
		assert_true(hidden.has(key), "简单模式必须隐藏进阶概念：%s" % key)
		assert_false(visible.has(key), "简单模式不得同时可见：%s" % key)
	# 隐藏的每个概念都要有「为什么先隐藏」的人话原因。
	var why: Dictionary = c["why_hidden"]
	for key: String in hidden:
		assert_ne(str(why.get(key, "")), "", "隐藏概念应给出原因：%s" % key)
	assert_ne(str(c["reason"]), "", "简单模式应给出总体原因文案")
	assert_true(str(c["reason"]).find("三倍") != -1, "原因应点明「概念量是普通编辑器三倍」这一文档依据")


func test_expert_mode_reveals_advanced_concepts() -> void:
	var c := TL.concepts_for(TL.MODE_EXPERT)
	assert_eq(str(c["mode"]), TL.MODE_EXPERT)
	var visible: Array = c["visible"]
	var hidden: Array = c["hidden"]
	for key: String in [TL.CONCEPT_SHAPE_DAG, TL.CONCEPT_RASTER_PRECISION,
			TL.CONCEPT_MEGA_CELL, TL.CONCEPT_BOOLEAN_OPS, TL.CONCEPT_HOTMAP]:
		assert_true(visible.has(key), "专家模式应暴露进阶概念：%s" % key)
	assert_true(hidden.is_empty(), "专家模式不应隐藏任何概念：%s" % str(hidden))
	# 两档的可见 + 隐藏合起来必须等于全部概念（不重不漏）。
	var c2 := TL.concepts_for(TL.MODE_SIMPLE)
	assert_eq((c2["visible"] as Array).size() + (c2["hidden"] as Array).size(),
			(c["visible"] as Array).size(), "实际概念总数应恒定")


func test_unknown_mode_falls_back_to_simple() -> void:
	var c := TL.concepts_for("nonsense_mode")
	assert_eq(str(c["mode"]), TL.MODE_SIMPLE, "未知模式必须 fail-safe 到简单模式")
	assert_true((c["hidden"] as Array).has(TL.CONCEPT_SHAPE_DAG), "兜底后仍应隐藏 DAG")
	assert_true(str(c["reason"]).find("未知模式") != -1, "兜底原因应注明未知模式")


# ==================== 3. 未知模板 id 兜底 ====================

func test_apply_unknown_id_fails_gracefully() -> void:
	var r := TL.apply("no_such_template")
	assert_false(bool(r["ok"]), "未知 id 应 ok=false")
	assert_true((r["doc_build"] as Dictionary).is_empty(), "未知 id 不应给出 doc_build")
	assert_ne(str(r["reason"]), "", "未知 id 应给可读原因")
	assert_true(str(r["reason"]).find("no_such_template") != -1, "原因应点名未知 id")
	assert_false(TL.has_template("no_such_template"))
	assert_null(TL.build_doc("no_such_template"), "未知 id 造 doc 应返回 null")


# ==================== 4. 所有模板都能被 EditorDoc 接受（不写盘） ====================

func test_all_templates_build_readable_docs() -> void:
	for t: Dictionary in TL.all_templates():
		var id := str(t["id"])
		var b: Dictionary = t["doc_build"]
		var estimate := EditorDoc.estimate_cells(str(b.get("shape_kind", "")),
				b.get("shape_params", {}), int(b["rows"]), int(b["cols"]))
		assert_gt(estimate, 0, "%s 应产出正数个格" % id)

		var doc := TL.build_doc(id)
		assert_not_null(doc, "%s 应能构造 EditorDoc" % id)
		if doc == null:
			continue
		assert_gt(doc.cell_count(), 0, "%s 盘上应有可用格" % id)
		var grid := doc.grid()
		assert_not_null(grid, "%s 应能构造棋盘" % id)
		if doc.shape_kind != "":
			assert_false(doc.topology().is_empty(), "%s（形状盘）应有邻接表" % id)
		assert_eq(doc.estimate_cells_now(), estimate, "%s 的事前估算应与静态口径一致" % id)

		# 雷位 / 初始翻开格必须真的在盘上（形状盘挖洞后最容易静默丢数据）。
		var on_board := {}
		for p in grid.all_positions():
			on_board[p] = true
		for m in doc.mines:
			assert_true(on_board.has(m), "%s 的雷位必须在盘上：%s" % [id, str(m)])
		for p in doc.revealed:
			assert_true(on_board.has(p), "%s 的初始翻开格必须在盘上：%s" % [id, str(p)])
			assert_false(doc.mines.has(p), "%s 的初始翻开格不能是雷：%s" % [id, str(p)])

		# 只读往返（内存里，不写盘）：导出关卡 JSON 再让 EditorDoc 读回。
		var lv := doc.to_level_json()
		var doc2 := EditorDoc.new()
		var rr := doc2.load_from(lv)
		assert_true(bool(rr["ok"]), "%s 导出后应能被 EditorDoc 读回：%s" % [id, str(rr.get("reason", ""))])
		assert_eq(doc2.mines.size(), doc.mines.size(), "%s 往返雷位数应一致" % id)
		assert_eq(doc2.rows, doc.rows, "%s 往返行数应一致" % id)
		assert_eq(doc2.cols, doc.cols, "%s 往返列数应一致" % id)
