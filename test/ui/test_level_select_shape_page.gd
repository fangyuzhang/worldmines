# test_level_select_shape_page.gd —— 选关页第四页「异形棋盘」（变体卡 → 浮动弹窗选棋盘）
#
# 背景：res://levels/ 下的异形关卡（挖洞/蜂窝/图案/风格/复刻 + 变体×棋盘）此前没有入口，
# 2026-09-21 建页；随后按用户要求改为**以变体为导向**——玩家的思考单位是「想玩哪个变体」，
# 同一个变体在不同异形棋盘上的推理体验差异才是这一页的内容。
#
# 本测试锁定契约：
#   ① 一级 = 变体卡片（每个可用变体一张，标题带「已通关 / 总数」）；
#   ② 点变体卡 → **浮动弹窗**展示该变体的全部异形棋盘卡片，按档位分组（**抽样实测** 3 个变体：
#      经典 / 一个 S 轴 / 一个 Z 轴；逐变体的完整性由数据层用例覆盖，避免每个变体都
#      重建一次卡片墙导致用例跑上百秒）。2026-09-25 用户口径：弹窗与单项/混合/Mod 页
#      **共用外壳**；2026-09-29 起标题栏整体移除（关闭 = 点遮罩 / ESC），见
#      test_shape_popup_shares_the_same_shell_as_other_pages；
#   ③ 汇总两级的关卡归属 == res://levels/ 里全部异形关卡（不重不漏，动态扫描不写死）；
#   ④ 变体的棋盘图解教程数据链路仍通（教程入口 2026-09-29 起只挂在模式弹窗右栏）。
extends GutTest

const TutorialOverlayScript := preload("res://ui/tutorial_overlay.gd")

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


## 按 meta 键收集卡片。**扫整页**（不只 `_shape_body`）：异形页的棋盘卡自 2026-09-25 起
## 在浮动弹窗里（`_overlay` 下），只扫 `_shape_body` 会找不到它们。
func _cards(meta_key: String) -> Array:
	var out: Array = []
	_collect(_view, meta_key, out)
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
		_view._open_shape_popup(vid)
		var cards := _cards("shape_path")
		assert_eq(cards.size(), int(counts[vid]),
			"变体 %s：弹窗应有 %d 张关卡卡片（实得 %d）" % [vid, int(counts[vid]), cards.size()])
		for c in cards:
			var p := str(c.get_meta("shape_path"))
			assert_eq(str(_expected().get(p, "MISSING")), vid,
				"变体 %s 的弹窗不应混入其它变体的关卡（%s 属于 %s）" % [vid, p, str(_expected().get(p, "?"))])
		_view._close_popup()
		# 必须等**出场动画走完**再开下一个：关闭期间 `_popup_closing` 为真，打开请求会被守卫
		# 忽略（真实交互无所谓——玩家不可能 0.22s 内连点两张卡）；而旧 overlay 是延迟释放的，
		# 不等就会让下一轮的 `_cards`（全树扫描）扫到它的残留卡片（首版测试就报了这个假失败）。
		await wait_seconds(0.3)


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


func test_variant_card_opens_popup_with_its_levels() -> void:
	## 点变体卡 → **浮动弹窗**（2026-09-25 用户口径：与单项/混合/Mod 页的交互统一，
	## 不再是页内切第二级）。弹窗里有且只有该变体的棋盘卡。
	var counts := _counts_by_variant()
	assert_gt(_cards("variant_id").size(), 0, "一级应有变体卡片")
	_view._show_tab(_view.PAGE_SHAPE)
	assert_null(_view._overlay, "未点卡片时不应有弹窗")
	_view._open_shape_popup("classic")
	assert_not_null(_view._overlay, "点变体卡应弹出浮动弹窗")
	assert_not_null(_view._popup, "弹窗主体应存在")
	# 2026-09-29 用户口径：标题栏整体移除，「变体名 · 异形棋盘」标题不再存在。
	assert_null(_view.get("_title_label"), "标题栏移除后不应再有标题标签")
	var cards := _cards("shape_path")
	assert_eq(cards.size(), int(counts["classic"]),
		"弹窗里应有经典变体的全部 %d 张棋盘卡（实得 %d）" % [int(counts["classic"]), cards.size()])
	for c in cards:
		var p := str(c.get_meta("shape_path"))
		assert_eq(str(_expected().get(p, "MISSING")), "classic",
			"弹窗不应混入别的变体的关卡（%s 属于 %s）" % [p, str(_expected().get(p, "?"))])
	_view._close_popup()
	assert_null(_view._overlay, "关闭后遮罩引用应立即释放")


func test_shape_popup_shares_the_same_shell_as_other_pages() -> void:
	## 弹窗外壳一致性：异形弹窗与模式弹窗共用 `_build_popup_shell`（同一遮罩/尺寸/关闭方式）。
	## 2026-09-29 用户口径：标题栏（标题 / 教程 / ✕）整体移除 ——
	## 关闭出口 = 点遮罩任意处 / ESC，两条都在本用例钉住。
	_view._show_tab(_view.PAGE_SHAPE)
	_view._open_shape_popup("classic")
	# 标题栏已删：弹窗内不应再有关闭按钮 / 教程入口
	# （教程书本按钮只挂在模式弹窗右栏「继续游戏」上方——异形弹窗没有右栏）
	var closes: Array = []
	_collect(_view._overlay, "popup_close", closes)
	assert_eq(closes.size(), 0, "标题栏移除后浮窗不应再有关闭按钮")
	var tuts: Array = []
	_collect(_view._overlay, "popup_tutorial", tuts)
	assert_eq(tuts.size(), 0, "异形弹窗没有右栏，教程入口不再出现在这里")
	# 出口 1：点遮罩关弹窗（2026-09-29 用户口径：点弹窗以外任意位置关闭）
	_view._close_popup()
	assert_null(_view._overlay, "点遮罩关闭后遮罩引用应立即释放")
	# 出口 2：ESC 关弹窗（2026-09-25 一致性补齐，标题栏移除后仍保留）
	_view._open_shape_popup("classic")
	var esc := InputEventAction.new()
	esc.action = "ui_cancel"
	esc.pressed = true
	_view._unhandled_input(esc)
	assert_null(_view._overlay, "ESC 应能关掉弹窗（与点遮罩并列出口）")


func test_daisy_chain_is_in_classic_variant() -> void:
	assert_eq(str(_expected().get("res://levels/daisy_chain.json", "MISSING")), "classic",
		"雏菊链应是经典变体（无 global_rules）")
	_view._open_shape_popup("classic")
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
	_view._open_shape_popup("classic")
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
	_view._open_shape_popup("classic")
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


# 2026-09-23 审计补齐 → 2026-09-29 迁移：变体关的教程**数据**仍要可达。
# 背景：异形页是 ani_*/vg_* 这批**变体形状关**的主入口（模式弹窗里没有它们）。
# 2026-09-29 用户口径把弹窗标题栏整体移除后，异形弹窗不再内嵌教程入口
# （教程书本按钮只挂在模式弹窗右栏）。本用例改钉两条：
#   ① 异形弹窗内确实没有教程入口（防有人「顺手」加回突兀的角标）；
#   ② 同一变体的棋盘图解教程经 TutorialOverlay 仍能正常拉出（数据链路不因入口迁移而断）。
func test_variant_level_offers_variant_tutorial() -> void:
	var counts := _counts_by_variant()
	# 优先挑官方轴上有教程页的变体（s2/s3/z3/dt 均有 tutorial_*_0.txt）；
	# 其它变体（vg_ 复刻族等）可能没有页，此时覆盖层显示兜底文案——两种都算通过。
	var vid := ""
	for prefer in ["s2", "s3", "z3", "dt"]:
		if counts.has(prefer):
			vid = prefer
			break
	if vid == "":
		for k: String in counts:
			if k != "classic":
				vid = k
				break
	if vid == "":
		pending("本机 levels/ 没有非 classic 变体的异形关")
		return
	# ① 异形弹窗内无教程入口（入口只活在模式弹窗右栏）
	_view._open_shape_popup(vid)
	var tut: Array = []
	_collect(_view._overlay, "popup_tutorial", tut)
	assert_eq(tut.size(), 0, "变体 %s：异形弹窗内不应有教程入口（标题栏已移除）" % vid)
	_view._close_popup()
	# ② 详细教程数据链路仍通：show_for 直接拉覆盖层，页 id 指向该变体
	var ov := TutorialOverlayScript.show_for(_view, vid)
	assert_not_null(ov, "变体 %s 的教程覆盖层应能拉出" % vid)
	if ov == null:
		return
	var title: Label = ov.get("_title")
	assert_true(title.text.find("tutorial_%s" % vid) >= 0 or title.text.find("暂无教程") >= 0,
		"应加载变体 %s 的教程页或显示兜底（实得：%s）" % [vid, title.text])


# 2026-09-23 新增契约、2026-09-25 迁移到弹窗：棋盘卡按**档位分组**（普通 / 困难 / 噩梦 / 未分档）。
# 为什么：内容目标 =「每个变体 × 每个档位都有较多异形棋盘」（用户口径）；平铺时这个事实
# 对玩家不可见（卡片只写格数/雷数）。这条钉住「分组标题存在、文案与 Difficulty.tier_text
# 同源、且分组不改变卡片总数」——分组整段消失（例如有人改回平铺）会在这里红灯。
func test_shape_popup_groups_by_tier() -> void:
	_view._open_shape_popup("classic")   # 内容最多的变体：三档 + 未分档都可能出现
	# 分组标题现在在**弹窗**里（原先在页内第二级）⇒ 扫整页，不再只扫 _shape_body
	var texts: Array[String] = []
	_collect_labels(_view, texts)
	var tier_headers := 0
	var none_headers := 0
	for t in texts:
		if t.contains("条线索）") and t.contains("·") and t.contains("关"):
			tier_headers += 1
		if t.begins_with("未分档"):
			none_headers += 1
	assert_gt(tier_headers, 0,
		"弹窗应有档位分组标题（Difficulty.tier_text 文案，如「普通（2–3 条线索）· N 关」）")
	assert_eq(none_headers, 1,
		"classic 有未分档关卡（peak≤1/超纲）⇒ 应有且仅有一段「未分档」标题")
	# 文案来源：与 Difficulty.tier_text 同源（禁止手写第二份档位表）
	var want_easy := Difficulty.tier_text("easy")
	var has_want := false
	for t in texts:
		if t.begins_with(want_easy):
			has_want = true
	assert_true(has_want, "档位标题应以 Difficulty.tier_text(\"easy\") 开头（实得：%s）" % want_easy)
	# 分组不改变卡片总数：第一级的关卡计数 == 第二级的卡片数
	var counts := _counts_by_variant()
	assert_eq(_cards("shape_path").size(), int(counts["classic"]),
		"按档位分组后 classic 的第二级卡片数应不变")
