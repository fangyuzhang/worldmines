extends GutTest

## 关卡格式内核（`core/level_format.gd`）单测。钉住的不变量（坏一条，玩家侧就会"盘加载不了"
## 或"编辑器一坏整关报废"）：
##   1) 两层字段**互不重叠**，且结果层不含任何设计字段；
##   2) **设计层损坏仍能只读结果层开局**（故障隔离在编辑侧）；
##   3) v1 / v2 迁移到当前版本且**旧字段不丢**；
##   4) 高于支持版本的格式**拒载 + 可读原因**；
##   5) `derive_id` **与字典插入顺序无关**（同输入同输出）；
##   6) 1/65536 量化往返误差 ≤ 1/65536；
##   7) 结果层格子"是否需要显式身份"判定正确（E④）；
##   8) 体积护栏在超 5000 格时 block 并给可读原因。


func _doc() -> Dictionary:
	return {
		"version": LevelFormat.CURRENT_VERSION,
		"name": "我的环绕变体",
		"size": {"rows": 8, "cols": 8},
		"total_mines": 2,
		"mines": [{"r": 0, "c": 0}, {"r": 2, "c": 3}],
		"revealed": [{"r": 1, "c": 1}],
		"clue_rule": "spec_x",
		"rule_level": true,
		"rule_spec": {"id": "spec_x", "params": {"k": 1}},
		"topology": {"positions": [{"x": 0, "y": 0}], "style": "custom"},
		"cells": [
			{"r": 0, "c": 0, "mine": true, "prototype_id": "hex6",
				"transform": {"tx": 0.5, "ty": 0.25, "rot": 60, "flip": 0}},
			{"r": 2, "c": 3, "mine": true, "manual_identity": "hand-1"},
			{"r": 1, "c": 1},
		],
		"prototypes": {
			"hex6": {"vertices": [{"x": 0.5, "y": 0.0}, {"x": 1.0, "y": 0.8660254}]},
		},
		# —— 设计层字段 ——
		"shape_kind": "hex",
		"shape_params": {"size": 4},
		"generation": {"seed": 12345, "params": {"difficulty": 2}},
		"notes": "手改过一格",
		"custom_thing": {"keep": true},
	}


# ==================== ① 两层拆分：字段不重叠 ====================

func test_result_and_design_keys_are_disjoint() -> void:
	var doc := _doc()
	var result := LevelFormat.to_result_layer(doc)
	var design := LevelFormat.to_design_layer(doc)
	for k in result.keys():
		assert_false(design.has(k), "结果层字段不得出现在设计层：%s" % str(k))
	for k in design.keys():
		assert_false(result.has(k), "设计层字段不得出现在结果层：%s" % str(k))


func test_result_layer_carries_no_design_fields() -> void:
	var result := LevelFormat.to_result_layer(_doc())
	for k in LevelFormat.DESIGN_KEYS:
		assert_false(result.has(k), "结果层不得含设计字段：%s" % str(k))
	# 游戏必需项必须都在
	for k in ["version", "size", "total_mines", "cells", "revealed", "rule", "topology", "prototypes"]:
		assert_true(result.has(k), "结果层缺游戏必需项：%s" % str(k))
	assert_eq(int(result["total_mines"]), 2, "雷数要带进结果层")
	assert_eq(str((result["rule"] as Dictionary)["id"]), "spec_x", "规则 id 要带进结果层")
	assert_true(bool((result["rule"] as Dictionary)["level"]), "rule_level 要带进结果层")
	assert_eq((result["rule"] as Dictionary).get("spec", {}).get("params", {}).get("k", 0), 1,
		"规则 spec 要随结果层走（游戏算线索要用）")
	# 设计字段确实被分到设计层
	var design := LevelFormat.to_design_layer(_doc())
	assert_eq(str(design.get("shape_kind", "")), "hex", "形状族应在设计层")
	assert_eq(int((design.get("shape_params", {}) as Dictionary).get("size", 0)), 4, "形状参数应在设计层")
	assert_eq(int((design.get("generation", {}) as Dictionary).get("seed", 0)), 12345, "生成种子应在设计层")
	assert_eq(str(design.get("name", "")), "我的环绕变体", "名称应在设计层")
	# 未识别字段不丢（进设计层）
	assert_true(design.has("custom_thing"), "未识别字段必须原样保留（不许静默丢数据）")


func test_prototypes_are_quantized_in_result() -> void:
	var result := LevelFormat.to_result_layer(_doc())
	var proto := (result["prototypes"] as Dictionary)["hex6"] as Dictionary
	var v0: Array = (proto["vertices"] as Array)[0]
	assert_eq(int(v0[0]), LevelFormat.quantize(0.5), "顶点坐标要按 1/65536 量化")
	assert_eq(int(v0[1]), LevelFormat.quantize(0.0), "顶点坐标要按 1/65536 量化")
	var cell0 := (result["cells"] as Array)[0] as Dictionary
	var tr: Dictionary = cell0["transform"]
	assert_eq(int(tr["tx"]), LevelFormat.quantize(0.5), "变换平移也要量化")


# ==================== ② 设计层损坏仍能开局 ====================

func test_corrupt_or_missing_design_still_loads_result() -> void:
	var result := LevelFormat.to_result_layer(_doc())
	# 设计层是垃圾字符串 / 完全缺失：两种都必须能开局
	var broken := {"version": LevelFormat.CURRENT_VERSION, "result": result, "design": "这不是字典"}
	var loaded := LevelFormat.load_result(broken)
	assert_true(bool(loaded["ok"]), "设计层损坏也必须能只读结果层开局：%s" % str(loaded["reason"]))
	assert_eq((loaded["level"] as Dictionary)["mines"].size(), 2, "开局要能拿到 2 颗雷")
	var missing := {"version": LevelFormat.CURRENT_VERSION, "result": result}
	assert_true(bool(LevelFormat.load_result(missing)["ok"]), "设计层缺失也必须能开局")


func test_load_result_rejects_broken_result_layer() -> void:
	# 反向守卫：结果层自身坏了必须明说，不能假装能开局。
	var bad := LevelFormat.load_result({"size": {"rows": 0, "cols": 0}, "cells": []})
	assert_false(bool(bad["ok"]), "结果层尺寸非法应 ok=false")
	assert_true(str(bad["reason"]).find("非法") != -1, "要给可读原因：%s" % str(bad["reason"]))


# ==================== ③ v1 / v2 迁移，旧字段不丢 ====================

func test_migrate_v1_keeps_old_fields_and_adds_new() -> void:
	var v1 := {"schema": 1, "name": "老关", "rows": 5, "cols": 5,
		"mines": [{"r": 1, "c": 1}], "legacy_tag": "x"}
	var m := LevelFormat.migrate(v1)
	assert_true(bool(m["ok"]), "v1 应能迁移：%s" % str(m["reason"]))
	assert_eq(int(m["version"]), LevelFormat.CURRENT_VERSION, "迁到当前版本")
	var doc: Dictionary = m["doc"]
	# 旧字段一个都不能丢
	assert_eq(str(doc.get("name", "")), "老关", "旧 name 不许丢")
	assert_eq(int(doc.get("rows", 0)), 5, "旧 rows 不许丢")
	assert_eq(int(doc.get("cols", 0)), 5, "旧 cols 不许丢")
	assert_eq(int(doc.get("schema", 0)), 1, "旧 schema 不许被改写")
	assert_eq(str(doc.get("legacy_tag", "")), "x", "未识别旧字段不许丢")
	assert_eq((doc.get("mines", []) as Array).size(), 1, "旧 mines 不许丢")
	# 新字段补齐
	assert_eq(int((doc.get("size", {}) as Dictionary).get("rows", 0)), 5, "应补出 size")
	assert_eq(int(doc.get("total_mines", 0)), 1, "应补出 total_mines")
	assert_true(doc.get("revealed", null) is Array, "应补出 revealed")
	assert_true(doc.get("cells", null) is Array, "v3 应补出 cells")
	# 迁移后能直接拆出结果层开局
	assert_true(bool(LevelFormat.load_result(LevelFormat.to_result_layer(doc))["ok"]))


func test_migrate_v2_keeps_old_fields_and_adds_new() -> void:
	var v2 := {"schema": 2, "size": {"rows": 6, "cols": 6}, "total_mines": 1,
		"mines": [{"r": 0, "c": 0}], "revealed": [{"r": 1, "c": 1}],
		"shape_kind": "hex", "old_extra": 7}
	var m := LevelFormat.migrate(v2)
	assert_true(bool(m["ok"]), "v2 应能迁移：%s" % str(m["reason"]))
	var doc: Dictionary = m["doc"]
	assert_eq(str(doc.get("shape_kind", "")), "hex", "设计字段 shape_kind 不许丢")
	assert_eq(int(doc.get("old_extra", 0)), 7, "未识别旧字段不许丢")
	assert_eq(int((doc.get("size", {}) as Dictionary).get("rows", 0)), 6, "旧 size 原样保留")
	assert_true(doc.get("cells", null) is Array, "v3 应补出 cells")
	assert_true(doc.get("rule", null) is Dictionary, "v3 应补出 rule")


# ==================== ④ 更高版本拒载 ====================

func test_migrate_rejects_unknown_higher_version() -> void:
	var fut := {"version": LevelFormat.CURRENT_VERSION + 96, "size": {"rows": 3, "cols": 3}, "mines": []}
	var m := LevelFormat.migrate(fut)
	assert_false(bool(m["ok"]), "更高版本必须拒载（不许猜语义）")
	assert_true(str(m["reason"]).find("%d" % int(fut["version"])) != -1,
		"原因里要写清拒绝的版本号：%s" % str(m["reason"]))
	assert_true(str(m["reason"]).find("拒绝") != -1, "原因要是人话：%s" % str(m["reason"]))


# ==================== ⑤ derive_id 与字典顺序无关 ====================

func test_derive_id_is_order_independent_and_stable() -> void:
	var a := {"r": 3, "c": 7}
	var b := {"c": 7, "r": 3}          # 插入顺序不同，语义相同
	assert_eq(LevelFormat.derive_id(42, a), LevelFormat.derive_id(42, b),
		"同一坐标、不同插入顺序必须得到相同 id")
	assert_eq(LevelFormat.derive_id(42, Vector2i(7, 3)), LevelFormat.derive_id(42, a),
		"Vector2i(c,r) 与 {r,c} 必须一致")
	assert_eq(LevelFormat.derive_id(42, a), LevelFormat.derive_id(42, a), "同输入必须可重复")
	# 不同种子 / 不同坐标必须区分
	assert_ne(LevelFormat.derive_id(42, a), LevelFormat.derive_id(43, a), "种子不同 id 应不同")
	assert_ne(LevelFormat.derive_id(42, a), LevelFormat.derive_id(42, {"r": 4, "c": 7}), "坐标不同 id 应不同")


# ==================== ⑥ 1/65536 量化往返 ====================

func test_quantization_round_trip_within_tolerance() -> void:
	var tol := 1.0 / float(LevelFormat.QUANT)
	for v in [0.0, 1.0, -1.0, 0.1, -3.7, 1.2345678, -0.99999, 1234.567]:
		var back := LevelFormat.dequantize(LevelFormat.quantize(v))
		assert_almost_eq(back, v, tol, "1/65536 量化往返误差须 ≤ 1/65536：%s" % str(v))


# ==================== ⑦ E④：显式身份判定 ====================

func test_only_hand_edited_cells_need_explicit_identity() -> void:
	# 生成的格子（可派生）不需要显式身份
	assert_false(LevelFormat.needs_explicit_identity({"r": 0, "c": 0, "prototype_id": "hex6"}),
		"生成的格子不该需要显式身份")
	# 手工改过 / 已带身份 / 声明来源为 manual：需要
	assert_true(LevelFormat.needs_explicit_identity({"r": 0, "c": 0, "manual_identity": "hand-1"}))
	assert_true(LevelFormat.needs_explicit_identity({"r": 0, "c": 0, "identity_source": "manual"}))
	assert_true(LevelFormat.needs_explicit_identity({"r": 0, "c": 0, "edited": true}))
	var cells := [
		{"r": 0, "c": 0, "prototype_id": "hex6"},
		{"r": 2, "c": 3, "manual_identity": "hand-1"},
		{"r": 1, "c": 1, "edited": true},
	]
	var mapping := LevelFormat.manual_identities(cells)
	assert_eq(mapping.size(), 2, "只有被手工改过的 2 格需要显式身份：%s" % str(mapping))
	assert_eq(str(mapping.get("2,3", "")), "hand-1", "显式身份要原样保留")
	# identity_of：显式优先，否则派生
	assert_eq(LevelFormat.identity_of({"r": 2, "c": 3, "manual_identity": "hand-1"}, 9), "hand-1")
	assert_eq(LevelFormat.identity_of({"r": 2, "c": 3}, 9), LevelFormat.derive_id(9, {"r": 2, "c": 3}),
		"无显式身份时应从种子 + 坐标派生")


# ==================== ⑧ 体积护栏 ====================

func test_budget_blocks_over_max_cells_with_reason() -> void:
	# 用显式 cells 撑过上限：5001 > 5000 ⇒ block
	var cells: Array = []
	for i in 5001:
		cells.append({"r": i, "c": 0})
	var over := LevelFormat.check_write_budget({"size": {"rows": 1, "cols": 5001}, "cells": cells})
	assert_false(bool(over["ok"]), "超 5000 格必须拒绝")
	assert_eq(str(over["level"]), "block")
	assert_eq(int(over["cells"]), 5001, "要报出真实格数")
	assert_true(str(over["reason"]).find("5000") != -1, "原因要写清上限：%s" % str(over["reason"]))
	# 恰好等于上限 ⇒ 放行（门槛是 >）
	var ok := LevelFormat.check_write_budget({"size": {"rows": 70, "cols": 70}, "cells": []})
	assert_true(bool(ok["ok"]), "4900 格应放行")
	assert_eq(str(ok["level"]), "ok")
	# 按 size 估算也有硬上限（空 cells 时走 rows×cols）
	var big := LevelFormat.check_write_budget({"size": {"rows": 80, "cols": 80}, "cells": []})
	assert_false(bool(big["ok"]), "80×80=6400 格必须拒绝")
	assert_eq(int(big["cells"]), 6400, "按 size 估出的格数要对")
