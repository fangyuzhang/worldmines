# test_level_select_interaction.gd —— 选关页交互契约
#
# 覆盖「只能靠运行期断言」的几点：
#   ① 四个页面（单项 / 混合档 / 异形棋盘 / Mod）都建起来，且目录里的变体在自己的页里有入口；
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
	_remove_mod_level()


# ---- 工具 ----

func _count_meta_buttons(node: Node, meta_key: String) -> int:
	var n := 0
	if node is Button and node.has_meta(meta_key):
		n += 1
	for c in node.get_children():
		n += _count_meta_buttons(c, meta_key)
	return n


## 形状档卡片数（kind == "shape"）：成员资格由 levels_lib/shape_* 库内容决定，
## 随形状族增减（T1 挖洞方格 / T2 蜂窝 / 未来 T48x…）——**不写死总数**。
## 单项页断言一律用「24 + 本值」：2026-09-21 加形状卡时旧断言写死 24 被打破，特此固化口径。
func _count_shape_cards(view) -> int:
	var n := 0
	for m in view.MODES:
		if str((m as Dictionary).get("kind", "")) == "shape":
			n += 1
	return n


## 收集带某 meta 标记的按钮（调用方传自己的数组，避免默认参数被共享）。
func _collect_meta_buttons(node: Node, meta_key: String, out: Array) -> Array:
	if node is Button and node.has_meta(meta_key):
		out.append(node)
	for c in node.get_children():
		_collect_meta_buttons(c, meta_key, out)
	return out


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


# LS1：四页都建起来，且目录里的每个变体在其所属页里有入口
# （这就是「引擎换了、UI 必须跟上」这条链在 UI 侧的兜底）
func test_ls1_three_pages_are_built() -> void:
	assert_not_null(_view, "选关页应能实例化")
	# 2026-09-21 起为四页：新增「异形棋盘」（res://levels/ 下手工异形关的唯一入口）。
	# 手工异形关不属于 MODES 变体体系、也不走生成/关卡库序列，此前在选关页完全没有入口。
	assert_eq(_view._pages.size(), 4,
			"应有四个页面（单项变体 / 混合档 / 异形棋盘 / Mod）")

	var single := _count_meta_buttons(_view._pages[_view.PAGE_SINGLE], "card_btn")
	# 2026-09-18 起按 GDD 终版 §4 收敛变体池：单项页 = 经典 1 + 官方观测 10 + 结构守恒 13
	# （s1~s7 结构 + z1~z5 守恒 + dt 骨牌）= 24 张。
	# 旧算子（4n/sc/knight/fr/distsum/hv/ep/4c）已移入 legacy_rules Mod（默认不加载）；
	# 与官方席位等价的 6 个内置实现（clock/loopruns/pf/mx/rl/qd）按 HIDDEN_RULES 隐藏。
	# 2026-09-21 起另加**形状档**（挖洞方格/蜂窝，成员由 levels_lib/shape_* 库内容决定）：
	# 断言用「24 + 形状卡数」而非写死总数，加新形状族（T48x 等）不再破本用例。
	var shape_cards := _count_shape_cards(_view)
	assert_eq(single, 24 + shape_cards, "单项变体页：官方算子 24 张 + 形状卡 %d 张" % shape_cards)
	assert_eq(_count_meta_buttons(_view._pages[_view.PAGE_MIXED], "cell_btn"), 7 * 10,
			"混合档默认表（T3 C 类）：7 结构 × 10 观测 = 70 个交叉格")

	var per_page := {0: 0, 1: 0, 2: 0}
	for m in _view.MODES:
		per_page[_view._page_of(m)] += 1
	assert_eq(per_page[_view.PAGE_SINGLE], single, "单项页卡片数应与目录一致")

	# 混合档有三张表（同页切换）：T3 C 类（70）+ T3 F 类（C(7,2) = 21）+ T4（50）。
	# 契约：三张表里**可点**的格子合起来 = 目录里的全部混合档（判冗余 / 未加载的格子置灰，不算入口）。
	_view._show_tab(_view.PAGE_MIXED)
	var clickable := 0
	for tab in _view.MIXED_TABS:
		_view._on_mixed_switch(tab)
		await get_tree().process_frame
		await get_tree().process_frame
		clickable += _count_clickable_cells(_view._pages[_view.PAGE_MIXED])
	assert_eq(clickable, per_page[_view.PAGE_MIXED], "三张表合起来应覆盖目录里的全部混合档")


# LS2：演示预设只存在于内存 —— 不得污染 user://progress.json
func test_ls2_mock_progress_is_not_persisted() -> void:
	_view._mode_idx = 0          # classic
	_view._size_idx = 0          # 5×5
	_view._lib_mode = false      # 生成流口径（LS2 测的是 gen:// 演示键，不走库）
	_view._tier = ""
	# 注意：_view 是 Variant（场景脚本无 class_name），必须显式标注类型，
	# 否则 Godot 4.7 会因无法推断而 Parse Error（交接文档已记录的坑）。
	var key: String = _view._level_key(0)
	assert_true(key.begins_with("gen://"), "本用例只测生成流的演示键（lib:// 键不走 mock）")
	var before: bool = ProgressStore.is_cleared(key)
	_view._mock_cleared.clear()  # 进程内演示记录是 static——先清掉其他用例可能留下的残留
	if _view._mode_has_lib("classic"):
		# classic 已量产入库（v4.1 形状库接线后成为常态）：生成流演示预设不再适用
		#（_ensure_mock 对库模式刻意不垫假通关）。改为断言「库模式不写 mock、不落盘」。
		_view._lib_mode = true
		_view._ensure_mock()
		assert_true(_view._mock_cleared.is_empty(),
				"库模式不预置演示通关（真实内容从零进度开始）")
		# 2026-09-22 修正：原断言写死 is_cleared(key) == false —— 隐含「测试机存档里
		# 该生成流键必未通关」的假设；玩家真通关过 classic 5×5 第 1 关时（本机存档
		# 就有 gen://classic/5/0 的真实记录）必然为 true，测试假红。本用例真正要守的
		# 语义是「演示预设不改动真实存档」，故与进入本用例时的状态对比（before 已在
		# 上方捕获）。非库分支早已有 `if not before` 保护，此处此前漏了。
		assert_eq(ProgressStore.is_cleared(key), before,
				"演示预设绝不写入真实存档（应保持进入本用例时的状态）")
		return
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


# LS6：混合档的焦点交接 → 必须先翻到混合档页**和它所在的那张表**
# （混合档现在有三张表：只翻页不切表，弹窗会开在一个看不见的表上）
func test_ls6_pending_focus_on_mixed_switches_page_and_tab() -> void:
	LevelSequence.request_focus("s3_o5x", 5)   # 结构 × 观测（T3 C 类）
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	assert_eq(v2._tab, v2.PAGE_MIXED, "混合档的下一关意图应先翻到混合档页")
	assert_eq(v2._mixed_tab, 0, "C 类组合应切到第一张表")
	assert_ne(v2._mode_idx, -1, "并展开它的选关弹窗")

	# T4 组合（带守恒算子）必须切到第三张表。id 里的结构搭档由 GDD §10.1 的循环构造决定：
	# 观测 o5x 是第 5 席（i=4）、守恒 z1 是第 1 席（z=0）→ 结构 = STRUCT_IDS[(4+0) mod 7] = s5
	LevelSequence.request_focus("z1+s5+o5x", 5)
	var v3 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v3)
	assert_eq(v3._mixed_tab, 2, "T4 组合应切到守恒叠加表")
	assert_ne(v3._mode_idx, -1, "并展开它的选关弹窗")


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
	# 24 = 经典 1 + 观测 10 + 结构守恒 13（GDD 终版 §4 口径）+ 形状卡（库内容决定）；
	# **玩家 Mod 变体（x2diag）仍不得混入**
	assert_eq(_count_meta_buttons(v2._pages[v2.PAGE_SINGLE], "card_btn"), 24 + _count_shape_cards(v2),
			"单项变体页含官方算子与形状卡、但不应混进玩家 Mod 变体（位置必须稳定）")
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
	# Def 是规则平台的**声明式子集**（window/aggregate 是封闭枚举），永远等价于某个内置变体：
	# 页面要如实标出来（玩家才知道去哪儿玩同款玩法），而不是含糊一句「未注册可玩变体」。
	assert_eq(PuzzleGenerator.def_to_rule(ModAPI.defs, "LsDir4N", true), "4n",
			"n4+sum 应映射到内置 4n")
	assert_eq(PuzzleGenerator.def_to_rule(ModAPI.defs, "LsMirror", false), "mx",
			"symmetry_axis 应映射到内置 mx")
	assert_true(_has_label_containing(v2._pages[v2.PAGE_MOD], "≡"),
			"Def 行应标出等价的内置变体（≡）")


# LS14：Mod 的「已生成关卡」接入选关页 —— 生成器的成品应能直接开玩
# （早先只有模组页能生成、成品也只列在那里，选关页看不见 → 玩家得回模组页找）
func test_ls14_generated_mod_levels_are_listed() -> void:
	_write_def_mod()
	_write_mod_level()
	var r: Dictionary = ModAPI.load_mod(DEF_MOD_DIR)
	if not r.get("ok", false):
		pending("Def mod 加载失败：%s" % str(r.get("reason", "")))
		return
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	var btn := _find_button(v2._pages[v2.PAGE_MOD], "LsDir4N_01")
	assert_not_null(btn, "已生成的 Mod 关卡应列在 Mod 页（否则玩家得回模组页找成品）")
	if btn != null:
		assert_true(btn.has_meta("mod_level_btn"), "应标记为 Mod 关卡入口")
		assert_true(str(btn.tooltip_text).contains("直接开始"), "tooltip 应说明点击即开局")


# LS11：混合档三张表的轴与结构契约（T3 C 类 / T3 F 类 / T4）+ 可行性真值贯通
func test_ls11_mixed_three_tables_and_feasibility() -> void:
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)

	# C 类（第一张表）：结构 × 观测 —— 每关恰 1 观测 + 1 结构（GDD §5.1 硬限制 1、2）
	assert_true(v2._mode_index.has("s3_o5x"), "C 类组合（结构 × 观测）应进变体表")
	var c: Dictionary = v2.MODES[int(v2._mode_index["s3_o5x"])]
	assert_eq(str(c["clue"]), "o5x", "C 类组合应带观测算子")
	assert_eq((c["globals"] as Array).size(), 1, "C 类组合恰带 1 个结构算子")
	assert_eq(v2._mixed_tab_of(c), 0, "C 类组合属第一张表")

	# F 类（第二张表）：结构 × 结构 —— 结构允许 2 个（硬限制 2 的上界），但不叠加观测
	assert_true(v2._mode_index.has("s3_s5"), "F 类组合（结构 × 结构）应进变体表")
	var f: Dictionary = v2.MODES[int(v2._mode_index["s3_s5"])]
	assert_eq(str(f["clue"]), "classic", "F 类组合不加观测（线索走经典）")
	assert_eq(v2._mixed_tab_of(f), 1, "F 类组合属第二张表")

	# T4（第三张表）：结构 × 观测 + 1 守恒。id 里的结构搭档由 GDD §10.1 的循环构造决定：
	# 观测 o5x 是第 5 席（i=4）、守恒 z1 是第 1 席（z=0）→ 结构 = STRUCT_IDS[(4+0) mod 7] = s5
	assert_true(v2._mode_index.has("z1+s5+o5x"), "T4 组合应进变体表")
	var t4: Dictionary = v2.MODES[int(v2._mode_index["z1+s5+o5x"])]
	assert_eq(v2._mixed_tab_of(t4), 2, "T4 组合属第三张表")

	# 硬限制 3：守恒算子每关至多 1 个 —— 全表扫描，任何组合都不得出现两个 z*
	# （早先按 KIND_GLOBAL 一锅端做的「约束 × 约束」表正是踩了这条）
	for m in v2.MODES:
		var z := 0
		for g in (m as Dictionary).get("globals", []):
			if VariantCatalog.CONSERVE_IDS.has(str(g)):
				z += 1
		assert_true(z <= 1, "%s 含 %d 个守恒算子（硬限制 3：≤1）" % [str((m as Dictionary)["id"]), z])

	# 格子结构：C 类 7×10 全交叉、F 类只填右上三角、T4 5×10 全交叉
	v2.anchor_right = 0.0
	v2.anchor_bottom = 0.0
	v2.size = Vector2(1280, 720)
	v2._show_tab(v2.PAGE_MIXED)
	var expect := [7 * 10, 7 * 6 / 2, 5 * 10]
	for tab in v2.MIXED_TABS:
		v2._on_mixed_switch(tab)
		await get_tree().process_frame
		await get_tree().process_frame
		assert_eq(_count_meta_buttons(v2._pages[v2.PAGE_MIXED], "cell_btn"), int(expect[tab]),
				"第 %d 张表应有 %d 格" % [tab, int(expect[tab])])
		# 官方席位全部已加载 → 三张表不该有置灰格（置灰只在算子未加载 / 判 forbid 时出现）
		assert_eq(_count_clickable_cells(v2._pages[v2.PAGE_MIXED]), int(expect[tab]),
				"第 %d 张表的格子应全部可点（算子已加载、无冗余组合）" % tab)

	# 可行性真值贯通：官方席位的可行性由 RuleFeasibility 真值查询给出（无手写 UNSAT 表），
	# 弹窗的尺寸按钮据此禁用 + 自动切到最近可行尺寸。
	var res := RuleFeasibility.resolve_mines("o5x", ["s3"], 7)
	assert_ne(int(res["mines"]), -1, "s3+o5x 在 7×7 应有可用雷数")
	assert_true(v2._mode_feasible(c, 7), "同一结论应贯通到弹窗的尺寸判定")


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


# LS13：交叉表支持键盘 / 手柄导航 —— 格子可获焦点（方向键走格、回车即开这一关）。
# 项目整体是「鼠标优先」（FOCUS_NONE），只给交叉表开这个例外；焦点样式必须存在，
# 否则方向键走到哪一格看不见（踩过同类坑：可见性/样式不写就等于没有）。
func test_ls13_matrix_cells_are_focusable() -> void:
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	v2._show_tab(v2.PAGE_MIXED)
	await get_tree().process_frame
	await get_tree().process_frame
	var cells := _collect_meta_buttons(v2._pages[v2.PAGE_MIXED], "cell_btn", [])
	assert_gte(cells.size(), 56, "交叉表应有 56 格")
	var actionable := 0
	for c in cells:
		var btn := c as Button
		if btn.disabled:
			continue
		actionable += 1
		assert_eq(btn.focus_mode, Control.FOCUS_ALL,
				"可点的交叉格应能获得焦点（键盘/手柄导航的前提）")
		assert_true(btn.has_theme_stylebox_override("focus"),
				"焦点态必须有可见样式，否则方向键走到哪看不见")
	assert_gte(actionable, 56, "约束×线索表的格子应全部可点")


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
		var shape_n := _count_shape_cards(v2)
		assert_eq(rects.size(), 24 + shape_n,
				"%s：单项变体页应有 24 张官方算子卡 + %d 张形状卡" % [vp, shape_n])
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


# LS8：三张交叉表的格子都不得互相重叠，且整表能放进设计分辨率（1280 宽不留横向滚动条）
func test_ls8_matrix_cells_do_not_overlap() -> void:
	var v2 = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(v2)
	v2.anchor_right = 0.0
	v2.anchor_bottom = 0.0
	v2.size = Vector2(1280, 720)
	v2._show_tab(v2.PAGE_MIXED)
	# 三张表的格子数：C 类 7×10、F 类 C(7,2)、T4 5×10
	var expect := [7 * 10, 7 * 6 / 2, 5 * 10]
	for tab in v2.MIXED_TABS:
		v2._on_mixed_switch(tab)
		await get_tree().process_frame
		await get_tree().process_frame
		var rects: Array = []
		_collect_rects(v2._pages[v2.PAGE_MIXED], "cell_btn", rects)
		assert_eq(rects.size(), int(expect[tab]),
				"第 %d 张表应有 %d 个格子" % [tab, int(expect[tab])])
		_assert_no_overlap(rects, "第 %d 张表的交叉格" % tab)
		# 列宽 × 列数 + 行首 + 列间距 + 页边距 ≤ 1280：否则右边一列会被裁掉
		var max_x := 0.0
		for r in rects:
			max_x = maxf(max_x, r.end.x)
		assert_true(max_x <= 1280.0,
				"第 %d 张表不得超出 1280 设计分辨率右侧（实际 %.1f）" % [tab, max_x])


# ---- Mod 关卡的小工具 ----

const DEF_LEVEL_NAME := "LsDir4N_01.json"


## 造一个「已生成关卡」成品（复制一个真实关卡当内容）。
func _write_mod_level() -> void:
	var dir_path := "user://mods/%s/levels" % DEF_MOD_ID
	DirAccess.make_dir_recursive_absolute(dir_path)
	var src := FileAccess.open("res://levels/classic_01.json", FileAccess.READ)
	if src == null:
		return
	var txt := src.get_as_text()
	src.close()
	var f := FileAccess.open("%s/%s" % [dir_path, DEF_LEVEL_NAME], FileAccess.WRITE)
	if f != null:
		f.store_string(txt)
		f.close()


func _remove_mod_level() -> void:
	var dir_path := "user://mods/%s/levels" % DEF_MOD_ID
	var d := DirAccess.open(dir_path)
	if d != null:
		d.remove(DEF_LEVEL_NAME)
	var parent := DirAccess.open("user://mods/%s" % DEF_MOD_ID)
	if parent != null:
		parent.remove("levels")


func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node as Button
	for c in node.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null
