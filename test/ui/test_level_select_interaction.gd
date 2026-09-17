# test_level_select_interaction.gd —— 选关页交互契约
#
# 覆盖「只能靠运行期断言」的几点：
#   ① 三个页面（单项 / 混合档 / Mod）都建起来，且目录里的变体在自己的页里有入口；
#   ② 演示预设（MOCK_CLEARED）不得写进真实进度存档；
#   ③ 弹窗关闭动画期间不得被重复打开（原实现会叠出第二个弹窗）；
#   ④ 终局页「下一关」交接的焦点意图应被领取、翻到对应页并展开弹窗；
#   ⑤ 卡片 / 交叉格不得互相遮挡（用户实测反馈过「选项之间互相遮挡」）。
extends GutTest

var _view


func before_each() -> void:
	_view = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(_view)


func after_each() -> void:
	LevelSequence.take_focus()  # 清掉可能残留的意图，避免污染其它用例
	# 装过的 demo Mod 必须卸掉：残留会让其它用例以为「这机器上装了 Mod」
	if ModAPI.list_mods().has("custom_rule_mod"):
		ModAPI.unload_mod("custom_rule_mod")
	ExampleMod.uninstall_demo_rule_mod()
	if ModAPI.list_mods().has(DEF_MOD_ID):
		ModAPI.unload_mod(DEF_MOD_ID)
	_remove_def_mod()


# ---- 工具 ----

func _count_meta_buttons(node: Node, meta_key: String) -> int:
	var n := 0
	if node is Button and node.has_meta(meta_key):
		n += 1
	for c in node.get_children():
		n += _count_meta_buttons(c, meta_key)
	return n


## 统计「可点」的交叉格（置灰的冗余格不算入口）。
func _count_clickable_cells(node: Node) -> int:
	var n := 0
	if node is Button and node.has_meta("cell_btn") and not (node as Button).disabled:
		n += 1
	for c in node.get_children():
		n += _count_clickable_cells(c)
	return n


## 找到页面里的流式容器（卡片排布在它里面，居中判定要看它的实际宽度）。
func _find_flow(node: Node) -> Control:
	if node is HFlowContainer:
		return node as Control
	for c in node.get_children():
		var r := _find_flow(c)
		if r != null:
			return r
	return null


func _collect_rects(node: Node, meta_key: String, out: Array) -> void:
	if node is Control and node.has_meta(meta_key) and (node as Control).is_visible_in_tree():
		out.append(Rect2((node as Control).global_position, (node as Control).size))
	for c in node.get_children():
		_collect_rects(c, meta_key, out)


func _assert_no_overlap(rects: Array, what: String) -> void:
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			assert_false(rects[i].intersects(rects[j]),
					"%s：第 %d 个与第 %d 个重叠（%s / %s）" % [what, i, j, rects[i], rects[j]])


const DEF_MOD_ID := "ls.def.test"
const DEF_MOD_DIR := "user://_ls_def_mod"


## 写一个 Def 数据包（runtime=def，无代码入口）到 user://：1 线索 + 1 约束。
func _write_def_mod() -> void:
	DirAccess.make_dir_recursive_absolute(DEF_MOD_DIR.path_join("defs"))
	var mf := FileAccess.open(DEF_MOD_DIR.path_join("manifest.json"), FileAccess.WRITE)
	mf.store_string(JSON.stringify({"id": DEF_MOD_ID, "version": "1.0.0",
			"entry": {"runtime": "def", "path": "defs"}}))
	mf.close()
	var f1 := FileAccess.open(DEF_MOD_DIR.path_join("defs/clue.json"), FileAccess.WRITE)
	f1.store_string('{"defName": "LsDir4N", "type": "clue", "window": "n4", "aggregate": "sum", "value_range": [0, 4]}')
	f1.close()
	var f2 := FileAccess.open(DEF_MOD_DIR.path_join("defs/constraint.json"), FileAccess.WRITE)
	f2.store_string('{"defName": "LsMirror", "type": "constraint", "op": "symmetry_axis"}')
	f2.close()


func _remove_def_mod() -> void:
	var d := DirAccess.open(DEF_MOD_DIR)
	if d == null:
		return
	d.remove("manifest.json")
	d.remove("defs/clue.json")
	d.remove("defs/constraint.json")
	d.remove("defs")


func _find_label_containing(node: Node, needle: String) -> Label:
	if node is Label and (node as Label).text.contains(needle):
		return node as Label
	for c in node.get_children():
		var r := _find_label_containing(c, needle)
		if r != null:
			return r
	return null


func _has_label_containing(node: Node, needle: String) -> bool:
	return _find_label_containing(node, needle) != null


# LS1：三页都建起来，且目录里的每个变体在其所属页里有入口
# （这就是「引擎换了、UI 必须跟上」这条链在 UI 侧的兜底）
func test_ls1_three_pages_are_built() -> void:
	assert_not_null(_view, "选关页应能实例化")
	assert_eq(_view._pages.size(), 3, "应有三个页面（单项变体 / 混合档 / Mod）")

	var single := _count_meta_buttons(_view._pages[_view.PAGE_SINGLE], "card_btn")
	assert_eq(single, 16, "单项变体页：经典 1 + 线索 8 + 全局约束 7 = 16 张卡片")
	assert_eq(_count_meta_buttons(_view._pages[_view.PAGE_MIXED], "cell_btn"), 8 * 7,
			"混合档默认表：8 线索 × 7 约束 = 56 个交叉格")

	var per_page := {0: 0, 1: 0, 2: 0}
	for m in _view.MODES:
		per_page[_view._page_of(m)] += 1
	assert_eq(per_page[_view.PAGE_SINGLE], single, "单项页卡片数应与目录一致")

	# 混合档有两张表（同页切换）：约束×线索（56 格）+ 约束×约束（C(7,2) 对）。
	# 契约：两张表里**可点**的格子合起来 = 目录里的全部混合档（判冗余的格子置灰、不算入口）。
	var clickable := _count_clickable_cells(_view._pages[_view.PAGE_MIXED])
	_view._show_tab(_view.PAGE_MIXED)
	_view._on_mixed_switch(true)
	await get_tree().process_frame
	await get_tree().process_frame
	clickable += _count_clickable_cells(_view._pages[_view.PAGE_MIXED])
	assert_eq(clickable, per_page[_view.PAGE_MIXED], "两张表合起来应覆盖目录里的全部混合档")


# LS2：演示预设只存在于内存 —— 不得污染 user://progress.json
func test_ls2_mock_progress_is_not_persisted() -> void:
	_view._mode_idx = 0          # classic
	_view._size_idx = 0          # 5×5
	# 注意：_view 是 Variant（场景脚本无 class_name），必须显式标注类型，
	# 否则 Godot 4.7 会因无法推断而 Parse Error（交接文档已记录的坑）。
	var key: String = _view._level_key(0)
	var before: bool = ProgressStore.is_cleared(key)
	_view._ensure_mock()
	assert_true(_view._is_cleared(key), "演示预设应在本进程内生效（解锁流程可演示）")
	if not before:
		assert_false(ProgressStore.is_cleared(key),
				"演示预设绝不能写入真实存档（历史 bug：留下永久的假通关成绩）")


# LS3：关闭动画期间禁止重开弹窗
func test_ls3_popup_close_animation_blocks_reopen() -> void:
	_view._open_popup(0)
	assert_ne(_view._mode_idx, -1, "应已打开弹窗")
	_view._close_popup()
	assert_eq(_view._mode_idx, -1, "关闭后模式复位")
	_view._open_popup(1)
	assert_eq(_view._mode_idx, -1, "关闭动画期间不得再开（否则会叠出两个弹窗）")


# LS4：终局页交接的焦点意图 → 自动展开对应变体的弹窗（单项变体）
func test_ls4_pending_focus_opens_matching_popup() -> void:
	LevelSequence.request_focus("classic", 5)
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_eq(v2._mode_idx, 0, "应自动展开 classic 的关卡弹窗")
	assert_not_null(v2._overlay, "弹窗应处于打开状态")


# LS6：混合档的焦点交接 → 必须先翻到混合档页（否则弹窗开在一个看不见的页上）
func test_ls6_pending_focus_on_mixed_switches_page() -> void:
	LevelSequence.request_focus("mx_4n", 5)   # 镜像 × 四邻
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_eq(v2._tab, v2.PAGE_MIXED, "混合档的下一关意图应先翻到混合档页")
	assert_ne(v2._mode_idx, -1, "并展开它的选关弹窗")


# LS7：Mod 页签的可见性与「是否装了 Mod」一致；无 Mod 时该页不可达且显示空状态
func test_ls7_mod_tab_follows_loaded_mods() -> void:
	var expected := not ModAPI.list_mods().is_empty()
	assert_eq(_view._tab_btns[_view.PAGE_MOD].visible, expected,
			"Mod 页签可见性必须与已加载 Mod 一致（空页签只会让人点进去看空）")
	if expected:
		return
	assert_true(_has_label_containing(_view._pages[_view.PAGE_MOD], "还没有加载任何 Mod"),
			"无 Mod 时 Mod 页应显示空状态与放置说明")
	_view._show_tab(_view.PAGE_MOD)
	assert_eq(_view._tab, _view.PAGE_SINGLE, "无 Mod 时 Mod 页不可达")


# LS9：装了代码 Mod → 页签出现、变体落在 Mod 页（不混进单项变体页）
# Mod 页是唯一「内容由运行期决定」的页面，这条覆盖它的真实渲染路径。
func test_ls9_mod_variant_lands_on_mod_page() -> void:
	var inst: Dictionary = ExampleMod.install_demo_rule_mod()
	if not inst.get("ok", false):
		pending("demo 代码 Mod 安装失败：%s" % str(inst.get("reason", "")))
		return
	var r: Dictionary = ModAPI.load_mod("user://mods/custom_rule_mod")
	assert_true(r.get("ok", false), "ModAPI 应能加载 demo 代码 Mod：%s" % str(r.get("reason", "")))
	if not r.get("ok", false):
		return
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_true(v2._tab_btns[v2.PAGE_MOD].visible, "装了 Mod 后 Mod 页签应可见")
	assert_true(v2._mode_index.has("x2diag"), "Mod 注册的规则应进入变体表")
	var mi: int = int(v2._mode_index.get("x2diag", -1))
	assert_eq(v2._page_of(v2.MODES[mi]), v2.PAGE_MOD, "Mod 变体应归 Mod 页")
	assert_gte(_count_meta_buttons(v2._pages[v2.PAGE_MOD], "card_btn"), 1, "Mod 页应有它的卡片")
	assert_eq(_count_meta_buttons(v2._pages[v2.PAGE_SINGLE], "card_btn"), 16,
			"单项变体页不应混进 Mod 变体（内置变体的位置必须稳定）")
	assert_true(_has_label_containing(v2._pages[v2.PAGE_MOD], "代码 Mod"),
			"分组标题应标出该 Mod 的创作形式")


# LS10：Def 数据包（runtime=def）不注册进规则表，所以没有变体卡片——
# 但它确实提供了可玩内容，页面必须如实列出「这个 Mod 有什么」，而不是写成「未注册可玩变体」。
func test_ls10_def_mod_lists_its_defs() -> void:
	_write_def_mod()
	var r: Dictionary = ModAPI.load_mod(DEF_MOD_DIR)
	assert_true(r.get("ok", false), "Def mod 应加载成功：%s" % str(r.get("reason", "")))
	if not r.get("ok", false):
		return
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_true(v2._tab_btns[v2.PAGE_MOD].visible, "装了 Mod（哪怕只是 Def 包）页签就应可见")
	assert_true(_has_label_containing(v2._pages[v2.PAGE_MOD], "LsDir4N"), "应列出该 Mod 的 Def 线索名")
	assert_true(_has_label_containing(v2._pages[v2.PAGE_MOD], "LsMirror"), "应列出该 Mod 的 Def 约束名")
	assert_false(_has_label_containing(v2._pages[v2.PAGE_MOD], "未注册可玩变体"),
			"有 Def 规则时不得写成「未注册可玩变体」")
	# 反「被流式容器压扁」：autowrap 的 Label 最小宽度≈0，一旦误放进卡片流就会排成一列单字
	# （实测踩过，肉眼才发现）。所以这里断言它的实际宽度接近整行。
	v2.anchor_right = 0.0
	v2.anchor_bottom = 0.0
	v2.size = Vector2(1280, 720)
	v2._show_tab(v2.PAGE_MOD)
	await get_tree().process_frame
	await get_tree().process_frame
	var def_lb := _find_label_containing(v2._pages[v2.PAGE_MOD], "LsDir4N")
	assert_not_null(def_lb, "Def 行应存在")
	if def_lb != null:
		assert_true(def_lb.size.x > 300.0,
				"Def 行应占满整行而不是被挤成一列单字（实际宽 %.1f）" % def_lb.size.x)


# LS11：双约束表（约束 × 约束）——上三角结构、冗余格置灰、真值贯通到弹窗
func test_ls11_gg_matrix_and_feasibility() -> void:
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_true(v2._mode_index.has("mx_rl"), "双约束组合应进变体表")
	var mi: int = int(v2._mode_index.get("mx_rl", -1))
	var m: Dictionary = v2.MODES[mi]
	assert_eq(str(m["clue"]), "classic", "双约束不加线索（线索走经典）")
	assert_eq((m["globals"] as Array).size(), 2, "应携带两条全局约束")
	assert_eq(v2._page_of(m), v2.PAGE_MIXED, "双约束属混合档页")
	assert_false(v2._mode_index.has("mx_ep"),
			"mx 逻辑蕴含 ep（后者冗余），判 forbid 的组合不应产生条目")

	v2.anchor_right = 0.0
	v2.anchor_bottom = 0.0
	v2.size = Vector2(1280, 720)
	v2._show_tab(v2.PAGE_MIXED)
	v2._on_mixed_switch(true)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(_count_meta_buttons(v2._pages[v2.PAGE_MIXED], "cell_btn"), 7 * 6 / 2,
			"双约束表：C(7,2) = 21 对（含 1 格判冗余的置灰占位）")
	assert_eq(_count_clickable_cells(v2._pages[v2.PAGE_MIXED]), 20, "其中 20 对可玩")

	var rects: Array = []
	_collect_rects(v2._pages[v2.PAGE_MIXED], "cell_btn", rects)
	assert_eq(rects.size(), 21, "21 格都应参与布局（含置灰格）")
	_assert_no_overlap(rects, "双约束表格子")
	var max_x := 0.0
	for r in rects:
		max_x = maxf(max_x, r.end.x)
	assert_true(max_x <= 1280.0, "双约束表不得超出 1280 设计分辨率右侧（实际 %.1f）" % max_x)

	# 尺寸级可行性的真值贯通：mx+rl 在 6×6 全候选无解、7×7 可行
	# （G+G 的尺寸级不可行比 G+C 常见，弹窗靠尺寸按钮禁用 + 自动切最近可行尺寸兜住）
	assert_false(v2._mode_feasible(m, 6), "mx+rl 在 6×6 全候选无解")
	assert_true(v2._mode_feasible(m, 7), "mx+rl 在 7×7 可行")


# LS12：失败终局「跳过本关」在选关页的四层联动
#   ① 跳过不算通关；② 下一关解锁；③ 定位前进而不是回落刚跳过的关；④ 方块显示 › 而非 ✓
func test_ls12_skip_unlocks_next_and_marks_tile() -> void:
	# 进度文件是**真实存档**：本用例要写 gen:// 键，先备份后还原
	# （用 9×9 这套：其它用例都停在不同尺寸，避免撞上演示预设的进程内记录）
	var backup := ""
	var existed := FileAccess.file_exists(ProgressStore.PATH)
	if existed:
		var f := FileAccess.open(ProgressStore.PATH, FileAccess.READ)
		backup = f.get_as_text()
		f.close()
	ProgressStore.reset_cache()

	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	v2._mode_idx = int(v2._mode_index.get("classic", 0))
	v2._size_idx = 4                      # SIZES[4] = 9×9
	var k0 := LevelSequence.level_key("classic", 9, 0)

	assert_false(v2._is_unlocked(1), "前置：第 1 关未通关时第 2 关应锁着")
	ProgressStore.record_skip(k0)
	assert_true(v2._is_skipped(k0), "应记为已跳过")
	assert_false(v2._is_cleared(k0), "跳过不算通关（统计与最佳用时不受影响）")
	assert_true(v2._is_unlocked(1), "跳过后下一关应解锁")
	assert_eq(v2._latest_unlocked(), 1, "定位应前进到第 2 关，而不是回落刚跳过的第 1 关")
	var tile: Button = v2._make_tile(0)
	add_child_autofree(tile)   # 未入树的按钮要显式回收（否则 GUT 报 orphan）
	assert_true(tile.text.contains("›"),
			"跳过的关卡方块应显示 › 角标、不能冒充通关：%s" % tile.text)
	assert_false(tile.disabled, "跳过的关卡仍可点进去回头补")
	var next_tile: Button = v2._make_tile(1)
	add_child_autofree(next_tile)
	assert_false(next_tile.disabled, "下一关应可进入")

	if existed:
		var f2 := FileAccess.open(ProgressStore.PATH, FileAccess.WRITE)
		f2.store_string(backup)
		f2.close()
	else:
		var d := DirAccess.open("user://")
		if d != null and d.file_exists("progress.json"):
			d.remove("progress.json")
	ProgressStore.reset_cache()


# LS5：卡片互不重叠（用户实测反馈：变体增多后选项之间互相遮挡）
# 拆页后排布交给容器，这条仍固化「不允许出现遮挡」。
# 多分辨率验证：1280×720 是项目设计分辨率；1280×1280 是 GUT 无头视口的实际尺寸。
func test_ls5_cards_do_not_overlap() -> void:
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	for vp in [Vector2(1280, 720), Vector2(1280, 1280)]:
		# 根节点是 full-rect 锚点，直接改 size 会被引擎覆盖并告警 → 先解除锚点
		v2.anchor_right = 0.0
		v2.anchor_bottom = 0.0
		v2.size = vp
		v2._show_tab(v2.PAGE_SINGLE)
		await get_tree().process_frame
		await get_tree().process_frame
		var rects: Array = []
		_collect_rects(v2._pages[v2.PAGE_SINGLE], "card_btn", rects)
		assert_eq(rects.size(), 16, "%s：单项变体页应有 16 张卡片" % vp)
		_assert_no_overlap(rects, "%s 单项变体卡片" % vp)
		for r in rects:
			assert_true(r.size.x > 0.0 and r.size.y > 0.0, "%s：卡片不得为零尺寸" % vp)
		# 左右留白必须对称（用户实测反馈过「不居中对称」）：流式容器默认左对齐，
		# 卡片宽不能整除可视宽时余量全堆右侧（实测 4 列：左 0px / 右 90px，肉眼很明显）。
		# 这类问题只在真机看得出来，所以在此固化——改成左对齐即失败。
		var flow := _find_flow(v2._pages[v2.PAGE_SINGLE])
		assert_not_null(flow, "%s：应能找到卡片流式容器" % vp)
		if flow != null:
			assert_eq(flow.alignment, FlowContainer.ALIGNMENT_CENTER,
					"%s：卡片流式容器应居中对齐" % vp)
			var left_edge := INF
			var right_edge := -INF
			for r in rects:
				left_edge = minf(left_edge, r.position.x)
				right_edge = maxf(right_edge, r.end.x)
			var pad_left := left_edge - flow.global_position.x
			var pad_right := (flow.global_position.x + flow.size.x) - right_edge
			assert_almost_eq(pad_left, pad_right, 1.0,
					"%s：卡片组应左右居中（左 %.1fpx / 右 %.1fpx）" % [vp, pad_left, pad_right])


# LS8：交叉表的格子互不重叠，且整表能放进设计分辨率（1280 宽不留横向滚动条）
func test_ls8_matrix_cells_do_not_overlap() -> void:
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	v2.anchor_right = 0.0
	v2.anchor_bottom = 0.0
	v2.size = Vector2(1280, 720)
	v2._show_tab(v2.PAGE_MIXED)
	await get_tree().process_frame
	await get_tree().process_frame
	var rects: Array = []
	_collect_rects(v2._pages[v2.PAGE_MIXED], "cell_btn", rects)
	assert_eq(rects.size(), 56, "交叉表应有 56 个格子")
	_assert_no_overlap(rects, "交叉表格子")
	# 列宽 × 列数 + 行首 + 列间距 + 页边距 ≤ 1280：否则右边一列会被裁掉
	var max_x := 0.0
	for r in rects:
		max_x = maxf(max_x, r.end.x)
	assert_true(max_x <= 1280.0, "交叉表不得超出 1280 设计分辨率右侧（实际 %.1f）" % max_x)
