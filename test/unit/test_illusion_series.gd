# test_illusion_series.gd —— 官方错觉 / 异形策展目录契约
extends GutTest

const Series := preload("res://core/illusion_series.gd")


func test_catalog_shape() -> void:
	assert_gte(Series.all().size(), 10, "系列目录至少 10 组（含非错觉造型）")
	var seen := {}
	for s in Series.all():
		var id := str(s.get("id", ""))
		assert_ne(id, "", "系列 id 不得为空")
		assert_false(seen.has(id), "系列 id 重复：%s" % id)
		seen[id] = true
		assert_ne(str(s.get("name", "")), "", "%s 缺名称" % id)
		assert_ne(str(s.get("hook", "")), "", "%s 缺一句话看点" % id)
		assert_ne(str(s.get("text", "")), "", "%s 缺导览正文" % id)
		assert_true((s.get("prefixes", []) as Array).size() > 0, "%s 缺前缀" % id)


func test_series_of_by_prefix() -> void:
	assert_eq(Series.series_of("res://levels/iso_01.json"), "iso", "iso_ 前缀 → 错觉立方体")
	assert_eq(Series.series_of("res://levels/t31212_01.json"), "tri", "t31212_ 前缀 → 三角镶嵌")
	assert_eq(Series.series_of("res://levels/sty_var_3.json"), "sty", "sty_var_ 前缀 → 造型变体")
	assert_eq(Series.series_of("res://levels/unknown_thing.json"), "", "无归属返回空")
	assert_eq(Series.series_of("fold_07"), "fold", "只给文件名也要认出来")


func test_illusion_membership() -> void:
	assert_true(Series.is_illusion("iso_01.json"), "错觉立方体属策展")
	assert_true(Series.is_illusion("fold_01.json"), "折叠属策展")
	assert_false(Series.is_illusion("girih_01.json"), "花纹不属错觉策展")
	assert_eq(Series.illusion_ids().size(), 6, "策展系列应为 6 组")


func test_labels_and_text() -> void:
	assert_ne(Series.label_for("res://levels/iso_01.json"), "", "应给出系列标签")
	assert_eq(Series.label_for("res://levels/none_01.json"), "", "无归属无标签")
	assert_ne(Series.text_for("res://levels/wormhole_01.json"), "", "应给出导览正文")


func test_every_series_has_unique_prefix_owner() -> void:
	# 反向守卫：任何前缀不得同时属于两个系列（否则 series_of 的归属会随遍历顺序抖动）。
	var owner := {}
	for s in Series.all():
		for pre in (s.get("prefixes", []) as Array):
			assert_false(owner.has(str(pre)),
				"前缀 %s 同时属于 %s 与 %s" % [str(pre), str(owner.get(str(pre), "")), str(s.get("id", ""))])
			owner[str(pre)] = str(s.get("id", ""))
