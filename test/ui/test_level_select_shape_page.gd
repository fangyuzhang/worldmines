# test_level_select_shape_page.gd —— 选关页第四页「异形棋盘」（**两级：先选变体，再选棋盘**）
#
# 背景：res://levels/ 下的异形关卡（挖洞/蜂窝/图案/风格/复刻 + 变体×棋盘）此前没有入口，
# 2026-09-21 建页；随后按用户要求改为**以变体为导向**——玩家的思考单位是「想玩哪个变体」，
# 同一个变体在不同异形棋盘上的推理体验差异才是这一页的内容。
#
# 本测试锁定两级契约：
#   ① 第一级 = 变体卡片（每个可用变体一张，标题带「已通关 / 总数」）；
#   ② 点变体 → 第二级 = 返回入口 + 该变体的全部异形棋盘卡片（**抽样实测** 3 个变体：
#      经典 / 一个 S 轴 / 一个 Z 轴；逐变体的完整性由数据层用例覆盖，避免每个变体都
#      重建一次卡片墙导致用例跑上百秒）；
#   ③ 汇总两级的关卡归属 == res://levels/ 里全部异形关卡（不重不漏，动态扫描不写死）；
#   ④ 返回能回到第一级。
extends GutTest

var _view
var _expected_cache := {}


func before_each() -> void:
	_view = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(_view)
	_expected_cache = {}
	# 2026-09-22：异形页内容改为**延迟一帧填**（性能——进选关页不再同步付 91 个
	# JSON 的全量扫描与两级卡片墙构建；_show_tab 有同步兜底，玩家切页时必已就绪）。
	# 契约：内容在下一帧就绪。这里等一帧再让用例做同步断言。
	await get_tree().process_frame


# ---- 工具 ----

## 期望集合：与生产端**独立实现**的扫描（照抄生产函数的话，生产判定坏了这里也跟着坏，
## 门禁就失去意义）。返回 {path: variant}；variant = global_rules[0]，无则 "classic"。
func _expected() -> Dictionary:
	if not _expected_cache.is_empty():
		return _expected_cache
	var out := {}
	for path in LevelLoader.list_levels():
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var d: Variant = JSON.parse_string(f.get_as_text())
		f.close()
		if not (d is Dictionary):
			continue
		var topo: Variant = (d as Dictionary).get("topology", null)
		if not (topo is Dictionary) or (topo as Dictionary).is_empty():
			continue
		var gr: Variant = (d as Dictionary).get("global_rules", [])
		var vid := "classic"
		if (gr is Array) and not (gr as Array).is_empty():
			vid = str((gr as Array)[0])
		out[path] = vid
	_expected_cache = out
	return out


## 各变体的关卡数（只按 global_rules 归并）。
func _counts_by_variant() -> Dictionary:
	var out := {}
	var exp := _expected()
	for path: String in exp:
		var vid := str(exp[path])
		out[vid] = int(out.get(vid, 0)) + 1
	return out


func _collect(node: Node, meta_key: String, out: Array) -> void:
	if node is Button and node.has_meta(meta_key):
		out.append(node)
	for c in node.get_children():
		_collect(c, meta_key, out)


func _cards(meta_key: String) -> Array:
	var out: Array = []
	if _view._shape_body != null and is_instance_valid(_view._shape_body):
		_collect(_view._shape_body, meta_key, out)
	return out


func _card_text(card: Button) -> String:
	var parts: Array[String] = []
	_collect_labels(card, parts)
	return "\n".join(parts)


func _collect_labels(node: Node, out: Array[String]) -> void:
	if node is Label:
		out.append(str((node as Label).text))
	for c in node.get_children():
		_collect_labels(c, out)


# ---- 用例 ----

func test_first_level_lists_one_card_per_variant() -> void:
	var counts := _counts_by_variant()
	assert_gt(counts.size(), 0, "levels/ 下应至少有一个异形关卡")
	var cards := _cards("variant_id")
	assert_eq(cards.size(), counts.size(),
		"第一级应有 %d 张变体卡片（实得 %d）" % [counts.size(), cards.size()])
	for c in cards:
		var vid := str(c.get_meta("variant_id"))
		assert_true(counts.has(vid), "变体卡片 %s 应来自实际扫描（不在期望集合里）" % vid)
		assert_true(_card_text(c).contains("/ %d" % int(counts[vid])),
			"变体卡片应显示该变体的棋盘数（%s 期望 / %d）：%s" % [vid, int(counts[vid]), _card_text(c)])


## 抽样实测：经典（最大集合）+ 一个 S 轴 + 一个 Z 轴变体。
func test_entering_variant_lists_only_its_levels() -> void:
	var counts := _counts_by_variant()
	var samples: Array[String] = ["classic"]
	for vid in ["s1", "z2"]:
		if counts.has(vid):
			samples.append(vid)
	for vid in samples:
		_view._open_shape_variant(vid)
		var cards := _cards("shape_path")
		assert_eq(cards.size(), int(counts[vid]),
			"变体 %s：第二级应有 %d 张关卡卡片（实得 %d）" % [vid, int(counts[vid]), cards.size()])
		assert_eq(_cards("shape_back").size(), 1, "变体 %s：第二级应有且仅有一个返回卡片" % vid)
		for c in cards:
			var p := str(c.get_meta("shape_path"))
			assert_eq(str(_expected().get(p, "MISSING")), vid,
				"变体 %s 的第二级不应混入其它变体的关卡（%s 属于 %s）" % [vid, p, str(_expected().get(p, "?"))])
		_view._back_to_shape_variants()


## 数据层完整性（不建 UI，避免逐变体重建卡片墙）：两级统计之和 == 全部异形关卡，不重不漏。
func test_variant_index_covers_every_shape_level() -> void:
	var counts := _counts_by_variant()
	var total := 0
	for vid: String in counts:
		total += int(counts[vid])
	assert_eq(total, _expected().size(), "变体索引应覆盖全部异形关卡")
	# 生产端的分组索引与独立扫描一致
	var prod := {}
	for info: Dictionary in _view._shape_levels():
		var vid := str(info["variant"])
		prod[vid] = int(prod.get(vid, 0)) + 1
	assert_eq(prod, counts, "生产端分组应与独立扫描一致（变体 id 口径不得漂移）")


func test_back_returns_to_variant_list() -> void:
	var before := _cards("variant_id").size()
	assert_gt(before, 0, "第一级应有变体卡片")
	_view._open_shape_variant("classic")
	assert_eq(_cards("variant_id").size(), 0, "第二级不应再有变体卡片")
	_view._back_to_shape_variants()
	assert_eq(_cards("variant_id").size(), before, "返回后应回到变体总览（且不残留第二级卡片）")


func test_daisy_chain_is_in_classic_variant() -> void:
	assert_eq(str(_expected().get("res://levels/daisy_chain.json", "MISSING")), "classic",
		"雏菊链应是经典变体（无 global_rules）")
	_view._open_shape_variant("classic")
	var paths: Array[String] = []
	for c in _cards("shape_path"):
		paths.append(str(c.get_meta("shape_path")))
	assert_true(paths.has("res://levels/daisy_chain.json"),
		"经典变体下应能找到「雏菊链」（此前它没有任何入口）")


func test_new_tiling_families_are_reachable_from_the_shape_page() -> void:
	## 2026-09-22 新增的五批异形几何：等轴菱面 / 等边三角 / 3.6.3.6 / 3.12.12 / 同心环盘
	## （vg_ 是「异形 × 变体」）。生成器把关卡文件写进 res://levels/ 只是「有文件」，
	## 能被选关页列出来才算「能玩到」—— 本测试就是这条链路的门禁。
	## 环盘单独点名：它是全库唯一的**带中央空洞**的盘（甜甜圈），也是唯一的环状拓扑。
	const WANT: Array[String] = ["iso_", "tri_", "trihex_", "t31212_", "ring_", "vg_"]
	var landed := {}
	for info: Dictionary in _view._shape_levels():
		var head := str(info.get("path", "")).get_file()
		for pre in WANT:
			if head.begins_with(pre):
				landed[pre] = true
	for pre2 in WANT:
		assert_true(landed.has(pre2), "异形页应列出 %s* 关卡" % pre2)

	# 全部归在经典变体下（这些几何都不带 global_rules 的变体关除外）
	_view._open_shape_variant("classic")
	var paths: Array[String] = []
	for c in _cards("shape_path"):
		paths.append(str(c.get_meta("shape_path")))
	for info2: Dictionary in _view._shape_levels():
		var p := str(info2.get("path", ""))
		if p.get_file().begins_with("vg_"):
			continue   # vg_ 带 global_rules，归到对应变体条目下，不在 classic
		var head2 := p.get_file()
		var is_new := false
		for pre3 in WANT:
			if head2.begins_with(pre3):
				is_new = true
		if is_new:
			assert_true(paths.has(p), "新族关卡应能在经典变体下找到：%s" % p)


func test_every_listed_level_actually_loads() -> void:
	_view._open_shape_variant("classic")
	var n := 0
	for c in _cards("shape_path"):
		var p := str(c.get_meta("shape_path"))
		assert_not_null(LevelLoader.load_level(p), "列出的异形关应能被载入：%s" % p)
		n += 1
	assert_gt(n, 0, "经典变体应有内容")


func test_is_shape_level_predicate() -> void:
	assert_false(_view._is_shape_level({}), "无 topology 字段 → 非异形")
	assert_false(_view._is_shape_level({"topology": 1}), "topology 非字典 → 非异形")
	assert_false(_view._is_shape_level({"topology": {}}), "topology 为空字典 → 非异形")
	assert_true(_view._is_shape_level({"topology": {"positions": [{"x": 0, "y": 0}]}}),
		"非空 topology → 异形")
