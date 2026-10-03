extends GutTest

## 数据缩略图（`core/level_thumbnail.gd`）单测。钉住的不变量：
##   ① `to_dict` → `from_dict` 往返**逐位一致**（含 JSON 序列化）；
##   ② `max_side` 上限生效 + 超限**裁剪标记** `cropped`；
##   ③ 同输入 hash 相同、内容不同 hash 不同；
##   ④ 空 / 异常输入 ⇒ 可读错误、不崩；
##   ⑤ 网格值确为**合法调色板索引**，且 empty 恒排首位。

const Thumb := preload("res://core/level_thumbnail.gd")


func _layer() -> Dictionary:
	return {
		"version": 3,
		"size": {"rows": 5, "cols": 5},
		"total_mines": 2,
		"cells": [
			{"r": 0, "c": 0, "mine": true},
			{"r": 0, "c": 1},
			{"r": 1, "c": 0},
			{"r": 2, "c": 2},
			{"r": 4, "c": 4, "mine": true},
		],
	}


# ==================== ① 往返逐位一致 ====================

func test_round_trip_is_bit_identical() -> void:
	var t := Thumb.build(_layer(), 8)
	assert_true(bool(t["ok"]), "应生成成功：%s" % str(t.get("reason", "")))
	var d := Thumb.to_dict(t)
	assert_eq(d, t, "to_dict 应产出与 build 相同的规范字典")
	var back := Thumb.from_dict(d)
	assert_true(bool(back["ok"]), "from_dict 应成功：%s" % str(back.get("reason", "")))
	assert_eq(back, t, "往返必须逐位一致")
	assert_eq(JSON.stringify(back), JSON.stringify(t), "序列化后也必须逐字节一致")


# ==================== ② 尺寸上限 + 裁剪标记 ====================

func test_max_side_caps_and_reports_crop() -> void:
	var big := {"size": {"rows": 10, "cols": 12}, "cells": [{"r": 0, "c": 0}]}
	var t := Thumb.build(big, 4)
	assert_true(bool(t["ok"]), "应生成成功：%s" % str(t.get("reason", "")))
	assert_eq(int(t["rows"]), 4, "行应被裁到上限")
	assert_eq(int(t["cols"]), 4, "列应被裁到上限")
	assert_true(bool(t["cropped"]), "源盘超上限应标记 cropped")
	assert_eq(int(t["src_rows"]), 10, "原始行数应如实记录")
	assert_eq(int(t["src_cols"]), 12, "原始列数应如实记录")
	assert_eq((t["grid"] as Array).size(), 16, "网格长度应为裁剪后 rows×cols")
	# 未超上限 ⇒ 不裁剪、尺寸原样
	var small := Thumb.build({"size": {"rows": 3, "cols": 2}, "cells": []}, 8)
	assert_false(bool(small["cropped"]), "未超上限不应裁剪")
	assert_eq(int(small["rows"]), 3, "未超上限行数原样")
	assert_eq(int(small["cols"]), 2, "未超上限列数原样")


# ==================== ③ 内容哈希稳定且对内容敏感 ====================

func test_hash_is_stable_and_content_sensitive() -> void:
	var a := Thumb.build(_layer(), 8)
	var b := Thumb.build(_layer(), 8)
	assert_eq(str(a["hash"]), str(b["hash"]), "同输入必须同 hash")
	assert_eq(Thumb.content_hash(a), str(a["hash"]), "content_hash 应与 build 写入的一致")
	assert_true(str(a["hash"]).length() > 0, "成功缩略图应有非空 hash")
	var changed := _layer()
	(changed["cells"] as Array).append({"r": 3, "c": 3, "mine": true})
	changed["total_mines"] = 3
	var c := Thumb.build(changed, 8)
	assert_ne(str(a["hash"]), str(c["hash"]), "内容不同 hash 必须不同")
	assert_eq(Thumb.content_hash({}), "", "非字典输入 hash 应为空串")


# ==================== ④ 空 / 异常输入：可读错误、不崩 ====================

func test_invalid_input_returns_readable_error() -> void:
	for bad in [{}, {"size": {"rows": 0, "cols": 3}}, null, 42, "x"]:
		var t := Thumb.build(bad, 8)
		assert_false(bool(t["ok"]), "非法输入 %s 应 ok=false" % str(bad))
		assert_true(str(t.get("reason", "")).length() > 0, "非法输入要给可读理由")
	assert_false(bool(Thumb.build(_layer(), 0)["ok"]), "max_side=0 应拒绝")
	assert_true(str(Thumb.build(_layer(), 0).get("reason", "")).length() > 0, "上限非法要给可读理由")
	var e := Thumb.from_dict({"rows": 1})
	assert_false(bool(e["ok"]), "缺字段的缩略图应拒绝")
	assert_true(str(e.get("reason", "")).length() > 0, "缺字段要给可读理由")
	assert_false(bool(Thumb.from_dict(null)["ok"]), "null 反序列化应拒绝")
	assert_eq(Thumb.content_hash({"ok": false}), "", "错误缩略图 hash 应为空串")


# ==================== ⑤ 网格值 = 合法调色板索引，empty 恒首位 ====================

func test_grid_uses_valid_palette_indices() -> void:
	var t := Thumb.build(_layer(), 8)
	var pal: Array = t["palette"]
	var grid: Array = t["grid"]
	assert_true(pal.has("empty"), "调色板应含 empty：%s" % str(pal))
	assert_true(pal.has("mine"), "调色板应含 mine：%s" % str(pal))
	var has_clue := false
	for code in pal:
		if str(code).begins_with("clue:"):
			has_clue = true
	assert_true(has_clue, "调色板应含线索编号码：%s" % str(pal))
	for v in grid:
		assert_true(int(v) >= 0 and int(v) < pal.size(), "网格值必须是合法调色板索引：%d" % int(v))
	assert_eq(str(pal[0]), "empty", "empty 应恒排调色板首位（索引 0）")
	# 雷格必落在 mine 码上
	var mine_idx := pal.find("mine")
	assert_true(mine_idx >= 0, "应有 mine 码")
	# (0,0) 是雷 ⇒ 索引 + 0 应为 mine 码
	assert_eq(str(pal[int(grid[0])]), "mine", "(0,0) 是雷，其码应为 mine")
