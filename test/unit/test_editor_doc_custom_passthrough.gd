# test_editor_doc_custom_passthrough.gd —— `custom` / `size` 两个**部分识别容器**的无损往返
#
# 缺陷（既有，非本套件引入）：`EditorDoc.load_from()` 此前把 `custom` **从 `{}` 重建**，
# 只写回本模型认识的几个键 ⇒ **Mod 自定义字段 / 将来新增的 `custom.*` 键在"打开→另存"一次后
# 静默消失**（`custom` 不在顶层 `passthrough` 里）。这与本仓「格式只增不改不删字段」的纪律冲突。
# `size` 里的未知子键同属一类（同样是"部分识别容器被整块重建"）。
#
# 本套件钉住：
#   ① 含未知 `custom.xyz` 的老 JSON ⇒ `load_from` 后仍能取到、`to_level_json` 后仍在（值逐字相同）；
#   ② 只含已识别键的文档：输出逐键不变（回归），且未知键绝不"顺手多写"；
#   ③ `custom.mega_cells` 与未知键共存、互不覆盖（既有新字段不被 passthrough 挤掉）；
#   ④ 空 / 缺失的 `custom` 不凭空造键；
#   ⑤ `size` 的未知子键（同类缺口）同样原样带回；
#   ⑥ Mod 的 `custom.schema_id` 在编辑器没有 spec 时不被吃掉（它是 `LevelCustomSchema` 的选表键）；
#   ⑦ 外来 `schema_id` 与编辑器 spec 共存时，"保存会覆盖它"必须在 `validate()` 里**可见**（warn）；
#   ⑧ 既有行为冒烟对照（不削弱 `test_editor_doc` 的断言）。
extends GutTest


func _level(custom: Variant = null, size: Variant = null) -> Dictionary:
	var lvl := {
		"name": "关卡",
		"size": size if size is Dictionary else {"rows": 4, "cols": 4},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
	}
	if custom != null:
		lvl["custom"] = custom
	return lvl


# ==================== ① 未知 custom.* 键无损往返 ====================

func test_unknown_custom_keys_round_trip() -> void:
	var xyz := {"a": 1, "b": ["u", 2], "c": {"deep": true}}
	var level := _level({
		"xyz": xyz,
		"mod_layers": [3, 1, 4],
		"mod_note": "来自 Mod",
	})
	var d := EditorDoc.new()
	var r := d.load_from(level)
	assert_true(bool(r["ok"]), "含未知 custom 键的老 JSON 必须能载入：%s" % str(r["reason"]))

	# 载入后就能取到（不用等导出）
	assert_eq(d.custom_passthrough.get("xyz"), xyz, "load_from 后未知 custom 键必须仍在（值逐字相同）")
	assert_eq(d.custom_passthrough.get("mod_layers"), [3, 1, 4], "未知数组子键必须仍在")
	assert_false(d.passthrough.has("custom"), "custom 是已识别字段，不该整块进 passthrough（否则两处真源）")

	# 导出后仍在
	var js := d.to_level_json()
	var cust: Variant = js.get("custom", {})
	assert_true(cust is Dictionary, "导出必须带 custom：%s" % str(js))
	var cd: Dictionary = cust
	assert_eq(cd.get("xyz"), xyz, "to_level_json 后未知键必须仍在（值逐字相同）")
	assert_eq(cd.get("mod_layers"), [3, 1, 4], "to_level_json 后未知数组子键必须仍在")
	assert_eq(cd.get("mod_note"), "来自 Mod", "to_level_json 后未知标量子键必须仍在")

	# 二次往返（打开→另存→打开→另存）逐键一致，不是"越导越少"
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(js)["ok"]), "二次载入应成功")
	var cust2: Variant = d2.to_level_json().get("custom", {})
	assert_eq(cust2, cd, "二次往返 custom 必须逐键一致")


# ==================== ② 只含已识别键：输出逐键不变（回归）====================

func test_recognized_keys_only_output_unchanged() -> void:
	var mc := MegaCell.new()
	assert_true(bool(mc.merge([Vector2i(0, 3), Vector2i(0, 4), Vector2i(1, 4)])["ok"]), "构造前提：复合格合并成功")
	var level := _level({
		"spec": {"id": "my_rule", "title": "我的规则"},
		"warp_points": [{"r": 1, "c": 2}],
		"regions": [{"id": "zone", "cells": [{"r": 2, "c": 2}]}],
		"mega_cells": mc.to_dict(),
	})
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(level)["ok"]), "载入应成功")
	assert_true(d.custom_passthrough.is_empty(),
		"只含已识别键时不应有残留 passthrough：%s" % str(d.custom_passthrough))

	var js := d.to_level_json()
	var cd: Dictionary = js["custom"]
	# 逐键不变：已识别键写回的就是原值（spec/warp_points/regions/mega_cells），额外只有编辑器自己的 schema_id
	assert_eq(cd.get("spec"), level["custom"]["spec"], "spec 原文写回（逐键不变）")
	assert_eq(cd.get("warp_points"), level["custom"]["warp_points"], "warp_points 写回（逐键不变）")
	assert_eq(cd.get("regions"), level["custom"]["regions"], "regions 写回（逐键不变）")
	assert_eq(cd.get("mega_cells"), level["custom"]["mega_cells"], "mega_cells 写回（逐键不变）")
	assert_eq(cd.get("schema_id"), EditorDoc.SCHEMA_ID, "带 spec 时应写 schema_id")
	var keys: Array = cd.keys()
	keys.sort()
	assert_eq(keys, ["mega_cells", "regions", "schema_id", "spec", "warp_points"],
		"已识别键的文档不得凭空多出别的 custom 键：%s" % str(keys))

	# 再往返一次仍逐键一致
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(js)["ok"]), "二次载入应成功")
	assert_eq(d2.to_level_json().get("custom"), cd, "已识别键文档二次往返逐键一致")


# ==================== ③ mega_cells 与未知键共存、互不覆盖 ====================

func test_mega_cells_and_unknown_keys_coexist() -> void:
	var src := EditorDoc.new(5, 5)
	src.mines.append(Vector2i(0, 0))
	assert_true(bool(src.mega_cells.merge([Vector2i(0, 3), Vector2i(0, 4), Vector2i(1, 4)])["ok"]),
		"构造前提：复合格合并成功")
	var level := src.to_level_json()
	var cust_in: Dictionary = (level["custom"] as Dictionary).duplicate(true)
	cust_in["mod_extra"] = {"note": "未知键"}
	cust_in["xyz"] = 7
	level["custom"] = cust_in

	var d := EditorDoc.new()
	assert_true(bool(d.load_from(level)["ok"]), "载入应成功")
	assert_eq(d.mega_cells.count(), 1, "mega_cells 是已识别键 ⇒ 读回复合格")
	assert_eq(d.custom_passthrough.get("mod_extra"), {"note": "未知键"}, "未知键与 mega_cells 共存")
	assert_eq(d.custom_passthrough.get("xyz"), 7, "未知标量键与 mega_cells 共存")
	assert_false(d.custom_passthrough.has("mega_cells"), "已识别键不该重复进 passthrough")

	var cd: Dictionary = d.to_level_json()["custom"]
	assert_eq(cd.get("mega_cells"), cust_in.get("mega_cells"), "mega_cells 内容逐字不变（未被未知键挤掉）")
	assert_eq(cd.get("mod_extra"), {"note": "未知键"}, "未知键仍在（未被 mega_cells 覆盖）")
	assert_eq(cd.get("xyz"), 7, "未知标量键仍在")


# ==================== ④ 空 / 缺失 custom 不凭空造键 ====================

func test_empty_or_absent_custom_does_not_invent_keys() -> void:
	# 空 custom
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(_level({}))["ok"]), "空 custom 应能载入")
	assert_true(d.custom_passthrough.is_empty(), "空 custom ⇒ 不该凭空造出未知键")
	assert_false(d.to_level_json().has("custom"), "空 custom 不该凭空写出 custom 键")

	# 完全没有 custom 键的老 JSON
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(_level())["ok"]), "无 custom 键应能载入")
	assert_false(d2.to_level_json().has("custom"), "老 JSON 无 custom ⇒ 输出也不写 custom（老文档输出不变）")

	# `{}` 值的未知键：保留"空"，不填充内容
	var d3 := EditorDoc.new()
	assert_true(bool(d3.load_from(_level({"mod_empty": {}}))["ok"]), "含空未知键应能载入")
	var cd: Dictionary = d3.to_level_json()["custom"]
	assert_eq(cd.get("mod_empty"), {}, "空值的未知键必须原样带出（仍是空，不被填内容）")


# ==================== ⑤ 同类缺口：size 的未知子键 ====================

func test_size_extra_keys_round_trip() -> void:
	var level := _level(null, {"rows": 4, "cols": 4, "layer": "L2", "depth": 3})
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(level)["ok"]), "带额外 size 子键的老 JSON 应能载入")
	assert_eq(d.rows, 4, "rows 仍按已识别键读")
	assert_eq(d.cols, 4, "cols 仍按已识别键读")
	var sz: Dictionary = d.to_level_json()["size"]
	assert_eq(sz.get("layer"), "L2", "size 的未知子键必须原样带回")
	assert_eq(sz.get("depth"), 3, "size 的未知子键必须原样带回")
	assert_eq(sz.get("rows"), 4, "rows 仍写 4")
	assert_eq(sz.get("cols"), 4, "cols 仍写 4")

	# 只有 rows/cols 的老文档：输出逐键不变
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(_level())["ok"]), "载入应成功")
	assert_eq(d2.to_level_json()["size"], {"rows": 4, "cols": 4}, "无额外子键时 size 输出逐键不变")


# ==================== ⑥ Mod 的 custom.schema_id 不能被吃掉 ====================

func test_foreign_schema_id_preserved_without_editor_spec() -> void:
	# `custom.schema_id` 是 `LevelCustomSchema` 选取 Mod 自定义校验器的键（形如
	# "workshop.2e@1.0/schema.json"）。编辑器**没有 spec** 时既不该覆盖它、更不该丢它——
	# 丢了就是"键还在、指向没了"，配套的 Mod custom 负载会一起变成无人校验的野数据。
	var level := _level({"schema_id": "workshop.2e@1.0/schema.json", "symbols": ["A", "B"]})
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(level)["ok"]), "Mod 关卡应能载入")
	assert_eq(d.custom_passthrough.get("schema_id"), "workshop.2e@1.0/schema.json",
		"没有 spec 时 Mod 的 schema_id 必须留存")
	var cd: Dictionary = d.to_level_json()["custom"]
	assert_eq(cd.get("schema_id"), "workshop.2e@1.0/schema.json", "没有 spec 时 Mod 的 schema_id 必须原样带回")
	assert_eq(cd.get("symbols"), ["A", "B"], "与 schema_id 配套的 Mod 负载也必须原样带回")

	# 编辑器自己带 spec 时仍按文档口径署自己的标记（已识别键语义不变）
	var lvl2 := _level({"schema_id": "workshop.2e@1.0/schema.json"})
	lvl2["custom"]["spec"] = {"id": "r1", "title": "t"}
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(lvl2)["ok"]), "载入应成功")
	assert_eq((d2.to_level_json()["custom"] as Dictionary).get("schema_id"), EditorDoc.SCHEMA_ID,
		"带 spec 时应写编辑器自己的 schema_id（文档口径不变）")


func test_foreign_schema_id_overwrite_is_warned() -> void:
	# 一键一义：外来 schema_id 与编辑器 spec 共存时会被覆盖 ⇒ 必须**可见**（不许只写在注释里）。
	var lvl := _level({"schema_id": "workshop.2e@1.0/schema.json"})
	lvl["custom"]["spec"] = {"id": "r1", "title": "t"}
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(lvl)["ok"]), "载入应成功")
	var rep := d.validate()
	assert_true(_has_code(rep["warnings"], "schema_id_overwrite"),
		"外来 schema_id + 编辑器 spec ⇒ 必须给出 warn：%s" % str(_codes(rep["warnings"])))
	assert_true(_has_code(rep["issues"], "schema_id_overwrite"), "该 warn 也必须出现在三级统一列表 issues 里")

	# 无 spec ⇒ 原样带回、不覆盖 ⇒ 不告警
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(_level({"schema_id": "workshop.2e@1.0/schema.json"}))["ok"]), "载入应成功")
	assert_false(_has_code(d2.validate()["warnings"], "schema_id_overwrite"), "没有 spec 时不该告警（不覆盖）")

	# schema_id 本来就是编辑器自己的标记 ⇒ 不告警（不是覆盖）
	var lvl3 := _level({"schema_id": EditorDoc.SCHEMA_ID})
	lvl3["custom"]["spec"] = {"id": "r1", "title": "t"}
	var d3 := EditorDoc.new()
	assert_true(bool(d3.load_from(lvl3)["ok"]), "载入应成功")
	assert_false(_has_code(d3.validate()["warnings"], "schema_id_overwrite"),
		"已是编辑器自己的 schema_id ⇒ 不算覆盖，不该告警")


func _codes(bucket: Array) -> Array:
	var out := []
	for it in bucket:
		out.append(str((it as Dictionary).get("code", "")))
	return out


func _has_code(bucket: Array, code: String) -> bool:
	return _codes(bucket).has(code)


# ==================== ⑦ 既有行为冒烟对照（不削弱既有断言）====================

func test_existing_behaviors_smoke() -> void:
	# 既有语义①：顶层未知字段原样带回（`passthrough` 那条路没被本次改动影响）
	var lvl := _level({"mod_x": 1})
	lvl["my_future_field"] = {"x": 1}
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(lvl)["ok"]), "载入应成功")
	assert_eq(d.to_level_json().get("my_future_field", {}), {"x": 1}, "顶层未知字段仍然无损往返")

	# 既有语义②：载入关卡会清空会话形状选择（形状不是关卡字段）
	var d2 := EditorDoc.new(5, 5)
	d2.mines.append(Vector2i(1, 1))
	d2.shape_kind = "hex"
	d2.shape_params = {"size": 3}
	assert_true(bool(d2.load_from(d2.to_level_json())["ok"]), "载入应成功")
	assert_eq(d2.shape_kind, "", "载入关卡必须清空会话形状选择（既有语义不变）")
	assert_true(d2.mines.has(Vector2i(1, 1)), "雷位是关卡内容，不被清（既有语义不变）")
