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

# 教程覆盖层用 preload 而非 class_name 引用（headless 下新全局类不在 .godot 缓存里，见坑表 #26）
const TutorialOverlayScript := preload("res://ui/tutorial_overlay.gd")

# ===== 常量 =====
# 序列相关的常量统一托管在 LevelSequence（终局页要靠它算「下一关」，两处必须同源）。
const LEVELS_PER_SET := LevelSequence.LEVELS_PER_SET   # 每套关卡数
const SIZES: Array = LevelSequence.SIZES
const PAGE_SIZE := 20           # 一页最多 20 关
const GRID_COLS := 5            # 网格 5 列
## 删线索阶段墙钟上限（ms），按尺寸分档。实测：≤7×7 用 3s 即可删到最优（4~10 线索）；
## 8×8 是瓶颈（3s→22 线索、4s→19、60s→9，收益递减）——3s 保证交互响应，线索略多但可接受；
## 9×9 单关 CP-SAT 约 6~12s（32 雷），3s 必超时失败，故单列 15s（GDD 03 号 8×8≤10s 之外）。
func _gen_timeout(side: int) -> int:
	if side >= 9:
		return 15000
	return 3000


## 生成耗时预览（按钮文案用）：按尺寸的实测经验值（classic 线索，自由模式口径）。
## 注：参数名用 side——`size` 会遮蔽 Control.size 属性（分析器告警）。
func _estimate_gen_seconds(side: int) -> int:
	if side >= 9:
		return 12
	if side >= 8:
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
## 页四：异形棋盘。res://levels/ 下**手工异形关卡**（挖洞方格 / 蜂窝 / 多边形镶嵌）的
## 唯一入口——它们不在 MODES 变体体系里，也不走生成/关卡库序列，此前没有任何入口。
## 判定 = 关卡 JSON 含非空 topology 字段；无此类关卡时页签隐藏（与 Mod 页同策略）。
const PAGE_SHAPE := 3


## 档位显示文案（v4.0 深度口径）：单一事实源在 core（`Difficulty.tier_text`，从 PEAK_WINDOWS 派生）。
## 此处仅作旧调用点薄封装，避免大范围改名；新代码请直接用 Difficulty.tier_text。
static func _tier_text(tier: String) -> String:
	return Difficulty.tier_text(tier)


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
## 难度列（关卡库模式）：四档竖排；该（变体×尺寸）库内无内容时整列隐藏，回退生成流。
var _tier_col: VBoxContainer = null
var _tier_btns: Array[Button] = []
var _tier := ""              # 当前档（仅关卡库模式）
var _lib_mode := false       # 当前（变体 × 尺寸）是否有正式关卡库内容
var _lib_count := 0          # 当前（变体 × 尺寸 × 档）的关数
var _frame: PanelContainer = null
var _grid_wrap: Control = null
var _grid: GridContainer = null
var _dots_box: VBoxContainer = null
var _stat_label: Label = null
var _play_btn: Button = null
var _title_label: Label = null
## 预热好的对局场景（首次进关的卡顿源：board_view 脚本首次编译 + 场景构建）。
## static：跨场景存活；且**持有引用**——裸 load 的返回值无引用会被释放、缓存随之失效
## （2026-09-22 实测踩过，见 main_menu._prewarm_board_view 注释）。
static var _board_view_prewarmed: PackedScene = null

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
	_prewarm_board_view()


## 预热对局场景：首次进入关卡的同步重活发生在玩家点「开始」之后，观感是「点了没反应、画面静止」。
##
## **实测（`tools/_probe_prewarm.gd`，2026-09-19）**：
##   首次 `load("res://ui/board_view.tscn")` = **132 ms**（再次 load 仅 0.004 ms —— 成本全在
##   首次的场景 + 依赖资源加载）；而 `instantiate` 仅 0.05 ms、脚本 load 0.01 ms。
##   这 132 ms 正是「首次进关顿挫」的最大单项，预热把它前移到玩家还在浏览变体列表时。
##   真机（尤其移动端）只会更贵 —— **不要因为「看不出效果」删掉这段**。
##
## 延后两帧执行：先让选关页自己画出来，再吃这份开销；失败无妨（只是没预热，不影响任何功能）。
## ⚠️ 它覆盖不到 `_ready` 里的节点构建（那部分不在上述测量范围内）。
func _prewarm_board_view() -> void:
	# **同步执行，不 await**（2026-09-19 真机崩溃修复）：
	# 原实现用 `await get_tree().process_frame` 延后两帧，但 await 恢复时节点可能已不在
	# 场景树 → `get_tree()` 返回 null → 报 `Parameter data.tree is null` /
	# `Invalid access to property 'process_frame' on a base object of type 'null instance'`。
	# 改为在 _ready 内同步完成：代价是选关页加载多 132ms（那本就是一次场景切换，玩家察觉不到），
	# 换来「进入关卡时不再补付这 132ms」——比异步版更早完成预热，也更快让玩家点到已热场景。
	#
	# 2026-09-22 起主菜单已提前预热（本函数多数时候只是命中缓存后的幂等复用）；
	# 保留它作兜底：直接从编辑器运行选关页场景时仍需要预热。
	if _board_view_prewarmed != null:
		return
	var packed := load("res://ui/board_view.tscn")
	if packed is PackedScene:
		_board_view_prewarmed = packed


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


## 终局页交接过来的意图：翻到对应变体×尺寸，必要时**直接开局**。
## 选关页默认会把选中项定位到「最新解锁关卡」——通关或跳过之后，那一项正好是下一关。
## auto_start 为真（来自「下一关」/「跳过本关」）时，展开弹窗后立刻开局：
## 生成仍归本页（这里才有生成器与取消入口），玩家感知是「点一下就进了下一关」；
## 生成失败或被取消则停在选关页（弹窗已开着），不会卡在无出路的状态。
func _consume_pending_focus() -> void:
	var focus: Dictionary = LevelSequence.take_focus()
	if focus.is_empty():
		return
	var mode_id := str(focus.get("mode", ""))
	var want_size := int(focus.get("size", 0))
	var want_tier := str(focus.get("tier", ""))
	var auto_start := bool(focus.get("auto_start", false))
	for i in MODES.size():
		if str(MODES[i]["id"]) != mode_id:
			continue
		_show_tab(_page_of(MODES[i]))   # 先翻到该变体所在的页，再开它的弹窗
		if _page_of(MODES[i]) == PAGE_MIXED:
			# 混合档有三张表：不切到目标那张，弹窗会开在一个看不见的表上
			_on_mixed_switch(_mixed_tab_of(MODES[i]))
		var size_i: int = SIZES.find(want_size)
		_open_popup(i)
		if size_i >= 0:
			_size_idx = size_i
			if want_tier != "":
				_tier = want_tier   # 跨档「下一关」：带上目标档（_refresh_popup 会校验该档有无内容）
			_ensure_mock()
			_refresh_popup()
		if auto_start:
			_on_play()
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
	for spec in [["单项变体", PAGE_SINGLE], ["混合档", PAGE_MIXED], ["异形棋盘", PAGE_SHAPE], ["Mod", PAGE_MOD]]:
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
	# 异形棋盘页在「一个异形关都没有」时不可达（页签已隐藏，同上防程序调用 / 键盘触发）
	if t == PAGE_SHAPE and _shape_levels().is_empty():
		t = PAGE_SINGLE
	if t == PAGE_SHAPE and not _shape_filled:
		# 延迟填充的兜底：玩家已切到本页，内容必须立刻就绪（只在首切时付一次构建成本）
		_shape_filled = true
		_refresh_shape_body()
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


## 混合档三张表各自的归属：按组合携带的**算子轴**判定，而不是按 id 字符串猜。
##   T4（tab 2）   = 带守恒算子（z*）
##   F 类（tab 1） = 两个结构算子（s* + s*）
##   C 类（tab 0） = 结构 + 观测（其余全部）
func _mixed_tab_of(m: Dictionary) -> int:
	var gs: Array = m.get("globals", [])
	var has_conserve := false
	var struct_count := 0
	for g in gs:
		if VariantCatalog.CONSERVE_IDS.has(str(g)):
			has_conserve = true
		elif VariantCatalog.STRUCT_IDS.has(str(g)):
			struct_count += 1
	if has_conserve:
		return 2
	return 1 if struct_count == 2 else 0


## 重建三页内容（Mod 加载 / 卸载、主题切换、首次进入时调用）。
func _rebuild_pages() -> void:
	for p in _pages:
		if is_instance_valid(p):
			p.queue_free()
	_pages.clear()
	_pages.append(_build_single_page())
	_pages.append(_build_mixed_page())
	_pages.append(_build_mod_page())
	_pages.append(_build_shape_page())
	for p in _pages:
		_page_host.add_child(p)
	# Mod 页签的可见性：没有 Mod 就整个隐藏（不是置灰——空页签只会让人点进去看空）
	if _tab_btns.size() > PAGE_MOD:
		_tab_btns[PAGE_MOD].visible = not ModAPI.list_mods().is_empty()
	# 异形棋盘页签同理：一个异形关都没有就隐藏（空页签只会让人点进去看一片空白）
	if _tab_btns.size() > PAGE_SHAPE:
		_tab_btns[PAGE_SHAPE].visible = not _shape_levels().is_empty()
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

## 三张混合档交叉表（轴不同，不是「叠几个约束」的数量差别）。
## 表本身就是索引：想找「带射距的组合」看一行，想找「无环类的」看一列——
## 141 组不需要搜索框。排布交给 GridContainer，故天然不会出现节点互相遮挡。
# 交叉格 / 表头尺寸：行首 130 + 7 列 × 142 + 列间距 7×6 = 1166 → 加页边距 44 后
# 仍能完整放进 1280 设计分辨率（不留横向滚动条）。窄窗口由 _make_page_shell(true) 兜底。
const CELL_W := 142
const ROW_HEAD_W := 130


## 混合档页有三张表，用右上角开关切换：
##   ① T3 C 类  行 = 观测 O（10）、列 = 结构 S（7）  → 70 组（每关：1 观测 + 1 结构）
##   ② T3 F 类  行 / 列 = 结构 S，只填右上三角      → 21 组（每关：2 结构）
##   ③ T4      行 = 观测 O（10）、列 = 守恒 Z（5）  → 50 组（每关：再叠 1 守恒）
## 为什么不能把「约束」当一类：代码的 KIND_GLOBAL 同时装 S 轴与 Z 轴（pf 是 S1、mx 是 Z1），
## 而 GDD §5.1 的硬限制是「观测恰 1 + 结构 ≤2 + 守恒 ≤1」——两个 Z 同关即犯规，
## 所以守恒必须单独成表（早先按 KIND 做的「约束 × 约束」表正是踩了这个）。
## 三张表共用同一套表头 / 格子 / 进度渲染，切换只换轴与格子来源。
const MIXED_TABS := 3
var _mixed_tab := 0
var _mixed_host: VBoxContainer = null
var _mixed_hint: Label = null
var _mixed_btns: Array[Button] = []


func _build_mixed_page() -> Control:
	var shell := _make_page_shell(true)
	var margin: MarginContainer = shell[1]
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	margin.add_child(vb)

	# 顶部：说明（随表切换重写）+ 三张表的切换开关
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	vb.add_child(bar)

	_mixed_hint = Label.new()
	_mixed_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 说明文字很长（三张表各一句），不裁会让右侧切换按钮被推出视口
	#（2026-09-18 截图复核：T4 按钮在 1280 下被右缘裁切）。裁断说明保按钮完整。
	_mixed_hint.clip_text = true
	_mixed_hint.add_theme_font_size_override("font_size", 13)
	_mixed_hint.set_meta("secondary", true)
	bar.add_child(_mixed_hint)

	_mixed_btns.clear()   # 主题切换会整页重建，旧按钮引用必须丢弃
	# 文案与宽度按 1280 设计分辨率定：截图复核（2026-09-18）发现原「T4 · 结构×观测+守恒」
	# 在 1280 下被窗口右缘裁切——按钮组与左侧说明文字同排，总宽超视口。缩文案 + 缩宽度。
	for spec in [["C 类 · 结构×观测", 0], ["F 类 · 结构×结构", 1], ["T4 · 叠加守恒", 2]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(184, 36)
		b.pressed.connect(_on_mixed_switch.bind(int(spec[1])))
		bar.add_child(b)
		_mixed_btns.append(b)
		UiTheme.bind_hover(b, 1.04)

	_mixed_host = VBoxContainer.new()
	_mixed_host.add_theme_constant_override("separation", 12)
	vb.add_child(_mixed_host)
	_fill_mixed_table()
	return shell[0]


func _on_mixed_switch(tab: int) -> void:
	_mixed_tab = tab
	_fill_mixed_table()


func _fill_mixed_table() -> void:
	if _mixed_host == null:
		return
	for c in _mixed_host.get_children():
		c.queue_free()
	match _mixed_tab:
		1: _mixed_host.add_child(_ss_table())
		2: _mixed_host.add_child(_t4_table())
		_: _mixed_host.add_child(_os_table())
	for i in _mixed_btns.size():
		_style_choice(_mixed_btns[i], i == _mixed_tab)


## 空表骨架：三张表共用（列数含行首）。表整体居中（默认左贴会右侧多出余量）。
func _matrix_new(columns: int) -> GridContainer:
	var table := GridContainer.new()
	table.columns = columns
	table.add_theme_constant_override("h_separation", 6)
	table.add_theme_constant_override("v_separation", 6)
	table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return table


## 表一（T3 C 类）：结构 × 观测。行 = 观测 O1~O10，列 = 结构 S1~S7。
func _os_table() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 10)
	var obs := VariantCatalog.mixed_clue_ids()
	var structs := VariantCatalog.mixed_global_ids()
	# 说明文字必须短：Label 的最小尺寸由文字撑出且 clip_text 只裁绘制不改最小尺寸——
	# 长说明 + 右侧三按钮会把 bar 撑过视口宽度，产生横向滚动条（2026-09-18 实测根因）
	_mixed_hint.text = "行 = 观测（O）　列 = 结构（S）　交叉格 = 两算子同关　·　点击任意格开这一关"

	var table := _matrix_new(structs.size() + 1)
	wrap.add_child(table)
	table.add_child(_matrix_corner("观测 ＼ 结构"))
	for j in structs.size():
		table.add_child(_matrix_head("S%d" % (j + 1), structs[j], false))
	for i in obs.size():
		table.add_child(_matrix_head("O%d" % (i + 1), obs[i], true))
		for sid in structs:
			table.add_child(_combo_cell("%s_%s" % [sid, obs[i]],
					"%s·%s" % [VariantCatalog.display_name(obs[i]), VariantCatalog.display_name(sid)]))

	wrap.add_child(_matrix_note("共 %d 组（%d 观测 × %d 结构，GDD §10.1 T3 C 类）　·　跨轴作用对象不同 → 判据恒为 J1 正交" % [
			obs.size() * structs.size(), obs.size(), structs.size()]))
	return wrap


## 表二（T3 F 类）：结构 × 结构。每对只出现一次 → 只填右上三角（C(7,2) = 21）。
## 左下留白不是省略：每一对都已在右上出现，重复填只会让人以为还有第二组。
func _ss_table() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 10)
	var structs := VariantCatalog.mixed_global_ids()
	_mixed_hint.text = "行 / 列 = 结构（S）　右上三角格 = 两结构同关　·　点击任意格开这一关"

	var table := _matrix_new(structs.size() + 1)
	wrap.add_child(table)
	table.add_child(_matrix_corner("结构 ＼ 结构"))
	for j in structs.size():
		table.add_child(_matrix_head("S%d" % (j + 1), structs[j], false))
	for i in structs.size():
		table.add_child(_matrix_head("S%d" % (i + 1), structs[i], true))
		for j in structs.size():
			if j > i:
				table.add_child(_combo_cell("%s_%s" % [structs[i], structs[j]],
						"%s·%s" % [VariantCatalog.display_name(structs[i]),
							VariantCatalog.display_name(structs[j])]))
			else:
				# 对角线（同一约束不可重复）与左下（与右上同一对）都不产生组合
				table.add_child(_matrix_blank())

	var pairs := structs.size() * (structs.size() - 1) / 2
	var alive := VariantCatalog.gg_all(_cur_size(), LevelSequence.mine_count(SIZES[_size_idx])).size()
	wrap.add_child(_matrix_note("共 %d 对（C(%d,2)，GDD §10.1 T3 F 类）　·　%d 组当前可用　·　同轴配对多为 J2 警告（可行域收窄但可生产）" % [
			pairs, structs.size(), alive]))
	return wrap


## 表三（T4）：结构 × 观测 + 1 守恒。行 = 观测 O1~O10，列 = 守恒 Z1~Z5；
## 结构搭档按 GDD §10.1 的循环构造指派 ((观测序 + 守恒序) mod 7)，与目录同源。
func _t4_table() -> Control:
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 10)
	var obs := VariantCatalog.mixed_clue_ids()
	var cons := VariantCatalog.mixed_conserve_ids()
	var structs := VariantCatalog.mixed_global_ids()
	_mixed_hint.text = "行 = 观测（O）　列 = 守恒（Z）　格 = 再叠 1 结构（循环指派）　·　点击任意格开这一关"

	if structs.is_empty() or cons.is_empty():
		# 结构 / 守恒算子全未加载（无头环境）：画空表而不是除零崩
		wrap.add_child(_matrix_note("结构或守恒算子尚未加载，暂无可列出的 T4 组合"))
		return wrap

	var table := _matrix_new(cons.size() + 1)
	wrap.add_child(table)
	table.add_child(_matrix_corner("观测 ＼ 守恒"))
	for j in cons.size():
		table.add_child(_matrix_head("Z%d" % (j + 1), cons[j], false))
	for i in obs.size():
		table.add_child(_matrix_head("O%d" % (i + 1), obs[i], true))
		for z in cons.size():
			var s: String = str(structs[(i + z) % structs.size()])
			table.add_child(_combo_cell("%s+%s+%s" % [cons[z], s, obs[i]],
					"%s·%s·%s" % [VariantCatalog.display_name(obs[i]),
						VariantCatalog.display_name(s), VariantCatalog.display_name(cons[z])]))

	var alive := VariantCatalog.conserved_all(_cur_size(), LevelSequence.mine_count(SIZES[_size_idx])).size()
	wrap.add_child(_matrix_note("共 %d 组（%d 守恒 × %d 观测，GDD §10.1 T4）　·　%d 组当前可用　·　结构搭档按循环指派，每组的结构搭档不重复" % [
			cons.size() * obs.size(), cons.size(), obs.size(), alive]))
	return wrap


## 当前尺寸（方盘）：SIZES 只存边长。
func _cur_size() -> Vector2i:
	var side: int = SIZES[_size_idx]
	return Vector2i(side, side)


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


## 组合格（三张混合档表共用）：按 mode_id 从目录取信息，tooltip / 进度全自动。
## label 由调用方按轴拼（表里已知轴，不必反查目录）。
func _combo_cell(mode_id: String, label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(CELL_W, 48)
	btn.clip_text = true   # 名称再长也不许撑宽格子（撑宽会把整表挤到横向滚动）
	# 交叉格开焦点 → 鼠标点一下就「进入」键盘/手柄导航，之后方向键可在表格内走格
	# （GridContainer 的相邻兄弟正是几何相邻格，Godot 自动推导四向邻居）。
	# 其余按钮仍 FOCUS_NONE，沿用项目「鼠标优先」设计。
	btn.focus_mode = Control.FOCUS_ALL
	btn.add_theme_font_size_override("font_size", 12)
	btn.set_meta("cell_btn", true)
	_style_card(btn)
	var mi: int = int(_mode_index.get(mode_id, -1))
	if mi < 0:
		# 该组合此刻不产生：算子未加载（无头环境 / Mod 未装）或判 forbid（逻辑冗余）。
		# 占位置灰而不是省略——省略会让行列错位，也看不出「这里本该有一格」。
		btn.disabled = true
		btn.tooltip_text = "%s\n该组合当前不可用（算子未加载，或叠加后逻辑冗余）" % label
		return btn
	var m: Dictionary = MODES[mi]
	var lines: Array[String] = ["%s（%s）" % [str(m["name"]), str(m["tip"])]]
	for rid in (m["globals"] as Array):
		lines.append(VariantCatalog.rule_text(str(rid)))
	if str(m["clue"]) != "classic":
		lines.append(VariantCatalog.rule_text(str(m["clue"])))
	# 判据理由由签名表**实时两两推导**（R1~R5），不再写死泛化文案：补入官方 22 席签名后，
	# 这里能给出具体依据（如 R2「同一作用域叠加」/ R3「对称群交集为空」），
	# 且随签名表更新自动跟上（改了签名不必回来改文案）。
	var ids: Array = [str(m["clue"])]
	ids.append_array(m["globals"])
	var why := ""
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var v := RuleSignature.compat(str(ids[i]), str(ids[j]), _cur_size(),
					LevelSequence.mine_count(SIZES[_size_idx]))
			if str(v["verdict"]) == RuleSignature.WARN and why == "":
				why = str(v["reason"])
	if why != "":
		lines.append("⚠ %s" % why)
		lines.append("部分尺寸可能无解——弹窗内的尺寸按钮会自动禁用并切到最近可行尺寸")
	lines.append("已通关 %d / %d" % [_cleared_total(mode_id), SIZES.size() * LEVELS_PER_SET])
	btn.tooltip_text = "\n".join(lines)
	btn.pressed.connect(_open_popup.bind(mi))
	UiTheme.bind_hover(btn, 1.04)
	_attach_progress(btn, mode_id)
	return btn


# ---------- 页三：Mod（按来源分组） ----------

## 玩家安装的 Mod（排除随包官方算子）。
## 官方 22 席经 ModAPI 自举加载，但其变体已并入「单项变体」页作为一等变体——
## 若本页再列出官方 Mod，会出现 22 个空章节（各自写着「未注册可玩变体」，实机实测踩过）。
func _player_mod_ids() -> Array[String]:
	var out: Array[String] = []
	for id in ModAPI.list_mods():
		if not ModAPI.is_bundled(str(id)):
			out.append(str(id))
	return out


## Mod 变体独立成页：数量由玩家装了什么决定，不占用内置变体的版面——
## 玩家装 3 个还是 30 个 Mod，「单项变体」页永远长一个样。
func _build_mod_page() -> Control:
	var shell := _make_page_shell()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 16)
	(shell[1] as MarginContainer).add_child(vb)

	var ids := _player_mod_ids()
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
	hint.text = "已安装 %d 个玩家 Mod：%d 个可玩变体 + %d 个 Def 规则　·　官方 22 席算子在「单项变体」页" % [
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

	# 已生成的 Mod 关卡（模组页生成按钮的成品，落在 user://mods/<mod>/levels/）：
	# 直接列在这里可开玩——没必要让玩家为了玩成品再回模组页找一遍。
	var levels := _mod_level_buttons(mod_id)
	if levels != null:
		wrap.add_child(levels)
	return wrap


## Def 规则行。Def 注册进的是 DefEngine 而不是规则注册表，因此**不会**出现在变体表里。
## 但它不是凭空消失的理由：Def 的 (window, aggregate) / op 是**封闭枚举**，
## 永远等价于内置 8 线索 / 7 约束之一（n4+sum ≡ 四邻、symmetry_axis ≡ 镜像）——
## 所以这里如实标出「≡ 哪个内置变体、去哪儿玩同款玩法」；
## 映射不到的组合（规则平台没有对应算子）则明说不可生成，而不是留个空分组。
func _mod_def_label(defs: Array) -> Control:
	var parts: Array[String] = []
	for d in defs:
		var n := str((d as Dictionary).get("name", ""))
		if n == "":
			continue
		var is_clue := str((d as Dictionary).get("type", "")) == "clue"
		var kind := "线索" if is_clue else "约束"
		var rid := PuzzleGenerator.def_to_rule(ModAPI.defs, n, is_clue)
		if rid == "":
			parts.append("%s %s（规则平台无对应算子，不可生成）" % [kind, n])
		else:
			parts.append("%s %s ≡ %s（%s）" % [kind, n, VariantCatalog.display_name(rid), rid])
	if parts.is_empty():
		parts.append("（无）")
	var lb := Label.new()
	lb.text = "Def 规则：%s　·　玩法等同对应内置变体，可在选关页直接玩；下方「已生成关卡」是它的成品" % "　".join(parts)
	lb.add_theme_font_size_override("font_size", 13)
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lb.set_meta("secondary", true)
	return lb


## 该 Mod 已生成的关卡（模组页生成器的成品）。无则返回 null，调用方不加空块。
func _mod_level_buttons(mod_id: String) -> Control:
	var dir_path := "user://mods/%s/levels" % mod_id
	var d := DirAccess.open(dir_path)
	if d == null:
		return null
	var files: Array[String] = []
	for f in d.get_files():
		if str(f).ends_with(".json"):
			files.append("%s/%s" % [dir_path, str(f)])
	if files.is_empty():
		return null
	files.sort()

	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 6)
	var head := Label.new()
	head.text = "已生成关卡 %d 个（点击直接开玩）" % files.size()
	head.add_theme_font_size_override("font_size", 13)
	head.set_meta("secondary", true)
	wrap.add_child(head)

	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 10)
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	wrap.add_child(flow)
	for p in files:
		var b := Button.new()
		b.text = str(p.get_file().get_basename())
		b.custom_minimum_size = Vector2(140, 40)
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "直接开始这一关\n%s" % p
		b.set_meta("mod_level_btn", true)
		_style_card(b)
		b.pressed.connect(_open_mod_level.bind(p))
		UiTheme.bind_hover(b, 1.04)
		flow.add_child(b)
	return wrap


## 直接开玩 Mod 关卡（Def / wasm 生成器的成品）。
## 异形或损坏关卡会被 LevelLoader 拒绝 → 只提示、不切场景（避免进了棋盘才发现是坏档）。
func _open_mod_level(path: String) -> void:
	if not GameSession.start_level(path):
		UiToast.popup(self, "关卡加载失败：%s" % path.get_file())
		return
	get_tree().change_scene_to_file("res://ui/board_view.tscn")


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
## focus 态是给交叉表的键盘/手柄导航用的（卡片仍 FOCUS_NONE，不会显示它）。
# ---------- 页四：异形棋盘（手工异形关卡，点击直接开局） ----------

## 异形关卡判定：关卡 JSON **含非空 topology 字段** = 非矩形网格（挖洞方格 / 蜂窝 /
## 多边形镶嵌）。classic_* / generated_* / 关卡库都没有该字段 ⇒ 天然排除，无需白名单。
static func _is_shape_level(d: Dictionary) -> bool:
	var t: Variant = d.get("topology", null)
	return t is Dictionary and not (t as Dictionary).is_empty()


## 扫描结果进程级缓存（2026-09-22 性能）：本函数一次全量扫 res://levels/ + 解析 JSON，
## 而建页流程一次至少调 3 处（页签可见性 / 变体分组 / 二级卡片）——此前每次切页签、
## 每次重建都重复扫盘，是进选关页 660ms 卡顿里的可去重项。
## 与 LevelLibrary.catalog() 同语义：进程内静态缓存，运行中新导入异形关需重启进程才可见
##（既有约定：形状档成员资格同样读进程内缓存，见 variant_catalog 形状档注释）。
static var _shape_cache: Array[Dictionary] = []
static var _shape_cache_loaded := false


## 扫描 res://levels/ 下的异形关卡 → [{path, title, cells, mines, kind, desc}]。
## 只在建页时读一次 JSON（十几关量级，重建页面开销可忽略），卡片不再二次读盘。
func _shape_levels() -> Array[Dictionary]:
	if _shape_cache_loaded:
		return _shape_cache
	var out: Array[Dictionary] = []
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
		var lv: Dictionary = d
		if not _is_shape_level(lv):
			continue
		var topo: Dictionary = lv.get("topology", {})
		var cells: int = (topo.get("positions", []) as Array).size()
		var sz: Dictionary = lv.get("size", {})
		var full: int = int(sz.get("rows", 0)) * int(sz.get("cols", 0))
		# 类型标签：**优先读关卡自带的 shape_kind**（生成 / 复刻时写入，语义确定）。
		# 缺该字段才回退几何判定（custom_shapes → 多边形镶嵌；满格 → 完整盘；否则裁剪 / 挖洞）。
		# 为什么不从文件名或格数猜：蜂窝盘与挖洞方格在场数据上都是「方阵裁掉一部分」，
		# 几何上无法可靠区分——猜出来的标签会把「蜂窝 02」标成「挖洞」（实测踩过）。
		var kind := str(lv.get("shape_kind", ""))
		if kind == "":
			kind = "裁剪 / 挖洞"
			if lv.has("custom_shapes"):
				kind = "多边形镶嵌"
			elif full > 0 and cells == full:
				kind = "完整盘"
		# 变体归属：由关卡自带的 global_rules 推导（空 = 经典底座）。这是**两级浏览**
		# （先选变体、再选棋盘）的索引键，也是「这个变体有哪些异形棋盘」的唯一事实源。
		var gr_v: Variant = lv.get("global_rules", [])
		var globals: Array = gr_v if (gr_v is Array) else []
		# 无 global_rules ⇒ 经典底座。id 取 "classic"（与 VariantCatalog.clue_ids() 的
		# 底座席位同名）——**不用空串**：空串在页面状态里是"第一级总览"的哨兵值，混用会令
		# 「经典」变体永远打不开（实测踩过）。
		var vid := str(globals[0]) if not globals.is_empty() else "classic"
		out.append({
			"path": path,
			"title": LevelLoader.get_level_name(path),
			"cells": cells,
			"mines": int(lv.get("total_mines", 0)),
			"kind": kind,
			"desc": str(lv.get("desc", "")),
			"variant": vid,
			"variant_name": "经典" if vid == "classic" else VariantCatalog.display_name(vid),
			"variant_text": "经典底座（无额外规则）" if vid == "classic" else VariantCatalog.rule_text(vid),
		})
	_shape_cache = out
	_shape_cache_loaded = true
	return out


## 当前浏览的变体（"" = 变体总览 = 第一级；否则 = 该变体 id = 第二级）。
## **为什么以变体为导向**（2026-09-21 改版）：玩家的思考单位是「我想玩哪个变体」，
## 而同一个变体在不同异形棋盘上的推理体验差异，才是这一页真正的内容。旧版把 60+ 张
## 关卡卡平铺成一面墙，既看不出变体维度、也找不准重点。
var _shape_variant := ""
var _shape_body: MarginContainer = null
var _shape_scroll: ScrollContainer = null


## 异形页内容「延迟一帧填」的状态（2026-09-22 性能）。
var _shape_filled := false
var _shape_fill_pending := false


func _build_shape_page() -> Control:
	var shell := _make_page_shell()
	_shape_scroll = shell[0] as ScrollContainer
	_shape_body = shell[1] as MarginContainer
	_shape_filled = false
	_schedule_shape_fill()
	return shell[0]


## 延迟一帧填异形页内容：进选关页实测 660ms 卡顿里，本页内容构建占 122ms
## （_shape_levels 扫 res://levels/ 全部关卡 JSON + 建两级卡片墙），而它默认不可见
## （首屏是单项变体页）。延迟一帧后玩家侧首屏不付这笔钱；_show_tab 有同步兜底，
## 内容必在被看见前就绪。
##
## 为什么用 process_frame 信号而不是 await：await 恢复时节点可能已不在树 → get_tree()
## 为 null → 真机崩溃（见 _prewarm_board_view 注释的同款事故）；信号连接随对象销毁
## 自动断开，回调内再查一次树内状态，两头都安全。
func _schedule_shape_fill() -> void:
	if _shape_filled or _shape_fill_pending or not is_inside_tree():
		return
	var tree := get_tree()
	if tree == null:
		return
	_shape_fill_pending = true
	tree.process_frame.connect(_fill_shape_deferred, CONNECT_ONE_SHOT)


func _fill_shape_deferred() -> void:
	_shape_fill_pending = false
	if not is_inside_tree() or _shape_filled:
		return
	_shape_filled = true
	_refresh_shape_body()


## 变体分组（第一级卡片的数据源）：按关卡的 global_rules[0] 归并（空 = 经典）。
## 顺序：经典优先，其余按官方三轴顺序（S 轴 → Z 轴），未登记变体（未来新增/Mod）追加末尾。
func _shape_variants() -> Array[Dictionary]:
	var by: Dictionary = {}
	for info: Dictionary in _shape_levels():
		var vid := str(info["variant"])
		if not by.has(vid):
			by[vid] = {"id": vid, "name": str(info["variant_name"]),
					"text": str(info["variant_text"]), "levels": 0, "cleared": 0}
		by[vid]["levels"] = int(by[vid]["levels"]) + 1
		if _is_cleared(str(info["path"])):
			by[vid]["cleared"] = int(by[vid]["cleared"]) + 1
	var order: Array = ["classic"] + VariantAxes.STRUCT + VariantAxes.CONSERVE
	var out: Array[Dictionary] = []
	for vid in order:
		if by.has(vid):
			out.append(by[vid])
	for vid in by:
		if not order.has(vid):
			out.append(by[vid])
	return out


## 重建内容区（切级 / 主题刷新时调用）：只换卡片墙，保住滚动容器本身。
func _refresh_shape_body() -> void:
	if _shape_body == null or not is_instance_valid(_shape_body):
		return
	for c in _shape_body.get_children():
		# 必须**先摘除再释放**：queue_free 是延迟的（本帧末才真正删除），只调它的话
		# 同一帧内的后续读取仍会看到旧卡片（切级瞬间新旧两批同时存在，实测踩过）。
		_shape_body.remove_child(c)
		c.queue_free()
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 14)
	flow.add_theme_constant_override("v_separation", 14)
	flow.alignment = FlowContainer.ALIGNMENT_CENTER
	_shape_body.add_child(flow)
	if _shape_variant == "":
		# 第一级：变体卡片（每个变体一张，带该变体的异形棋盘覆盖与通关进度）
		for v: Dictionary in _shape_variants():
			flow.add_child(_make_variant_card(v))
		return
	# 第二级：返回入口 + 该变体下的全部异形棋盘
	flow.add_child(_make_shape_back_card())
	for info: Dictionary in _shape_levels():
		if str(info["variant"]) == _shape_variant:
			flow.add_child(_make_shape_card(info))


## 第一级卡片：变体名 + 覆盖（「3 / 4」= 已通关 / 该变体的异形棋盘数）。
func _make_variant_card(v: Dictionary) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_meta("card_btn", true)
	btn.set_meta("variant_id", str(v["id"]))       # 测试 / 调试可据此定位变体
	var total := int(v["levels"])
	var cleared := int(v["cleared"])
	btn.tooltip_text = "%s\n%s\n该变体有 %d 个异形棋盘（已通关 %d）\n点击查看全部棋盘" % [
		str(v["name"]), str(v["text"]), total, cleared]
	btn.pressed.connect(_open_shape_variant.bind(str(v["id"])))
	_style_card(btn)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 10
	box.offset_right = -10
	box.offset_top = 8
	box.offset_bottom = -15
	btn.add_child(box)

	var title := Label.new()
	title.text = "%s　%d / %d%s" % [str(v["name"]), cleared, total, "　✓" if cleared >= total else ""]
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", ThemeManager.text())
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var desc := Label.new()
	desc.text = "%s\n%d 种异形棋盘" % [str(v["text"]), total]
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", ThemeManager.text_secondary())
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.max_lines_visible = 3
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(desc)

	UiTheme.bind_hover(btn, 1.03)
	return btn


## 第二级的返回入口（同尺寸卡片，网格里不突兀）。
func _make_shape_back_card() -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_meta("card_btn", true)
	btn.set_meta("shape_back", true)
	btn.tooltip_text = "返回变体列表"
	btn.pressed.connect(_back_to_shape_variants)
	_style_card(btn)
	var lb := Label.new()
	lb.text = "← 返回变体列表"
	lb.add_theme_font_size_override("font_size", 15)
	lb.add_theme_color_override("font_color", ThemeManager.text_secondary())
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(lb)
	UiTheme.bind_hover(btn, 1.03)
	return btn


func _open_shape_variant(vid: String) -> void:
	_shape_variant = vid
	_refresh_shape_body()
	# 切级回到顶部：否则会停在上一级留下的滚动位置（看起来像"点了没反应"）
	if _shape_scroll != null and is_instance_valid(_shape_scroll):
		_shape_scroll.scroll_vertical = 0


func _back_to_shape_variants() -> void:
	_shape_variant = ""
	_refresh_shape_body()
	if _shape_scroll != null and is_instance_valid(_shape_scroll):
		_shape_scroll.scroll_vertical = 0


func _make_shape_card(info: Dictionary) -> Button:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(CARD_W, CARD_H)
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_meta("card_btn", true)
	btn.set_meta("shape_path", str(info["path"]))   # 测试 / 调试可据此定位关卡
	var desc_txt := str(info["desc"])
	btn.tooltip_text = "%s\n%s · %d 格 · %d 雷%s" % [
		str(info["title"]), str(info["kind"]), int(info["cells"]), int(info["mines"]),
		("\n" + desc_txt) if desc_txt != "" else ""]
	btn.pressed.connect(_open_shape_level.bind(str(info["path"])))
	_style_card(btn)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 点击必须落到按钮上
	box.add_theme_constant_override("separation", 4)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 10
	box.offset_right = -10
	box.offset_top = 8
	box.offset_bottom = -15
	btn.add_child(box)

	# 进度键：LevelSequence.progress_key 对非序列关（res://levels/*.json）原样返回路径
	# ⇒ 直接用路径查 ProgressStore，与写侧同一约定（不然会「通关了不打勾」）。
	var title := Label.new()
	title.text = "%s%s" % [str(info["title"]), "  ✓" if _is_cleared(str(info["path"])) else ""]
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", ThemeManager.text())
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(title)

	var desc := Label.new()
	desc.text = "%s · %d 格 · %d 雷" % [str(info["kind"]), int(info["cells"]), int(info["mines"])]
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
	return btn


## 异形关开局：点卡片直接进对局（无尺寸/变体弹窗——关卡是固定的成品，不是生成的）。
## 续档与 _try_resume_saved 同口径，但**不能复用它**：它内部取 _level_key(_selected)，
## 依赖弹窗状态（_mode_idx / _selected）；页内直接点卡片时 _mode_idx = -1 ⇒ 会越界崩溃。
func _open_shape_level(path: String) -> void:
	var d := SaveCoordinator.load_save()
	if not d.is_empty():
		var meta_v: Variant = d.get("metadata", {})
		if meta_v is Dictionary:
			var meta: Dictionary = meta_v
			if (not bool(meta.get("ended", false))) and str(meta.get("level_path", "")) == path \
					and not _is_cleared(path) and GameSession.restore_from_save():
				get_tree().change_scene_to_file("res://ui/board_view.tscn")
				return
	if GameSession.start_level(path):
		get_tree().change_scene_to_file("res://ui/board_view.tscn")
	else:
		# 异形或损坏关卡会被 LevelLoader 拒绝 → 只提示、不切场景（避免进了棋盘才发现坏档）
		UiToast.popup(self, "关卡加载失败：%s" % path.get_file())


func _style_card(btn: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus"]:
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
			"focus":
				# 方向键走到哪一格必须一眼看出来：底色再亮一档 + 2px 边框
				sb.bg_color = ThemeManager.card().lightened(0.12)
				sb.border_color = ThemeManager.accent()
				sb.set_border_width_all(2)
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
	var total := _mode_total(mode_id)
	btn.draw.connect(func():
		# 必须显式写成 btn.draw_rect(...)：GDScript 的 lambda 里 self 是外层对象
		#（= 选关页），直接 draw_rect 会画到「正在绘制的那个节点」之外 → 报 !drawing。
		var w: float = maxf(btn.size.x - 16.0, 1.0)
		var y: float = btn.size.y - 7.0
		btn.draw_rect(Rect2(Vector2(8.0, y), Vector2(w, 3.0)), ThemeManager.grid_line(), true)
		btn.draw_rect(Rect2(Vector2(8.0, y), Vector2(w * float(done) / float(total), 3.0)),
				ThemeManager.safe(), true))


## 该变体在各尺寸（含正式关卡库的全部档）下的已通关总数。
func _cleared_total(mode_id: String) -> int:
	var n := 0
	for s in SIZES:
		for i in LEVELS_PER_SET:
			if _is_cleared(LevelSequence.level_key(mode_id, s, i)):
				n += 1
		var c := LevelLibrary.counts(mode_id, s)
		for t in c:
			for i in int(c[t]):
				if _is_cleared(LevelSequence.lib_key(mode_id, s, str(t), i)):
					n += 1
	return n


## 该变体的总关数（卡片进度条分母）：库内有关卡按库计，否则按生成关口径（5 尺寸 × 3 关）。
func _mode_total(mode_id: String) -> int:
	var t := LevelLibrary.total(mode_id)
	if t > 0:
		return t
	return SIZES.size() * LEVELS_PER_SET





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

	# 教程入口（2026-09-23 用户决策）：从主菜单总入口改为**上下文相关**——标题栏里放
	# 「教程」，点击看**当前变体**的教程（标题显示的就是变体名，语义直接对应）。
	# 覆盖层 add 到 self（整页）：弹窗 _overlay 同级但更早，教程节点后加 → 盖在弹窗之上 ✓
	var tut := Button.new()
	tut.text = "教程"
	tut.focus_mode = Control.FOCUS_NONE
	tut.custom_minimum_size = Vector2(72, 40)
	tut.set_meta("std_btn", true)
	tut.tooltip_text = "查看当前变体的教程"
	tut.pressed.connect(func():
		TutorialOverlayScript.show_for(self, str(MODES[_mode_idx]["id"])))
	head.add_child(tut)

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
	# 每次开弹窗都重建控件：清掉上一轮的引用，否则 _refresh_tier_buttons 会往
	# **已随弹窗释放**的按钮上写字（实机报「previously freed」）。
	_tier_btns.clear()
	_tier_col = null
	_size_btns.clear()
	_frame = PanelContainer.new()
	_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_frame.custom_minimum_size = Vector2(700, 0)
	# PanelContainer 默认 mouse_filter=IGNORE，不设 STOP 收不到滚轮事件
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame.gui_input.connect(_on_frame_input)
	parent.add_child(_frame)

	# 左：难度列（关卡库模式）｜右：尺寸栏 + 关卡网格——「上方棋盘大小、左侧难度竖列」。
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	_frame.add_child(row)

	_tier_col = VBoxContainer.new()
	_tier_col.add_theme_constant_override("separation", 8)
	_tier_col.custom_minimum_size = Vector2(120, 0)
	row.add_child(_tier_col)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 12)
	vbox.add_theme_constant_override("margin_right", 16)
	vbox.add_theme_constant_override("margin_top", 14)
	vbox.add_theme_constant_override("margin_bottom", 16)
	row.add_child(vbox)

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

	_build_tier_col()


## 难度列：四档竖排（关卡库模式）。每格 = 档名 + 该档关数；无内容的档置灰。
## 整个（变体 × 尺寸）库内无内容 → 整列隐藏，回退「按种子生成 3 关」的老流程。
func _build_tier_col() -> void:
	var cap := Label.new()
	cap.text = "难度"
	cap.add_theme_font_size_override("font_size", 15)
	cap.set_meta("secondary", true)
	_tier_col.add_child(cap)
	for t in LevelLibrary.TIER_ORDER:
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(120, 54)
		b.clip_text = true
		b.set_meta("choice_btn", true)
		b.pressed.connect(_on_tier_selected.bind(str(t)))
		_tier_col.add_child(b)
		_tier_btns.append(b)
		UiTheme.bind_hover(b, 1.04)


## 档位按钮刷新（文字 = 档名 + 关数；无内容置灰；非库模式整列隐藏）。
func _refresh_tier_buttons() -> void:
	if _tier_col == null or not is_instance_valid(_tier_col):
		return
	_tier_col.visible = _lib_mode
	if not _lib_mode:
		return
	var m: Dictionary = MODES[_mode_idx]
	var c := LevelLibrary.counts(str(m["id"]), SIZES[_size_idx])
	for i in _tier_btns.size():
		var t: String = str(LevelLibrary.TIER_ORDER[i])
		var n := int(c.get(t, 0))
		_tier_btns[i].text = "%s\n%d 关" % [_tier_text(t), n]
		_tier_btns[i].disabled = n <= 0
		_style_choice(_tier_btns[i], t == _tier)


func _on_tier_selected(t: String) -> void:
	if not _lib_mode or t == _tier:
		return
	if LevelLibrary.count(str(MODES[_mode_idx]["id"]), SIZES[_size_idx], t) <= 0:
		return
	_tier = t
	_page = 0
	_scroll_accum = 0.0
	_refresh_popup()


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
func _mode_feasible(mode: Dictionary, side: int) -> bool:
	# v3.0：候选雷数回退——标准值不可行但候选可行时，该尺寸仍可玩（生成侧自动用回退雷数）。
	# 全候选不可行才禁用（如 mx+rl 6×6：镜像+行锁在全部候选雷数下均矛盾）。
	# 注：参数名用 side——`size` 会遮蔽 Control.size 属性（分析器告警）。
	return int(RuleFeasibility.resolve_mines(str(mode["clue"]), mode.get("globals", []), side)["mines"]) >= 0


## 该尺寸对该变体是否可选（RM2，2026-09-21 审计修复）：
## 形状档（kind == "shape"）的内容在**关卡库**（levels_lib/shape_*）——库内没有该尺寸时，
## `_lib_mode` 为假 ⇒ 原实现会静默回退"按种子生成"，产出与卡名不符的**矩形经典关**，
## 且进度落在 gen:// 与 lib:// 两个分桶。改为：形状档没有库内容的尺寸一律不可选。
func _size_available(m: Dictionary, side: int) -> bool:
	if str(m.get("kind", "")) == "shape":
		return LevelLibrary.has_any(str(m["id"]), side)
	return _mode_feasible(m, side)


## 该变体是否在**任一尺寸**有正式关卡库内容（RM4：库 mode 一律不写演示进度）。
func _mode_has_lib(mode_id: String) -> bool:
	for s: int in SIZES:
		if LevelLibrary.has_any(mode_id, s):
			return true
	return false


func _refresh_popup() -> void:
	if _mode_idx < 0 or _grid == null:
		return
	var m: Dictionary = MODES[_mode_idx]
	# 当前尺寸不可选（数学不可行 / 形状档缺库内容）→ 自动切到最近的可选尺寸
	if not _size_available(m, SIZES[_size_idx]):
		for i in SIZES.size():
			var cand: int = ( _size_idx + i ) % SIZES.size()
			if _size_available(m, SIZES[cand]):
				_size_idx = cand
				break
	_title_label.text = "%s · %d×%d" % [m["name"], SIZES[_size_idx], SIZES[_size_idx]]

	# 尺寸按钮高亮 + 禁用（不可选组合置灰 + tooltip 说明原因，点不了）
	var is_shape := str(m.get("kind", "")) == "shape"
	for i in _size_btns.size():
		_style_choice(_size_btns[i], i == _size_idx)
		var ok := _size_available(m, SIZES[i])
		_size_btns[i].disabled = not ok
		if ok:
			_size_btns[i].tooltip_text = ""
		elif is_shape:
			# RM2：形状档缺库内容 ≠ 数学无解——文案必须区分（否则玩家以为是规则问题）
			_size_btns[i].tooltip_text = "该尺寸暂无形状关卡（量产入库后可选）"
		else:
			_size_btns[i].tooltip_text = \
				"该变体在 %d×%d（%d 雷）下数学上无解——请换尺寸或换变体" % [
						SIZES[i], SIZES[i], LevelSequence.mine_count(SIZES[i])]
	_style_frame()

	# ---- 关卡库开关（2026-09-17）：本（变体 × 尺寸）有正式关卡 → 走库（难度列生效）；
	#      没有 → 回退「按种子生成 3 关」的老流程（未量产的组合仍然可玩，无需开关切换）。
	_lib_mode = LevelLibrary.has_any(str(m["id"]), SIZES[_size_idx])
	if _lib_mode:
		var present := LevelLibrary.tiers_present(str(m["id"]), SIZES[_size_idx])
		if present.is_empty():
			# L1（2026-09-21 审计修复）：catalog 计数 > 0 但集文件损坏 / 档名不在 TIER_ORDER 时，
			# tiers_present 可能为空 —— 原实现 present[0] 直接越界报错。降级为"非库模式"（走生成流兜底）。
			_lib_mode = false
		elif not present.has(_tier):
			_tier = str(present[0])   # 默认落在该尺寸最轻的档（入门优先）
	else:
		_tier = ""
	_refresh_tier_buttons()
	_lib_count = LevelLibrary.count(str(m["id"]), SIZES[_size_idx], _tier) if _lib_mode else 0

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
	var end := mini(start + PAGE_SIZE, _set_count())
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
	if _lib_mode:
		# 库关卡：标签 = 序号 + 难度值（两行）——同一档内 100 关，玩家靠难度挑关
		var m: Dictionary = MODES[_mode_idx]
		btn.text = LevelLibrary.level_label(str(m["id"]), SIZES[_size_idx], _tier, idx)
		if cleared:
			btn.text += " ✓"
		# dif = 紧凑度画像（difficulty_profile.difficulty，Σ1/批量），**不是档位判据**——
		# v4.0 档位由峰值（max_complexity）落窗决定，故文案叫「紧凑度」而不叫「难度」。
		var dif := LevelLibrary.level_difficulty(str(m["id"]), SIZES[_size_idx], _tier, idx)
		btn.tooltip_text = "%s · %d×%d · %s 档第 %d 关\n（紧凑度 %.2f；正式量产关卡）" % [
				str(m["name"]), SIZES[_size_idx], SIZES[_size_idx],
				_tier_text(_tier), idx + 1, dif]
	else:
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
	for i in _set_count():
		if _is_cleared(_level_key(i)):
			cleared += 1
	if _lib_mode:
		_stat_label.text = "已通关 %d / %d\n（%s 档）" % [cleared, _set_count(),
				_tier_text(_tier)]
	else:
		_stat_label.text = "已通关 %d / %d" % [cleared, _set_count()]
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
		if c is Button and c.has_meta("idx"):
			var i := int(c.get_meta("idx"))
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
	if _lib_mode:
		return LevelSequence.lib_key(str(m["id"]), SIZES[_size_idx], _tier, idx)
	return "gen://%s/%d/%d" % [m["id"], SIZES[_size_idx], idx]


func _level_seed(idx: int) -> int:
	# 确定性种子：同模式+尺寸+序号必得同一盘。
	# v3.1：改用模式 id / 尺寸边长的稳定哈希而非数组下标——插入新变体/尺寸
	# 不再改变所有后续模式的种子（「同 seed 同盘」承诺不因 MODES/SIZES 顺序变化失效）。
	# 雷数不掺入种子（GDD §8.1）：它由 mode×size 经候选回退唯一确定，见 _level_key 注释。
	return hash("%s|%d|%d" % [str(MODES[_mode_idx]["id"]), SIZES[_size_idx], idx])


## 当前集的关数：关卡库 = 该（变体×尺寸×档）的关数；生成关 = LEVELS_PER_SET。
func _set_count() -> int:
	return _lib_count if _lib_mode else LEVELS_PER_SET


func _page_count() -> int:
	return maxi(1, ceili(float(_set_count()) / float(PAGE_SIZE)))


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
	for i in _set_count():
		var key := _level_key(i)
		if not _is_cleared(key) and not _is_skipped(key):
			return i
	return maxi(0, _set_count() - 1)


## 解锁条件：前一关**已通关或已跳过**。
## 跳过是失败终局给出的正当出路，同样推进序列（否则跳过按钮点了也进不去下一关）。
func _is_unlocked(idx: int) -> bool:
	if _lib_mode:
		return true   # 库关卡 = 官方内容，全部开放（不设逐关解锁，玩家自选难度与序号）
	if idx == 0:
		return true
	var prev := _level_key(idx - 1)
	return _is_cleared(prev) or _is_skipped(prev)


## 演示预设：首次进入某套时预置前 MOCK_CLEARED 关为「已通关」（便于演示解锁/继续流程）。
## **只写内存字典，不落盘**——写进 ProgressStore 等于往玩家真存档里塞假成绩。
func _ensure_mock() -> void:
	if _mode_idx < 0:
		return
	# RM4（2026-09-21 审计修复）：判据从"当前尺寸是库模式"改为"**该变体任一尺寸有库内容**"。
	# 原实现只看 _lib_mode（当前尺寸），形状卡首次打开时它还是初值 false ⇒ 写入了
	# gen://shape_*/ 的 mock 键；整页重建后 _cleared_total 把它算进卡片"已通关"，显示虚高。
	if _lib_mode or _mode_has_lib(str(MODES[_mode_idx]["id"])):
		return   # 库关卡不预置演示通关：真实内容从零进度开始（打勾代表玩家真打过）
	# 历史回归（2026-09-22 修复）：测试/工具运行中往 levels_lib 动态写库（或该进程启动时
	# 库为空、后来被导入），_mode_has_lib 会随后变真 —— 但演示记录早在库尚空时已写入。
	# 这里在「本次真的要写 mock」时**再次**复核库状态，防止往已有库内容的变体上垫假通关。
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
	# RM2 防御（正常已被 _refresh_popup 的尺寸禁用拦下）：形状档在库内无该尺寸内容时，
	# 绝不进"按种子生成"流——那会产出与卡名不符的**矩形经典关**。
	if str(m.get("kind", "")) == "shape" and not LevelLibrary.has_any(str(m["id"]), s):
		_play_btn.disabled = false
		UiToast.popup(self, "该尺寸暂无形状关卡（量产入库后可选）")
		return
	# 关卡库模式：直接物化正式关卡 → 开局（不经生成/可行性预筛——盘已在库里且门禁验过）。
	if _lib_mode and _tier != "":
		_play_btn.disabled = true
		_play_btn.text = "载入中…"
		# 等**真正画完一帧**再干重活（而非 process_frame：那只是帧回调，绘制在其之后）。
		# 后面紧跟着同步重活（start_level + change_scene_to_file 里首次构建 board_view），
		# 若在绘制前就阻塞，按钮状态永远上不了屏 —— 玩家观感是「点了没反应，画面静止」。
		await RenderingServer.frame_post_draw
		# await 期间玩家可能已关掉弹窗（控件已释放）：失败路径触碰控件前必须判活
		var lp := LevelLibrary.materialize(str(m["id"]), s, _tier, _selected)
		if lp == "":
			if is_instance_valid(_play_btn):
				_play_btn.disabled = false
				_refresh_stat()
			UiToast.popup(self, "关卡数据缺失（%s 档第 %d 关）" % [
					_tier_text(_tier), _selected + 1])
			return
		if _try_resume_saved(lp):
			return
		if GameSession.start_level(lp):
			get_tree().change_scene_to_file("res://ui/board_view.tscn")
			return
		if is_instance_valid(_play_btn):
			_play_btn.disabled = false
			_refresh_stat()
		UiToast.popup(self, "关卡加载失败")
		return
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
	# 自动续档（v3.2）：本关有「未终局、未通关」的进行中存档 → 直接恢复该进度，
	# 不重开、不弹窗；恢复失败（坏档/雷位校验不符）则照常全新开局。
	# 已通关的关不再续旧档（重玩应当从零开始）。
	if _try_resume_saved(path):
		return
	if GameSession.start_level(path):
		get_tree().change_scene_to_file("res://ui/board_view.tscn")
	else:
		_play_btn.disabled = false
		_refresh_stat()
		UiToast.popup(self, "关卡加载失败")


## 自动续档：存档存在、未终局、level_path 与本关一致、且本关尚未通关 → 恢复并进对局。
## 任一条件不满足或恢复失败 → false（调用方照常全新开局），绝不阻断开局路径。
func _try_resume_saved(path: String) -> bool:
	var d := SaveCoordinator.load_save()
	if d.is_empty():
		return false
	var meta_v: Variant = d.get("metadata", {})
	if not (meta_v is Dictionary):
		return false
	var meta: Dictionary = meta_v
	if bool(meta.get("ended", false)):
		return false  # 终局盘不可恢复（防 SL 复活失败局，同 restore_from_save 口径）
	if str(meta.get("level_path", "")) != path:
		return false  # 存的是别的关 → 交还给全新开局（旧档随后被新对局存档覆盖）
	if _is_cleared(_level_key(_selected)):
		return false  # 已通关的关重玩 = 从零开始，不续旧进度
	if not GameSession.restore_from_save():
		# RM3（2026-09-21 审计修复）：存档与本关匹配但恢复失败（典型：库重导入 → materialize
		# 重写了同名关卡文件 ⇒ 旧档的雷位/尺寸与新盘不符）——旧进度即将被新对局存档覆盖。
		# 必须明确告知，否则玩家只看到"从第 1 关重来"而不知原因（静默丢进度）。
		UiToast.popup(self, "存档与当前关卡数据不符（关卡可能已更新），已开始新对局")
		return false
	get_tree().change_scene_to_file("res://ui/board_view.tscn")
	return true


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
	# v4.1 严格难度梯度：目标窗口 = 当前档位窗口；未选档（""）则只要求「落在梯度内」。
	var win := Difficulty.tier_range(_tier)
	if FileAccess.file_exists(path):
		# 缓存关也要过梯度复验：历史产物可能出自旧口径/旧窗口（v4.0 四档或更早标量），
		# 玩家不该拿到名不副实的一关。不合格就删掉重生成（自愈，不静默复用）。
		if _gen_file_conforms(path, win):
			return path
		DirAccess.remove_absolute(path)

	DirAccess.make_dir_recursive_absolute(LevelSequence.GEN_DIR)
	var dlg := _open_gen_dialog(s)
	var deadline := Time.get_ticks_msec() + _gen_timeout(s)
	var gen := PuzzleGenerator.new()
	var out := ""
	var rejected := 0   # 窗口外拒收数（用于区分「产不出」与「超时」的失败原因）
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
		# v4.1 严格梯度：不命中窗口就不落盘（宁可不产，也不产「文件和档位名不副实」的关）。
		var peak := int((level.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))
		if not _gen_peak_ok(peak, win):
			rejected += 1
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
	if out == "" and rejected > 0 and not _gen_cancel:
		# 把失败原因讲清楚：不是"卡住"，而是该（变体×尺寸）在本档窗口内产不出内容
		var want := Difficulty.tier_text(_tier) if _tier != "" else "符合梯度"
		UiToast.popup(self, "该变体在 %d×%d 产不出「%s」的关卡（已试 %d 次，%d 次落在窗口外）——建议换难度或换尺寸" % [
			s, s, want, GEN_ATTEMPTS, rejected])
	return out


## v4.1 严格梯度：峰值可否收下。选档时必须命中该档窗口；未选档时至少落在梯度内
##（peak≤1 一眼盘、≥21 超纲都不收 —— 与入库闸门、retier 重标同一判据）。
func _gen_peak_ok(peak: int, win: Vector2i) -> bool:
	if win.x >= 0:
		return Difficulty.in_window(peak, win.x, win.y)
	return Difficulty.tier_of_peak(peak) != ""


## 复用已缓存生成关前的口径复验（防历史缓存绕过梯度）。
func _gen_file_conforms(path: String, win: Vector2i) -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return false
	var dp: Dictionary = (parsed as Dictionary).get("difficulty_profile", {})
	if not Difficulty.gradient_ok(dp):
		return false
	return _gen_peak_ok(int(dp.get("max_complexity", -1)), win)


## 生成进度弹窗：明确告诉玩家「程序在忙」，并给取消出口。
func _open_gen_dialog(side: int) -> PopupPanel:
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
	title.text = "正在生成 %d×%d 关卡" % [side, side]
	title.add_theme_font_size_override("font_size", 22)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)

	var sub := Label.new()
	sub.add_theme_font_size_override("font_size", 16)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.text = "大概需要 %d 秒，复杂变体会更久" % _estimate_gen_seconds(side)
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
		if n is Label and n.has_meta("secondary"):
			var col := ThemeManager.text_secondary() if bool(n.get_meta("secondary")) else ThemeManager.text()
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
		elif c is Button and c.has_meta("std_btn") and bool(c.get_meta("std_btn")):
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
