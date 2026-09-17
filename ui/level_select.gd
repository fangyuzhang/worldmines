# level_select.gd —— 关卡选择：三个页面 + 变体关卡浮动弹窗
#
# 结构（v3.2 起按内容分页）：
#   页一 单项变体   经典基线 + 线索型 + 全局约束，卡片平铺（16 个，一屏放得下）；
#   页二 混合档     线索型 × 全局约束 交叉表（8 × 7 = 56 个），行 C 列 G，格子即变体；
#   页三 Mod        按 Mod 分组，数量随玩家加载变化；无 Mod 时显示空状态且页签隐藏。
#   弹窗            固定尺寸（切换内容不缩放）：尺寸选择栏 + 关卡网格同一容器框（选中蓝色高亮发光）
#                   + 网格右侧竖排分页圆点 + 右侧面板（通关统计 / 继续·开始游戏）。
#
# 为什么分页（而不是继续用一张径向节点图装下全部变体）：
#   三类内容的**数量级与性质都不同**——单项 16 个、混合档 56 个（且是正交组合）、
#   Mod 0~∞ 个。塞进同一屏时，为给 56 个混合档腾位置，单项变体也被迫缩小并滚动；
#   而交叉表本身就是索引（想看「和骑士有关的组合」看一行，想看「镜像类的」看一列），
#   56 个格子不需要搜索框，也不存在节点互相遮挡的可能。详见 HANDOFF 的选关页条目。
#
# 数据：每个模式 × 4 种棋盘尺寸（5×5/6×6/7×7/8×8）= 一套独立关卡列表（LEVELS_PER_SET 关）。
#      关卡由种子确定性生成（同 seed 必同盘），首次进入某套时预置前若干关为已通关（模拟存档）。
extends Control

# ===== 常量 =====
# 序列相关的常量统一托管在 LevelSequence（终局页要靠它算「下一关」，两处必须同源）。
const LEVELS_PER_SET := LevelSequence.LEVELS_PER_SET   # 每套关卡数
const SIZES: Array = LevelSequence.SIZES
const PAGE_SIZE := 20           # 一页最多 20 关
const GRID_COLS := 5            # 网格 5 列
## 删线索阶段墙钟上限（ms），按尺寸分档。实测：≤7×7 用 3s 即可删到最优（4~10 线索）；
## 8×8 是瓶颈（3s→22 线索、4s→19、60s→9，收益递减）——3s 保证交互响应，线索略多但可接受；
## 9×9 单关 CP-SAT 约 6~12s（32 雷），3s 必超时失败，故单列 15s（GDD 03 号 8×8≤10s 之外）。
func _gen_timeout(size: int) -> int:
	if size >= 9:
		return 15000
	return 3000


## 生成耗时预览（按钮文案用）：按尺寸的实测经验值（classic 线索，自由模式口径）。
func _estimate_gen_seconds(size: int) -> int:
	if size >= 9:
		return 12
	if size >= 8:
		return 4
	return 1
const MOCK_CLEARED := 1         # 模拟存档：首次进入预置已通关数（3 关中预置 1 关，定位到第 2 关）
const SCROLL_THRESHOLD := 2.0   # 滚轮累积阈值（factor 单位）
const ANIM := 0.22              # 统一过渡时长（0.2~0.25s）
const POPUP_SIZE := Vector2(1040, 640)
const TILE := Vector2(116, 84)

# ===== 页面编号 =====
const PAGE_SINGLE := 0          # 页一：单项变体（经典 + 线索型 + 全局约束）
const PAGE_MIXED := 1           # 页二：混合档（线索 × 全局约束 交叉表）
const PAGE_MOD := 2             # 页三：Mod（按 Mod 分组，无 Mod 时页签隐藏）

# 变体表：**运行时从规则注册表派生**（见 ui/variant_catalog.gd）。
#
# 历史问题：这里原先是一张写死的 15 条常量表，引擎换变体（新增 knight、
# 新增 O/S/Z 系列 Mod 算子）后 UI 完全不知情 —— 也就是「引擎换了、UI 没动」。
# 现在改为启动时由 VariantCatalog.build_modes() 生成，成员随注册表实时变化，
# 结构（kind / id / name / tip / clue / globals / parents / enabled）保持不变，
# 下游的布局、绘制、进度键逻辑都无需改动。
var MODES: Array = []

# ===== 运行时状态 =====
# 页签（0 单项变体 / 1 混合档 / 2 Mod）。_tab_memory 用 static：
# 进对局再返回时回到离开时那一页，否则每次都把玩家弹回第一页。
static var _tab_memory := PAGE_SINGLE
var _tab := PAGE_SINGLE
var _tab_btns: Array[Button] = []
var _page_host: Control = null
var _pages: Array[Control] = []
## 变体 id -> MODES 下标（交叉表按 id 找条目，不依赖列表顺序）。
var _mode_index: Dictionary = {}
var _overlay: Control = null
var _popup: PanelContainer = null
var _popup_body: Control = null

var _mode_idx := -1                  # 当前弹窗所属模式（-1 = 未打开）
var _size_idx := 0
var _page := 0
var _selected := 0

# 弹窗内控件引用
var _size_btns: Array[Button] = []
var _frame: PanelContainer = null
var _grid_wrap: Control = null
var _grid: GridContainer = null
var _dots_box: VBoxContainer = null
var _stat_label: Label = null
var _play_btn: Button = null
var _title_label: Label = null

var _scroll_accum := 0.0

## 弹窗关闭动画期间禁止重开（原实现把 _overlay 立刻置 null，
## 动画的 0.22s 内再点节点就会叠出第二个弹窗）。
var _popup_closing := false

## Mod 加载 / 卸载后注册表已变，但弹窗开着时不便重建节点 → 记脏标记，关闭时补建。
var _modes_dirty := false

## 演示用「已通关」记录。**只在本次进程内有效、不落盘**。
## 历史 bug：这些记录原先直接写进真实的 ProgressStore（user://progress.json），
## 于是首次进入任何变体×尺寸都会永久留下一条「20.00 秒通关」的假数据，
## 还会连带解锁下一关——演示脚手架污染了玩家存档。
static var _mock_cleared: Dictionary = {}


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	_tab = _tab_memory
	_refresh_modes()      # 变体表必须在建页之前生成：页内容 = MODES 的派生
	_build_ui()
	_consume_pending_focus()
	# Mod 加载 / 卸载 → 注册表变化 → 选关页内容实时增减（卸载时 mod_api 会注销其规则）
	ModAPI.events.on(EventBus.MOD_LOADED, _on_mods_changed)


## Mod 生命周期回调：弹窗开着时只记脏标记（不打断玩家），关闭后再重建。
func _on_mods_changed(_payload: Variant = null) -> void:
	if _overlay != null or _popup_closing:
		_modes_dirty = true
		return
	_rebuild_all()


## 注册表变化后的统一重建：变体表 + 三页内容。
func _rebuild_all() -> void:
	_refresh_modes()
	_rebuild_pages()


## 从规则注册表重算变体表（页面/交叉表都按它派生）。
func _refresh_modes() -> void:
	MODES = VariantCatalog.build_modes(Vector2i(SIZES[_size_idx], SIZES[_size_idx]),
			LevelSequence.mine_count(SIZES[_size_idx]))
	_mode_index.clear()
	for i in MODES.size():
		_mode_index[str((MODES[i] as Dictionary)["id"])] = i


## 终局页「下一关」交接过来的意图：直接展开对应变体×尺寸的关卡弹窗。
## 选关页默认就会把选中项定位到「最新解锁关卡」，所以玩家看到的就是下一关已被选中。
func _consume_pending_focus() -> void:
	var focus: Dictionary = LevelSequence.take_focus()
	if focus.is_empty():
		return
	var mode_id := str(focus.get("mode", ""))
	var want_size := int(focus.get("size", 0))
	for i in MODES.size():
		if str(MODES[i]["id"]) != mode_id:
			continue
		_show_tab(_page_of(MODES[i]))   # 先翻到该变体所在的页，再开它的弹窗
		var size_i: int = SIZES.find(want_size)
		_open_popup(i)
		if size_i >= 0:
			_size_idx = size_i
			_ensure_mock()
			_refresh_popup()
		return


## 通关判定：真实存档 + 进程内演示记录。
func _is_cleared(key: String) -> bool:
	if bool(_mock_cleared.get(key, false)):
		return true
	return ProgressStore.is_cleared(key)


## 跳过判定（失败终局「跳过本关」）。跳过只解锁下一关，不计入通关统计。
func _is_skipped(key: String) -> bool:
	return ProgressStore.is_skipped(key)


# ==================== 主界面：网状节点图 ====================

func _build_ui() -> void:
	# 顶部标题
	var title := Label.new()
	title.text = "选择关卡"
	title.add_theme_font_size_override("font_size", 28)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 14
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	# 返回按钮（左上）
	var back := Button.new()
	back.text = "返回"
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size = Vector2(96, 42)
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	back.offset_left = 24
	back.offset_top = 14
	back.set_meta("std_btn", true)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
	add_child(back)

	# 页签栏（三个页面各一个标签）
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bar.offset_left = 24
	bar.offset_right = -24
	bar.offset_top = 58
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 10)
	add_child(bar)
	for spec in [["单项变体", PAGE_SINGLE], ["混合档", PAGE_MIXED], ["Mod", PAGE_MOD]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(148, 42)
		# 选中态由 _style_choice 负责；打标记让 _apply_theme 不要把它刷回默认按钮样式
		b.set_meta("choice_btn", true)
		b.pressed.connect(_show_tab.bind(int(spec[1])))
		bar.add_child(b)
		_tab_btns.append(b)
		UiTheme.bind_hover(b, 1.04)

	# 页容器：页签以下的整块区域（滚动由各页自己的 ScrollContainer 负责）
	_page_host = Control.new()
	_page_host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_page_host.offset_left = 8
	_page_host.offset_right = -8
	_page_host.offset_top = 110
	_page_host.offset_bottom = -8
	add_child(_page_host)

	_rebuild_pages()
	_apply_theme()


# ---------- 页签 / 页面管理 ----------

## 切换当前页（页签点击、焦点交接、Mod 卸载回退都走这里）。
func _show_tab(t: int) -> void:
	if t < 0 or t >= _pages.size():
		return
	# Mod 页在「一个 Mod 都没加载」时不可达（页签已隐藏，这里防程序调用 / 键盘触发）
	if t == PAGE_MOD and ModAPI.list_mods().is_empty():
		t = PAGE_SINGLE
	_tab = t
	_tab_memory = t
	for i in _pages.size():
		if is_instance_valid(_pages[i]):
			_pages[i].visible = (i == t)
	for i in _tab_btns.size():
		_style_choice(_tab_btns[i], i == t)


## 该变体属于哪一页。**三种数量级不同的内容各占一页**：
##   单项变体 16 个（一屏放得下）、混合档 56 个（正交组合，交叉表即索引）、
##   Mod 数量随玩家加载任意增长。混在一页的结果是：为了给 56 个腾地方，
##   单项变体也得跟着缩小 + 滚动，而玩家通常只想打开其中一个。
func _page_of(m: Dictionary) -> int:
	if str(m.get("kind", "clue")) == "mixed":
		return PAGE_MIXED
	if str(m.get("source", "builtin")) == "mod":
		return PAGE_MOD   # Mod 变体一律进 Mod 页（按来源分组，与它是线索还是约束无关）
	return PAGE_SINGLE


## 重建三页内容（Mod 加载 / 卸载、主题切换、首次进入时调用）。
func _rebuild_pages() -> void:
	for p in _pages:
		if is_instance_valid(p):
			p.queue_free()
	_pages.clear()
	_pages.append(_build_single_page())
	_pages.append(_build_mixed_page())
	_pages.append(_build_mod_page())
	for p in _pages:
		_page_host.add_child(p)
	# Mod 页签的可见性：没有 Mod 就整个隐藏（不是置灰——空页签只会让人点进去看空）
	if _tab_btns.size() > PAGE_MOD:
		_tab_btns[PAGE_MOD].visible = not ModAPI.list_mods().is_empty()
	_show_tab(_tab)


## 页体外壳：滚动容器 + 内边距。窗口小于内容时滚动，大于时留白（不做缩放）。
## allow_h_scroll：交叉表在窄窗口下必须能横向滚动（关掉就变成截断右边一列）。
func _make_page_shell(allow_h_scroll: bool = false) -> Array:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if allow_h_scroll \
			else ScrollContainer.SCROLL_MODE_DISABLED
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 22)
	scroll.add_child(margin)
	return [scroll, margin]


# ---------- 页一：单项变体（卡片平铺） ----------

func _build_single_page() -> Control:
	var shell := _make_page_shell()
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 14)
	# 每行居中：流式容器默认 ALIGNMENT_BEGIN，卡片宽度不能整除可视宽时
	# 余量会全部堆到右侧（实测 4 列：左留白 0px / 右留白 90px），看着是「没居中」。
	# 居中后余量左右均分；最后一行若不满行也居中（last_wrap_alignment 默认继承）。
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	(shell[1] as MarginContainer).add_child(flow)
	for i in MODES.size():
		var m: Dictionary = MODES[i]
		if _page_of(m) != PAGE_SINGLE:
			continue
		flow.add_child(_make_card(i, m))
	return shell[0]


## 变体卡片：名称 + 编号 + 规则一句话 + 底部进度条。
##
## 文字全部放在**子 Label** 里，按钮自身不带文字：Button 的最小尺寸由 text 撑出，
## 而 Button 不支持 autowrap（只有 Label 有）——直接把长说明塞进 text 会把卡片撑到
## 300+ px，每行只排得下 3 张、第 16 张被挤出可视区（实测踩过）。
## 子 Label 走 autowrap，宽度则由 custom_minimum_size 唯一决定。
const CARD_W := 272
const CARD_H := 104


func _make_card(mode_idx: int, m: Dictionary) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.focus_mode = Control.FOCUS_NONE
	btn.tooltip_text = _card_tooltip(m)
	btn.set_meta("card_btn", true)
	btn.pressed.connect(_open_popup.bind(mode_idx))
	_style_card(btn)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 点击必须落到按钮上
	box.add_theme_constant_override("separation", 4)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 10
	box.offset_right = -10
	box.offset_top = 8
	box.offset_bottom = -15                          # 给底部进度条留位置
	btn.add_child(box)

	var title := Label.new()
	title.text = "%s  %s" % [str(m["name"]), str(m["tip"])]
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", ThemeManager.text())
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var desc := Label.new()
	desc.text = VariantCatalog.rule_text(str(m["id"]))
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", ThemeManager.text_secondary())
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # 中文断行按字，标点不落行首
	desc.max_lines_visible = 3
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(desc)

	UiTheme.bind_hover(btn, 1.03)
	_attach_progress(btn, str(m["id"]))
	return btn


func _card_tooltip(m: Dictionary) -> String:
	var lines: Array[String] = ["%s（%s）" % [str(m["name"]), str(m["tip"])]]
	var text := VariantCatalog.rule_text(str(m["id"]))
	if not text.is_empty():
		lines.append(text)
	if str(m.get("source", "builtin")) == "mod":
		lines.append("来自已加载的 Mod，可在主菜单「模组」页管理 / 卸载")
	lines.append("已通关 %d / %d" % [_cleared_total(str(m["id"])), SIZES.size() * LEVELS_PER_SET])
	return "\n".join(lines)


# ---------- 页二：混合档（线索 × 全局约束 交叉表） ----------

## 交叉表：行 = 线索型（C 类），列 = 全局约束（G 类），交叉格 = 两者的混合变体。
## 表本身就是索引：想找「和骑士有关的组合」看一行，想找「镜像类的」看一列——
## 56 个组合不需要搜索框。排布交给 GridContainer，故天然不会出现节点互相遮挡。
# 交叉格 / 表头尺寸：行首 130 + 7 列 × 142 + 列间距 7×6 = 1166 → 加页边距 44 后
# 仍能完整放进 1280 设计分辨率（不留横向滚动条）。窄窗口由 _make_page_shell(true) 兜底。
const CELL_W := 142
const ROW_HEAD_W := 130


## 混合档页有两种表，用右上角开关切换：
##   ① 约束 × 线索   行 = C 类、列 = G 类（56 格）；
##   ② 约束 × 约束   行 / 列都是 G 类，只填右上三角（C(7,2) = 21 对，每对只出现一次）。
## 两者共用同一套表头 / 格子 / 进度渲染，切换只换轴与格子来源。
var _mixed_gg := false
var _mixed_host: VBoxContainer = null
var _mixed_hint: Label = null
var _mixed_btns: Array[Button] = []


func _build_mixed_page() -> Control:
	var shell := _make_page_shell(true)
	var margin: MarginContainer = shell[1]
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	margin.add_child(vb)

	# 顶部：说明（随表切换重写）+ 两张表的切换开关
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	vb.add_child(bar)

	_mixed_hint = Label.new()
	_mixed_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mixed_hint.add_theme_font_size_override("font_size", 13)
	_mixed_hint.set_meta("secondary", true)
	bar.add_child(_mixed_hint)

	_mixed_btns.clear()   # 主题切换会整页重建，旧按钮引用必须丢弃
	for spec in [["1 约束 · 约束×线索", false], ["2 约束 · 约束×约束", true]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(176, 36)
		b.pressed.connect(_on_mixed_switch.bind(bool(spec[1])))
		bar.add_child(b)
		_mixed_btns.append(b)
		UiTheme.bind_hover(b, 1.04)

	_mixed_host = VBoxContainer.new()
	_mixed_host.add_theme_constant_override("separation", 12)
	vb.add_child(_mixed_host)
	_fill_mixed_table()
	return shell[0]


func _on_mixed_switch(gg: bool) -> void:
	_mixed_gg = gg
	_fill_mixed_table()


func _fill_mixed_table() -> void:
	if _mixed_host == null:
		return
	for c in _mixed_host.get_children():
		c.queue_free()
	_mixed_host.add_child(_gg_table() if _mixed_gg else _gc_table())
	for i in _mixed_btns.size():
		_style_choice(_mixed_btns[i], (i == 1) == _mixed_gg)


## 表一：约束 × 线索（行 C / 列 G，8 × 7 = 56 格）。
func _gc_table() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 10)
	var clues := VariantCatalog.mixed_clue_ids()
	var globals := VariantCatalog.mixed_global_ids()
	_mixed_hint.text = "行 = 线索型（C 类）　列 = 全局约束（G 类）　交叉格 = 两者叠加的混合变体　·　点击任意格开这一关"

	var table := GridContainer.new()
	table.columns = globals.size() + 1
	table.add_theme_constant_override("h_separation", 6)
	table.add_theme_constant_override("v_separation", 6)
	table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 表整体居中（默认左贴会右侧多出余量）
	wrap.add_child(table)

	# 表头行：左上角占位 + 每个全局约束一列
	table.add_child(_matrix_corner("线索型 ＼ 全局约束"))
	for j in globals.size():
		table.add_child(_matrix_head("G%d" % (j + 1), globals[j], false))
	# 每个线索型一行：行首 + 每列一格
	for i in clues.size():
		table.add_child(_matrix_head("C%d" % (i + 1), clues[i], true))
		for gid in globals:
			table.add_child(_matrix_cell(clues[i], gid))

	wrap.add_child(_matrix_note("共 %d 个组合（%d 线索 × %d 约束）　·　全部经可行性真值查询：数学均可行" % [
			clues.size() * globals.size(), clues.size(), globals.size()]))
	return wrap


## 表二：约束 × 约束（行 / 列都是 G，21 对只出现一次 → 只填右上三角）。
## 左下留白不是省略：每一对都已在右上出现，重复填只会让人以为还有第二组组合。
func _gg_table() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 10)
	var globals := VariantCatalog.mixed_global_ids()
	_mixed_hint.text = "行 / 列 = 全局约束（G 类）　右上三角格 = 两个约束同时生效（每对只出现一次）　·　点击任意格开这一关"

	var table := GridContainer.new()
	table.columns = globals.size() + 1
	table.add_theme_constant_override("h_separation", 6)
	table.add_theme_constant_override("v_separation", 6)
	table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 表整体居中（与约束×线索表一致）
	wrap.add_child(table)

	table.add_child(_matrix_corner("约束 ＼ 约束"))
	for j in globals.size():
		table.add_child(_matrix_head("G%d" % (j + 1), globals[j], false))
	for i in globals.size():
		table.add_child(_matrix_head("G%d" % (i + 1), globals[i], true))
		for j in globals.size():
			if j > i:
				table.add_child(_gg_cell(globals[i], globals[j]))
			else:
				# 对角线（同一约束不可重复）与左下（与右上同一对）都不产生组合
				table.add_child(_matrix_blank())

	var pairs := globals.size() * (globals.size() - 1) / 2
	var alive := VariantCatalog.gg_all(Vector2i(SIZES[_size_idx], SIZES[_size_idx]),
			LevelSequence.mine_count(SIZES[_size_idx])).size()
	wrap.add_child(_matrix_note("共 %d 对（C(%d,2)）　·　%d 个可玩（判逻辑冗余的不产生，格子置灰）　·　部分尺寸无解由弹窗内的尺寸按钮自动禁用" % [
			pairs, globals.size(), alive]))
	return wrap


func _matrix_corner(text: String) -> Control:
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 13)
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.custom_minimum_size = Vector2(ROW_HEAD_W, 40)
	lb.set_meta("secondary", true)
	return lb


## 交叉表里的空位（对角线 / 左下三角）：占位保证列宽与行高不变。
func _matrix_blank() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(CELL_W, 48)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _matrix_note(text: String) -> Label:
	var note := Label.new()
	note.text = text
	note.add_theme_font_size_override("font_size", 13)
	note.set_meta("secondary", true)
	return note


## 表头（行首 / 列头）：编号 + 名称，悬停显示规则全文。
## code 由调用方按轴序给出（不在表头里反查目录：那会为每个表头重建一次注册表清单）。
func _matrix_head(code: String, rule_id: String, is_row: bool) -> Control:
	var lb := Label.new()
	lb.text = ("%s %s" % [code, VariantCatalog.display_name(rule_id)])
	lb.add_theme_font_size_override("font_size", 13)
	lb.tooltip_text = VariantCatalog.display_name(rule_id) + "\n" + VariantCatalog.rule_text(rule_id)
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if is_row:
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lb.custom_minimum_size = Vector2(ROW_HEAD_W, 48)
	else:
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.custom_minimum_size = Vector2(CELL_W, 40)
	return lb


## 交叉格：该线索 × 该约束的混合变体。点开即进它自己的选关弹窗。
func _matrix_cell(clue_id: String, global_id: String) -> Button:
	var mode_id := "%s_%s" % [global_id, clue_id]
	var btn := Button.new()
	var mi: int = int(_mode_index.get(mode_id, -1))
	btn.text = "%s·%s" % [VariantCatalog.display_name(global_id), VariantCatalog.display_name(clue_id)]
	btn.custom_minimum_size = Vector2(CELL_W, 48)
	btn.clip_text = true   # 名称再长也不许撑宽格子（撑宽会把整表挤到横向滚动）
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 12)
	btn.set_meta("cell_btn", true)
	_style_card(btn)
	if mi < 0:
		# 组合被判 forbid（逻辑冗余/矛盾）→ 不产生条目：占位显示、不可点，避免死格
		btn.disabled = true
		btn.tooltip_text = "%s·%s\n该组合逻辑冗余或矛盾，不产生混合档" % [
				VariantCatalog.display_name(global_id), VariantCatalog.display_name(clue_id)]
		return btn
	var m: Dictionary = MODES[mi]
	var lines: Array[String] = ["%s（%s）" % [str(m["name"]), str(m["tip"])],
			VariantCatalog.rule_text(global_id), VariantCatalog.rule_text(clue_id)]
	if str(m.get("verdict", "ok")) == RuleSignature.WARN:
		lines.append("⚠ 该组合的可行域偏窄（约束与线索作用域叠加），生成更慢")
	lines.append("已通关 %d / %d" % [_cleared_total(mode_id), SIZES.size() * LEVELS_PER_SET])
	btn.tooltip_text = "\n".join(lines)
	btn.pressed.connect(_open_popup.bind(mi))
	UiTheme.bind_hover(btn, 1.04)
	_attach_progress(btn, mode_id)
	return btn


## 双约束格：两条全局约束同时生效（线索走经典）。与 _matrix_cell 同构，只是轴不同。
func _gg_cell(g1: String, g2: String) -> Button:
	var mode_id := "%s_%s" % [g1, g2]
	var btn := Button.new()
	var mi: int = int(_mode_index.get(mode_id, -1))
	btn.text = "%s·%s" % [VariantCatalog.display_name(g1), VariantCatalog.display_name(g2)]
	btn.custom_minimum_size = Vector2(CELL_W, 48)
	btn.clip_text = true   # 名称再长也不许撑宽格子（撑宽会把整表挤到横向滚动）
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 12)
	btn.set_meta("cell_btn", true)
	_style_card(btn)
	if mi < 0:
		# 判 forbid（逻辑冗余 / 矛盾，如 mx 蕴含 ep）→ 不产生条目：置灰占位，避免死格
		btn.disabled = true
		btn.tooltip_text = "%s·%s\n两个约束叠加时后者完全冗余，不产生混合档" % [
				VariantCatalog.display_name(g1), VariantCatalog.display_name(g2)]
		return btn
	var m: Dictionary = MODES[mi]
	var lines: Array[String] = ["%s（%s）" % [str(m["name"]), str(m["tip"])],
			VariantCatalog.rule_text(g1), VariantCatalog.rule_text(g2)]
	if str(m.get("verdict", "ok")) == RuleSignature.WARN:
		lines.append("⚠ 两条全局约束叠加，可行域偏窄——部分尺寸无解，已由弹窗内的尺寸按钮禁用")
	lines.append("已通关 %d / %d" % [_cleared_total(mode_id), SIZES.size() * LEVELS_PER_SET])
	btn.tooltip_text = "\n".join(lines)
	btn.pressed.connect(_open_popup.bind(mi))
	UiTheme.bind_hover(btn, 1.04)
	_attach_progress(btn, mode_id)
	return btn


# ---------- 页三：Mod（按来源分组） ----------

## Mod 变体独立成页：数量由玩家装了什么决定，不占用内置变体的版面——
## 玩家装 3 个还是 30 个 Mod，「单项变体」页永远长一个样。
func _build_mod_page() -> Control:
	var shell := _make_page_shell()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	(shell[1] as MarginContainer).add_child(vb)

	var ids := ModAPI.list_mods()
	if ids.is_empty():
		vb.add_child(_mod_empty_state())
		return shell[0]

	var total := 0
	for i in MODES.size():
		if _page_of(MODES[i]) == PAGE_MOD:
			total += 1
	var def_total := 0
	for id in ids:
		def_total += (ModAPI.mod_info(id).get("defs", []) as Array).size()
	var hint := Label.new()
	hint.text = "已加载 %d 个 Mod：%d 个可玩变体 + %d 个 Def 规则　·　变体自动出现在本页，卸载后自动消失" % [
			ids.size(), total, def_total]
	hint.add_theme_font_size_override("font_size", 14)
	hint.set_meta("secondary", true)
	vb.add_child(hint)

	for mod_id in ids:
		vb.add_child(_mod_section(mod_id))
	return shell[0]


## 单个 Mod 一节：标题（名称 / 形式 / 状态）+ 它注册的可玩变体卡片。
func _mod_section(mod_id: String) -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 8)

	var info := ModAPI.mod_info(mod_id)
	var manifest: Dictionary = info.get("manifest", {})
	var entry: Dictionary = manifest.get("entry", {})
	var runtime := str(entry.get("runtime", ""))
	var head := Label.new()
	head.text = "%s　[%s]　%s" % [str(manifest.get("name", mod_id)),
			_mod_runtime_label(runtime), _mod_state_label(str(info.get("state", "")))]
	head.add_theme_font_size_override("font_size", 16)
	wrap.add_child(head)

	# Def 行放在分组 VBox 里（**不能**进下面的卡片流）：autowrap 的 Label 最小宽度≈0，
	# 进流式容器会被压成一列单字（实测踩过）。
	var mod_defs: Array = info.get("defs", [])
	if not mod_defs.is_empty():
		wrap.add_child(_mod_def_label(mod_defs))

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 14)
	flow.alignment = FlowContainer.ALIGNMENT_CENTER   # 与单项变体页一致：每行居中，不右侧堆积留白
	wrap.add_child(flow)

	var count := 0
	for i in MODES.size():
		var m: Dictionary = MODES[i]
		if _page_of(m) != PAGE_MOD:
			continue
		if ModAPI.find_rule_owner(str(m["id"])) != mod_id:
			continue
		flow.add_child(_make_card(i, m))
		count += 1
	if count == 0 and mod_defs.is_empty():
		var note := Label.new()
		note.text = "该 Mod 未注册可玩变体（仅数据 / 资源）"
		note.add_theme_font_size_override("font_size", 13)
		note.set_meta("secondary", true)
		flow.add_child(note)
	return wrap


## Def 规则行。Def 注册进的是 DefEngine 而不是规则注册表，因此**不会**出现在本页的变体表里，
## 但它确实提供了可玩内容（主菜单「模组」页可为其生成关卡）——如实列出，
## 否则玩家看到空白分组会以为装了个空包。
func _mod_def_label(defs: Array) -> Control:
	var clues: Array[String] = []
	var constraints: Array[String] = []
	for d in defs:
		var n := str((d as Dictionary).get("name", ""))
		if n == "":
			continue
		if str((d as Dictionary).get("type", "")) == "clue":
			clues.append(n)
		else:
			constraints.append(n)
	var parts: Array[String] = []
	if not clues.is_empty():
		parts.append("线索 %d 个（%s）" % [clues.size(), ", ".join(clues)])
	if not constraints.is_empty():
		parts.append("约束 %d 个（%s）" % [constraints.size(), ", ".join(constraints)])
	var lb := Label.new()
	lb.text = "Def 规则：%s　·　在主菜单「模组」页可为其生成关卡" % "　".join(parts)
	lb.add_theme_font_size_override("font_size", 13)
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lb.set_meta("secondary", true)
	return lb


func _mod_runtime_label(runtime: String) -> String:
	match runtime:
		ManifestParser.RUNTIME_DEF:
			return "Def 数据包"
		ManifestParser.RUNTIME_WASM:
			return "wasm Mod"
		ManifestParser.RUNTIME_GDScript:
			return "代码 Mod"
	return runtime if runtime != "" else "未知形式"


func _mod_state_label(state: String) -> String:
	match state:
		ModAPI.STATE_ENABLED:
			return "已启用"
		ModAPI.STATE_DISABLED:
			return "已禁用"
		ModAPI.STATE_CRASHED:
			return "已崩溃隔离"
	return "已加载"


func _mod_empty_state() -> Control:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.card().darkened(0.2)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = ThemeManager.grid_line()
	panel.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.add_theme_constant_override("margin_left", 20)
	vb.add_theme_constant_override("margin_right", 20)
	vb.add_theme_constant_override("margin_top", 22)
	vb.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "还没有加载任何 Mod"
	title.add_theme_font_size_override("font_size", 18)
	vb.add_child(title)

	var body := Label.new()
	body.text = "把 Mod 目录放进 mods 文件夹后重进本页即可，变体会自动出现在这里。\n" + \
			ProjectSettings.globalize_path(ModAPI.MODS_DIR) + "\n" + \
			"支持三种形式：defs/*.json 数据包（纯声明）、GDScript 代码 Mod、wasm 黑盒 Mod（沙箱运行）。"
	body.add_theme_font_size_override("font_size", 13)
	body.set_meta("secondary", true)
	vb.add_child(body)
	return panel


# ---------- 卡片 / 进度 ----------

## 卡片与交叉格共用的紧凑样式（标准按钮内边距 16/8 会把交叉格撑到相互挤压）。
func _style_card(btn: Button) -> void:
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(6)
		sb.set_border_width_all(1)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 6
		sb.content_margin_bottom = 8   # 给底部进度条留位置
		match state:
			"hover":
				sb.bg_color = ThemeManager.card().lightened(0.06)
				sb.border_color = ThemeManager.accent()
			"pressed":
				sb.bg_color = ThemeManager.accent().darkened(0.35)
				sb.border_color = ThemeManager.accent()
			_:
				sb.bg_color = ThemeManager.card()
				sb.border_color = ThemeManager.grid_line()
		btn.add_theme_stylebox_override(state, sb)
	btn.add_theme_color_override("font_color", ThemeManager.text())
	btn.add_theme_color_override("font_disabled_color", ThemeManager.text_secondary().darkened(0.3))


## 卡片 / 交叉格底部的细进度条（该变体全部尺寸合计的已通关比例）。
## 只在有进度时才画：变体这么多，玩家需要一眼看出「哪些还没碰过」。
func _attach_progress(btn: Button, mode_id: String) -> void:
	var done := _cleared_total(mode_id)
	if done <= 0:
		return
	var total := SIZES.size() * LEVELS_PER_SET
	btn.draw.connect(func():
		# 必须显式写成 btn.draw_rect(...)：GDScript 的 lambda 里 self 是外层对象
		#（= 选关页），直接 draw_rect 会画到「正在绘制的那个节点」之外 → 报 !drawing。
		var w: float = maxf(btn.size.x - 16.0, 1.0)
		var y: float = btn.size.y - 7.0
		btn.draw_rect(Rect2(Vector2(8.0, y), Vector2(w, 3.0)), ThemeManager.grid_line(), true)
		btn.draw_rect(Rect2(Vector2(8.0, y), Vector2(w * float(done) / float(total), 3.0)),
				ThemeManager.safe(), true))


## 该变体在各尺寸下的已通关总数（0 ~ SIZES.size() * LEVELS_PER_SET）。
func _cleared_total(mode_id: String) -> int:
	var n := 0
	for s in SIZES:
		for i in LEVELS_PER_SET:
			if _is_cleared(LevelSequence.level_key(mode_id, s, i)):
				n += 1
	return n





# ==================== 弹窗 ====================

func _open_popup(mode_idx: int) -> void:
	if _overlay != null or _popup_closing:
		return
	_mode_idx = mode_idx
	_size_idx = 0
	_page = 0
	_selected = 0
	_scroll_accum = 0.0
	_ensure_mock()

	# 遮罩（点击外部关闭）
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_close_popup())
	_overlay.add_child(shade)

	# 弹窗主体（固定尺寸）
	_popup = PanelContainer.new()
	_popup.custom_minimum_size = POPUP_SIZE
	_popup.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_popup.position = -POPUP_SIZE * 0.5
	_popup.pivot_offset = POPUP_SIZE * 0.5
	_overlay.add_child(_popup)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 0)
	_popup.add_child(root)

	# 标题栏
	var head := HBoxContainer.new()
	head.custom_minimum_size = Vector2(0, 58)
	head.add_theme_constant_override("margin_left", 22)
	head.add_theme_constant_override("margin_right", 18)
	root.add_child(head)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title_label)

	var close := Button.new()
	close.text = "✕"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(40, 40)
	close.set_meta("std_btn", true)
	close.pressed.connect(_close_popup)
	head.add_child(close)

	# 内容区：左（棋盘框） + 右（面板）
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	body.add_theme_constant_override("margin_left", 18)
	body.add_theme_constant_override("margin_right", 18)
	body.add_theme_constant_override("margin_bottom", 18)
	root.add_child(body)
	_popup_body = body

	_build_left(body)
	_build_right(body)

	_refresh_popup()

	# 入场动画：缩放 + 淡入
	_popup.scale = Vector2(0.92, 0.92)
	_popup.modulate.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_popup, "scale", Vector2.ONE, ANIM).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_popup, "modulate:a", 1.0, ANIM)
	_apply_theme()


## 左侧：棋盘框（尺寸选择栏 + 关卡网格 + 分页圆点），整体蓝色高亮发光。
func _build_left(parent: Node) -> void:
	_frame = PanelContainer.new()
	_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.custom_minimum_size = Vector2(700, 0)
	# PanelContainer 默认 mouse_filter=IGNORE，不设 STOP 收不到滚轮事件
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame.gui_input.connect(_on_frame_input)
	parent.add_child(_frame)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.add_theme_constant_override("margin_left", 16)
	vbox.add_theme_constant_override("margin_right", 16)
	vbox.add_theme_constant_override("margin_top", 14)
	vbox.add_theme_constant_override("margin_bottom", 16)
	_frame.add_child(vbox)

	# 尺寸选择栏
	var size_bar := HBoxContainer.new()
	size_bar.add_theme_constant_override("separation", 10)
	vbox.add_child(size_bar)

	for i in SIZES.size():
		var s: int = SIZES[i]
		var b := Button.new()
		b.text = "%d×%d" % [s, s]
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(104, 40)
		b.pressed.connect(_on_size_selected.bind(i))
		size_bar.add_child(b)
		_size_btns.append(b)
		UiTheme.bind_hover(b, 1.04)

	# 网格区（网格 + 右侧分页圆点）
	var grid_row := HBoxContainer.new()
	grid_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid_row.add_theme_constant_override("separation", 12)
	vbox.add_child(grid_row)

	_grid_wrap = Control.new()
	_grid_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid_wrap.clip_contents = true
	grid_row.add_child(_grid_wrap)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLS
	_grid.add_theme_constant_override("h_separation", 14)
	_grid.add_theme_constant_override("v_separation", 14)
	_grid.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_grid_wrap.add_child(_grid)

	_dots_box = VBoxContainer.new()
	_dots_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_dots_box.add_theme_constant_override("separation", 10)
	_dots_box.custom_minimum_size = Vector2(24, 0)
	grid_row.add_child(_dots_box)


## 右侧面板：通关统计 + 继续/开始游戏按钮。
func _build_right(parent: Node) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(280, 0)
	parent.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 16)
	vbox.add_theme_constant_override("margin_left", 18)
	vbox.add_theme_constant_override("margin_right", 18)
	vbox.add_theme_constant_override("margin_top", 18)
	vbox.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(vbox)

	var cap := Label.new()
	cap.text = "通关统计"
	cap.add_theme_font_size_override("font_size", 18)
	vbox.add_child(cap)

	_stat_label = Label.new()
	_stat_label.add_theme_font_size_override("font_size", 26)
	vbox.add_child(_stat_label)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	_play_btn = Button.new()
	_play_btn.custom_minimum_size = Vector2(0, 54)
	_play_btn.focus_mode = Control.FOCUS_NONE
	_play_btn.set_meta("std_btn", true)
	_play_btn.pressed.connect(_on_play)
	vbox.add_child(_play_btn)
	UiTheme.bind_hover(_play_btn, 1.03)


func _close_popup() -> void:
	if _overlay == null or _popup_closing:
		return
	var ov := _overlay
	_popup_closing = true
	_overlay = null
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_popup, "scale", Vector2(0.92, 0.92), ANIM)
	tw.tween_property(_popup, "modulate:a", 0.0, ANIM)
	tw.chain().tween_callback(func():
		ov.queue_free()
		_popup_closing = false
		# 弹窗开着期间若有 Mod 加载/卸载，此刻补建页面
		if _modes_dirty:
			_modes_dirty = false
			_rebuild_all())
	_size_btns.clear()
	_mode_idx = -1


# ==================== 弹窗内容刷新 ====================

## 该变体在该尺寸下是否可生成（R07 固定雷数下的数学可行性）。
## v2.9.3 起走 RuleFeasibility 真值查询（CP-SAT is_feasible + 缓存）——不再手写
## UNSAT 规则表（手写表曾漏掉 rl 6×6 / qd 6×6、8×8 导致玩家选中后永远转圈；
## 且新增/Mod 变体都需要同步手改，必然再漏）。真值查询对任何变体自动正确。
func _mode_feasible(mode: Dictionary, size: int) -> bool:
	# v3.0：候选雷数回退——标准值不可行但候选可行时，该尺寸仍可玩（生成侧自动用回退雷数）。
	# 全候选不可行才禁用（如 mx+rl 6×6：镜像+行锁在全部候选雷数下均矛盾）。
	return int(RuleFeasibility.resolve_mines(str(mode["clue"]), mode.get("globals", []), size)["mines"]) >= 0


func _refresh_popup() -> void:
	if _mode_idx < 0 or _grid == null:
		return
	var m: Dictionary = MODES[_mode_idx]
	# 当前尺寸对该变体不可行 → 自动切到最近的可行尺寸（避免「选中即必失败」状态）
	if not _mode_feasible(m, SIZES[_size_idx]):
		for i in SIZES.size():
			var cand: int = ( _size_idx + i ) % SIZES.size()
			if _mode_feasible(m, SIZES[cand]):
				_size_idx = cand
				break
	_title_label.text = "%s · %d×%d" % [m["name"], SIZES[_size_idx], SIZES[_size_idx]]

	# 尺寸按钮高亮 + 可行性禁用（不可行组合按钮置灰 + tooltip 说明原因，点不了）
	for i in _size_btns.size():
		_style_choice(_size_btns[i], i == _size_idx)
		var ok := _mode_feasible(m, SIZES[i])
		_size_btns[i].disabled = not ok
		_size_btns[i].tooltip_text = "" if ok else \
			"该变体在 %d×%d（%d 雷）下数学上无解——请换尺寸或换变体" % [
					SIZES[i], SIZES[i], LevelSequence.mine_count(SIZES[i])]
	_style_frame()

	# 分页：定位到「最新解锁关卡」所在页（切换尺寸时重置）
	var page_count := _page_count()
	_page = clampi(_page, 0, page_count - 1)
	_selected = _latest_unlocked()
	_page = floori(float(_selected) / float(PAGE_SIZE))

	_rebuild_grid()
	_rebuild_dots()
	_refresh_stat()


func _rebuild_grid() -> void:
	for c in _grid.get_children():
		c.queue_free()
	var start := _page * PAGE_SIZE
	var end := mini(start + PAGE_SIZE, LEVELS_PER_SET)
	for i in range(start, end):
		_grid.add_child(_make_tile(i))
	# 关卡不足时网格留白：补足空占位，保证方块尺寸统一、从左到右从上到下排列
	var shown := end - start
	for _k in range(PAGE_SIZE - shown):
		var ph := Control.new()
		ph.custom_minimum_size = TILE
		_grid.add_child(ph)
	# 内容淡入
	_grid_wrap.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_grid_wrap, "modulate:a", 1.0, ANIM)


func _make_tile(idx: int) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = TILE
	btn.focus_mode = Control.FOCUS_NONE
	var unlocked := _is_unlocked(idx)
	var cleared := _is_cleared(_level_key(idx))
	# 跳过态必须与「已通关 ✓」区分：玩家看到「第 2 关没打勾却能进第 3 关」
	# 会当成 bug，所以给跳过单独的角标 ›（可回头补，补完就变 ✓）。
	var skipped := (not cleared) and _is_skipped(_level_key(idx))
	btn.text = str(idx + 1)
	if cleared:
		btn.text += "  ✓"
	elif skipped:
		btn.text += "  ›"
	elif not unlocked:
		btn.text = "🔒"
	btn.disabled = not unlocked
	btn.set_meta("idx", idx)  # 选中态刷新需要回读关卡序号
	btn.pressed.connect(_on_tile_pressed.bind(idx))
	_style_tile(btn, idx == _selected, cleared, skipped)
	UiTheme.bind_hover(btn, 1.05)
	return btn


func _rebuild_dots() -> void:
	for c in _dots_box.get_children():
		c.queue_free()
	var n := _page_count()
	for i in n:
		var d := Button.new()
		d.custom_minimum_size = Vector2(14, 14)
		d.focus_mode = Control.FOCUS_NONE
		d.pressed.connect(_go_page.bind(i))
		_style_dot(d, i == _page)
		_dots_box.add_child(d)


func _refresh_stat() -> void:
	var cleared := 0
	for i in LEVELS_PER_SET:
		if _is_cleared(_level_key(i)):
			cleared += 1
	_stat_label.text = "已通关 %d / %d" % [cleared, LEVELS_PER_SET]
	# 按钮：选中最新解锁关卡 → 继续游戏；手选其他 → 开始游戏；未开放变体 → 禁用
	if _mode_enabled():
		_play_btn.disabled = false
		_play_btn.text = "继续游戏" if _selected == _latest_unlocked() else "开始游戏"
	else:
		_play_btn.disabled = true
		_play_btn.text = "尚未开放"


func _go_page(p: int) -> void:
	var n := _page_count()
	var np := clampi(p, 0, n - 1)
	if np == _page:
		return
	_page = np
	_scroll_accum = 0.0
	_rebuild_grid()
	_rebuild_dots()


func _on_size_selected(i: int) -> void:
	if i == _size_idx:
		return
	_size_idx = i
	_page = 0
	_scroll_accum = 0.0
	_ensure_mock()
	_refresh_popup()  # 内部会重置分页并定位最新解锁关卡


func _on_tile_pressed(idx: int) -> void:
	if not _is_unlocked(idx):
		return
	_selected = idx
	for c in _grid.get_children():
		if c is Button:
			var i := int(c.get_meta("idx", -1))
			var key := _level_key(i)
			var done := _is_cleared(key)
			# 跳过态同样要刷新：不传的话点一下别的格子就会把 › 的样式冲掉
			_style_tile(c, i == _selected, done, (not done) and _is_skipped(key))
	_refresh_stat()


# ==================== 数据 / 进度 ====================

## 当前模式是否开放关卡（混合档 enabled=false：弹窗可看，但不生成/进入关卡）。
func _mode_enabled() -> bool:
	if _mode_idx < 0:
		return false
	return bool(MODES[_mode_idx].get("enabled", true))


func _level_key(idx: int) -> String:
	# 缓存/进度键不掺雷数：同 mode×size 的雷数由 resolve_mines 唯一确定（候选回退是
	# 确定性判定 + 缓存），且回退组合在旧版（固定标准雷数）下本就生成不出文件
	#（UNSAT），不存在「旧缓存与新雷数撞键」的歧义——无需为候选回退改键结构。
	var m: Dictionary = MODES[_mode_idx]
	return "gen://%s/%d/%d" % [m["id"], SIZES[_size_idx], idx]


func _level_seed(idx: int) -> int:
	# 确定性种子：同模式+尺寸+序号必得同一盘。
	# v3.1：改用模式 id / 尺寸边长的稳定哈希而非数组下标——插入新变体/尺寸
	# 不再改变所有后续模式的种子（「同 seed 同盘」承诺不因 MODES/SIZES 顺序变化失效）。
	# 雷数不掺入种子（GDD §8.1）：它由 mode×size 经候选回退唯一确定，见 _level_key 注释。
	return hash("%s|%d|%d" % [str(MODES[_mode_idx]["id"]), SIZES[_size_idx], idx])


func _page_count() -> int:
	return maxi(1, ceili(float(LEVELS_PER_SET) / float(PAGE_SIZE)))


func _mine_count() -> int:
	# v3.0 候选雷数回退（GDD 终版 §8.1）：走 RuleFeasibility 真值解析——标准雷数与
	# 守恒算子互斥时自动回退候选列表下一项（如 qd 8×8：26 非 4 倍数 → 回退 24）。
	# 结果带缓存（同 mode×size 仅首次走 CP-SAT），与 _mode_feasible 共享同一批查询。
	# 全候选不可行返回 -1（正常流程被 _refresh_popup 的尺寸禁用 + _on_play 防御拦下，
	# 不会走到生成）。
	var m: Dictionary = MODES[_mode_idx]
	return int(RuleFeasibility.resolve_mines(
			String(m["clue"]), m.get("globals", []), SIZES[_size_idx])["mines"])


## 最新解锁关卡：第一个「既未通关、也未跳过」的关卡；都没有则为最后一关。
## 跳过的关不再算「待攻克」——否则跳过后回到选关页，会被重新定位回刚跳过的那一关，
## 玩家看到的是「跳过没生效」（明明已经跳过了）。
func _latest_unlocked() -> int:
	for i in LEVELS_PER_SET:
		var key := _level_key(i)
		if not _is_cleared(key) and not _is_skipped(key):
			return i
	return LEVELS_PER_SET - 1


## 解锁条件：前一关**已通关或已跳过**。
## 跳过是失败终局给出的正当出路，同样推进序列（否则跳过按钮点了也进不去下一关）。
func _is_unlocked(idx: int) -> bool:
	if idx == 0:
		return true
	var prev := _level_key(idx - 1)
	return _is_cleared(prev) or _is_skipped(prev)


## 演示预设：首次进入某套时预置前 MOCK_CLEARED 关为「已通关」（便于演示解锁/继续流程）。
## **只写内存字典，不落盘**——写进 ProgressStore 等于往玩家真存档里塞假成绩。
func _ensure_mock() -> void:
	if _mode_idx < 0:
		return
	for i in LEVELS_PER_SET:
		if _is_cleared(_level_key(i)):
			return
	for i in mini(MOCK_CLEARED, LEVELS_PER_SET):
		_mock_cleared[_level_key(i)] = true


# ==================== 进入对局 ====================

## 生成尝试总数（与原 generate_with_rules(attempts=50) 口径一致）。
const GEN_ATTEMPTS := 50
var _gen_cancel := false


func _on_play() -> void:
	if _play_btn == null or _mode_idx < 0:
		return
	var m: Dictionary = MODES[_mode_idx]
	var s: int = SIZES[_size_idx]
	_play_btn.disabled = true
	_play_btn.text = "校验中…"
	await get_tree().process_frame
	# 0) 防御：全候选雷数均不可行（正常流程已被尺寸按钮禁用拦下）→ 直接拒绝，不进生成。
	#    （resolve_mines 带缓存，此处与 _mine_count/_mode_feasible 共享查询结果。）
	var rr := RuleFeasibility.resolve_mines(String(m["clue"]), m.get("globals", []), s)
	if int(rr["mines"]) < 0:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "该变体在 %d×%d 的全部候选雷数下数学无解——请换尺寸或换变体" % [s, s])
		return
	# 候选雷数回退提示（非阻断 toast，GDD 终版 §8.1 口径）：标准雷数与守恒算子互斥时，
	# 生成器自动改用候选列表下一项——明确告知玩家，不打断流程。
	if not bool(rr["standard"]):
		UiToast.popup(self, "该组合在 %d 雷下不可行，已回退 %d 雷（候选列表自动选择）" % [
			LevelSequence.mine_count(s), int(rr["mines"])])
	# 1) 可行性预筛（毫秒级）：规则冗余/矛盾、雷数不可达 → 立即拒绝，绝不暴力生成
	var pre := PuzzleGenerator.precheck_rules(String(m["clue"]), m["globals"], Vector2i(s, s), _mine_count())
	if not pre["ok"]:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, str(pre["reason"]))
		return
	# 2) 组合可行，进入生成。
	#    生成是同步阻塞的（CP-SAT 全管线单次调用不可中断），原先只能干等到它跑完——
	#    现在把重试循环提到 UI 层：每次 attempt 之间让出一帧，界面可响应「取消」。
	var path := await _ensure_level_file_async(_selected)
	if path == "":
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "已取消生成" if _gen_cancel else \
				"该组合可行，但本关未能生成序贯可解布局，请换一关或换尺寸")
		return
	if GameSession.start_level(path):
		get_tree().change_scene_to_file("res://ui/board_view.tscn")
	else:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "关卡加载失败")


## 生成并缓存关卡文件（已存在则直接复用，避免重复生成）。
## 异步版：attempt 之间让帧 + 可被玩家取消。
func _ensure_level_file_async(idx: int) -> String:
	var m: Dictionary = MODES[_mode_idx]
	var s: int = SIZES[_size_idx]
	# 兜底防御（正常已被 _refresh_popup 的尺寸禁用拦下）：数学不可行组合直接拦截，
	# 不进入生成器白耗 50 次 attempt（每次都会 UNSAT 返回空）。
	if not _mode_feasible(m, s):
		push_warning("关卡选择：变体 %s 在 %d×%d（全部候选雷数）下数学不可行，已拦截生成" % [
			str(m["id"]), s, s])
		return ""
	var path := LevelSequence.level_path(str(m["id"]), s, idx)
	if FileAccess.file_exists(path):
		return path

	DirAccess.make_dir_recursive_absolute(LevelSequence.GEN_DIR)
	var dlg := _open_gen_dialog(s)
	var deadline := Time.get_ticks_msec() + _gen_timeout(s)
	var gen := PuzzleGenerator.new()
	var out := ""
	# 说明：生成期间界面仍可响应（每次 attempt 之间 await 让帧），取消按钮据此生效。
	var started_ms := Time.get_ticks_msec()
	for attempt in GEN_ATTEMPTS:
		await get_tree().process_frame
		if _gen_cancel:
			break
		var used_sec: int = (Time.get_ticks_msec() - started_ms) / 1000
		dlg.get_meta("sub").text = "已用时 %d 秒（上限 %d 秒）" % [used_sec, _gen_timeout(s) / 1000]
		var remain: int = deadline - Time.get_ticks_msec()
		if remain <= 0:
			break
		# 单次 attempt + 外层换种子：首尝试的种子派生与原来完全一致
		# （内部 attempts=1 ⇒ _derive_seed(seed, 0)），保证既有关卡文件复现语义不变。
		var level: Dictionary = gen.generate_with_rules(
			String(m["clue"]), m["globals"], Vector2i(s, s), _mine_count(),
			_level_seed(idx) + attempt, 0, 1, null, remain)
		if level.is_empty():
			continue
		# 记录生成参数，便于追溯复现
		level["gen"] = {"mode": m["id"], "size": s, "index": idx, "seed": _level_seed(idx)}
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			break
		f.store_string(JSON.stringify(level, "  "))
		f.close()
		out = path
		break
	_close_gen_dialog(dlg)
	_gen_cancel = false
	return out


## 生成进度弹窗：明确告诉玩家「程序在忙」，并给取消出口。
func _open_gen_dialog(size: int) -> PopupPanel:
	_gen_cancel = false
	var dlg := PopupPanel.new()
	dlg.exclusive = true
	var panel := PanelContainer.new()
	dlg.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(320, 0)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "正在生成 %d×%d 关卡" % [size, size]
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 16)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.text = "大概需要 %d 秒，复杂变体会更久" % _estimate_gen_seconds(size)
	vb.add_child(sub)

	var cancel := Button.new()
	cancel.text = "取消"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.custom_minimum_size = Vector2(0, 44)
	cancel.pressed.connect(func():
		_gen_cancel = true
		dlg.hide())
	vb.add_child(cancel)

	dlg.set_meta("sub", sub)
	add_child(dlg)
	dlg.hide()   # Window 默认 visible=true
	dlg.popup_centered()
	return dlg


func _close_gen_dialog(dlg: PopupPanel) -> void:
	if dlg != null and is_instance_valid(dlg):
		dlg.queue_free()


# ==================== 滚轮翻页 ====================

func _on_frame_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton) or not ev.pressed:
		return
	var dir := 0.0
	if ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		dir = 1.0
	elif ev.button_index == MOUSE_BUTTON_WHEEL_UP:
		dir = -1.0
	else:
		return
	var factor := float((ev as InputEventMouseButton).factor)
	if factor <= 0.0:
		factor = 1.0
	_scroll_accum += dir * factor
	if abs(_scroll_accum) >= SCROLL_THRESHOLD:
		var d := 1 if _scroll_accum > 0 else -1
		_scroll_accum = 0.0
		_go_page(_page + d)
	else:
		_bounce(dir * factor)


## 轻滚回弹：网格轻微位移后弹回，给「翻页未触发」一点触感反馈。
func _bounce(dir: float) -> void:
	if _grid_wrap == null:
		return
	if _grid_wrap.has_meta("bounce_tw"):
		var old: Tween = _grid_wrap.get_meta("bounce_tw")
		if old != null and old.is_valid():
			old.kill()
	_grid_wrap.position.y = clampf(dir * 10.0, -16.0, 16.0)
	var tw := create_tween()
	tw.tween_property(_grid_wrap, "position:y", 0.0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_grid_wrap.set_meta("bounce_tw", tw)


# ==================== 样式 / 主题 ====================

## 棋盘框：选中尺寸后整体蓝色高亮 + 微弱发光。
func _style_frame() -> void:
	if _frame == null:
		return
	var sb := StyleBoxFlat.new()
	sb.bg_color = ThemeManager.card().darkened(0.25)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(2)
	sb.border_color = ThemeManager.accent()
	sb.shadow_color = Color(ThemeManager.accent().r, ThemeManager.accent().g, ThemeManager.accent().b, 0.35)
	sb.shadow_size = 14
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	_frame.add_theme_stylebox_override("panel", sb)


## 尺寸选项按钮 / 页签：选中态蓝色高亮。
func _style_choice(b: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(6)
	sb.set_border_width_all(2 if active else 1)
	if active:
		sb.bg_color = ThemeManager.accent().darkened(0.55)
		sb.border_color = ThemeManager.accent()
	else:
		sb.bg_color = ThemeManager.card()
		sb.border_color = ThemeManager.grid_line()
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_color_override("font_color", ThemeManager.text())


## 关卡方块四态：选中蓝色高亮 / 已通关绿 / 已跳过中性偏蓝 / 未解锁灰（禁用）。
func _style_tile(b: Button, selected: bool, cleared: bool, skipped: bool = false) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(2 if selected else 1)
	if selected:
		sb.bg_color = ThemeManager.accent().darkened(0.5)
		sb.border_color = ThemeManager.accent()
	elif cleared:
		sb.bg_color = ThemeManager.safe().darkened(0.55)
		sb.border_color = ThemeManager.safe().darkened(0.2)
	elif skipped:
		# 已跳过：可点的中性调，介于「已通关的绿」与「未解锁的灰」之间——
		# 一眼看出这关被让过去了、而且随时能回来补。
		sb.bg_color = ThemeManager.accent().darkened(0.78)
		sb.border_color = ThemeManager.accent().darkened(0.45)
	else:
		sb.bg_color = ThemeManager.card()
		sb.border_color = ThemeManager.grid_line()
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	b.add_theme_color_override("font_color", ThemeManager.text())
	# 禁用态必须用 font_disabled_color（font_color 对 disabled 无效）
	b.add_theme_color_override("font_disabled_color", ThemeManager.text_secondary().darkened(0.25))


func _style_dot(d: Button, active: bool) -> void:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(7)
	sb.bg_color = ThemeManager.accent() if active else ThemeManager.text_secondary().darkened(0.35)
	sb.set_border_width_all(0)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	d.add_theme_stylebox_override("normal", sb)
	d.add_theme_stylebox_override("hover", sb)
	d.add_theme_stylebox_override("pressed", sb)


## 页面外 chrome 的主题刷新（标题 / 返回按钮 / 页签）。
## 卡片、交叉格、表头标签都在页面内部，样式全由代码生成 → 由 _on_theme_changed 整页重建，
## 这里逐层刷反而容易漏（且会把 _style_choice 的选中态打回默认外观）。
func _apply_theme() -> void:
	for n in get_children():
		if n is Label:
			var col := ThemeManager.text_secondary() if bool(n.get_meta("secondary", false)) else ThemeManager.text()
			n.add_theme_color_override("font_color", col)
		elif n is Button and n.has_meta("std_btn"):
			UiTheme.style_button(n)
	if _overlay != null:
		_apply_popup_theme(_overlay)
	queue_redraw()


## 弹窗内主题：Label 直接刷色；Button 只刷新「标准按钮」（标记 std_btn）。
## 关卡方块 / 尺寸选项 / 分页圆点是自定义样式，由 _refresh_popup 重建；
## 若在此遍历覆盖，会把它们打回默认外观（选中高亮、圆点全失效）。
func _apply_popup_theme(root: Node) -> void:
	for c in root.get_children():
		if c is Label:
			c.add_theme_color_override("font_color", ThemeManager.text())
		elif c is Button and bool(c.get_meta("std_btn", false)):
			UiTheme.style_button(c)
		if c.get_child_count() > 0 and not (c is Button):
			_apply_popup_theme(c)


## 主题切换去抖（v3.1）：ThemeManager 一次切换广播 ~10 次 theme_changed，而
## _refresh_popup 会重跑 4 次 RuleFeasibility 查询（弹窗开着时 = 40 次 CP-SAT 调用
## + 网格整体重建闪烁）；再加上重建三页（16 卡片 + 56 交叉格）同样不便宜。
## 300ms 去抖把多次广播合并为 1 次刷新，最终状态一致——文字色仍立即生效，
## 避免切换瞬间闪回旧色。
var _theme_refresh_pending := false

func _on_theme_changed() -> void:
	_apply_theme()
	if _theme_refresh_pending:
		return
	_theme_refresh_pending = true
	await get_tree().create_timer(0.3).timeout
	_theme_refresh_pending = false
	_rebuild_pages()
	if _mode_idx >= 0:
		_refresh_popup()


# ==================== 杂项 ====================
# toast 统一走 UiToast（原先此处与 main_menu 各实现了一份完全相同的 Label+Timer）。
