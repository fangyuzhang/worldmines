extends Control

## 变体扫雷编辑器（P2）：左工具栏 / 中画布 / 右面板（属性·规则·验证）/ 底状态栏。
##
## 【为什么 UI 全在代码里建】`.tscn` 只放"根 Control + 本脚本"，子节点在 `_ready()` 里建：
## 手写大段 .tscn 布局在本环境里既没法目视校准，diff 也读不出语义（.tscn 是数据不是代码）。
## 需求要的是"普通玩家不需要看代码也能上手"，所以标签/按钮一律中文、每个工具有文字说明。
##
## 【职责分工】本文件负责"编辑会话"：撤销栈、面板、存读、验证、试玩、打包；
## 画布（`ui/editor_canvas.gd`）只负责画格子与翻译鼠标；数据与规则全在 `core/editor_doc.gd`
##（含实时预览与校验）、验证在 `core/editor_verify.gd`、打包在 `core/workshop_pack.gd`。
##
## 【撤销为什么用快照而不是 op】编辑动作五花八门（画笔/橡皮/填充/粘贴/随机布雷/改尺寸），
## 逐个写 op 既要覆盖所有路径又容易漏；整份文档快照（`to_level_json()`）在 64x64 上只有几 KB，
## 50 步上限与 `ui/drawing_layer.gd:26 UNDO_LIMIT` 同口径 ⇒ 简单且不会漏。
## 拖动时按时间窗合并（700ms 内的连续改动算一步），否则一笔画会吃掉半条撤销栈。

const CANVAS := preload("res://ui/editor_canvas.gd")
const UI_TOAST := preload("res://ui/ui_toast.gd")

const EDITOR_DIR := "user://editor"
## 图标工厂：本仓约定是**逐文件 preload**（`ui_icons.gd` 刻意没有 class_name，见其文件头注释）
const Icons := preload("res://ui/ui_icons.gd")
const AUTOSAVE_PATH := "user://editor/_autosave.json"
const PLAY_PATH := "user://editor/_play.json"
## 试玩回程（2026-10-02）：点「试玩」时把它写进 `GameSession.playtest_return`，
## 游戏 HUD / 结算层据此多显示「回编辑器」按钮（正式游戏里该标记为空 ⇒ 玩家看不到"编辑器"字样）。
const PLAYTEST_RETURN := "res://ui/level_editor.tscn"
const UNDO_LIMIT := 50
const STROKE_COALESCE_MS := 700
const AUTOSAVE_IDLE_MS := 1200
## 昂贵检查（拓扑审计 + 关卡结构校验）与全量预览的去抖窗口。
## 实测（64x64 环绕盘 / 400 雷）：全量预览 101 ms、`grid()` 91 ms、拓扑审计更贵 ⇒
## 每改一格都跑一遍会让拖动直接卡死；去抖后编辑路径只剩"增量重算 ≤9 格"。
const CHECKS_IDLE_MS := 260

var doc: EditorDoc
var canvas: EditorCanvas

var _syncing := false
var _undo: Array = []
var _redo: Array = []
var _last_undo_ms := 0
var _dirty := false
var _last_change_ms := 0
# 去抖待办（0 = 无）：昂贵检查与全量预览不能每敲一个字符/每画一格就跑
var _checks_due := 0
var _full_preview_due := 0

var _status: Label
## 「说明」层（2026-10-02 用户需求）：独立的「说明」按钮开关，默认不显示。
## 说明卡片贴在各自按钮**右边**、用折线连起来；读数（雷数/格子数）**不受影响**。
## 实现见 `ui/editor_help.gd`（非模态、不挡点击、每帧跟随按钮位置）。
var _help_layer: Control = null
var _help_btn: Button
## 左栏根节点：「说明」层要扫描它的按钮来生成条目
var _left_bar: Control = null
## 右侧页签容器：「说明」层要显示**当前页**的说明，并跟着页签切换更新
var _tabs: TabContainer = null
## 【审查 D12 删除】`TAB_HELP` 与 `_tab_help_title/_tab_help_text` 已无调用方（说明层 v4 改走
## `_help_page_items` 逐控件收集）。留着只会误导后来人以为"页级说明"还在生效。


## 从界面上**搬进「说明」的长解释文字**（用户原话：用户忘了一个按钮是干什么的，打开说明看一眼就想起来了；
## 会了之后再看界面上这么多字会觉得烦 ⇒ 界面只留干净列表，正文放这里）。
## 键 = 界面上那条"指路标签"的开头（说明卡片会连线指回它）。
## 【2026-10-02 用户口径："说明里都是说了一堆废话，删了，换成给用户的引导"】
## 一步一句话、动词开头、只说"点了会发生什么"，不解释为什么这么设计。
const HELP_GUIDE := ("① 左栏「随机布雷」——先铺一盘\n"
	+ "② 「开始验证」——看它能不能不靠猜推完\n"
	+ "③ 不满意：改「棋盘尺寸 / 布雷」，或去「AI 帮我写」说一句你要的规则\n"
	+ "④ 满意：点「生成分享包」→「装进游戏」，选关页就能玩到")


# 【2026-10-02 用户口径】原来这里的三段长解释（操作提示 / 术语对照 / 验证不通过怎么办）已**删除**，
# 说明层改为一条照着点的引导（见 HELP_GUIDE）。删掉的原因就一句：用户觉得它们是废话。


## 在左栏找那条"指路标签"（按开头的词匹配），让说明卡片能连线指回它。
# 【2026-10-03 清理】`_find_bar_label()` 已删除：它是为「三段长解释找锚点」而写的，那三段已按用户口径
# 删掉（见 HELP_GUIDE），于是它再无调用方。留着就是"下一个人以为还有这套机制"的死代码。


## 说明文字的字色：【用户要"白字看清楚"】+【审查 A2：不能把浅色主题变成白底白字】。
## 规则：当前主题的字色本身浅（深底主题）⇒ 给纯白（最清楚）；浅底主题 ⇒ 跟随主题字色。
func _label_color() -> Color:
	var c := ThemeManager.text()
	if c.get_luminance() < 0.5:
		return Color(1, 1, 1, 1)
	return c


## 主题切换后重刷字色：`font_color` 是 per-label override，**不会**随主题自动变。
func _repaint_labels() -> void:
	var c := _label_color()
	for n in find_children("*", "Label", true, false):
		var lb := n as Label
		if lb.has_meta("ed_label"):
			lb.add_theme_color_override("font_color", c)


## 当前页签名与它的说明（页签切换时同步给「说明」层）。
## 懒查找右侧页签容器：它在 `_ready` 里比左栏**晚**构建 ⇒ 早期查不到（CI 与真机都踩过），
## 所以第一次真需要时再找，找到就缓存。
func _right_tabs() -> TabContainer:
	if _tabs != null and is_instance_valid(_tabs):
		return _tabs
	for n in find_children("*", "TabContainer", true, false):
		_tabs = n as TabContainer
		return _tabs
	return null


## 按钮没有 tooltip 时的兜底说明（键 = 按钮文字；有 tooltip 的优先用 tooltip，两者都空就跳过）。
const HELP_TEXT := {
	"说明": "点一次展开：每段解释就贴在对应按钮右边，中间那条折线表示这段字说的是谁；再点一次收起。",
	"随机布雷（按上面的雷数）": "按「布雷」那栏填的雷数，在空格子里随机撒雷（可撤销）。",
	"清空全部雷/障碍/翻开": "一次性清空盘面（会先问一句；清空后能撤销）。",
	"返回选关": "回到关卡列表（会先自动存档）。",
	"开始验证": "检查这一关能不能不靠猜推完，下面会给出结论与问题清单。",
	"新手引导（怎么用）": "重新打开首屏那三句话（忘了怎么用时看这里）。",
	"安装分享包（装进游戏）": "把别人给的 zip 分享包装进游戏：选关页 → Mod 里就能玩到。",
	"换一盘随机布雷": "验证不通过时最快的出路：换一盘随机布雷再试。",
	"先去试玩看看": "直接开一局感受难度（等同正式游戏，试玩里能回编辑器）。",
	"复制关卡文本（发给别人）": "把整关数据复制成文本，方便贴给别人。",
	"粘贴关卡文本（别人发来的）": "把别人发来的关卡文本粘回来，直接变成当前关卡。",
	"打开存档文件夹": "打开本机存档目录（分享包 zip 也在这里）。",
	"打开这个存档": "打开下拉框里选中的那份存档（自动存档也会出现在列表里）。",
	"生成分享包": "把当前关卡打成一个 zip（带分类与图文图例）；没接 Steamworks 时要自己上传。",
	"要做很多关？→ 批量生成关卡": "一次做一批关卡：勾棋盘大小、填每档几关（可选先探一次），带进度条与预计时间，随时能停；做完自动打包并装进游戏。",
	"插入「周围 8 格计数」模板": "在规则原文里插入「周围 8 格 = 数字」的标准写法，改规则时省得从零写。",
	# 从「AI 帮我写」页搬进说明的原文（界面已不再显示）——挂在这一页的关键按钮上，
	# 这样它依然是"点这个按钮时能看到的说明"（用户要求：只解释控件，不解释"页"）。
	"复制「给 AI 的话」（点完去粘给 AI）": "照这三步做（不用懂代码、不用懂 JSON）：\n"
		+ "① 上面写一句你想要的效果（或点一个现成例子）→ 点这个按钮复制那段话\n"
		+ "② 打开你电脑上任意一个 AI 聊天（DeepSeek / 豆包 / ChatGPT…），把那段话粘进去、回车\n"
		+ "③ 把 AI 的**整段回复**（带解释、带代码块都行）粘到下面 ② 的框里 → 点「读懂并导入」\n"
		+ "导入成功后右边棋盘会立刻按新规则算数字；不满意就改①那句话，再来一遍。\n\n"
		+ "不会写代码也能做规则：把想法交给电脑上的任意 AI，它给你一段 JSON；"
		+ "你把它的整段回复粘回来就行 —— 编辑器会自己找出 JSON、检查，并马上算给你看。",
	"读懂并导入": "把 ② 那个框里的整段 AI 回复读懂并算一遍：能认出 JSON 就当作新规则（立刻按它重算棋盘数字）。",
	"从剪贴板粘贴": "把剪贴板里的内容直接填进 ② 的框（省得手动 Ctrl+V）。",
	"③ 导入失败？点这里复制「让 AI 修」的话": "导入失败时点它：复制一段「把错误说明给 AI、让它改好再来」的话。",
}
var _rows_spin: SpinBox
var _cols_spin: SpinBox
var _mines_spin: SpinBox
var _density_label: Label
var _foreign_note: Label
var _wrap_check: CheckBox
var _shape_opt: OptionButton
var _shape_size: SpinBox
var _self_check: CheckBox
var _preset_opt: OptionButton
var _dirs_edit: LineEdit
var _rule_id_edit: LineEdit
var _spec_edit: TextEdit
var _rule_report: Label
var _verify_state: Label
var _verify_issues: VBoxContainer
var _issues_box: VBoxContainer
var _open_opt: OptionButton
# ---- 零代码页「AI 帮我写」（逻辑在 core/spec_helper.gd，本页只负责"三段式"交互）----
var _idea_edit: LineEdit
var _ai_text: TextEdit
var _ai_result: Label
var _ai_fix_btn: Button
var _recipe_opt: OptionButton
var _recipe_note: Label
# ---- 小白可用性修补（2026-10-02 以小白身份走查后加的）----
# 关卡名字：原界面**没有**任何地方能起名字 ⇒ 存出来永远叫 level.json / level_2.json…
var _title_edit: LineEdit
# 首屏"三句话"引导条（可关、可从左栏「新手引导」再打开）
var _intro_bar: PanelContainer
# 验证结论的"人话"一行（技术细节仍在下面那一行，但先让小白看懂结论）
var _verify_plain: Label
## 验证按钮：验证是同步重活 ⇒ 点下去先禁用 + 写"正在验证…"，算完再恢复。
var _verify_btn: Button
## 危险操作确认条（自绘，见 `_build_confirm_bar` 的注释）
var _confirm_bar: PanelContainer
var _confirm_label: Label
var _confirm_action := Callable()
# ---- 批量生成（P6）：参数弹窗 + 逐帧步进 + 进度条/ETA ----
var _forge: BatchForge = null
var _forge_dlg: PopupPanel
var _forge_msg: Label
var _forge_hint: Label
var _forge_bar: ProgressBar
## 雷密度（百分比 SpinBox）：标准扫雷 12.3%。原来只显示不可改，用户以为编辑器没问过雷数。
var _forge_ratio: SpinBox
## 重型预探（P6e）：实测能力档案 → 事前预估"哪些档能出、这批大概多久"。
## 预算 45 秒、每个大小 4 个候选（**粗测**：目的是给预期，不是精确画像）。
const FORGE_PROBE_BUDGET_MS := 45000
const FORGE_PROBE_CAND := 4
var _forge_probe_btn: Button
var _forge_est: Label
var _probe_running := false
var _probe_cancel := false
## 弹窗尺寸（成员而非常量：测试要拿它验"控件都在窗口内"，写成常量测试就取不到）
var _forge_dlg_size := Vector2i(660, 680)
var _forge_start_btn: Button
var _forge_stop_btn: Button
var _forge_close_btn: Button
## 【审查修 B6】关窗即停：置位后协程收尾**不打包**（否则用户以为关掉了，却收到"生成完成"）。
var _forge_closed := false
var _forge_size_checks: Dictionary = {}    # 边长 -> CheckBox
var _forge_count_spins: Dictionary = {}    # 档位 -> SpinBox
var _forge_mines_labels: Dictionary = {}   # 边长 -> Label（显示这一档雷数用几颗）
## 上一次批量的产出（打包/安装要用）：{dir, files, index, categories, tutorial_dir}
var _forge_out: Dictionary = {}
## 布局规则入口（P6d）：给变体加"雷怎么摆"的约束（如"任意 2×2 里最多 2 颗雷"）。
## 没有它，AI 路径做出来的变体只能带线索规则 ⇒ 图例里那套「满足 / 不满足」棋盘演示
## **永远不会出现**（演示只对布局型规则有意义）。
var _global_opt: OptionButton
var _global_list: Label
const INTRO_SEEN_PATH := "user://editor/_intro_seen"
## 上一次导入失败时的原文与报错：「让 AI 修」按钮把它们原样交回给 AI（用户不必看懂 JSON）。
var _ai_last_text := ""
var _ai_last_errors: Array[String] = []
## 当前正在编辑的文件路径（"" = 还没保存过）。保存时优先覆盖它，避免同名关卡互相覆盖。
var _current_path := ""
var _tool_group := ButtonGroup.new()
var _kind_group := ButtonGroup.new()


func _ready() -> void:
	add_to_group("themed")
	name = "LevelEditor"
	ThemeManager.theme_changed.connect(_on_theme_changed)
	ThemeManager.theme_settled.connect(_on_theme_settled)
	_build_ui()
	doc = EditorDoc.new(9, 9)
	_doc_to_ui()
	_load_autosave_if_any()
	_refresh_all()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _full_preview_due != 0 and now >= _full_preview_due:
		_full_preview_due = 0
		_refresh_preview()
		_refresh_errors()
	if _checks_due != 0 and now >= _checks_due:
		_checks_due = 0
		_refresh_errors()
	if not _dirty:
		return
	if now - _last_change_ms < AUTOSAVE_IDLE_MS:
		return
	_write_autosave()


# ==================== UI 组装 ====================

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	# 首屏"三句话"：实测小白打开后看不懂"这是干什么的、从哪开始"（全界面没有标题/说明）。
	root.add_child(_build_intro_bar())
	# 危险操作确认条（默认隐藏，见 _build_confirm_bar）
	root.add_child(_build_confirm_bar())

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	root.add_child(body)

	# 左栏建好后做一次套框后处理（每组一块面板，见 _frame_left_bar_groups）：
	# 放在构建**之后**是刻意的 —— 各组代码不必知道"框"的存在，将来加新组自动被框住。
	var left_bar := _build_left_bar()
	_frame_left_bar_groups(left_bar)
	_left_bar = left_bar                      # 「说明」层要扫描它的按钮
	for n in find_children("*", "TabContainer", true, false):
		_tabs = n as TabContainer             # 右侧页签容器（说明要显示"当前页"）
	body.add_child(left_bar)
	canvas = CANVAS.new()
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 画布最小尺寸：窗口被压小时宁可让左右面板先挤，也不要让画布塌成 0（塌了就完全没法编辑）
	canvas.custom_minimum_size = Vector2(240, 180)
	canvas.cell_edited.connect(_on_cell_edited)
	# 框选完成时的即时提示（P6h）：用户实测抱怨"选完还得跑去左栏点复制按钮"太绕 ⇒ 当场把下一步写出来。
	# 用**内联 lambda** 是刻意的：这段文案只服务于这一个信号，不值得为 4 行再加一个成员函数；
	# 判据是"框选那一刻用户就知道该按什么"：剪贴板空 ⇒ 提示 Ctrl+C；有内容 ⇒ 提示 Ctrl+V 粘到此处。
	canvas.selection_changed.connect(func(rect: Rect2i) -> void:
		if rect.size == Vector2i.ZERO:
			return
		if _clipboard_cells.is_empty():
			_toast("已框选 %d×%d：按 Ctrl+C 复制这片格型（或点左栏「复制选区」）" % [
				rect.size.x, rect.size.y])
		else:
			_toast("已框选 %d×%d：按 Ctrl+V 把刚复制的 %d 格粘到这里" % [
				rect.size.x, rect.size.y, _clipboard_cells.size()]))
	# 撤销点取在"改动之前"（画布在手势开始时发这个信号）——见 editor_canvas.gd 里那条注释
	canvas.cell_edit_started.connect(_on_cell_edit_started)
	body.add_child(canvas)
	body.add_child(_build_right_panel())

	root.add_child(_build_status_bar())


## 首屏"三句话"引导条。
## 【为什么必须有】2026-10-02 以小白身份实测：打开后看不懂「这是干什么的 / 从哪开始」——
## 全界面没有一个标题或一句说明，唯一像引导的是画布操作提示。
## 点「知道了」后不再自动出现（标记文件），左栏「新手引导（怎么用）」可随时再打开。
func _build_intro_bar() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "新手引导"
	_intro_bar = panel
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := _plain_label("第一次用？三步就能玩上：① 右边「棋盘」设行/列和雷数 → ② 左边「随机布雷」 → ③ 左上角「试玩」。"
		+ "想改玩法（比如只算上下左右、数字 +1）→ 右边第二页「AI 帮我写」，照着点就行。")
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var ex := _action_button("看示例关卡", _load_example)
	ex.custom_minimum_size = Vector2(110, 32)
	row.add_child(ex)
	var ok := _action_button("知道了", func() -> void: _set_intro_visible(false))
	ok.custom_minimum_size = Vector2(80, 32)
	row.add_child(ok)
	panel.add_child(row)
	panel.visible = not FileAccess.file_exists(INTRO_SEEN_PATH)
	return panel


## 显示/关闭引导条。persist=true 时把"看过了"记到磁盘（只有点「知道了」才记，
## 这样"再打开"这次会话内不会立刻自相矛盾）。
func _set_intro_visible(v: bool, persist := true) -> void:
	if _intro_bar == null:
		return
	_intro_bar.visible = v
	if persist and not v:
		DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
		var f := FileAccess.open(INTRO_SEEN_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string("1")
			f.close()


## 危险操作的确认条（默认隐藏）。
## 【为什么自绘、不用 AcceptDialog/ConfirmationDialog】本仓在无头（GUT/CI）下会实例化编辑器：
## 原生弹窗会真的开窗口、要人去关，测试不可控；自绘只是一个 PanelContainer + 两个按钮，
## 测试可以直接断言"问了没有 / 点了确认才生效"。
func _build_confirm_bar() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "确认条"
	_confirm_bar = panel
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_confirm_label = _plain_label("")
	_confirm_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_confirm_label)
	var yes := _action_button("确认", func() -> void: _resolve_confirm(true))
	yes.custom_minimum_size = Vector2(84, 32)
	row.add_child(yes)
	var no := _action_button("取消", func() -> void: _resolve_confirm(false))
	no.custom_minimum_size = Vector2(84, 32)
	row.add_child(no)
	panel.add_child(row)
	panel.visible = false
	return panel


## 问一句再动手（用于"一下就没了"的操作，例如清空全部）。
func _ask_confirm(msg: String, action: Callable) -> void:
	_confirm_action = action
	_confirm_label.text = msg
	_confirm_bar.visible = true


func _resolve_confirm(ok: bool) -> void:
	if _confirm_bar != null:
		_confirm_bar.visible = false
	var a := _confirm_action
	_confirm_action = Callable()
	if ok and a.is_valid():
		a.call()


func _build_left_bar() -> Control:
	# 【2026-10-02 小白实测后的结构改动】原来左栏是一整个滚动区：内容高 1010px、窗口只有 691px
	# ⇒ 「保存」「试玩」这两个**最关键**的按钮在屏幕外，不滚滚轮根本看不到。
	# 现在把「试玩 / 保存」常驻顶部（不随滚动），其余说明性/高级功能留在下面的滚动区。
	var outer := VBoxContainer.new()
	outer.custom_minimum_size = Vector2(196, 0)
	outer.add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var play_btn := _action_button("试玩", _playtest)
	play_btn.custom_minimum_size = Vector2(92, 40)
	play_btn.add_theme_font_size_override("font_size", 15)
	play_btn.tooltip_text = "用现在这块棋盘直接开一局（等同正式游戏）"
	top.add_child(play_btn)
	var save_btn := _action_button("保存", _save)
	save_btn.custom_minimum_size = Vector2(92, 40)
	save_btn.add_theme_font_size_override("font_size", 15)
	save_btn.tooltip_text = "存到游戏存档文件夹（Ctrl+S 同效）"
	top.add_child(save_btn)
	# 「说明」开关（2026-10-02 用户需求）：独立的第三个常驻按钮，默认收起。
	# 点开把每个按钮的用法贴在**它自己右边**并用折线连起来（见 _toggle_help / ui/editor_help.gd）。
	_help_btn = _action_button("说明", _toggle_help)
	_help_btn.custom_minimum_size = Vector2(92, 40)
	_help_btn.add_theme_font_size_override("font_size", 15)
	_help_btn.toggle_mode = true          # 展开时显"按下"，一眼看出现在是不是开着
	_help_btn.tooltip_text = "展开/收起按钮说明（解释贴在每个按钮右边，用线连起来）"
	top.add_child(_help_btn)
	outer.add_child(top)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	# 工具按钮较多：装进滚动容器，矮窗口下可滚动而不是把底部按钮挤出屏幕
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_child(box)
	outer.add_child(scroll)
	# 「一关做完的四个步骤」（P7.3，小白友好）。这条路径原来散落在各处 tooltip 与提示里，
	# 新手得自己拼"下一步该干嘛"；这里给一条**有序**的直达通道（每步一句说明）。
	# 放在工具清单**之前**是刻意的：第一次打开的人先要看到"流程"，而不是"一堆工具"。
	box.add_child(_section_label("一关做完的四个步骤（点按钮直达）"))
	var flow := HBoxContainer.new()
	flow.add_theme_constant_override("separation", 4)
	for step in [
			["① 验证", "检查这关能不能不靠猜推完；过不了就按提示改盘面（会顺手切到「验证」页）",
				Callable(self, "_flow_verify")],
			["② 试玩", "进游戏亲手玩一遍（会先自动存一次，不怕丢）", Callable(self, "_playtest")],
			["③ 保存", "存进游戏存档（Ctrl+S 同效）", Callable(self, "_save")],
			["④ 分享", "生成分享包 zip（在「打开存档文件夹」里）；要装进游戏就点下面的「安装分享包」",
				Callable(self, "_make_pack")]]:
		var step_btn := _action_button(str(step[0]), step[2])
		step_btn.tooltip_text = str(step[1])
		step_btn.add_theme_font_size_override("font_size", 12)   # 一行放四个，字号缩小
		flow.add_child(step_btn)
	box.add_child(flow)
	# 【真机目视发现 2026-10-02】左栏内容已长到 ≈2 屏高（四步条 + 提示 + 术语对照 + 工具 + 格型
	# + 布雷 + 编辑 + 存档与分享 + 批量做关卡…），「批量生成关卡」按钮落在**首屏之外**
	#（要滚约 1.5 屏），而它是"一次做很多关"的唯一入口 —— 小白不会去滚一个看不出有内容的侧栏。
	# 所以首屏（四步条正下方）再放一个同样的入口；下面那一组保留（那里有「安装分享包」等邻居）。
	box.add_child(_action_button("要做很多关？→ 批量生成关卡", _open_forge))
	box.add_child(_section_label("工具"))
	# 每个工具都要能自己讲清"这是什么、拿来干什么"——用户实测问过"区域选择有什么用吗"，
	# 而它（配合下面的「复制选区 / 粘贴到选区」整块复制格型）在界面上原本一个字都没解释。
	for t in [[EditorCanvas.Tool.PAINT, "画笔", "在格子上涂当前选的格型（按住拖动可连画）"],
			[EditorCanvas.Tool.ERASE, "橡皮", "把格子擦回「空」"],
			[EditorCanvas.Tool.RECT_FILL, "矩形填充", "拖一个方框，整块刷成当前格型（批量摆障碍/已翻开）"],
			[EditorCanvas.Tool.SELECT, "区域选择",
				"先框选一片区域，再用下面的「复制选区 / 粘贴到选区」整块复制格型——例如把一块障碍图案搬到别处"],
			[EditorCanvas.Tool.PAN, "平移（或按住中键）", "拖动整张棋盘看（棋盘很大时用）；也可以直接按住鼠标中键拖"]]:
		var tool_btn := _toggle_button(str(t[1]), _tool_group, func() -> void:
			canvas.tool = int(t[0]))
		tool_btn.tooltip_text = str(t[2])
		box.add_child(tool_btn)

	box.add_child(_section_label("格型（画笔画什么）"))
	for k in [[EditorCanvas.KIND_MINE, "地雷"], [EditorCanvas.KIND_OBSTACLE, "障碍"],
			[EditorCanvas.KIND_REVEAL, "初始已翻开"], [EditorCanvas.KIND_CLEAR, "清空该格"]]:
		box.add_child(_toggle_button(str(k[1]), _kind_group, func() -> void:
			canvas.paint_kind = str(k[0])))

	box.add_child(_section_label("布雷"))
	var row := HBoxContainer.new()
	row.add_child(_plain_label("雷数"))
	_mines_spin = _spin(1, 4096, 1)
	_mines_spin.value_changed.connect(func(_v: float) -> void: _on_mines_changed())
	row.add_child(_mines_spin)
	box.add_child(row)
	box.add_child(_action_button("随机布雷（按上面的雷数）", _random_mines))
	box.add_child(_action_button("清空全部雷/障碍/翻开", _clear_all))

	box.add_child(_section_label("编辑"))
	var r2 := HBoxContainer.new()
	r2.add_child(_action_button("撤销", _undo_once))
	r2.add_child(_action_button("重做", _redo_once))
	box.add_child(r2)
	var r3 := HBoxContainer.new()
	r3.add_child(_action_button("复制选区", _copy_selection))
	r3.add_child(_action_button("粘贴到选区", _paste_selection))
	box.add_child(r3)
	# 术语白话化（2026-10-02 小白实测）：原按钮写着 JSON / 剪贴板 / workshop 包 / user://mods/，
	# 实测完全看不懂，这里改成"文本 / 分享包 / 存档文件夹"。
	box.add_child(_action_button("复制关卡文本（发给别人）", _export_clipboard))
	box.add_child(_action_button("粘贴关卡文本（别人发来的）", _import_clipboard))

	box.add_child(_section_label("存档与分享"))
	_open_opt = OptionButton.new()
	_open_opt.custom_minimum_size = Vector2(0, 30)
	box.add_child(_open_opt)
	box.add_child(_action_button("打开这个存档", _open_selected))
	box.add_child(_action_button("打开存档文件夹", _open_save_dir))
	var pack_btn := _action_button("生成分享包", _make_pack)
	# 悬停说明补上"上传哪个文件"：实测小白看到"请手动上传"时不知道要传什么、在哪找。
	pack_btn.tooltip_text = "生成一份 zip 分享包（文件在左栏「打开存档文件夹」里）；本机没接 Steamworks 时要自己上传"
	box.add_child(pack_btn)
	box.add_child(_section_label("批量做关卡（一次做很多关）"))
	var forge_btn := _action_button("批量生成关卡（按大小 × 档位）", _open_forge)
	forge_btn.tooltip_text = "勾选棋盘大小、填每个难度要几关，一次生成一批；带进度条与预计时间，随时可停"
	box.add_child(forge_btn)
	box.add_child(_action_button("安装分享包（装进游戏）", _install_pack))
	box.add_child(_action_button("返回选关", _back_to_select))
	box.add_child(_action_button("新手引导（怎么用）", func() -> void: _set_intro_visible(true, false)))
	# 【为什么写这么长】2026-10-02 以"手机扫雷玩家"身份实测：他的第一反应是**左键点格子想开格**，
	# 但在编辑器里左键 = 放雷；他还会**右键想插旗**，而编辑器里右键什么都不做（编辑器没有"旗帜"格型）。
	# 这两件事必须在界面上说清，否则他会以为"点了没反应/我是不是搞坏了"。
	# 【用户要求 2026-10-02：界面只留"干净的列表"】原来这里 4 行操作说明，其中"插旗"那句搬进「说明」
	#（见 REF_TEXT["操作提示"]），界面压成两行短句、只留最要紧的。
	box.add_child(_section_label("操作提示"))
	box.add_child(_plain_label("左键点格子 = 放雷 / 改格型（不是开格！）｜右键 = 擦掉该格（按住可连擦）\n"
		+ "拖动 = 连续画 ｜滚轮 = 缩放 ｜中键拖 = 平移 ｜快捷键：Ctrl+Z 撤销 ｜ Ctrl+Y 重做 ｜ Ctrl+S 保存"))
	# 术语对照（P7.5，小白友好）：规格/邻域/环绕/深度/峰值 这些词界面上到处在用，
	# 但**没有一处解释过它们**——第一次来的人只能猜。就地给一张小对照表，比 tooltip 更可靠
	#（tooltip 不悬停就看不到，本会话已在别处踩过这个坑）。
	# 【用户要求 2026-10-02：界面只留干净列表】术语对照的 5 行正文搬进「说明」（REF_TEXT["术语对照"]），
	# 界面上只留这个**一行指路**给小白的入口标签。
	# 【2026-10-02 用户口径】术语对照那五条长解释已从「说明」里删除（"废话"）⇒ 这条指路标签一并撤掉，
	# 否则界面还在说"去看说明"，而说明里已经没有它了（本会话反复强调：指路必须指向真的存在的东西）。
	box.add_child(_plain_label("规格：你自己定的那套「数字怎么算」的算法（「规则」页能看全）。\n"
		+ "邻域：算一个数字时，要看它周围哪些格子（默认周围 8 格）。\n"
		+ "环绕：棋盘上下、左右相通——边上的格子能看到对面的格。\n"
		+ "深度：解开某一步要同时把握几条线索；越大越难。\n"
		+ "峰值：整盘最深那一步的深度（难度档位就是按峰值分的：普通 2~3、困难 4~5、噩梦 6+）。"))
	return outer


func _build_right_panel() -> Control:
	var tabs := TabContainer.new()
	tabs.custom_minimum_size = Vector2(330, 0)
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_child(_build_props_tab())
	# 页序 = 上手顺序：小白从「AI 帮我写」进，手写 JSON 的「规则」页在后。
	tabs.add_child(_build_ai_tab())
	tabs.add_child(_build_rule_tab())
	tabs.add_child(_build_verify_tab())
	return tabs


## 「AI 帮我写」：零代码创作路径（用户只做三件事：复制一段话 → 粘给任意 AI → 把回复粘回来）。
## 为什么不塞进「规则」页：这一页的目标用户不该看到 JSON（他只面对"想法 / 粘贴 / 结果"），
## 而手写 JSON 的作者仍走「规则」页——两页共用同一真源（doc.rule_spec + 注册表），不是双份实现。
func _build_ai_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "AI 帮我写"
	box.add_theme_constant_override("separation", 4)
	var scroll := ScrollContainer.new()
	# 【用户反馈修 2026-10-02：这一行漏了 ⇒ 整页空白】本页是「VBox 里套 ScrollContainer」，
	# 而 **VBox 只按最小高度排不伸缩的子节点** ⇒ 没有 `SIZE_EXPAND_FILL` 的 ScrollContainer 被压成
	# ≈0 高，内容全在视口之外，用户点开「AI 帮我写」看到的是**一张空白页**。
	#（左栏 / 验证页 / 批量弹窗的 scroll 都有这行，只有这一页漏了。）
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 4)
	scroll.add_child(col)

	# 页面第一眼就要回答"我要干什么"：三步 + 明确"看不懂就点①"。
	# 【2026-10-02 用户要求：说明里有了就不在界面上重复】原来这里有两段长说明（"照这三步做…"与
	# "不会写代码也能做规则…"）——现在它们收进「说明」（见 PAGE_HELP["AI 帮我写"]），
	# 界面上只留这一行**指路**，把页面让给真正要操作的控件（界面简洁）。
	col.add_child(_plain_label("三步怎么走？点左栏顶部「说明」→ 那里写着这三步（原页面上的长说明已收进说明里）。"))

	col.add_child(_section_label("① 你的想法（一句话，可留空）"))
	_idea_edit = LineEdit.new()
	_idea_edit.placeholder_text = "例如：数字 = 周围 8 格里的雷数 + 1"
	col.add_child(_idea_edit)
	var grid := GridContainer.new()
	grid.columns = 2
	for ex in SpecHelper.idea_examples():
		grid.add_child(_chip_button(ex, func() -> void: _idea_edit.text = ex))
	col.add_child(grid)
	col.add_child(_action_button("复制「给 AI 的话」（点完去粘给 AI）", _copy_ai_prompt))

	col.add_child(_section_label("② 把 AI 的回复整段粘到这里"))
	_ai_text = TextEdit.new()
	_ai_text.custom_minimum_size = Vector2(0, 140)
	_ai_text.placeholder_text = "整段粘进来即可（带解释文字、带代码块都没关系）"
	col.add_child(_ai_text)
	var row := HBoxContainer.new()
	row.add_child(_action_button("读懂并导入", _import_ai_text))
	row.add_child(_action_button("从剪贴板粘贴", _paste_ai_text))
	col.add_child(row)
	_ai_result = _plain_label("")
	col.add_child(_ai_result)

	_ai_fix_btn = _action_button("③ 导入失败？点这里复制「让 AI 修」的话", _copy_repair_prompt)
	_ai_fix_btn.disabled = true
	col.add_child(_ai_fix_btn)

	col.add_child(_section_label("不想用 AI？直接用现成配方"))
	_recipe_opt = OptionButton.new()
	_recipe_opt.custom_minimum_size = Vector2(0, 30)
	# 【为什么下拉项只放标题】2026-10-02 实测：把"标题 — 说明"塞进下拉项时，最长一项 47 个字，
	# 会把下拉框的最小宽度顶到 730px ⇒ 整个右面板被撑宽、棋盘从 694px 挤到 286px（一格只剩 29px）。
	# 说明放在下面的说明行里一样看得见；`fit_to_longest_item = false` 是第二道保险，
	# 将来谁再加长文案也不会再把面板撑开。
	_recipe_opt.fit_to_longest_item = false
	_recipe_opt.clip_text = true     # 同上：长 item 文本不许顶开面板宽
	var rs := SpecHelper.recipes()
	for i in rs.size():
		var rec: Dictionary = rs[i]
		_recipe_opt.add_item(str(rec["title"]), i)
	_recipe_opt.item_selected.connect(func(_i: int) -> void: _refresh_recipe_note())
	col.add_child(_recipe_opt)
	_recipe_note = _plain_label("")
	col.add_child(_recipe_note)
	col.add_child(_action_button("用这个配方（立刻生效）", _apply_recipe))
	col.add_child(_plain_label("导入成功后，左边的数字会立刻按新规则重算。"
		+ "接着可以「随机布雷」→「试玩」，或到「验证」页看不猜能不能解。"))
	_refresh_recipe_note()
	return box


func _build_props_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "属性"
	box.add_theme_constant_override("separation", 4)
	# 属性页最长（含"本盘问题"清单）：包一层滚动，避免矮窗口下把底部内容裁掉
	var scroll := ScrollContainer.new()
	# 页签名取这里（TabContainer 拿子节点名当标题）：实测它原来显示成内部名「属性页滚动」
	scroll.name = "属性"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 关卡名字：原来全界面没有地方能起名字 ⇒ 存出来永远叫 level.json / level_2.json…
	box.add_child(_section_label("关卡名字（保存时用作文件名）"))
	_title_edit = LineEdit.new()
	_title_edit.placeholder_text = "例如：我的第一关"
	_title_edit.text_changed.connect(func(_t: String) -> void: _on_title_changed())
	box.add_child(_title_edit)
	box.add_child(_section_label("棋盘"))
	var r := HBoxContainer.new()
	r.add_child(_plain_label("行"))
	_rows_spin = _spin(1, 64, 1)
	_rows_spin.value_changed.connect(func(_v: float) -> void: _on_size_changed())
	r.add_child(_rows_spin)
	r.add_child(_plain_label("列"))
	_cols_spin = _spin(1, 64, 1)
	_cols_spin.value_changed.connect(func(_v: float) -> void: _on_size_changed())
	r.add_child(_cols_spin)
	box.add_child(r)
	_density_label = _plain_label("")
	box.add_child(_density_label)

	box.add_child(_section_label("边界与邻域"))
	_wrap_check = CheckBox.new()
	_wrap_check.text = "环绕边界（上下/左右相通）"
	_wrap_check.toggled.connect(func(_p: bool) -> void: _on_neighborhood_changed())
	box.add_child(_wrap_check)
	_self_check = CheckBox.new()
	_self_check.text = "邻域含自身"
	_self_check.toggled.connect(func(_p: bool) -> void: _on_neighborhood_changed())
	box.add_child(_self_check)
	_preset_opt = OptionButton.new()
	_preset_opt.add_item("邻域：周围 8 格（默认）", 0)
	_preset_opt.add_item("邻域：上下左右 4 格", 1)
	_preset_opt.add_item("邻域：骑士步（国际象棋马）", 2)
	_preset_opt.add_item("邻域：自定义偏移（见下）", 3)
	_preset_opt.item_selected.connect(func(_i: int) -> void: _on_preset_selected())
	box.add_child(_preset_opt)
	_dirs_edit = LineEdit.new()
	_dirs_edit.placeholder_text = "自定义偏移：dx,dy; dx,dy; …（如 -1,0; 1,0）"
	_dirs_edit.text_submitted.connect(func(_t: String) -> void: _on_neighborhood_changed())
	_dirs_edit.focus_exited.connect(func() -> void: _on_neighborhood_changed())
	box.add_child(_dirs_edit)
	_foreign_note = _plain_label("")
	_foreign_note.visible = false
	box.add_child(_foreign_note)

	box.add_child(_section_label("布局规则（可选：给「雷怎么摆」定规矩）"))
	box.add_child(_plain_label("上面那些管的是「数字怎么算」；这里管的是「雷摆在哪才算合法」，"
		+ "例如「任意 2×2 里最多 2 颗雷」。\n加上之后：出关卡会照这条规矩生成，"
		+ "教程图例里也会多出「满足 / 不满足」的棋盘演示（不满足的用红叉标出来）。"))
	_global_opt = OptionButton.new()
	# 与配方下拉同因：长文案不许把右栏撑宽（实测会把棋盘挤到一格只剩 29px）
	_global_opt.fit_to_longest_item = false
	# 实测：属性页最小宽 468 的元凶就是这个下拉（item 文案长）⇒ clip_text 后不再顶开面板
	_global_opt.clip_text = true
	_global_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for e in VariantCatalog.entries(RulePlugin.KIND_GLOBAL):
		var item_text := "%s —— %s" % [str(e["name"]), str(e["text"])]
		_global_opt.add_item(item_text, _global_opt.item_count)
		_global_opt.set_item_metadata(_global_opt.item_count - 1, str(e["id"]))
	box.add_child(_global_opt)
	var grow := HBoxContainer.new()
	grow.add_theme_constant_override("separation", 6)
	grow.add_child(_action_button("加上这条规则", _on_global_added))
	grow.add_child(_action_button("全部去掉", _on_globals_cleared))
	box.add_child(grow)
	_global_list = _plain_label("")
	_global_list.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_global_list)

	# 本盘问题列表：需求明确要求"错误信息要显示在界面上，不能只打印到控制台"。
	# 状态栏只放第一条（空间有限），完整清单放这里，逐条带格坐标（点画布上高亮的就是它们）。
	box.add_child(_section_label("本盘问题"))
	_issues_box = VBoxContainer.new()
	_issues_box.add_theme_constant_override("separation", 2)
	box.add_child(_issues_box)
	# 原句是"棋盘会被当作异形盘（走邻接表）；只有声明支持任意拓扑的规则才会被真正使用"——
	# 2026-10-02 实测小白完全看不懂，改成"现象 + 下一步"。
	box.add_child(_plain_label("提示：把「邻域」改成上下左右、勾上「环绕边界」或加上障碍之后，"
		+ "这块棋盘就按「谁挨着谁」来算——能用上的规则会变少。\n"
		+ "如果下面的「本盘问题」冒出红字，照着它说的改就行。"))

	# 形状族：借 `ShapeGenerator` 的九族实现（这里先接最常用的两族；加族只需再加一个分支）
	box.add_child(_section_label("形状（六边形 / 三角等）"))
	_shape_opt = OptionButton.new()
	_shape_opt.add_item("方形网格（默认）", 0)
	_shape_opt.add_item("蜂窝六边形", 1)
	_shape_opt.add_item("三角网格", 2)
	_shape_opt.item_selected.connect(func(_i: int) -> void: _on_shape_selected())
	box.add_child(_shape_opt)
	var srow := HBoxContainer.new()
	srow.add_child(_plain_label("形状尺寸"))
	_shape_size = _spin(2, 12, 1)
	_shape_size.value = 4
	_shape_size.value_changed.connect(func(_v: float) -> void: _on_shape_selected())
	srow.add_child(_shape_size)
	box.add_child(srow)
	box.add_child(_plain_label("选形状后，邻域/边界控件不适用；雷位与障碍照常编辑。"))
	scroll.add_child(box)
	return scroll


func _build_rule_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "规则"
	box.add_theme_constant_override("separation", 4)
	# 小白不该从这一页入门（这页是给会看 JSON 的人的高级入口）：先把人劝到「AI 帮我写」。
	box.add_child(_plain_label("【高级页】这里能直接看/改规则原文。新手不用管这一页——"
		+ "请到左边「AI 帮我写」页，复制一句话给 AI 就行。\n"
		+ "留空 = 用默认的普通扫雷。"))
	var rr := HBoxContainer.new()
	rr.add_child(_plain_label("规则 id"))
	_rule_id_edit = LineEdit.new()
	_rule_id_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rule_id_edit.placeholder_text = "留空 = classic"
	_rule_id_edit.text_submitted.connect(func(_t: String) -> void: _on_rule_changed())
	_rule_id_edit.focus_exited.connect(func() -> void: _on_rule_changed())
	rr.add_child(_rule_id_edit)
	box.add_child(rr)
	box.add_child(_action_button("插入「周围 8 格计数」模板", _insert_classic_template))
	_spec_edit = TextEdit.new()
	_spec_edit.custom_minimum_size = Vector2(0, 220)
	_spec_edit.placeholder_text = "{ \"spec_version\": 1, \"id\": \"spec_my_rule\", ... }"
	_spec_edit.text_changed.connect(_on_rule_changed)
	box.add_child(_spec_edit)
	_rule_report = _plain_label("")
	box.add_child(_rule_report)
	return box


func _build_verify_tab() -> Control:
	var box := VBoxContainer.new()
	box.name = "验证"
	box.add_theme_constant_override("separation", 4)
	box.add_child(_plain_label("点「开始验证」，就会告诉你：这一关能不能不靠猜推完。\n"
		+ "（计算有时间上限，不会卡死。）"))
	_verify_btn = _action_button("开始验证", _on_verify)
	box.add_child(_verify_btn)
	# 「验证不通过怎么办」（P7.4，小白友好）：验证页会给出人话结论（可解/要猜/矛盾），
	# 但结论之后"我该怎么办"原来得自己想。这里给三条**可执行**的出路（都用已有能力，不新造机制），
	# 顺序从省事到费事；顺手点一下就能试，不必先去学一遍整个系统。
	# 【用户要求 2026-10-02】三招正文搬进「说明」（REF_TEXT["验证不通过怎么办"]），界面只留标题+按钮
	box.add_child(_section_label("验证不通过怎么办？"))
	var fix_row := HBoxContainer.new()
	fix_row.add_theme_constant_override("separation", 6)
	fix_row.add_child(_action_button("换一盘随机布雷", _random_mines))
	fix_row.add_child(_action_button("先去试玩看看", _playtest))
	box.add_child(fix_row)
	# 先给结论的人话版，再给技术细节（原实现一上来就是"序贯演绎 3 轮推完全盘…解数 2"，小白读不懂）
	_verify_plain = _plain_label("")
	_verify_plain.add_theme_font_size_override("font_size", 14)
	box.add_child(_verify_plain)
	_verify_state = _plain_label("")
	box.add_child(_verify_state)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_verify_issues = VBoxContainer.new()
	_verify_issues.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_verify_issues)
	box.add_child(scroll)
	return box


func _build_status_bar() -> Control:
	var panel := PanelContainer.new()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_status = _plain_label("")
	row.add_child(_status)
	panel.add_child(row)
	return panel


# ---- 小控件工厂（统一样式，避免每处重复四行） ----

func _section_label(text: String) -> Label:
	var l := _plain_label(text)
	l.add_theme_font_size_override("font_size", 14)          # 组标题靠字号区分，不靠描边
	l.add_theme_color_override("font_color", _label_color())
	# 打上"组标题"标记：左栏的**套框后处理**（见 _frame_left_bar_groups）靠它切分组。
	# 用元数据而不是字号/文案来判断 —— 字号将来改了就散架，文案更是随时变。
	l.set_meta("group_head", true)
	return l


## 【用户反馈修 2026-10-02："编辑器界面看起来有些乱，加些框、界限分明"】
## 左栏有十几组功能（四步条 / 工具 / 格型 / 布雷 / 编辑 / 存档与分享 / 批量做关卡 / 术语对照…），
## 组与组之间只靠一行 13px 小标题区分 ⇒ 一屏文字连成一片，看不出"哪里到哪里是一件事"。
## 这里做一次**后处理**：把"每个组标题 + 它后面直到下一个标题之前的所有控件"装进一块主题面板
## （`PanelContainer`，与设置弹窗 / 教程层同一套约定）⇒ 每组自带一个框、边界一眼可见。
## **不动任何既有排版代码**：只按原顺序搬节点 —— 内容还是原来那些内容，只是多了边界。
func _frame_left_bar_groups(root: Node) -> void:
	var host := _find_group_host(root)
	if host == null:
		return
	var runs: Array = []
	var run: Array = []
	for child in host.get_children():
		if child is Label and (child as Label).has_meta("group_head") and not run.is_empty():
			runs.append(run)
			run = []
		run.append(child)
	if not run.is_empty():
		runs.append(run)
	for nodes in runs:
		_wrap_in_frame(host, nodes)


## 找"直接装着各组控件"的那个容器：它至少有一个带 group_head 标记的 Label 子节点。
func _find_group_host(node: Node) -> Container:
	if node is Container:
		for c in node.get_children():
			if c is Label and (c as Label).has_meta("group_head"):
				return node as Container
	for c in node.get_children():
		var got := _find_group_host(c)
		if got != null:
			return got
	return null


func _wrap_in_frame(host: Container, nodes: Array) -> void:
	var frame := PanelContainer.new()
	# 主题面板自带的内边距是给弹窗用的（偏大）；左栏只有 356px 宽，套框后要留够文字宽度，
	# 所以复制一份样式、换成薄边距 + 小圆角。拿不到 StyleBoxFlat（非平板主题）就不动它。
	var sb := frame.get_theme_stylebox("panel")
	if sb is StyleBoxFlat:
		var thin := (sb as StyleBoxFlat).duplicate() as StyleBoxFlat
		# 【真机实测校准】左右只留 2px：左右内边距会**直接变成左栏的最小宽度** —— 实测 8+8 时
		# 左栏从 356 撑到 372，棋盘被挤掉 16px（正是本仓明令防的"面板撑宽、棋盘变小"）。
		# 边界的观感靠**框线 + 背景**，不靠内边距；上下留 6px 不占宽度，保住组内呼吸感。
		thin.content_margin_left = 2.0
		thin.content_margin_right = 2.0
		thin.content_margin_top = 6.0
		thin.content_margin_bottom = 6.0
		thin.set_corner_radius_all(10)
		frame.add_theme_stylebox_override("panel", thin)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	frame.add_child(inner)
	var at := (nodes[0] as Node).get_index()
	host.add_child(frame)
	host.move_child(frame, at)
	for n in nodes:
		host.remove_child(n)
		inner.add_child(n)


func _plain_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 【用户拍板 2026-10-02："不用描边，换成白色的字就行"】+【审查修 A2：浅色主题不能白底白字】
	l.add_theme_color_override("font_color", _label_color())
	l.set_meta("ed_label", true)     # 标记：主题切换后靠它重刷字色（override 不随主题自动变）
	return l


func _action_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	# 简单动作给图标（P6g）。图标 + 文字并存：一眼认得，又不丢文字说明。
	var tex := _icon_for(text)
	if tex != null:
		b.icon = tex
	# 【防宽度抖动】长标签不许把面板/左栏撑宽：TabContainer 取**当前页最小宽度**，
	# 一个"批量生成关卡（按大小 × 档位）"就足以让右栏变宽、棋盘被挤小（实测 468 vs 330）。
	b.clip_text = true
	# 【但最小宽不能给 0】实测（2026-10-02）：clip_text + 最小宽 0 ⇒ 最小宽度只剩图标+内边距（约 8px），
	# 而 HBox 里的兄弟只拿"最小宽度" ⇒ 文字被整段裁掉，用户看到一排**空按钮**（重做/复制选区/
	# 加上这条规则/读懂并导入…18 个，报告原话"有些按钮没有内容，不知道是什么按钮"）。
	# 现在：84 的地板 + 行内横向均分 ⇒ 既不撑宽面板，也不会被挤空。
	b.custom_minimum_size = Vector2(84, 30)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 万一还是被裁（超长标签），悬停能看到全文
	if b.tooltip_text == "":
		b.tooltip_text = text
	b.pressed.connect(cb)
	return b


## 简单动作 → 图标（P6g）。用**关键词包含**匹配：标签文案微调不会静默丢图标，
## 且有测试按同一规则在真实控件树上复核（"这些按钮真的有图标吗"）。
func _icon_for(text: String) -> Texture2D:
	# 顺序要紧：先"清空该格"（局部擦除），再"清空全部"（整盘删除）
	if text.find("清空该格") != -1:
		return Icons.eraser_partial()
	if text.find("橡皮") != -1:
		return Icons.eraser()
	if text.find("清空") != -1:
		return Icons.trash()
	if text.find("试玩") != -1:
		return Icons.play()
	if text.find("撤销") != -1:
		return Icons.undo()
	if text.find("新手引导") != -1 or text.find("怎么用") != -1:
		return Icons.book()
	if text.find("返回选关") != -1 or text.find("关闭") != -1:
		return Icons.close()
	return null


func _toggle_button(text: String, group: ButtonGroup, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	# 工具/格型是互斥切换按钮（走这个 helper，不走 _action_button）⇒ 图标逻辑要同步加，
	# 否则「橡皮 / 清空该格」这类简单动作会漏掉图标（实测漏了，被测试当场抓住）
	var tex := _icon_for(text)
	if tex != null:
		b.icon = tex
	b.clip_text = true
	b.custom_minimum_size = Vector2(84, 30)     # 同 _action_button：不许被挤成空按钮
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if b.tooltip_text == "":
		b.tooltip_text = text
	b.toggle_mode = true
	b.button_group = group
	# 【审查修 D12】这里原来又把 `custom_minimum_size` 覆盖成 `(0, 28)`，把上面那句
	# "不许被挤成空按钮"的 (84,30) 抹掉了（注释与代码自相矛盾）。删掉这次覆盖。
	var first := group.get_buttons().is_empty()
	b.button_pressed = first
	b.pressed.connect(cb)
	return b


func _spin(lo: int, hi: int, step: int) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.custom_minimum_size = Vector2(78, 30)
	return s


## 小号按钮：给「想法示例」用。330px 的右栏放不下长句按钮 ⇒ 缩小字号 + 裁剪 + 悬停看全文。
func _chip_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	# 【实测缺陷】原来最小宽 0 + clip_text ⇒ 在 GridContainer 里被压成 **8px 宽**（一排小方块，
	# 用户以为「AI 帮我写」这一页是空的）。给足最小宽 + 让它横向撑开，再裁长文本（悬停看全文）。
	b.custom_minimum_size = Vector2(150, 28)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_text = true
	b.add_theme_font_size_override("font_size", 12)
	b.tooltip_text = text
	b.pressed.connect(cb)
	return b


# ==================== 文档 ⇄ 界面同步 ====================

func _doc_to_ui() -> void:
	_syncing = true
	_rows_spin.value = doc.rows
	_cols_spin.value = doc.cols
	if _title_edit != null:
		_title_edit.text = doc.title
	_mines_spin.value = maxi(doc.mine_count(), 1)
	_wrap_check.button_pressed = doc.wrap
	_self_check.button_pressed = doc.include_self
	_rule_id_edit.text = doc.clue_rule_id
	_spec_edit.text = "" if doc.rule_spec.is_empty() else JSON.stringify(doc.rule_spec, "  ")
	_dirs_edit.text = _dirs_to_text(doc.dirs)
	_preset_opt.selected = _preset_index()
	# 形状下拉与当前文档一致（打开关卡/撤销后也要对上）
	match doc.shape_kind:
		"hex":
			_shape_opt.selected = 1
			_shape_size.value = int(doc.shape_params.get("size", 4))
		"tri_grid":
			_shape_opt.selected = 2
			_shape_size.value = int(doc.shape_params.get("cols", 4))
		_:
			_shape_opt.selected = 0
	_syncing = false


func _on_size_changed() -> void:
	if _syncing:
		return
	_push_undo(false)
	doc.rows = int(_rows_spin.value)
	doc.cols = int(_cols_spin.value)
	# 用"盘上是否有这一格"判定（方阵盘上等价于越界清理；形状盘上还会清掉形状之外的格）
	_drop_off_board()
	_sync_declared_total()   # 缩小棋盘会丢掉盘外的雷 ⇒ 声明值也要跟着走实际
	_mark_dirty()
	_refresh_all()


## 改关卡名字：只影响"保存成哪个文件名"，不会动棋盘（所以不调 _refresh_all）。
func _on_title_changed() -> void:
	if _syncing:
		return
	doc.title = _title_edit.text.strip_edges()
	_mark_dirty()


func _on_mines_changed() -> void:
	if _syncing:
		return
	# 这里的"雷数"是**目标值**：改它不直接动雷位（雷位是画上去的），只影响随机布雷。
	_refresh_status()


func _on_neighborhood_changed() -> void:
	if _syncing:
		return
	_push_undo(false)
	doc.wrap = _wrap_check.button_pressed
	doc.include_self = _self_check.button_pressed
	doc.dirs = _text_to_dirs(_dirs_edit.text)
	_mark_dirty()
	_refresh_all()


## 选形状 ⇒ 棋盘改由 `ShapeGenerator` 生成（九族现成），并把 rows/cols 同步成其包围盒。
## 形状盘上「邻域/边界」不适用（与载入外部拓扑同理，validate 会给出 `shape_active` 提醒）。
func _on_shape_selected() -> void:
	if _syncing:
		return
	_push_undo(false)
	match _shape_opt.selected:
		1:
			doc.shape_kind = "hex"
			doc.shape_params = {"size": int(_shape_size.value)}
		2:
			doc.shape_kind = "tri_grid"
			doc.shape_params = {"cols": int(_shape_size.value), "rows": int(_shape_size.value)}
		_:
			doc.shape_kind = ""
			doc.shape_params = {}
	doc.sync_size_to_shape()
	# 换盘型后原来的雷/障碍可能落在盘外：**移走并告知**（画布上没有那个格 ⇒ 留着会变成
	# "看得见的校验错误 + 看不见的雷"，比移除更糟）。已 `_push_undo`，可一键撤销。
	var dropped := _drop_off_board()
	_mark_dirty()
	_doc_to_ui()
	_refresh_all()
	if dropped > 0:
		_toast("换了形状：%d 个盘外格（雷/障碍/翻开）已移除（可撤销）" % dropped)


## 移除"不在当前盘上"的雷/障碍/翻开（方阵盘上等效于越界清理；形状盘上还要清形状之外）。
func _drop_off_board() -> int:
	var on_board := {}
	for p in doc.grid().all_positions():
		on_board[p] = true
	var dropped := 0
	for p in doc.mines.duplicate():
		if not on_board.has(p):
			doc.mines.erase(p)
			dropped += 1
	for p in doc.obstacles.duplicate():
		if not on_board.has(p):
			doc.obstacles.erase(p)
			dropped += 1
	for p in doc.revealed.keys().duplicate():
		if not on_board.has(p):
			doc.revealed.erase(p)
			dropped += 1
	return dropped


func _on_preset_selected() -> void:
	if _syncing:
		return
	match _preset_opt.selected:
		0:
			doc.dirs = []
			_dirs_edit.text = ""
		1:
			doc.dirs.assign(WrapTopology.DIRS_ORTHO4)
			_dirs_edit.text = _dirs_to_text(doc.dirs)
		2:
			doc.dirs.assign(WrapTopology.DIRS_KNIGHT8)
			_dirs_edit.text = _dirs_to_text(doc.dirs)
		_:
			pass   # 自定义：等用户在输入框里写
	_mark_dirty()
	_refresh_all()


func _preset_index() -> int:
	if doc.dirs.is_empty():
		return 0
	if _same_dirs(doc.dirs, WrapTopology.DIRS_ORTHO4):
		return 1
	if _same_dirs(doc.dirs, WrapTopology.DIRS_KNIGHT8):
		return 2
	return 3


func _same_dirs(a: Array[Vector2i], b: Array[Vector2i]) -> bool:
	if a.size() != b.size():
		return false
	for d in a:
		if not b.has(d):
			return false
	return true


func _dirs_to_text(dirs: Array[Vector2i]) -> String:
	var parts: Array[String] = []
	for d in dirs:
		parts.append("%d,%d" % [d.x, d.y])
	return "; ".join(parts)


func _text_to_dirs(text: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for chunk in text.split(";", false):
		var p := chunk.strip_edges().split(",")
		if p.size() == 2:
			out.append(Vector2i(int(p[0]), int(p[1])))
	return out


func _on_rule_changed() -> void:
	if _syncing:
		return
	doc.clue_rule_id = _rule_id_edit.text.strip_edges()
	var text := _spec_edit.text.strip_edges()
	if text == "":
		doc.rule_spec = {}
	else:
		# 用安全解析：用户打字打到一半必然不是合法 JSON，`JSON.parse_string` 会为此刷 ERROR 日志
		var parsed: Variant = SpecHelper.parse_json_safe(text)
		if parsed is Dictionary:
			doc.rule_spec = parsed
		# 不是合法 JSON 时**保留旧规格**（否则打字打到一半就把规则清空了），
		# 由下面的校验提示告诉用户哪里不对。
	_mark_dirty()
	_refresh_rule_report()
	# 改规则会改变**全盘**线索值 ⇒ 需要全量预览，但打字时不能每个字符都跑 100 ms 的全量
	# ⇒ 去抖到 260 ms 空闲后再算（规格错误提示仍是即时的，因为它便宜）。
	_full_preview_due = Time.get_ticks_msec() + CHECKS_IDLE_MS


func _insert_classic_template() -> void:
	var refs: Array = []
	for d in ClueEngine.ring_dirs():
		refs.append({"dx": d.x, "dy": d.y})
	var xs: Array = []
	for i in refs.size():
		xs.append({"t": "ref", "i": i})
	var spec := {
		"spec_version": 1,
		"id": "spec_editor_%d" % (Time.get_ticks_msec() % 100000),
		"title": "周围 8 格计数（模板）",
		"geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}},
	}
	_spec_edit.text = JSON.stringify(spec, "  ")
	_on_rule_changed()


# ==================== 编辑动作 ====================

## 手势开始 ⇒ 存"改动前"的快照（撤销栈里必须是改动前的状态，否则按一次撤销等于没动）。
func _on_cell_edit_started(_pos: Vector2i) -> void:
	_push_undo()


## 改一格后的**快路径**：只重算"该格 + 其邻居"的线索值并刷新状态栏；
## 昂贵的检查（拓扑审计 / 结构校验）与全量预览合并到去抖里跑（见 `_process`）。
func _on_cell_edited(pos: Vector2i) -> void:
	_sync_declared_total()
	_mark_dirty()
	_refresh_preview_around(pos)
	_refresh_status()
	_checks_due = Time.get_ticks_msec() + CHECKS_IDLE_MS


## 增量预览：一处改动只影响"该格与其邻居"的线索值（对称关系）。
## 全量重算在 64x64 环绕盘上要 100 ms（见 `core/editor_doc.gd:struct_signature` 的实测注释），
## 增量路径只算 ≤9 格 ⇒ 拖动时不再掉帧。
func _refresh_preview_around(pos: Vector2i) -> void:
	var cells: Array[Vector2i] = [pos]
	for nb in doc.grid().get_neighbors(pos):
		cells.append(nb)
	var inc := doc.preview_cells(cells)
	# 被改的格自己也可能"刚变成雷 / 刚取消雷"⇒ 先删掉它的旧值再合并
	canvas.values.erase(pos)
	for p in inc:
		canvas.values[p] = inc[p]
	canvas.queue_redraw()


## 记一步撤销快照。
## `allow_merge`：**画布手势**传 true（700ms 内的连续改动算一步，否则一笔画会吃掉半条撤销栈）；
## **按钮命令**（清空 / 随机布雷 / 粘贴 / 改尺寸 / 改邻域 / 换形状）传 false ——
## 实测（2026-10-02）：两个不同按钮在 700ms 内先后点下会被合并成一步，小白按一次撤销
## 会看到"一下退了两件事"（当时我先把"清空无法撤销"报成缺陷，查清后是这个原因）。
## 非合并的一步之后把时间戳清零 ⇒ 紧接的手势一定自成一步，不会再被折进上一条命令。
func _push_undo(allow_merge := true) -> void:
	var now := Time.get_ticks_msec()
	if allow_merge and now - _last_undo_ms < STROKE_COALESCE_MS and not _undo.is_empty():
		_last_undo_ms = now
		return
	_last_undo_ms = 0 if not allow_merge else now
	# 用 snapshot() 而不是 to_level_json()：后者含 topology（派生、可达数 MB），
	# 50 步撤销会吃掉上百 MB（见 core/editor_doc.gd:snapshot 的注释）
	_undo.append(doc.snapshot())
	while _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()


func _undo_once() -> void:
	if _undo.is_empty():
		_toast("没有可撤销的操作")
		return
	_redo.append(doc.snapshot())
	var snap: Dictionary = _undo.pop_back()
	doc.restore(snap)
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()


func _redo_once() -> void:
	if _redo.is_empty():
		_toast("没有可重做的操作")
		return
	_undo.append(doc.snapshot())
	var snap: Dictionary = _redo.pop_back()
	doc.restore(snap)
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()


## 编辑动作之后把"声明的总雷数"改回未声明 ⇒ 以实际雷位为准。
## 不这么做的话：打开任何已保存的关卡（其 total_mines 是导入时的旧值）再增删雷，
## 立刻会报一条**用户没法修**的「声明的总雷数不一致」，并把试玩/打包一起挡住（2026-10-02 实测）。
func _sync_declared_total() -> void:
	doc.sync_declared_total()


func _random_mines() -> void:
	# 按钮命令 ⇒ 自成一步撤销（不被 700ms 合并窗折进上一条命令）
	var target := int(_mines_spin.value)
	# 【审查修 A3（真 bug）】这里原来用 `for y in doc.rows / for x in doc.cols` 双层遍历，而形状盘
	# （蜂窝/三角/自定义）的坐标**不连续** —— 约定见 core/grid_interface.gd「遍历必须用 all_positions()」。
	# 后果：盘外被塞进"看不见、也点不到"的雷 ⇒ 试玩/打包被永久挡住，用户除了撤销无从下手。
	# 这里先取盘内格集合，再在候选里筛（下面的双层循环只是枚举坐标，不再当"有效格"用）。
	var on_board := {}
	for bp in doc.grid().all_positions():
		on_board[bp] = true
	var free: Array[Vector2i] = []
	for y in doc.rows:
		for x in doc.cols:
			var p := Vector2i(x, y)
			if on_board.has(p) and not doc.obstacles.has(p):
				free.append(p)
	if target > free.size():
		_toast("雷数 %d 超过可用格数 %d" % [target, free.size()], true)
		return
	_push_undo(false)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# Fisher-Yates 取前 target 个（无重复、无偏）
	for i in range(free.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t := free[i]
		free[i] = free[j]
		free[j] = t
	# 逐个 append 而不是 `free.slice(...)`：slice() 的返回类型不保证是 `Array[Vector2i]`，
	# 直接赋给强类型字段会在运行期抛"element type"错（本仓踩过同类坑）。
	doc.mines.clear()
	for i in target:
		doc.mines.append(free[i])
	for p in doc.mines:
		doc.revealed.erase(p)
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()


## 「清空全部雷/障碍/翻开」：这是"一下就没了"的操作 ⇒ **先问一句**。
## 实测（2026-10-02）：原来点下去直接清空，小白的第一反应是"啊我全没了"；撤销虽能救回，
## 但得先想到撤销 ⇒ 问句里顺带把"可以撤销"写出来，并说明盘上没什么可清时不弹（免得白问）。
func _clear_all() -> void:
	if doc.mines.is_empty() and doc.obstacles.is_empty() and doc.revealed.is_empty():
		_toast("盘上本来就是空的")
		return
	_ask_confirm("确定清空全部雷 / 障碍 / 已翻开格吗？\n（清空后可以按左栏「撤销」恢复）",
		func() -> void: _clear_all_now())


func _clear_all_now() -> void:
	_push_undo(false)
	doc.mines.clear()
	doc.obstacles.clear()
	doc.revealed.clear()
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()
	_toast("已清空（可以按「撤销」恢复）")


func _copy_selection() -> void:
	if canvas.selection.size == Vector2i.ZERO:
		_toast("先框选一个区域（区域选择工具）")
		return
	_clipboard_cells = _cells_in(canvas.selection)
	_toast("已复制 %d 格的格型" % _clipboard_cells.size())


func _paste_selection() -> void:
	if _clipboard_cells.is_empty():
		_toast("剪贴板里没有格型（先复制选区）")
		return
	_push_undo(false)
	var base := canvas.selection.position if canvas.selection.size != Vector2i.ZERO else Vector2i.ZERO
	for item in _clipboard_cells:
		var rel: Vector2i = item["rel"]
		var kind := str(item["kind"])
		var p := base + rel
		if p.x < doc.cols and p.y < doc.rows:
			_apply_kind_at(p, kind)
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()


var _clipboard_cells: Array = []


## 选区 → [{rel, kind}]（相对选区左上角，便于任意位置粘贴）。
func _cells_in(rect: Rect2i) -> Array:
	var out: Array = []
	for y in range(rect.position.y, rect.position.y + rect.size.y + 1):
		for x in range(rect.position.x, rect.position.x + rect.size.x + 1):
			var p := Vector2i(x, y)
			if p.x >= doc.cols or p.y >= doc.rows:
				continue
			out.append({"rel": p - rect.position, "kind": _kind_of(p)})
	return out


func _kind_of(p: Vector2i) -> String:
	if doc.mines.has(p):
		return EditorCanvas.KIND_MINE
	if doc.obstacles.has(p):
		return EditorCanvas.KIND_OBSTACLE
	if doc.revealed.has(p):
		return EditorCanvas.KIND_REVEAL
	return EditorCanvas.KIND_CLEAR


func _apply_kind_at(p: Vector2i, kind: String) -> void:
	# 【审查修 D12】这里原来是 `EditorCanvas._apply_kind` 的**第二份实现**（雷↔障碍↔翻开 互斥）。
	# 两份现在一致，但迟早分叉（画笔与粘贴行为不一致）⇒ 收口到画布那唯一写入口。
	if canvas != null:
		# 画布持有**自己的** `doc` 引用：编辑器换过文档（含冒烟测试直接 `ed.doc = d` 这种）时必须先同步，
		# 否则写入口会把雷写进画布那份旧文档里（实测：冒烟测试当场抓到这个）。
		canvas.doc = doc
		canvas.apply_kind(p, kind)


# 【审查 D12 删除】`_drop_out_of_range` 是 `_drop_off_board` 的死重复（无任何调用方，
# 且它按 rows/cols 判界，对形状盘本来就是错口径）。


# ==================== 刷新 ====================

func _mark_dirty() -> void:
	_dirty = true
	_last_change_ms = Time.get_ticks_msec()


func _refresh_all() -> void:
	_refresh_preview()
	_refresh_errors()
	_refresh_rule_report()
	_refresh_status()
	_refresh_open_list()
	_refresh_global_list()


func _refresh_preview() -> void:
	var pv := doc.preview_clues()
	# 只在"换了文档对象"时重绑画布：`set_doc()` 会重置缩放/平移，
	# 每改一格就重置一次等于让用户永远没法缩放（自己写的时候踩过）。
	if canvas.doc != doc:
		canvas.set_doc(doc)
	canvas.set_values(pv["values"] if bool(pv["ok"]) else {})
	if not bool(pv["ok"]):
		_toast("预览失败：%s" % str(pv["reason"]), true)


func _refresh_errors() -> void:
	var rep := doc.validate()
	canvas.set_highlight(doc.highlight_cells(rep))
	var first := ""
	for it in rep["errors"]:
		first = str((it as Dictionary)["text"])
		break
	canvas.set_meta("first_error", first)
	_refresh_issue_list(rep)
	_refresh_status()


## 把 validate() 的结论铺进"本盘问题"列表（错误在前、提醒在后，各带格坐标）。
## 只展示前 12 条：面板是给人看的，超过这个量说明该先修结构性问题而不是刷屏。
func _refresh_issue_list(rep: Dictionary) -> void:
	for c in _issues_box.get_children():
		c.queue_free()
	if bool(rep["ok"]) and (rep["warnings"] as Array).is_empty():
		_issues_box.add_child(_plain_label("没有问题：可以按左上角「试玩」，或存成分享包。"))
		return
	var shown := 0
	for bucket in [["errors", "错误"], ["warnings", "提醒"]]:
		for it in rep[bucket[0]]:
			if shown >= 12:
				break
			var d: Dictionary = it
			var pos: Vector2i = d["pos"]
			_issues_box.add_child(_plain_label("· [%s] %s%s" % [
				str(bucket[1]), str(d["text"]),
				"" if pos.x < 0 else "（格 %d,%d）" % [pos.x, pos.y]]))
			shown += 1
	if shown >= 12:
		_issues_box.add_child(_plain_label("…还有更多，先在画布里逐个修掉高亮格"))


func _refresh_rule_report() -> void:
	if doc.rule_spec.is_empty():
		_rule_report.text = "当前使用已注册规则/内置经典扫雷（未使用 JSON 规格）。"
		return
	var v := SpecSchema.validate(doc.rule_spec)
	var lines: Array[String] = []
	if bool(v["ok"]):
		lines.append("规格合法，规则 id = %s" % str(doc.rule_spec.get("id", "?")))
	else:
		lines.append("规格有误：")
	for e in v["errors"]:
		lines.append("  · %s" % str(e))
	for w in v["warnings"]:
		lines.append("  提醒：%s" % str(w))
	_rule_report.text = "\n".join(lines)


func _refresh_status() -> void:
	if doc == null:
		return
	_density_label.text = "总格数 %d，可用 %d，雷 %d，密度 %.1f%%" % [
		doc.rows * doc.cols, doc.cell_count(), doc.mine_count(), doc.density() * 100.0]
	var tool_names := ["画笔", "橡皮", "矩形填充", "区域选择", "平移"]
	var kind_names := {"mine": "地雷", "obstacle": "障碍", "reveal": "初始已翻开", "clear": "清空"}
	var err := str(canvas.get_meta("first_error", "")) if canvas != null else ""
	var pos_text := "盘外" if canvas == null or canvas.hover.x < 0 else "(%d,%d)" % [canvas.hover.x, canvas.hover.y]
	_status.text = "坐标 %s ｜ 格 %d×%d ｜ 雷 %d ｜ 密度 %.0f%% ｜ 工具 %s ｜ 格型 %s%s" % [
		pos_text, doc.cols, doc.rows, doc.mine_count(), doc.density() * 100.0,
		tool_names[canvas.tool] if canvas != null else "-",
		kind_names.get(canvas.paint_kind, "-") if canvas != null else "-",
		"" if err == "" else " ｜ ⚠ %s" % err]


func _refresh_open_list() -> void:
	var dir := DirAccess.open(EDITOR_DIR)
	var keep := _open_opt.selected
	_open_opt.clear()
	if dir == null:
		return
	var names: Array[String] = []
	for f in dir.get_files():
		if str(f).ends_with(".json") and not str(f).begins_with("_"):
			names.append(str(f))
	names.sort()
	for n in names:
		_open_opt.add_item(n)
	if keep >= 0 and keep < _open_opt.item_count:
		_open_opt.selected = keep


# ==================== 批量生成（P6） ====================
#
# 用户原话：自己想了一个变体 → 在电脑上生成 100 关发布创意工坊；要进度条、要"按难度分类"和
# "按棋盘大小分类"（每类各多少关由用户定）；玩家侧也按同一套分类浏览；上传/下载都要带分类。
# 分工：参数与进度在本 UI，生成逻辑在 `core/batch_forge.gd`（纯逻辑、有单测），
# 分类格式在 `core/level_sets.gd`（一份实现，批量写/打包收/玩家读三处共用）。

## 打开批量生成弹窗（首次调用时构建，之后只显示）。
func _open_forge() -> void:
	if _forge_dlg == null:
		_build_forge_dialog()
	# 每次打开都从本机档案刷一遍预估（上次探过就直接有数字，不必再烧机时）
	_refresh_forge_estimate()
	if _forge != null and not _forge.is_done():
		_forge_msg.text = "正在生成中…（要停就点「停止」）"
	else:
		_forge_msg.text = "勾好大小与每档份数，点「开始生成」。" + _last_forge_note() + _last_pack_note()
		_forge_bar.value = 0
		_forge_start_btn.disabled = false
		_forge_stop_btn.disabled = true
	# `popup_centered` 不夹屏幕 ⇒ 内容高过屏幕时按钮会跑到屏外（真机踩过）。用 clamped 版夹到屏内。
	_forge_dlg.popup_centered_clamped(_forge_dlg_size, 0.95)
	_forge_fit_window()


## 把弹窗**强行**夹回屏内（可用区的 95%）。
## 【为什么需要这一步 —— 真机目视两轮才定位到】`wrap_controls = false` 只挡住了"按内容撑开"这一条路：
## 实测弹窗内容一变长（`_last_forge_note()` 的上一批记录、预估文本、ETA 文本都会变长），
## 窗口就又被撑成 652×1322，**「开始生成 / 停止 / 关闭」再次跑到 720px 屏幕之外**（局部 y 1282~1322）。
## 与其继续猜引擎什么时候会按内容重算尺寸，不如每步都夹一次：位置也一起居中，永远在屏内。
func _forge_fit_window() -> void:
	if _forge_dlg == null or not _forge_dlg.visible:
		return
	# 【必须用父窗口居中，不能用物理屏幕坐标】上一版我用 `screen_get_usable_rect` 居中，
	# 真机结果：弹窗被甩到游戏窗口之外（点了「先试一小批」那一击落在窗口外的画布上，
	# exclusive 弹窗判定"点了外面"自己关掉 ⇒ 预设没生效、我也看不到它）。
	var pw := get_window()
	if pw == null:
		return
	var box := _forge_geometry(Rect2i(pw.position, pw.size), _subwindows_embedded(), _forge_dlg_size)
	if _forge_dlg.size != box.size:
		_forge_dlg.size = box.size
	_forge_dlg.position = box.position


## 弹窗几何（纯函数，便于单测）。【审查修 B7（潜在风险）】上一版直接拿 `get_window().position`
## 当"父窗口在屏幕上的位置"，但子窗口**默认是嵌入的**（工程未设
## `display/window/subwindows/embed_subwindows`）⇒ 嵌入时 `Window.position` 已是**相对父视口**，
## 再加一次父窗口屏幕位置就多偏移一次；CI/无头下 `window.position == (0,0)` 恰好把它掩盖。
## 这里把口径收成纯函数：嵌入 ⇒ 以视口原点为基准；独立窗口 ⇒ 以屏幕位置为基准。
func _forge_geometry(parent_rect: Rect2i, embedded: bool, want_nominal: Vector2i) -> Rect2i:
	var area := Rect2i(Vector2i.ZERO, parent_rect.size) if embedded else parent_rect
	var want := Vector2i(mini(want_nominal.x, maxi(360, area.size.x - 24)),
		mini(want_nominal.y, maxi(260, area.size.y - 24)))
	return Rect2i(area.position + (area.size - want) / 2, want)


## 子窗口是否嵌入父视口（Godot 默认为真）。
func _subwindows_embedded() -> bool:
	return bool(ProjectSettings.get_setting("display/window/subwindows/embed_subwindows", true))


func _build_forge_dialog() -> void:
	var dlg := PopupPanel.new()
	dlg.name = "批量生成"
	dlg.exclusive = true
	# 【真机目视修 2026-10-02】原来内容直接挂在 PopupPanel 下，而 PopupPanel 默认
	# `wrap_controls = true` ⇒ **窗口按内容最小尺寸撑开**：本弹窗内容实测 ≈830px（真机几何里
	# 子元素一直排到 y≈830，整个内容 VBox 被撑成 652×10904），在 720px 高的屏幕上窗口远大于屏幕
	# ⇒「开始生成 / 停止 / 关闭」那一行（y 787~827）落在**屏幕外，用户点不到开始**。
	# 修法三件：① `wrap_controls = false`（窗口不再被内容撑开）② 内容装进 ScrollContainer
	# （放不下时可在弹窗内滚动）③ **按钮行留在滚动区之外**（永远可见可点）。
	dlg.wrap_controls = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	dlg.add_child(box)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body)
	box.add_child(_plain_label("一次做很多关。每关都要跑一次求解器（几秒到几十秒），"
		+ "生成期间界面会短暂停顿——进度与预计时间在下面，随时可以停。\n"
		+ "生成完会自动打包（带分类）并装进游戏，选关页 → Mod 里就能按大小 × 档位玩到。"))
	# 一键预设（P7.2，小白友好）：面对"大小 × 每档份数 × 雷密度"三层参数，新手会卡在"我该填多少"。
	# 两个按钮把参数迷宫压成一句话，点完**仍可自己微调**（预设不是黑箱）。
	# 放在标题行里是刻意的：弹窗已经接近屏幕高度上限，不能再多占一行。
	var apply_preset := func(kind: String) -> void:
		var sizes := [5, 6, 7] if kind == "taste" else [5, 6, 7, 8, 9]
		var counts := {"easy": 3, "normal": 0, "hard": 0} if kind == "taste" \
			else {"easy": 10, "normal": 5, "hard": 2}
		for size in _forge_size_checks.keys():
			(_forge_size_checks[size] as CheckBox).button_pressed = sizes.has(int(size))
		for tier in _forge_count_spins.keys():
			(_forge_count_spins[tier] as SpinBox).value = int(counts.get(tier, 0))
		_refresh_forge_hint()
		_toast("参数已填好（%s），点「开始生成」" % ("先试一小批" if kind == "taste" else "做一整套"))
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 6)
	var head_sec := _section_label("① 棋盘大小（勾上的都会生成）")
	head_sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(head_sec)
	var taste_btn := _action_button("先试一小批", func() -> void: apply_preset.call("taste"))
	taste_btn.tooltip_text = "一键填好参数：5×5 · 普通 3 关（约 1 分钟）。先跑通一次再加量"
	head_row.add_child(taste_btn)
	var full_btn := _action_button("做一整套", func() -> void: apply_preset.call("full"))
	full_btn.tooltip_text = "一键填好参数：5~9 五个尺寸 × 普通 10 / 困难 5 / 噩梦 2（量大，建议先试一小批）"
	head_row.add_child(full_btn)
	box.add_child(head_row)
	var grid := GridContainer.new()
	grid.columns = 3
	for size in [5, 6, 7, 8, 9]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var cb := CheckBox.new()
		cb.text = "%d×%d" % [size, size]
		cb.button_pressed = size <= 7      # 默认 5/6/7：小盘便宜，先让用户跑通一次再加大
		cb.toggled.connect(func(_p: bool) -> void: _refresh_forge_hint())
		_forge_size_checks[size] = cb
		row.add_child(cb)
		var ml := _plain_label("")
		_forge_mines_labels[size] = ml
		row.add_child(ml)
		grid.add_child(row)
	box.add_child(grid)
	box.add_child(_section_label("② 每个难度要几关（填 0 = 不做这一档）"))
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 10)
	for tier in Difficulty.PEAK_WINDOWS.keys():      # 档位名单唯一真源
		var col := VBoxContainer.new()
		col.add_child(_plain_label(Difficulty.tier_short(tier)))
		var sp := _spin(0, 100, 1)
		sp.value = {"easy": 5, "normal": 3, "hard": 0}.get(tier, 0)
		sp.value_changed.connect(func(_v: float) -> void: _refresh_forge_hint())
		_forge_count_spins[tier] = sp
		col.add_child(sp)
		trow.add_child(col)
	box.add_child(trow)
	box.add_child(_section_label("③ 雷的密度（每个大小按这个比例算雷数）"))
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	_forge_ratio = _spin(3, 40, 1)
	_forge_ratio.value = int(round(BatchForge.DEFAULT_MINES_RATIO * 100.0))
	_forge_ratio.value_changed.connect(func(_v: float) -> void: _refresh_forge_hint())
	drow.add_child(_forge_ratio)
	drow.add_child(_plain_label("%（标准扫雷 12%；调大 = 雷更多、更挤）"))
	box.add_child(drow)
	box.add_child(_section_label("④ 先探一次（可选，约 45 秒）"))
	box.add_child(_plain_label("它会真的试几个候选，量出「这个变体在这些大小上到底能出哪些难度、"
		+ "平均一次要多久」，然后给你这批的**时间预期**（结果存在本机，下次打开直接有）。\n"
		+ "探测期间偶尔会停几秒（一次求解不可中断）；随时可停，已经测到的都会留下。"))
	_forge_probe_btn = _action_button("先探一次（约 45 秒）", _forge_probe_start)
	box.add_child(_forge_probe_btn)
	_forge_est = _plain_label("")
	_forge_est.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_forge_est.custom_minimum_size = Vector2(620, 46)   # 同上：钉死换行宽度，别让最小高度炸掉
	box.add_child(_forge_est)
	_forge_hint = _plain_label("")
	box.add_child(_forge_hint)
	# 【真机目视修 2026-10-02 之二】进度条与进度消息**固定在弹窗底部**（滚动区之外）：
	# 实测内容 884px 装进 626px 视口，进度条与进度文字原来排在滚动区下方（真机 y=772 / y=803）
	# ⇒ 点「开始生成」后**屏幕上一动不动**，用户得先滚动才看得到进度；而"知道还要多久才能生成完"
	# 正是批量生成这个功能的核心诉求（用户原话）。所以：内容进滚动区，**进度区 + 按钮行留在外面**。
	while box.get_child_count() > 1:              # 0 号是滚动区本身，跳过
		var c := box.get_child(1)
		box.remove_child(c)
		body.add_child(c)
	_forge_bar = ProgressBar.new()
	_forge_bar.custom_minimum_size = Vector2(0, 22)
	_forge_bar.max_value = 100
	box.add_child(_forge_bar)
	_forge_msg = _plain_label("")
	_forge_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 【真机修 2026-10-02 之三：**必须钉死换行宽度**】Godot 里 `Control.size ≥ combined_minimum_size`，
	# 而**自动换行 Label 在宽度很小时会把最小高度算成几百上千像素**（真机实测这条消息标签被量成
	# **1239px 高**，弹窗内容最小高度 1322 ⇒ 窗口永远压不回 680，按钮被挤到 720px 屏幕之外，
	# `wrap_controls=false` 与"每步夹屏"都救不了 —— 因为它们压的是窗口，而撑住的是**最小尺寸**）。
	# 钉死换行宽度后，最小高度回到"几行"的正常值，窗口才压得住。
	_forge_msg.custom_minimum_size = Vector2(620, 64)
	box.add_child(_forge_msg)
	var btns := HBoxContainer.new()
	_forge_start_btn = _action_button("开始生成", _forge_start)
	btns.add_child(_forge_start_btn)
	_forge_stop_btn = _action_button("停止（已生成的都留着）", _forge_stop)
	_forge_stop_btn.disabled = true
	btns.add_child(_forge_stop_btn)
	_forge_close_btn = _action_button("关闭", _forge_close)
	btns.add_child(_forge_close_btn)
	box.add_child(btns)
	add_child(dlg)
	_forge_dlg = dlg
	_refresh_forge_hint()


## 参数提示：告诉他"一共会做多少关""每个大小用几颗雷"——免得他以为编辑器没问过雷数。
func _refresh_forge_hint() -> void:
	var sizes := _forge_sizes()
	var counts := _tier_counts()
	var per_size := 0
	for t in counts.keys():
		per_size += int(counts[t])
	var probe := BatchForge.new()
	probe.start({"sizes": sizes, "tier_counts": counts, "mines_ratio": _ratio()})
	for size in sizes:
		(_forge_mines_labels[size] as Label).text = "雷 %d 颗" % probe.mines_for(size)
	_forge_hint.text = "一共会做 %d 关（%d 个大小 × 每个大小 %d 关）；雷数按标准密度 12.3%% 自动算。" % [
		sizes.size() * per_size, sizes.size(), per_size]
	# 改大小/档位/密度都会改变预估（预估依赖"每个桶要几关"）
	_refresh_forge_estimate()


## 批量生成的入参（抽成纯函数：可单测，且**规则来源只有一处**）。
##
## 【两个曾经写死的坑，都在这修掉了（2026-10-02 自查）】
##   · 线索规则原写死取 `doc.rule_spec` 的 id、回退 "classic" ⇒ 从**内置变体关卡**
##     （例如载入一张 z1 / dt 的关卡）批量生成时，会静默产出**经典规则**的关卡。
##     正解：`doc.rule_id_effective()` —— 它才是"这份文档当前到底在用什么规则"的权威。
##   · 布局规则原写死 `[]` ⇒ 变体带的全局约束（hv / 4c / pf…）在批量产出里被**悄悄丢掉**：
##     图例在教那条约束、关卡却不含它，自相矛盾。正解：原样带上 `doc.global_rule_ids`。
func _forge_opts(sizes: Array, counts: Dictionary) -> Dictionary:
	var clue_id := ""
	if doc.has_method("rule_id_effective"):
		clue_id = str(doc.call("rule_id_effective"))
	if clue_id == "":
		clue_id = str(doc.rule_spec.get("id", ""))
	if clue_id == "":
		clue_id = "classic"
	return {
		"clue_rule_id": clue_id,
		"global_rule_ids": Array(doc.global_rule_ids),
		"sizes": sizes,
		"tier_counts": counts,
		"mode": _forge_mode(),
		"name_prefix": doc.title if doc.title != "" else "我的关卡",
		"out_dir": "user://forge/%s" % _forge_mode(),
		"mines_ratio": _ratio(),
	}


## 把选中的布局规则加进本关。允许叠加多条（引擎支持同时满足多条约束），
## 但不许重复加：重复在约束层面是幂等的，在界面上只会让人以为加了两条。
func _on_global_added() -> void:
	if _global_opt == null or _global_opt.selected < 0:
		_toast("先挑一条布局规则（下拉里选）", true)
		return
	var gid := str(_global_opt.get_item_metadata(_global_opt.selected))
	if gid == "":
		return
	if doc.global_rule_ids.has(gid):
		_toast("这条已经在列表里了：%s" % VariantCatalog.display_name(gid))
		return
	_push_undo(false)
	doc.global_rule_ids.append(gid)
	_mark_dirty()
	_refresh_all()
	_toast("已加上：%s —— 出关卡会照它生成，教程图例也会演示它" % VariantCatalog.display_name(gid))


func _on_globals_cleared() -> void:
	if doc.global_rule_ids.is_empty():
		_toast("本来就没有布局规则")
		return
	_push_undo(false)
	doc.global_rule_ids.clear()
	_mark_dirty()
	_refresh_all()
	_toast("已去掉全部布局规则")


## 当前布局规则：中文名 + 代码（空的时候**明说没有**，不留白让人猜）。
func _refresh_global_list() -> void:
	if _global_list == null:
		return
	if doc.global_rule_ids.is_empty():
		_global_list.text = "当前：没有布局规则（只按线索规则算数字）"
		return
	var parts: Array[String] = []
	for gid in doc.global_rule_ids:
		parts.append("%s（%s）" % [VariantCatalog.display_name(gid), gid])
	_global_list.text = "当前：%s" % "；".join(parts)


## 雷密度：SpinBox 是整数百分比 ⇒ 换算成比例；控件还没建时用默认。
func _ratio() -> float:
	if _forge_ratio == null:
		return BatchForge.DEFAULT_MINES_RATIO
	return float(int(_forge_ratio.value)) / 100.0


## 上次这条件变体的实测吞吐（`core/batch_forge.gd` 写在 index.json 里）：
## 点开弹窗就有个时间预期，不必先烧几十秒做预探。
func _last_forge_note() -> String:
	var idx := LevelSets.read_level("user://forge/%s/index.json" % _forge_mode())
	var n := int(idx.get("count", 0))
	var ms := int(idx.get("elapsed_ms", 0))
	if n <= 0 or ms <= 0:
		return ""
	return "\n上次这条件变体：%d 关用了 %s（约 %s/关）。" % [n, BatchForge.human_ms(ms),
		BatchForge.human_ms(int(round(float(ms) / float(n))))]


## 上一次批量产出的包在哪（`_forge_out` 的记录）：省得用户再去存档文件夹里翻。
func _last_pack_note() -> String:
	var zip := str(_forge_out.get("zip", ""))
	if zip == "":
		return ""
	return "\n上次生成好的包：%s" % zip


## 重型预探：逐帧跑几个候选，把"能出哪些档 / 单次多久"实测出来存进能力档案。
## 与 `core/variant_capability.gd` 共用同一份采样实现（`probe_seed`），不另写一套。
func _forge_probe_start() -> void:
	if _probe_running:
		_probe_cancel = true
		_forge_est.text = "正在停止探测…（等这一次求解算完就收工，已测到的都会留下）"
		return
	var sizes := _forge_sizes()
	if sizes.is_empty():
		_toast("先勾至少一个棋盘大小", true)
		return
	_probe_running = true
	_probe_cancel = false
	_forge_probe_btn.text = "停止探测"
	var opts := _forge_opts(sizes, _tier_counts())
	var clue := str(opts["clue_rule_id"])
	var globals: Array = doc.global_rule_ids
	var key := VariantCapability.rule_key(clue, globals)
	var gen := PuzzleGenerator.new()
	var t0 := Time.get_ticks_msec()
	var sides_data: Dictionary = VariantCapability.load_for(key).get("sides", {})
	for size in sizes:
		var size_i := int(size)
		if _probe_cancel or Time.get_ticks_msec() - t0 > FORGE_PROBE_BUDGET_MS:
			break
		var mines := int(RuleFeasibility.resolve_mines(clue, globals, size_i)["mines"])
		if mines < 0:
			continue      # 这个尺寸数学不可行 ⇒ 没有可测的东西（不是失败）
		var acc := VariantCapability.probe_new(mines)
		for k in FORGE_PROBE_CAND:
			if _probe_cancel or Time.get_ticks_msec() - t0 > FORGE_PROBE_BUDGET_MS:
				break
			_forge_est.text = "正在探测 %d×%d：第 %d/%d 个候选，已用 %s…" % [size_i, size_i, k + 1,
				FORGE_PROBE_CAND, BatchForge.human_ms(Time.get_ticks_msec() - t0)]
			await get_tree().process_frame      # 先把上面这行画出去，再跑（可能卡几秒的）求解
			if not is_inside_tree():
				return
			VariantCapability.probe_absorb(acc, VariantCapability.probe_seed(gen, clue, globals,
				size_i, mines, k + 1))
		var fin := VariantCapability.probe_finish(acc)
		if int(fin["cand"]) > 0:
			sides_data[str(size_i)] = fin
			VariantCapability.upsert_side(key, size_i, fin)      # 落盘：下次打开就有预估
	_probe_running = false
	_forge_probe_btn.text = "先探一次（约 45 秒）"
	_refresh_forge_estimate()
	_toast("探测结束：已记进本机档案，下次打开直接给预估")


## 预估（P6e）：把实测能力档案翻译成"哪些档能出、这批大概多久"。
## 没有档案时**如实说"还没实测"**并指到按钮上，不编一个"大概"。
func _refresh_forge_estimate() -> void:
	if _forge_est == null:
		return
	var opts := _forge_opts([], {})
	var key := VariantCapability.rule_key(str(opts["clue_rule_id"]), doc.global_rule_ids)
	var est := BatchForge.estimate(VariantCapability.load_for(key), _forge_sizes(), _tier_counts())
	if not bool(est["known_any"]):
		_forge_est.text = "还没实测过这个变体：点上面的「先探一次」，它会告诉你哪些难度大概能出、这批大概要跑多久。"
		return
	var lines: Array[String] = []
	for row in (est["per_bucket"] as Array):
		var r: Dictionary = row
		var tier_s := Difficulty.tier_short(str(r["tier"]))
		if bool(r["known"]):
			lines.append("　%d×%d %s：命中 %.0f%%、单次约 %s ⇒ %d 关约 %s" % [int(r["size"]), int(r["size"]),
				tier_s, float(r["hit_rate"]) * 100.0, BatchForge.human_ms(int(round(float(r["cost_ms"])))),
				int(r["want"]), BatchForge.human_ms(int(r["eta_ms"]))])
		else:
			lines.append("　⚠ %d×%d %s：实测**没出过**这一档 ⇒ 建议去掉它，或先把大小改小" % [
				int(r["size"]), int(r["size"]), tier_s])
	lines.append("　按实测（样本最少 %d 个候选）预估，总计约 %s —— 实际以进度条为准" % [
		int(est["cand_min"]), BatchForge.human_ms(int(est["eta_ms"]))])
	_forge_est.text = "\n".join(lines)


## 「① 验证」这一步（P7.3）：**先切到验证页再跑**——只跑不切的话，结论写在一个用户没在看的页面上，
## 等于"点了没反应"。切页用标题匹配而不是写死下标：页序以后调整时不会默默切错。
func _flow_verify() -> void:
	for c in find_children("*", "TabContainer", true, false):
		var tabs := c as TabContainer
		if tabs == null:
			continue
		for i in tabs.get_tab_count():
			if tabs.get_tab_title(i) == "验证":
				tabs.current_tab = i
				break
		break
	_on_verify()


func _forge_sizes() -> Array:
	var out: Array = []
	var keys: Array = _forge_size_checks.keys()
	keys.sort()
	for size in keys:
		if (_forge_size_checks[size] as CheckBox).button_pressed:
			out.append(int(size))
	return out


func _tier_counts() -> Dictionary:
	var out := {}
	for tier in _forge_count_spins.keys():
		out[tier] = int((_forge_count_spins[tier] as SpinBox).value)
	return out


func _forge_mode() -> String:
	# 【审查修 A4（真 bug）】原来用 `doc.rule_spec.id` ⇒ 两张**内置变体**（rule_spec 为空）都退化成
	# "classic"：输出目录、包 id、安装目录、"先删同名目录"、上次耗时全部撞在一起 ⇒ 后生成的变体
	# 会把前一个变体的关卡集与已装 Mod **一起删掉**。本文件别处已改用 rule_id_effective()（把线索规则
	# 与全局规则拼成稳定身份，见 editor_doc.gd），这里跟上。
	# 身份 = 线索规则 + **全局规则（排序去重）**：用于输出目录 / 包 id / 安装目录 / "先删同名目录"。
	#   · 为什么要全局规则：只差全局约束的两个变体（classic+hv / classic+4c）否则撞同一目录、互相删。
	#   · 为什么排序去重：`global_rule_ids` 来自关卡 JSON，同一集合可能顺序不同 ⇒ 不排序会出现
	#     `z1+hv+4c` 与 `z1+4c+hv` 两份身份（同一变体在选关页重复出现），而 `VariantCapability.rule_key`
	#     是按排序去重判等的 —— 两处口径必须一致（审查 #6）。
	#   · ⚠ **只用于身份**，绝不能拿去当 `clue_rule_id` 喂生成器（审查 #1 的血案）。
	var base := doc.rule_id_effective()
	if base.is_empty():
		base = "classic"
	var ids: Array[String] = []
	for g in doc.global_rule_ids:
		var s := str(g)
		if not s.is_empty() and not ids.has(s):
			ids.append(s)
	ids.sort()
	var out := base
	for s in ids:
		out += "+" + s
	# 身份会进目录名 / 包 id / zip 名 ⇒ 只留安全字符（审查 #6 的护栏；`+` 在 Windows 文件名里合法）
	var safe := ""
	for i in out.length():
		var ch := out[i]
		safe += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "+" else "_"
	return "forge_%s" % safe


func _forge_start() -> void:
	if _forge != null and not _forge.is_done():
		return
	var sizes := _forge_sizes()
	var counts := _tier_counts()
	if BatchForge.total_of(BatchForge.plan(sizes, counts)) <= 0:
		_forge_msg.text = "请至少勾一个棋盘大小，并给某一档填大于 0 的份数。"
		return
	_forge_out = {}
	_forge = BatchForge.new()
	_forge.start(_forge_opts(sizes, counts))
	_forge_start_btn.disabled = true
	_forge_stop_btn.disabled = false
	_forge_closed = false
	_forge_close_btn.text = "关闭（会停止生成）"   # 运行中关窗=停，按钮上先说清，免得用户以为只是收起
	_forge_loop()


## 逐帧步进：**先把进度画出去，再跑一次（可能阻塞数秒的）生成**——顺序不能反，
## 反了用户就只看到界面发呆（`core/batch_forge.gd` 的 step 是不可中断的 CP-SAT 调用）。
func _forge_loop() -> void:
	while _forge != null and not _forge.is_done():
		if _forge_dlg == null or not _forge_dlg.visible:   # 关窗/ESC 收起 ⇒ 立刻停（见 _forge_close）
			_forge.cancel()
			_forge_closed = true
			break
		_forge_fit_window()   # 生成途中文字会变长，窗口可能被重新撑大 ⇒ 每一步都夹回屏内
		var p := _forge.progress()
		_forge_bar.value = 100.0 * float(p["made"]) / maxf(1.0, float(p["total"]))
		var extra := ""
		if not str(p["bucket_text"]).is_empty():
			extra = "\n[当前] %s" % str(p["bucket_text"])
			var eta := int(p["eta_ms"])
			if eta > 0 and not bool(p["done"]):
				extra += "，预计还要 %s" % BatchForge.human_ms(eta)
		_forge_msg.text = str(p["msg"]) + extra
		await get_tree().process_frame
		if not is_inside_tree():
			return
		if _forge == null or _forge.is_done():
			break
		_forge.step()
	_forge_start_btn.disabled = false
	_forge_stop_btn.disabled = true
	_forge_close_btn.text = "关闭"
	var made := 0
	if _forge != null:
		made = int(_forge.progress()["made"])
	if _forge_closed:
		# 关窗停止：**不打包、不安装**，只说清已生成的关卡在哪（否则等于替用户静默发布了半套）
		_forge_bar.value = 100.0
		_toast("已停止：%d 关留在 %s（未打包）" % [made, str((_forge.report() as Dictionary).get("dir", ""))], false)
		return
	if made <= 0:
		_forge_msg.text = "一关都没生成出来（这个变体在这些大小上太难命中）。\n" \
			+ "可以少勾几个大小、只留「普通」，或把大尺寸去掉再试一次。"
		return
	_forge_bar.value = 100
	_forge_finish()
	_forge_fit_window()      # 完成消息有好几行（分类明细 + 路径）⇒ 再夹一次，别让按钮被挤出屏幕


## 【审查修 B6（真 bug）】关窗 = 停：原来「关闭」只 `hide()`，而协程仍在跑 —— 每步 `step()` 是不可中断
## 的 CP-SAT（数秒），界面既无进度也点不动，跑完还会**静默打包 + 安装**并弹一条完成提示：
## 用户以为取消了，却发现自己"发布"了半套关卡。现在关窗即取消，且收尾不打包。
func _forge_close() -> void:
	if _forge != null and not _forge.is_done():
		_forge.cancel()
		_forge_closed = true
	_forge_dlg.hide()


func _forge_stop() -> void:
	if _forge == null or _forge.is_done():
		return
	_forge.cancel()
	_forge_msg.text = "正在停止…（等这一次求解算完就落盘，已经生成的关卡都会留着）"


## 生成完：集文件 → 图例 → 打包（带分类索引）→ 装进游戏，一步都不缺。
func _forge_finish() -> void:
	var rep := _forge.report()
	var dir := str(rep["dir"])
	var idx := LevelSets.read_level("%s/%s" % [dir, BatchForge.INDEX_NAME])
	var tut_dir := _make_legend_files(dir)
	var zip_res := WorkshopPack.build(doc, {
		"id": _forge_mode(),
		"title": "%s（批量 %d 关）" % [doc.title if doc.title != "" else "我的关卡", int(rep["made"])],
		"description": "批量关卡：%d 关，按棋盘大小 × 难度分类（%s）" % [int(rep["made"]),
			_cat_text(rep["per_tier"])],
		"extra_manifest": {"categories": idx.get("categories", {}), "levels_index": idx.get("levels", [])},
		"levels_dirs": ["%s/%s" % [dir, BatchForge.LEVELS_DIR]],
		"tutorial_dirs": [tut_dir] if tut_dir != "" else [],
	})
	if not bool(zip_res["ok"]):
		_forge_msg.text = "生成好了 %d 关，但打包失败：%s\n（关卡文件在 %s）" % [
			int(rep["made"]), str(zip_res["reason"]), dir]
		return
	var zip_path := str(zip_res["path"])
	var ins := _install_mod_zip(zip_path, _forge_mode())
	_forge_out = {"dir": dir, "zip": zip_path, "index": idx, "mod": str(ins.get("mod_dir", ""))}
	var tail := "已装进游戏：选关页 → Mod 里按「大小 × 档位」浏览。" if bool(ins["ok"]) \
		else "打包好了，但装进游戏失败：%s" % str(ins["reason"])
	var legend_note := "（含图文图例）" if tut_dir != "" else "（这条规则没有图文图例：不是规格规则）"
	_forge_msg.text = "完成！%s\n分类：%s\n包：%s %s\n%s\n%s" % [str(rep["summary"]),
		_cat_text(rep["per_tier"]), zip_path, legend_note, tail, _short_note(rep)]
	_toast("批量完成：%d 关已打包并装进游戏" % int(rep["made"]))


func _cat_text(per_tier: Dictionary) -> String:
	var parts: Array[String] = []
	for tier in Difficulty.PEAK_WINDOWS.keys():
		var n := int(per_tier.get(tier, 0))
		if n > 0:
			parts.append("%s %d" % [Difficulty.tier_short(tier), n])
	return " ・ ".join(parts) if not parts.is_empty() else "无"


func _short_note(rep: Dictionary) -> String:
	var short: Array = rep["short"]
	if short.is_empty():
		return ""
	return "没做满的档位：%s（这些大小×档位太难命中，已跳过）" % "；".join(
		short.map(func(s: Variant) -> String: return str(s)))


## 生成图例（图文教程）到 `<批量目录>/tutorial/`，返回该目录（没有则 ""）。
## P6b：多页模式——"数字怎么读" + 每条全局规则的「满足 / 不满足」演示（红叉标违规雷）。
func _make_legend_files(dir: String) -> String:
	if doc.rule_spec.is_empty():
		return ""
	var rid := str(doc.rule_spec.get("id", ""))
	if rid == "":
		return ""
	var tut_dir := "%s/tutorial" % dir
	var res := RuleLegend.write_pages(rid, doc.rule_spec, doc.global_rule_ids, tut_dir)
	if not bool(res["ok"]):
		_toast("图例没生成：%s" % str(res["reason"]), true)
		return ""
	return tut_dir


## 装进游戏。**先清掉编辑器自己装的同名旧版本**：`install_from_zip` 遇到同名目录会拒装，
## 而"生成 → 装 → 再生成 → 再装"是批量生产的正常节奏（否则第二次永远装不上）。
## 只删 `author == "编辑器"` 的目录 —— 不碰玩家的其它 Mod。
func _install_mod_zip(zip_path: String, id: String) -> Dictionary:
	var dst := "user://mods/%s" % id
	# 【审查 #3 修】改成"**先装到临时根 → 成功后再替换正式目录**"。
	# 原来是"先把旧目录删掉再安装"：一旦安装失败（写盘失败 / 校验不过 / 目录被占用），玩家就变成
	# "内存里说已加载、磁盘上没目录"，而旧版本已经删了、回不来 —— 半成品比失败更坏。
	var stage_root := "user://mods__staging"
	_remove_dir_recursive("%s/%s" % [stage_root, id])
	var res := WorkshopPack.install_from_zip(zip_path, stage_root)
	if not bool(res.get("ok", false)):
		return res
	var staged := str(res.get("mod_dir", ""))
	if staged.is_empty():
		return {"ok": false, "reason": "安装返回了空目录", "mod_dir": "", "files": []}
	# 成功之后才动旧版本：只删 `author == "编辑器"` 的目录，不碰玩家自己的 Mod
	var man := LevelSets.read_level("%s/manifest.json" % dst)
	if not man.is_empty() and str(man.get("author", "")) == "编辑器":
		_remove_dir_recursive(dst)
	DirAccess.make_dir_recursive_absolute("user://mods")
	var mv := DirAccess.rename_absolute(staged, dst)
	if mv != OK:
		# 搬不进去（跨设备 / 目录被占用 / 已有别人的同名 Mod）⇒ 临时目录仍完整保留，说清原因
		return {"ok": false, "reason": "装好了但搬不进 user://mods（错误码 %d），成品留在 %s" % [mv, staged],
			"mod_dir": staged, "files": res.get("files", [])}
	_remove_dir_recursive(stage_root)
	var out: Dictionary = res.duplicate()
	out["mod_dir"] = dst
	# 【P0-1 修复：端到端断链】装完**顺手加载**。原来只落盘不加载，而选关页只列 `ModAPI.list_mods()`
	# （已加载的），加载的唯一入口在「模组」页的手动按钮 ⇒ 用户按界面提示去选关页，**Mod 页签是空的**
	# （`test/ui/test_level_select_interaction.gd` 的 `ls14` 用例钉的就是这条链路）。
	# 【P0-1 修复：端到端断链】装完**顺手加载**（选关页只列 `ModAPI.list_mods()`）；【审查 #2】同名已加载
	# 时先卸内存（不删盘）再加载，否则"装的是新版、跑的是旧规则"。
	if ModAPI.list_mods().has(id):
		ModAPI.unload_mod(id)
	ModAPI.load_mod(dst)
	return out


static func _remove_dir_recursive(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_remove_dir_recursive(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)


# ==================== 零代码创作（AI 帮我写） ====================
#
# 用户只做三件事：复制一段话 → 粘给任意 AI → 把回复粘回来。其余全在这里：
# 取 JSON（宽容解析）、分流（规则/关卡/清单）、校验、注册、白话解释、失败回喂给 AI。
# 与「规则」页的关系：本页是**包装**，最终仍写进同一个真源（doc.rule_spec + 注册表），
# 所以两页永远一致——不存在"AI 页生效了、规则页没同步"这种双真源。

## 当前的棋盘信息：必须告诉 AI。对方的 AI 看不到本仓库，也不知道用户画的是方盘还是环绕盘，
## 而 geometry 选错会让数字**静默算错**（方盘上写 refs="topo" ⇒ 全 0）。
func _ai_context() -> Dictionary:
	return {
		"idea": _idea_edit.text.strip_edges() if _idea_edit != null else "",
		"rows": doc.rows,
		"cols": doc.cols,
		"mines": doc.mine_count(),
		"wrap": doc.wrap,
		"shape": doc.shape_kind,
		"foreign": not doc.foreign_topology.is_empty(),
	}


func _copy_ai_prompt() -> void:
	var text := SpecHelper.ai_prompt(_ai_context())
	DisplayServer.clipboard_set(text)
	_ai_result.text = "已复制 %d 字。把它粘给你电脑上的 AI（DeepSeek / 豆包 / ChatGPT 都行），\n再把 AI 的回复整段粘到下面的框里。" % text.length()
	_toast("「给 AI 的话」已复制到剪贴板")


func _paste_ai_text() -> void:
	var t := DisplayServer.clipboard_get()
	if t.strip_edges() == "":
		_toast("剪贴板是空的", true)
		return
	_ai_text.text = t
	_ai_result.text = "已粘贴 %d 字，点「读懂并导入」。" % t.length()


## 核心入口：读懂用户粘回来的东西（规则 / 关卡 / Mod 清单，各自分流）。
func _import_ai_text() -> void:
	var raw := _ai_text.text
	var ex := SpecHelper.extract_json(raw)
	if not bool(ex["ok"]):
		_ai_last_text = raw
		_ai_last_errors = _to_str_array(ex["errors"])
		_ai_fix_btn.disabled = false
		_ai_result.text = "没读出 JSON。\n%s\n\n下一步：点下面 ③ 复制「让 AI 修」的话，粘给 AI 让它重新只输出一次 JSON。" % "\n".join(_ai_last_errors)
		return
	var data: Dictionary = ex["data"]
	match SpecHelper.kind_of(data):
		"spec":
			_apply_ai_spec(data, str(ex["note"]))
		"level":
			# 关卡（不是规则）：走既有载入路径，清掉当前文件路径避免覆盖别人
			_current_path = ""
			if _load_from_text(JSON.stringify(data)):
				_ai_fix_btn.disabled = true
				_ai_result.text = "这一段读出来是**关卡**（不是规则），已按关卡导入并加载到画布上。"
			else:
				_ai_result.text = "这一段像是关卡，但加载失败（缺少 size / mines 等字段）。\n可以让 AI 再检查一遍，或改用「规则」页手写。"
		"manifest":
			_ai_result.text = "这一段是**Mod 清单**（manifest.json），不是规则。\n请把它与 entry.gd 一起放进 user://mods/<你的mod>/ 目录。"
		_:
			_ai_result.text = "读到了一段 JSON，但看不出是「规则」还是「关卡」——\n请让 AI 只输出规则 JSON（含 spec_version 与 clue）。"


## 把一份规格真正落地：写进文档（唯一真源）→ 注册 → 立刻重算数字 → 白话解释。
## `note` 说明这份规格从哪来（配方 / 已替换同名旧版本），会显示给用户。
func _apply_ai_spec(spec: Dictionary, note := "") -> void:
	_ai_last_text = _ai_text.text
	var v := SpecSchema.validate(spec)
	var errs := _to_str_array(v.get("errors", []))
	# 用户让 AI 改了一版、id 却没变时，「id 已被注册」会让小白卡死。
	# 只对**注册表里那个 id 恰好是本插件注册的规格规则**这一种情况做替换（先注销再注册）；
	# 内置 / 官方规则一律照实报错——绝不悄悄覆盖别人的规则。
	var sid := str(spec.get("id", ""))
	if errs.size() == 1 and errs[0].find("已被注册") != -1 and sid != "" and SpecHelper.is_replaceable_spec(sid):
		RuleRegistry.default().unregister(StringName(sid))
		v = SpecSchema.validate(spec)
		errs = _to_str_array(v.get("errors", []))
		note += "（已用新版本替换了同名的旧规格规则）"
	if not bool(v["ok"]):
		_ai_last_errors = errs
		_ai_fix_btn.disabled = false
		_ai_result.text = "这条规则还差一点，先看这几条：\n%s\n\n下一步：点下面 ③ 复制「让 AI 修」的话，AI 会给你修好的完整 JSON。" % _friendly_text(v)
		return

	# 通过：写进唯一真源（规则页看到的就是同一份），再注册，再重算
	_syncing = true
	_spec_edit.text = JSON.stringify(spec, "  ")
	_rule_id_edit.text = str(spec.get("id", ""))
	_syncing = false
	_on_rule_changed()
	var reg := doc.register_rule()
	if not bool(reg["ok"]):
		_ai_last_errors = _to_str_array([str(reg["reason"])])
		_ai_fix_btn.disabled = false
		_ai_result.text = "规则没能注册：%s" % str(reg["reason"])
		return
	_ai_fix_btn.disabled = true
	_refresh_preview()
	_refresh_errors()
	_refresh_status()
	_ai_result.text = "导入成功%s\n\n%s\n\n下一步：左边「随机布雷」→「试玩」，或到「验证」页看不猜能不能解。" % [note, SpecHelper.explain_spec(spec)]
	_toast("规则已生效：%s" % str(spec.get("title", spec.get("id", ""))))


func _copy_repair_prompt() -> void:
	var errs: Array[String] = []
	errs.assign(_ai_last_errors)
	if errs.is_empty():
		errs.append("没能从你的回复里读出 JSON 代码块")
	var text := SpecHelper.repair_prompt(_ai_last_text, errs)
	DisplayServer.clipboard_set(text)
	_ai_result.text = "已复制「让 AI 修」的话（含报错原文）。粘给 AI，它会给修正后的完整 JSON；\n把它的回复再整段粘回上面的框，重新点「读懂并导入」。"
	_toast("已复制：把这段话交给 AI，让它改")


func _apply_recipe() -> void:
	var rs := SpecHelper.recipes()
	var i := _recipe_opt.selected
	if i < 0 or i >= rs.size():
		return
	var rec: Dictionary = rs[i]
	_ai_text.text = JSON.stringify(rec["spec"], "  ")
	_apply_ai_spec(rec["spec"], "（来自现成配方：%s）" % str(rec["title"]))


func _refresh_recipe_note() -> void:
	var rs := SpecHelper.recipes()
	var i := _recipe_opt.selected
	if i < 0 or i >= rs.size():
		return
	var rec: Dictionary = rs[i]
	_recipe_note.text = "%s\n适用：%s" % [str(rec["blurb"]), str(rec["note"])]


## 校验结果 → 显示用文本（校验器原文 + 小白建议）。
func _friendly_text(v: Dictionary) -> String:
	var lines: Array[String] = []
	for it in SpecHelper.friendly(v):
		var d: Dictionary = it
		var tag := "问题" if str(d["level"]) == "error" else "提醒"
		lines.append("· %s：%s" % [tag, str(d["text"])])
		lines.append("　→ %s" % str(d["hint"]))
	return "\n".join(lines)


static func _to_str_array(x: Variant) -> Array[String]:
	var out: Array[String] = []
	if x is Array or x is PackedStringArray:
		for it in x:
			out.append(str(it))
	return out


# ==================== 验证 ====================

## 点「开始验证」：**先把"正在验证…"画出去，再算**。
## 验证是同步重活（9×9 约 90ms；组合数超限时由廉价预检直接拒绝，不会真卡死），
## 但小白看不到任何动静就会以为"点了没反应 / 是不是卡了"。先等一帧（这一帧会被绘制）
## 再跑计算，他就能看到那行字；算完把按钮恢复。
func _on_verify() -> void:
	if _verify_btn != null:
		_verify_btn.disabled = true
	if _verify_plain != null:
		_verify_plain.text = "正在验证…（棋盘越大越慢，请稍等）"
	if _verify_state != null:
		_verify_state.text = ""
	for c in _verify_issues.get_children():
		c.queue_free()
	await get_tree().process_frame
	_run_verify()
	if _verify_btn != null:
		_verify_btn.disabled = false


func _run_verify() -> void:
	var r := EditorVerify.verify(doc)
	# 先给"人话结论"（小白只看这一行就够），技术细节放下一行（保留，供作者/再交给 AI 时用）
	if _verify_plain != null:
		_verify_plain.text = _plain_conclusion(str(r["state"]))
	_verify_state.text = "%s\n%s" % [str(r["label"]), str(r["reason"])]
	var st: Dictionary = r["stats"]
	if not st.is_empty():
		var sol := int(st.get("solutions", -1))
		# 去掉"后端 cpsat"这类黑话（stats 字典里仍保留 backend，测试要用）
		_verify_issues.add_child(_plain_label("推了 %d 轮 ｜ 开局已翻开 %d 格 ｜ 又推出安全格 %d ｜ 又推出雷 %d ｜ 雷的摆法有 %s 种 ｜ 用时 %d 毫秒" % [
			int(st.get("rounds", 0)), int(st.get("revealed_start", 0)), int(st.get("forced_safe", 0)),
			int(st.get("forced_mine", 0)), "未知" if sol < 0 else str(sol),
			int(st.get("elapsed_ms", 0))]))
	for it in r["issues"]:
		_verify_issues.add_child(_plain_label("· %s" % str((it as Dictionary)["text"])))


## 验证结论 → 小白版一句话（技术原文仍显示在下一行）。
func _plain_conclusion(state: String) -> String:
	match state:
		EditorVerify.STATE_NO_GUESS:
			return "好消息：这一关不用猜就能推完。"
		EditorVerify.STATE_NEEDS_GUESS:
			return "有些格子必须靠猜（玩起来可能会卡住）。"
		EditorVerify.STATE_CONTRADICTION:
			return "这一关有矛盾：按数字推会互相打架，做不出来。"
		_:
			return "没能得出结论——下面的「本盘问题」里如果有红字，先照着改，再点一次验证。"


# ==================== 数据：保存 / 打开 / 剪贴板 / 打包 / 试玩 ====================

## 文件名用的标题：只去掉文件系统不认的字符，**其余（含中文）原样保留**。
## 【为什么要改】原实现只留 ASCII 字母数字 ⇒ 中文标题一律被吃掉，"关卡名字"这个输入框形同虚设
##（2026-10-02 实测：起名"我的第一关"，存出来还是 level.json）。中文文件名在 Windows/Godot 都合法。
func _slug(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch := text[i]
		if ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"].has(ch) or ch.unicode_at(0) < 32:
			continue
		out += ch
	out = out.strip_edges().trim_suffix(".")
	if out.length() > 40:
		out = out.substr(0, 40).strip_edges()
	return out if out != "" else "我的关卡"


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var path := _target_save_path()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_toast("保存失败：%s" % path, true)
		return
	f.store_string(JSON.stringify(doc.to_level_json(), "  "))
	f.close()
	_current_path = path
	_dirty = false
	_refresh_open_list()
	# 只说文件名 + 去哪儿找：原来把 user://editor/level.json 直接甩给用户，小白既看不懂也找不到
	_toast("已保存：%s\n（在左栏「打开存档文件夹」里能看到这个文件）" % path.get_file(), false, 5.0)


## 决定写哪个文件：**当前正在编辑的文件优先**（"保存"应当覆盖自己的文件，这是人的预期）；
## 标题改了、或还没定过路径时，找一个**不重名**的新文件。
## 原实现直接用标题当文件名 ⇒ 两份同名关卡互相覆盖、连提示都没有（2026-10-02 复查发现）。
func _target_save_path() -> String:
	var base := _slug(doc.title)
	if _current_path != "" and _current_path.get_file().get_basename() == base:
		return _current_path
	var candidate := EDITOR_DIR.path_join("%s.json" % base)
	if not FileAccess.file_exists(candidate):
		return candidate
	var i := 2
	while FileAccess.file_exists(EDITOR_DIR.path_join("%s_%d.json" % [base, i])):
		i += 1
	return EDITOR_DIR.path_join("%s_%d.json" % [base, i])


func _open_selected() -> void:
	if _open_opt.item_count == 0:
		_toast("还没有保存过的关卡——先按左上角「保存」", true)
		return
	var path := EDITOR_DIR.path_join(_open_opt.get_item_text(_open_opt.selected))
	if not _load_from_file(path):
		_toast("打开失败：%s" % path.get_file(), true)
		return
	# 原来打开成功**没有任何提示**（只有棋盘内容变了）⇒ 小白不知道到底开没开
	_toast("已打开：%s" % path.get_file())


## 打开"关卡存档"所在文件夹。
## 为什么需要：保存路径是 user://（在系统的隐藏目录里），小白既看不懂也找不到；
## 这里直接把文件夹打开，并在提示里打印真实路径（万一系统拒绝打开，用户还能照着手动找）。
func _open_save_dir() -> void:
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var abs := ProjectSettings.globalize_path(EDITOR_DIR)
	OS.shell_open(abs)   # 注意是 OS.shell_open（DisplayServer 上没有这个静态函数，写错会让整个脚本解析失败）
	_toast("已打开文件夹：\n%s" % abs, false, 6.0)


## 一键载入示例关卡：9×9 / 10 雷，固定随机种子（每次一样，便于互相讲解）。
## 走的是**真实载入路径**（`_load_from_text`），和"打开别人发来的关卡"完全同一条代码。
func _load_example() -> void:
	var d := EditorDoc.new(9, 9)
	d.title = "示例关 9×9 十雷"
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261002
	var free: Array[Vector2i] = []
	for y in d.rows:
		for x in d.cols:
			free.append(Vector2i(x, y))
	for i in range(free.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Vector2i = free[i]
		free[i] = free[j]
		free[j] = tmp
	for k in 10:
		d.mines.append(free[k])
	_current_path = ""
	if _load_from_text(JSON.stringify(d.to_level_json())):
		_set_intro_visible(false, false)
		_toast("已载入示例关卡（9×9、10 颗雷）：可以直接按左上角「试玩」", false, 5.0)
	else:
		_toast("示例关卡载入失败（不该发生，请反馈）", true)


func _load_from_file(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var ok := _load_from_text(text)
	if ok:
		_current_path = path   # 之后"保存"就覆盖这个文件（符合人的预期）
	return ok


func _load_from_text(text: String) -> bool:
	# 安全解析：粘贴/导入的内容读不懂是常态（用户会粘错东西），不该刷 ERROR 日志
	var parsed: Variant = SpecHelper.parse_json_safe(text)
	if not (parsed is Dictionary):
		return false
	_undo.append(doc.snapshot())
	_redo.clear()
	var r := doc.load_from(parsed)
	if not bool(r["ok"]):
		return false
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()
	return true


func _export_clipboard() -> void:
	DisplayServer.clipboard_set(JSON.stringify(doc.to_level_json(), "  "))
	_toast("已复制关卡文本：粘到聊天窗口就能发给朋友", false, 5.0)


func _import_clipboard() -> void:
	var text := DisplayServer.clipboard_get()
	if text.strip_edges() == "":
		_toast("粘贴板是空的", true)
		return
	# 从剪贴板导入的是"新东西"⇒ 清掉当前路径，避免下次保存覆盖掉原来那个文件
	_current_path = ""
	if not _load_from_text(text):
		_toast("粘贴板里的内容不是一份关卡\n（让对方在自己的编辑器里按「复制关卡文本」再发一次）", true, 7.0)


func _make_pack() -> void:
	var r := WorkshopPack.build(doc, {})
	if not bool(r["ok"]):
		_toast("生成分享包失败：%s\n（先照「本盘问题」里的红字改，再试一次）" % str(r["reason"]), true, 7.0)
		return
	# 产品要求：未集成 Steamworks 时明确提示手动上传（绝不给假成功）。
	# 后面补一句人话解释："包"是什么、去哪儿找——原提示只给一个 user:// 路径。
	_toast("已生成分享包：%s\n%s\n（就是一份 zip，在左栏「打开存档文件夹」里；发给朋友即可）" % [
		str(r["path"]).get_file(), SteamWorkshop.UPLOAD_HINT], false, 8.0)


## 一键安装：生成包 → 解包到 `user://mods/<id>/`（下次启动游戏即可见）。
## 不代做 Steam 上传（产品要求），但安装这步没必要让玩家手动解压。
func _install_pack() -> void:
	var built := WorkshopPack.build(doc, {})
	if not bool(built["ok"]):
		_toast("生成分享包失败：%s\n（先照「本盘问题」里的红字改，再试一次）" % str(built["reason"]), true, 7.0)
		return
	# 【审查 #8 修】不再自己走一遍安装：**复用 `_install_mod_zip`**（清旧版 + 临时目录替换 + 装完即加载）。
	# 否则两个安装入口各有一套行为：单关包重装必失败、提示也不指路，「生成分享包」与「批量安装」体验分叉。
	var id := _pack_id_of(str(built["path"]))
	if id == "":
		_toast("安装失败：包里的 manifest 读不出 id（包可能损坏）", true, 6.0)
		return
	var r := _install_mod_zip(str(built["path"]), id)
	if not bool(r["ok"]):
		_toast("安装失败：%s" % str(r["reason"]), true, 6.0)
		return
	_toast("已装进游戏并加载好了：选关页 → Mod 页签就能看到这份关卡", false, 5.0)


## 读一个分享包（zip）里 manifest 的 id —— 安装前要先知道它会落到 `user://mods/` 下哪个目录。
func _pack_id_of(zip_path: String) -> String:
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return ""
	var txt := zr.read_file(WorkshopPack.MANIFEST_NAME)
	zr.close()
	if txt == null:
		return ""
	var mv := ManifestParser.new().parse(txt.get_string_from_utf8())
	if not bool(mv.get("ok", false)):
		return ""
	return str((mv["manifest"] as Dictionary).get("id", ""))


## 「说明」开关（2026-10-02 用户需求）：
##   · 独立按钮、**默认不显示**，点一次展开、再点一次收起；
##   · 每条说明贴在**它对应的按钮右边**，中间用折线连起来（"这条线表示这段字说的是谁"）；
##   · 用户滚动后按钮位置变了，说明跟着按钮走（`editor_help.gd` 每帧读按钮全局矩形）；
##   · **读数（雷数 / 格子数 / 状态栏结论）始终显示**：本层只叠加、不隐藏任何既有内容。
func _toggle_help() -> void:
	if _help_layer != null:
		_close_help()
		return
	_open_help()


## 收起（顺带断开页签同步，免得下次打开重复连接）。
func _close_help() -> void:
	if _help_layer != null:
		_help_layer.queue_free()
		_help_layer = null
	if _help_btn != null:
		_help_btn.button_pressed = false
	var tabs := _right_tabs()
	if tabs != null and tabs.tab_changed.is_connected(_on_help_tab_changed):
		tabs.tab_changed.disconnect(_on_help_tab_changed)


func _open_help() -> void:
	var items: Array = []
	var tabs := _right_tabs()
	# ① 左栏每个按钮
	
	if _left_bar != null:
		for n in _left_bar.find_children("*", "Button", true, false):
			var b := n as Button
			if b.text.strip_edges() == "":
				continue
			var desc := str(b.tooltip_text).strip_edges()
			if desc == "":
				desc = str(HELP_TEXT.get(b.text, ""))
			if desc == "":
				# 【用户要求 2026-10-02："有很多左侧按钮的说明没有"】兜底：一个都不许空着。
				desc = "点它执行「%s」。" % b.text
			items.append({"btn": b, "title": b.text, "text": desc})
	# ④ 【2026-10-02 用户口径】那三段"长解释"已删 ⇒ 换成**一条照着点的引导**（挂在左栏边上）。
	if _left_bar != null:
		items.append({"btn": _left_bar, "title": "怎么用（照着点就行）", "text": HELP_GUIDE})
	if _status != null:
		items.append({"btn": _status, "title": "常驻读数",
			"text": "雷数 / 格子数 / 校验结论一直显示在这里，开关说明不会影响它们。"})
	var layer: Control = load("res://ui/editor_help.gd").new()
	add_child(layer)
	layer.z_index = 60                 # 压在所有既有层之上（左栏 / 画布 / 右栏）
	# 说明落在**中间区**（画布那块）；画布会被**高斯模糊**并**拦截点击**（见 editor_help.gd）
	layer.call("setup", items, canvas)
	layer.call("set_page_items", _help_page_items())     # 右侧当前页的控件说明
	# 点说明外任意一处（或按 ESC）即关闭
	layer.connect("dismissed", _close_help)
	_help_layer = layer
	if tabs != null and not tabs.tab_changed.is_connected(_on_help_tab_changed):
		tabs.tab_changed.connect(_on_help_tab_changed)
	if _help_btn != null:
		_help_btn.button_pressed = true
	_toast("说明已展开（棋盘已模糊、暂时点不动）：右侧换页会跟着换说明", false, 6.0)


## 当前页相关的说明条目：①"这页是干什么的"总述；②**页面里自带的解释文字**
##（用户要求："把这类解释说明的文字也放进说明里面"）—— 原文照搬，折线直接指到那段字本身。
## 都带 `page` 标记 ⇒ 换页时可以整组替换。
func _help_page_items() -> Array:
	var out: Array = []
	var tabs := _right_tabs()
	if tabs == null:
		return out
	# 【用户要求 2026-10-02】**不解释"属性/验证"这种大类**，只解释**控件**：
	# 把当前页里的按钮 / 填空 / 下拉 / 勾选逐个列出来，各给一句话。
	var page := tabs.get_child(tabs.current_tab)
	if page == null:
		return out
	for n in page.find_children("*", "", true, false):
		var entry := _control_help_entry(n)
		if not entry.is_empty():
			entry["page"] = true
			out.append(entry)
	return out


## 一个控件 → 一条说明（空字典 = 不解释它）。用户原话："解释按钮，填空之类的即可"。
func _control_help_entry(node: Node) -> Dictionary:
	if node is Button and not (node is CheckBox) and not (node is OptionButton):
		var b := node as Button
		if b.text.strip_edges() == "":
			return {}
		# 按钮的说明优先级：**人工写的对照表（HELP_TEXT）> 悬停说明 > 兜底**。
		# 为什么对照表优先：`_action_button` 会给按钮自动塞 tooltip（内容往往就是按钮文字），
		# 若 tooltip 优先，则我精心写的说明（如「AI 帮我写」那三步）永远轮不到（真机+CI 都踩过）。
		var desc := str(HELP_TEXT.get(b.text, "")).strip_edges()
		if desc == "":
			desc = str(b.tooltip_text).strip_edges()
		if desc == "":
			desc = "点它执行「%s」。" % b.text
		return {"btn": b, "title": b.text, "text": desc}
	if node is CheckBox:
		var cb := node as CheckBox
		if cb.text.strip_edges() == "":
			return {}
		return {"btn": cb, "title": cb.text,
			"text": _desc_for(cb, cb.tooltip_text, "勾上/取消它。")}
	if node is OptionButton:
		var ob := node as OptionButton
		return {"btn": ob, "title": _option_title(ob),
			"text": _desc_for(ob, ob.tooltip_text, "下拉选择：点开挑一个。")}
	if node is SpinBox:
		var sp := node as SpinBox
		return {"btn": sp, "title": "数字：%d ~ %d" % [int(sp.min_value), int(sp.max_value)],
			"text": _desc_for(sp, sp.tooltip_text, "数字输入框：点上下箭头，或直接输数字。")}
	if node is LineEdit:
		var le := node as LineEdit
		return {"btn": le, "title": _field_title(le.placeholder_text, "填空"),
			"text": _desc_for(le, le.tooltip_text, "在这里输入文字（框里的灰字是提示）。")}
	if node is TextEdit:
		var te := node as TextEdit
		return {"btn": te, "title": _field_title(te.placeholder_text, "多行填空"),
			"text": _desc_for(te, te.tooltip_text, "在这里粘贴/输入多行内容。")}
	return {}


func _desc_for(node: Control, tip: Variant, fallback: String) -> String:
	var s := str(tip).strip_edges()
	if s != "":
		return s
	return fallback


func _field_title(placeholder: String, fallback: String) -> String:
	var s := placeholder.strip_edges()
	if s == "":
		return fallback
	return s if s.length() <= 14 else s.substr(0, 14) + "…"


func _option_title(ob: OptionButton) -> String:
	if ob.item_count <= 0:
		return "下拉选择"
	return "下拉：%s" % ob.get_item_text(ob.selected)


## 右侧换页 ⇒ **整层重建**：页签一变，"这一页自带的解释文字"也换了对象（要重新连线），
## 重建比就地改结构更不容易漏；按钮保持按下态。
func _on_help_tab_changed(_idx: int) -> void:
	if _help_layer == null:
		return
	_help_layer.call("set_page_items", _help_page_items())


func _playtest() -> void:
	var rep := doc.validate()
	if not bool(rep["ok"]):
		var first := ""
		for it in rep["errors"]:
			first = str((it as Dictionary)["text"])
			break
		_toast("先修好这些问题再试玩：%s" % first, true)
		return
	var reg := doc.register_rule()
	if not bool(reg["ok"]):
		_toast("规则注册失败：%s" % str(reg["reason"]), true)
		return
	# 【为什么要先存一手】自动存档只在"改动后空闲 1.2 秒"才写；而试玩会直接切场景把编辑器节点销毁。
	# 小白实测路径是"画完立刻点试玩" ⇒ 最后那 1 秒内的改动会丢。这里显式存一次。
	_write_autosave()
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var f := FileAccess.open(PLAY_PATH, FileAccess.WRITE)
	if f == null:
		_toast("无法写入试玩文件", true)
		return
	f.store_string(JSON.stringify(doc.to_level_json(), "  "))
	f.close()
	if not GameSession.start_level(PLAY_PATH):
		_toast("试玩加载失败（关卡数据被加载器拒绝）", true)
		return
	# 留下回程（2026-10-02 用户反馈："点完试玩就回不来" —— 游戏侧 HUD 唯一的出口是「关卡列表」→ 选关页）。
	# 游戏 HUD 与结算层见到它非空就多显示一个「回编辑器」；正式发售的游戏里它一直是空串。
	GameSession.playtest_return = PLAYTEST_RETURN
	get_tree().change_scene_to_file("res://ui/board_view.tscn")


func _back_to_select() -> void:
	_write_autosave()
	get_tree().change_scene_to_file("res://ui/level_select.tscn")


# ==================== 自动保存（原子写） ====================

func _write_autosave() -> void:
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var tmp := AUTOSAVE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(doc.to_level_json(), "  "))
	f.close()
	# 三段式原子写：先写 tmp 再改名，避免断电/崩溃留下半截文件
	DirAccess.rename_absolute(tmp, AUTOSAVE_PATH)
	_dirty = false


func _load_autosave_if_any() -> void:
	if not FileAccess.file_exists(AUTOSAVE_PATH):
		return
	var f := FileAccess.open(AUTOSAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and bool(doc.load_from(parsed)["ok"]):
		_doc_to_ui()
		_toast("已恢复上次未保存的编辑内容")


# ==================== 杂项 ====================

func _on_theme_changed() -> void:
	if canvas != null:
		canvas.queue_redraw()
	_repaint_labels()   # 审查 A2：字色 override 不会随主题变，切到浅色主题要立刻重刷（否则白底白字）


func _on_theme_settled() -> void:
	_refresh_all()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	if k.ctrl_pressed and k.keycode == KEY_Z:
		_undo_once()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_Y:
		_redo_once()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_S:
		_save()
		get_viewport().set_input_as_handled()
	# 选区的复制/粘贴走快捷键（P6h）：用户的抱怨是"选完还得跑去左栏点按钮"太绕
	elif k.ctrl_pressed and k.keycode == KEY_C:
		_copy_selection()
		get_viewport().set_input_as_handled()
	elif k.ctrl_pressed and k.keycode == KEY_V:
		_paste_selection()
		get_viewport().set_input_as_handled()


## ttl：停留秒数。默认 2 秒对短提示够用；但"去哪儿找文件 / 分享包是什么"这类要读完的信息
##（2026-10-02 实测）2 秒根本读不完 ⇒ 调用处显式传更长的 ttl。
func _toast(msg: String, danger: bool = false, ttl := 2.0) -> void:
	if is_inside_tree():
		# 危险提示除了染红，再加一个符号：颜色不能是**唯一**信号
		#（色盲用户、黑白截图、以及"红绿色弱"的人分不出红字与普通字）。
		UI_TOAST.popup(self, ("⚠ " + msg) if danger else msg, danger, ttl)
