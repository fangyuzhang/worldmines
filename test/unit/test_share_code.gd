extends GutTest

## 分享短码（`core/share_code.gd`）单测。
##
## 钉死四件事（文档「八、分享分级」）：
##   ① 短码要能**离线往返**（雷位 / 尺寸 / 规则），② 同一关卡**两次编码同一短码**（确定性），
##   ③ 篡改一字符 / 非法字符 / 空串都**不能崩**且给可读原因，④ 含自定义形状 ⇒ classify 判 `file`。
## 这些是"粘贴即玩"的信任基础：任何一条松了，玩家就会拿到一张打不开或对不上的盘。


## 规范的"小关卡"（= decode 的产出形状：mines/revealed 已按 r,c 升序）。
func _lv() -> Dictionary:
	return {
		"size": {"rows": 9, "cols": 9},
		"total_mines": 3,
		"mines": [{"r": 0, "c": 0}, {"r": 4, "c": 4}, {"r": 8, "c": 8}],
		"revealed": [{"r": 1, "c": 1}, {"r": 2, "c": 3}],
		"rule": {"id": "o5_triangle", "level": true},
	}


func test_round_trip_preserves_size_mines_revealed_rule() -> void:
	var lv := _lv()
	var enc := ShareCode.encode(lv)
	assert_true(bool(enc["ok"]), "小关卡应能编码：%s" % str(enc["reason"]))
	var dec := ShareCode.decode(str(enc["code"]))
	assert_true(bool(dec["ok"]), "自己编的码应能解回来：%s" % str(dec["reason"]))
	assert_eq(dec["level"], lv, "decode(encode(x)) 必须等于 x（尺寸/雷位/已翻/规则全保留）")


func test_rule_spec_round_trips_with_integers_intact() -> void:
	var lv := {
		"size": {"rows": 5, "cols": 5},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [],
		"rule": {"id": "custom_x", "level": true, "spec": {"mode": "radius", "radius": 3}},
	}
	var enc := ShareCode.encode(lv)
	assert_true(bool(enc["ok"]), "含 spec 的规则应能编码：%s" % str(enc["reason"]))
	var dec := ShareCode.decode(str(enc["code"]))
	assert_true(bool(dec["ok"]), "含 spec 的码应能解回来：%s" % str(dec["reason"]))
	assert_eq(dec["level"], lv, "spec 里的整数经 JSON 规范化后仍应是整数，整体等于原关卡")


func test_encode_is_deterministic_and_order_independent() -> void:
	var lv := _lv()
	var a := str(ShareCode.encode(lv)["code"])
	var b := str(ShareCode.encode(lv)["code"])
	assert_true(a != "", "编码应成功")
	assert_eq(a, b, "同一关卡两次编码必须得到同一短码（不许掺时间/随机）")
	var shuffled := lv.duplicate(true)
	shuffled["mines"] = [{"r": 8, "c": 8}, {"r": 0, "c": 0}, {"r": 4, "c": 4}]
	shuffled["revealed"] = [{"r": 2, "c": 3}, {"r": 1, "c": 1}]
	assert_eq(a, str(ShareCode.encode(shuffled)["code"]), "雷位/已翻的书写顺序不得影响短码")


func test_tampered_char_fails_checksum_with_readable_reason() -> void:
	var code := str(ShareCode.encode(_lv())["code"])
	var first := code[0]
	var repl := "A" if first != "A" else "B"
	var tampered := repl + code.substr(1)
	assert_ne(tampered, code, "前置：确实改了一字符")
	var dec := ShareCode.decode(tampered)
	assert_false(bool(dec["ok"]), "改一字符必须解不出来")
	assert_true(str(dec["reason"]).find("校验失败") != -1, "原因要说明校验失败：%s" % str(dec["reason"]))


func test_illegal_char_and_empty_string_give_reasons_without_crash() -> void:
	var d1 := ShareCode.decode("")
	assert_false(bool(d1["ok"]), "空串应被拒绝")
	assert_true(str(d1["reason"]).find("空") != -1, "空串要有可读原因：%s" % str(d1["reason"]))
	var d2 := ShareCode.decode("ABC$DEF")
	assert_false(bool(d2["ok"]), "非法字符应被拒绝")
	assert_true(str(d2["reason"]).find("非法字符") != -1, "要指明非法字符：%s" % str(d2["reason"]))
	var d3 := ShareCode.decode("ABC DE")
	assert_false(bool(d3["ok"]), "空格也是非法字符（不许静默忽略）")


func test_oversize_level_is_rejected_and_suggests_file() -> void:
	# 40×40=1600 格的矩形盘，光两个位图就 400B > 384B 上限 ⇒ 必须拒绝并建议文件。
	var lv := {"size": {"rows": 40, "cols": 40}, "total_mines": 0, "mines": [], "revealed": []}
	var enc := ShareCode.encode(lv)
	assert_false(bool(enc["ok"]), "超容量必须拒绝")
	assert_eq(str(enc["code"]), "", "拒绝时不产出短码")
	assert_true(str(enc["reason"]).find("文件") != -1, "要建议改走文件形式：%s" % str(enc["reason"]))
	assert_true(str(ShareCode.classify(lv)["kind"]) == ShareCode.KIND_FILE, "classify 也应把它判成 file")


func test_classify_custom_shapes_goes_to_file_with_reason() -> void:
	var lv := {
		"size": {"rows": 8, "cols": 8},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"revealed": [],
		"custom_shapes": {"unit": 2.0, "cells": [{"x": 0, "y": 0, "poly": [[0.0, 0.0]]}]},
	}
	var c := ShareCode.classify(lv)
	assert_eq(str(c["kind"]), ShareCode.KIND_FILE, "含自定义形状必须走文件形式")
	assert_true(str(c["reason"]) != "", "file 判定必须给出非空依据：%s" % str(c["reason"]))


func test_classify_parametric_shape_and_plain_rect() -> void:
	var shaped := {"size": {"rows": 8, "cols": 8}, "total_mines": 1,
		"mines": [{"r": 0, "c": 0}], "revealed": [], "shape_kind": "hex", "shape_params": {"size": 4}}
	assert_eq(str(ShareCode.classify(shaped)["kind"]), ShareCode.KIND_FILE,
		"参数化形状（设计层 shape_kind/shape_params）也应走文件")
	var plain := {"size": {"rows": 8, "cols": 8}, "total_mines": 1,
		"mines": [{"r": 0, "c": 0}], "revealed": []}
	var cp := ShareCode.classify(plain)
	assert_eq(str(cp["kind"]), ShareCode.KIND_CODE, "纯矩形小盘走短码")
	assert_eq(str(cp["reason"]), "", "code 判定不需要理由")


func test_unknown_version_is_rejected_not_crashed() -> void:
	# 校验通过、但版本号高于本程序 ⇒ 必须给「版本不支持」，绝不硬猜。
	var payload := PackedByteArray([99, 0, 1, 1, 0])  # version=99, flags=0, rows=1, cols=1, mines=0
	var full := payload.duplicate()
	var cs := ShareCode._fnv1a_bytes(payload)
	full.append((cs >> 24) & 0xFF)
	full.append((cs >> 16) & 0xFF)
	full.append((cs >> 8) & 0xFF)
	full.append(cs & 0xFF)
	var dec := ShareCode.decode(ShareCode._b64url_encode(full))
	assert_false(bool(dec["ok"]), "未知版本应被拒绝")
	assert_true(str(dec["reason"]).find("版本不支持") != -1, "要说明版本不支持：%s" % str(dec["reason"]))


func test_decode_reports_content_over_limit() -> void:
	# 校验通过、但尺寸大到超过硬上限 ⇒ 必须报「内容超限」而不是照单全收。
	var payload := PackedByteArray([ShareCode.CURRENT_VERSION, 0, 99, 99, 0])  # 99×99 格
	var full := payload.duplicate()
	var cs := ShareCode._fnv1a_bytes(payload)
	full.append((cs >> 24) & 0xFF)
	full.append((cs >> 16) & 0xFF)
	full.append((cs >> 8) & 0xFF)
	full.append(cs & 0xFF)
	var dec := ShareCode.decode(ShareCode._b64url_encode(full))
	assert_false(bool(dec["ok"]), "超内容上限应被拒绝")
	assert_true(str(dec["reason"]).find("内容超限") != -1, "要说明内容超限：%s" % str(dec["reason"]))
