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
## 键位绑定表（独立段 `[editor_keys]`）与编辑/试玩统一状态机。
## 都**不用 class_name**：headless 下新全局类不在 `.godot` 缓存里，按类名引用会让整份脚本解析失败
##（本文件顶部与 `ui/tutorial_overlay.gd:12` 记的同一个坑 #26）。
const BINDINGS := preload("res://core/editor_bindings.gd")
const VIEW_STATE := preload("res://core/editor_view_state.gd")
## 猜点热力图 / 推理链回放：只接线，算法在 core 的两个纯逻辑模块里（本切片不重写它们）。
## 同 BINDINGS/VIEW_STATE：**用 preload 引用、不按 class_name 引用**——headless 下新全局类
## 不在 `.godot` 缓存里时，按类名会让整份脚本解析失败（坑表 #26）。
const HOTMAP := preload("res://core/hotmap.gd")
const REPLAY := preload("res://core/replay_model.gd")
## 推理链的数据来源（ProofLog 产出 ReasoningStep.to_dict() 数组，正是 ReplayModel.load 吃的形态）。
const PROOF_LOG := preload("res://core/proof_log.gd")
## 全局性能记账 + 统一降级顺序（core/perf_ledger.gd；本切片只**接线**、不改它）。
## 同 BINDINGS/VIEW_STATE：**用 preload 引用、不按 class_name 引用**——headless 下新全局类不在
## `.godot` 缓存里时，按类名会让整份脚本解析失败（坑表 #26）。
const PERF_LEDGER := preload("res://core/perf_ledger.gd")
## 模板库（core/template_library.gd，文档「九」+「十.6」）。它**刻意没有 class_name**（见其文件头），
## 所以只能 preload；本切片只接线，模板数据与 `apply_to_doc` 全在 core。
const TEMPLATES := preload("res://core/template_library.gd")
## 形状布尔 / 形状依赖图 / 修复建议 / 短码分享 —— 四个 core 能力（都已单测）接到界面上。
## 【为什么一律用 preload 而不是 class_name】本仓的坑 #26：headless 下**新全局类不在 `.godot`
## 全局类缓存里**（本轮已核实：ShapeBoolean/ShapeDag/RepairSuggest/ShareCode 四个名字都不在
## `global_script_class_cache.cfg` 中），按类名引用会让整份脚本解析失败 ⇒ 与 BINDINGS/TEMPLATES 同法。
const SHAPE_BOOLEAN := preload("res://core/shape_boolean.gd")
const SHAPE_DAG := preload("res://core/shape_dag.gd")
const REPAIR_SUGGEST := preload("res://core/repair_suggest.gd")
const SHARE_CODE := preload("res://core/share_code.gd")
## 复合格（MegaCell）：合并/拆分/邻接门禁/**下钻**全在 core（已单测），本轮只补 UI 入口。
## 同上面四个模块：**用 preload 引用、不按 class_name 引用**（坑 #26）。
## 【下钻状态是导航、不是关卡内容】它只由 UI 持有，绝不写进 `doc.to_level_json()`。
const MEGA_CELL := preload("res://core/mega_cell.gd")
## 【2026-10-09 接线】文档 §3/§5/§9/§8 的几个 core 能力（文字转形状 / 四象染色预览 / 行容量 /
## 骨牌划分 / 直方图 / 配色锁定 / 认证提交队列 / 重栅格化保留手工格）。同上面几组：**一律 preload**
## 引用、不按 class_name 引用（坑 #26：headless 下新全局类不在 `.godot` 缓存里）。
const GLYPH_FONT := preload("res://core/glyph_font.gd")
const COLORING := preload("res://core/coloring_preview.gd")
const SUBMISSION_QUEUE := preload("res://core/submission_queue.gd")
const REFLOW := preload("res://core/shape_reflow.gd")
const HISTOGRAM := preload("res://core/stats_histogram.gd")
const DISCLOSURE := preload("res://core/editor_disclosure.gd")
## 骨牌划分（`DominoModel`）：与 `MegaCell` 同为「关卡内容」，但**不复用 class_name**（同坑 #26）。
const DOMINO_MODEL := preload("res://core/domino_model.gd")
## 手绘轮廓 / 文字 → 格集（多边形栅格化在 core，UI 只转发；同 DOMINO_MODEL 理由不按 class_name 引用）。
const TTS := preload("res://core/text_to_shape.gd")


## 存档占用锁（功能清单 §8「防事故」前半）：**跨会话互斥** —— 同一份存档不允许两个编辑窗口同时写。
## 同 `DOMINO_MODEL` 的理由：不按 `class_name` 引用（headless 下全局类可能还没注册，见本仓坑 #26）。
const LOCK := preload("res://core/file_lock.gd")
## 缩略图（功能清单 §8「防事故」后半）：结果层 → 小尺寸索引网格（纯数据，headless 可测）。
const THUMB := preload("res://core/level_thumbnail.gd")
## 缩略图的「显示器」：`_draw()` 涂色块，不建节点、不参与玩法判定。
const THUMB_VIEW := preload("res://ui/level_thumb_view.gd")

const EDITOR_DIR := "user://editor"
## 图标工厂：本仓约定是**逐文件 preload**（`ui_icons.gd` 刻意没有 class_name，见其文件头注释）
const Icons := preload("res://ui/ui_icons.gd")
const AUTOSAVE_PATH := "user://editor/_autosave.json"
const PLAY_PATH := "user://editor/_play.json"
## 试玩回程（2026-10-02）：点「试玩」时把它写进 `GameSession.playtest_return`，
## 游戏 HUD / 结算层据此多显示「回编辑器」按钮（正式游戏里该标记为空 ⇒ 玩家看不到"编辑器"字样）。
const PLAYTEST_RETURN := "res://ui/level_editor.tscn"
## 【W1】清单·一：撤销深度**至少 200 步**。diff 化之后这一步很便宜（≈12B/格），
## 但"快照型"记录（结构改动/随机布雷这类批量动作）仍然贵（5000 格 ≈2MB）⇒ 它另有上限
##（`UNDO_SNAP_LIMIT`）：200 张快照 ≈ 400MB，40 张 ≈ 80MB，这是清单里点名的内存爆炸 D。
const UNDO_LIMIT := 200
const UNDO_SNAP_LIMIT := 40
const STROKE_COALESCE_MS := 700
## 自动保存空闲去抖（毫秒）。**这是"原频率"基准**：降级后实际间隔 = 本值 ÷ `_perf.rate_of("autosave")`
##（见 `_process`；`PerfLedger.DELAYED_AUTOSAVE_RATE = 0.25` ⇒ 1200/0.25 = 4800ms，即"延后自动保存"）。
const AUTOSAVE_IDLE_MS := 1200
## 【待真机标定】重活耗时预算（毫秒）：`PerfLedger.tick_measured()` 用它把"已上报的实测耗时合计"
## 判成达标 / 超载。依据：本仓**没有**真机帧时间实测值可引，`core/perf_ledger.gd` 头部也只写
## "帧预算要真机标定"、其 `RESTORE_MARGIN` 同为启发式常量；故取仓内**唯一有出处**的耗时预算 ——
## `EditorVerify.DEFAULT_TOTAL_BUDGET_MS`（8s，core/editor_verify.gd:36 注释的"总墙钟预算"）：
## 四件重活的实测耗时合计不该超过验证器自己的总预算。**这是起点占位、不是实测帧预算**，待真机 profile 后替换。
const PERF_FRAME_BUDGET_MS := EditorVerify.DEFAULT_TOTAL_BUDGET_MS
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
## 输入侧总量闸门（清单·数据爆炸 I）。**用 preload 而不是 class_name**：本文件顶部注释与
## `ui/tutorial_overlay.gd:12` 都记着同一个坑（坑表 #26）——headless 下**新全局类不在 .godot 缓存里**，
## 一旦别的脚本按类名引用它，整份脚本解析失败（我 2026-10-03 当场踩了一次）。
const LevelGuardRef := preload("res://core/level_guard.gd")


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
	"复制短码": "把这一关压成一行短码并复制到剪贴板（贴聊天就能发）。只服务小关卡；含自定义形状或盘太大时会说明原因，请改用「生成分享包」。",
	"载入短码": "把上面框里（或剪贴板里）的短码读成一关。读不出来会说清是哪里不对（字符非法 / 被改过 / 版本不支持…）。",
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
# ---- 形状组合（ShapeBoolean / ShapeDag 接线，2026-10-03）----
## 形状依赖图实例（core/shape_dag.gd）。**不写类型注解**（同 `_perf` 的写法）：本仓不用
## class_name 引用这些新模块（坑 #26），无注解的 Variant 才能直接调它的方法。
var _dag = SHAPE_DAG.new()
var _dag_shape_opt: OptionButton          # 加进依赖图的形状（圆 / 星 / 扇）
var _dag_shape_size: SpinBox
var _dag_a_opt: OptionButton              # 操作数 A（布尔左值 / 依赖的父）
var _dag_b_opt: OptionButton              # 操作数 B（布尔右值 / 依赖的子）
var _dag_note: Label                      # 常驻结果/拒绝原因（失败必须有可读文案，不许只弹 toast）
var _dag_shape_made := 0                  # 已生成形状节点的序号（s1、s2…）
var _dag_bool_made := 0                   # 已生成布尔节点的序号（b1、b2…）
# ---- 修复建议（RepairSuggest 接线）----
var _repair_btn: Button
var _repair_msg: Label
var _repair_box: VBoxContainer
## 当前展示的建议 plan（按行索引取）。列表一刷新就清空 ⇒ 过期条目不会拿旧 plan 硬应用。
var _repair_plans: Array = []
# ---- 短码分享（ShareCode 接线）----
var _share_edit: LineEdit
var _share_note: Label
var _self_check: CheckBox
var _preset_opt: OptionButton
var _dirs_edit: LineEdit
var _rule_id_edit: LineEdit
var _spec_edit: TextEdit
var _rule_report: Label
var _verify_state: Label
var _verify_issues: VBoxContainer
var _issues_box: VBoxContainer
# ---- 复合格下钻（MegaCell 接线，2026-10-04）----
## 下钻状态是**纯数据**（`MegaCell.drill_state()` 口径：`{version, path}`）。UI 只持有它。
## 判据一律问 core（`is_inside` / `drill_path`），本文件不自造"我现在在第几层"的算法。
var _mega_drill: Dictionary = MEGA_CELL.drill_state()
## 试玩视图切换时暂存的下钻状态（`drill_to_dict` 产物）——见 `_enter_playtest` / `_exit_playtest`。
var _mega_drill_saved: Dictionary = {}
var _mega_opt: OptionButton
var _mega_state_label: Label
var _mega_note: Label
var _open_opt: OptionButton
# ---- 【2026-10-09 接线】文档 §3/§5/§8/§9 的余项（全部只转发到 core，UI 不自造判据）----
## 四象染色预览开关（显示组）：数据走 `ColoringPreview.quadrant_preview`，颜色走它的色表。
var _quad_btn: Button
var _quad_note: Label
## 行容量侧栏：每行目标雷数 + 可行性预检（`ColoringPreview.row_report`）。
var _row_target_spin: SpinBox
var _row_capacity_label: Label
## 文字转形状（`GlyphFont.text_cells_fit` → `TextToShape`）：放不下会自动降档并**必须说出来**。
var _text_shape_edit: LineEdit
var _text_shape_px: SpinBox
var _text_shape_note: Label
## 骨牌划分（`DominoModel.partition` / `verify_partition`）：结论常驻，失败给逐格坐标。
var _domino_note: Label
## 统计面板（`StatsHistogram`）：雷密度 + 数字分布直方图。
var _stats_note: Label
## 配色锁定（`EditorDisclosure.lock_report`）：同色变体点名的常驻结论。
var _color_lock_note: Label
## 认证提交（`SubmissionQueue`）：本地队列，文案不假装联网。
var _submit_note_edit: LineEdit
var _submit_note: Label
## 简单 / 专家渐进披露（`EditorDisclosure.visible_controls`）。
var _mode_btn: Button
var _expert_mode := true
## 用户**手工改过**的格（画笔/橡皮/粘贴/矩形填充…都经 `canvas.cell_edited`）：
## 换形状重栅格化时，它是「手工格负载」的唯一来源（`ShapeReflow.reflow` 第 4 个参数）。
var _variant_id_edit: LineEdit     # 配色锁定：变体 id
var _variant_color_edit: LineEdit  # 配色锁定：色码（RED / #ff8800…）
var _hand_edited: Dictionary = {}
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

# ---- 存档占用锁 + 缩略图（文档 §8「防事故」）----
## 本会话的锁所有者标识（**每次运行唯一**：同一台机器开两个窗口必须能互相区分）。
var _lock_owner := ""
## 当前**持锁目录**（"" = 没持锁）。锁的是「每份存档自己的隐藏子目录」，不是存档目录——
## 存档平铺在 user://editor，直接锁那个目录会让「编辑别的关」的另一个窗口也撞锁（误伤）。
var _locked_dir := ""
## 只读打开（打开时发现别人正开着）：能看 / 能试玩，但不许覆盖；要留改动只能改标题另存。
var _read_only := false
var _read_only_path := ""
## 缩略图预览控件与说明文字（节点在「存档与分享」段建，见 _build_* 里的 THUMB_VIEW）。
## 控件**不加类型标注**（同 _replay_model 的理由）：它的 set_thumb/thumb_hash 是本仓自定义方法，
## 声明成 Control 再调自定义方法会被 GDScript 静态检查判成编译失败。
var _thumb_view = null
var _thumb_note: Label
var _tool_group := ButtonGroup.new()
var _kind_group := ButtonGroup.new()

# ---- 快捷键体系 + 显示开关（文档「二」「七」）----
## 键位绑定表：唯一真源，独立段 `[editor_keys]`，可读回、可缺省回退。
var _bindings := BINDINGS.new()
## 编辑/试玩两态的统一状态机（禁止各处自己判断"要不要显示作弊信息"）。
var _view_state := VIEW_STATE.new()
var _grid_btn: Button
var _cheat_btn: Button
var _sym_btn: Button
## 对称模式：0=关 1=竖轴 2=横轴 3=四象（Ctrl+G 循环）。
var _sym_mode := 0
## 内嵌试玩层（Tab 秒切用）：非空 = 正在"试玩态"。点「试玩」按钮仍走整场景切换。
var _play_overlay: CanvasLayer = null
## 工具/格型按钮（快捷键改状态后要同步它们的高亮，否则界面在骗人）。
var _tool_btns: Array = []
var _kind_btns: Array = []
## 验证页的星级行（1~5 星；旧三档文案保留在 `_verify_state` 里）。
var _verify_stars: Label

# ---- 猜点热力图（HotMap 接线）：开关 + 一行可读说明（理由/错误都显示出来，不静默） ----
## 画布叠加层的层名：热力图的数据与显隐都挂在画布这一个名字上（正式 API 见 `editor_canvas.set_overlay`）。
const HOTMAP_OVERLAY := "hotmap"
var _hotmap_btn: Button
var _hotmap_note: Label
var _hotmap_on := false
## 求解器（`HotMap.build`）实际跑过几次。**可观察字段**，供单测断言"恢复可见时不重跑"
##（与画布 `_static_cache_builds` 同一套路：状态可观察、不靠像素/耗时猜）。
var _hotmap_builds := 0

# ---- 全局性能记账（PerfLedger 接线）：每编辑器一个实例（纯 RefCounted，不依赖场景树）----
## 上报实测耗时 + 按文档钦定的统一降级顺序降档 / 回爬；状态机全在 core/perf_ledger.gd，本文件只接线。
var _perf = PERF_LEDGER.new()

# ---- 模板库入口（TemplateLibrary 接线）：左栏「从模板开始」下拉 + 用这个模板 ----
var _template_opt: OptionButton
var _template_note: Label

# ---- 推理链回放（ReplayModel 接线）：虚拟化列表 + 截断 banner ----
## 不加类型标注（也不写 `ReplayModel`）：headless 下新全局类不在 `.godot` 缓存里，
## 按类名写会让整份脚本解析失败（坑表 #26）⇒ 走 `REPLAY.new()` + 动态调用。
var _replay_model = null
var _replay_btn: Button
var _replay_scroll: ScrollContainer
var _replay_rows: Control
var _replay_banner: Label
var _replay_note: Label
## 行高用 var 而非 const：测试要通过 `ed.get()` 读它（Object 取不到脚本常量）。
var _replay_row_h := 22.0


func _ready() -> void:
	add_to_group("themed")
	name = "LevelEditor"
	_bindings.load_cfg()          # 先读键位：左栏 tooltip 要显示当前键名
	ThemeManager.theme_changed.connect(_on_theme_changed)
	ThemeManager.theme_settled.connect(_on_theme_settled)
	_build_ui()
	## 建完左栏立刻应用一次披露档位：`_mode_btn` 的文案与真实可见性必须开局就一致（默认专家档 ⇒ 全部可见）。
	_apply_disclosure()
	doc = EditorDoc.new(9, 9)
	_doc_to_ui()
	_load_autosave_if_any()
	_refresh_all()
	# 画布此时才存在（`_build_left_bar` 比它早）⇒ 统一状态机的"显雷"这一侧在这里再应用一次。
	_apply_cheat_visibility()


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	# 【PerfLedger 接线 ④】每帧用"上报的实测耗时预算"驱动统一降级状态机（预算见 PERF_FRAME_BUDGET_MS）。
	# 返回**本次实际执行**的降级 / 回爬动作（受进入/退出/最小保持三重滞后约束，最多一档）；
	# 有变档才去把这些动作落到界面上（本文件只影响热力图显隐，其余是"读参数"式接线）。
	var perf_acts: Array = _perf.tick_measured(now, PERF_FRAME_BUDGET_MS)
	if not perf_acts.is_empty():
		_apply_perf_actions(perf_acts)
	if _full_preview_due != 0 and now >= _full_preview_due:
		_full_preview_due = 0
		_refresh_preview()
		_refresh_errors()
	if _checks_due != 0 and now >= _checks_due:
		_checks_due = 0
		_refresh_errors()
	if not _dirty:
		return
	# 【PerfLedger 接线 ③】自动保存空闲间隔按 `rate_of("autosave")` 缩放（见 `_autosave_idle_ms`）。
	if now - _last_change_ms < _autosave_idle_ms():
		return
	_write_autosave()


## 当前自动保存空闲间隔（毫秒）= `AUTOSAVE_IDLE_MS ÷ rate_of("autosave")`。
## 1.0 = 原 1200ms；降到 DELAYED_AUTOSAVE_RATE(0.25) ⇒ 1200/0.25 = 4800ms（延后落盘，内存里的文档不丢）。
func _autosave_idle_ms() -> int:
	return int(AUTOSAVE_IDLE_MS / maxf(0.01, _perf.rate_of(PERF_LEDGER.JOB_AUTOSAVE)))


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
	# 油漆桶结果：截断时必须说清"仅染了前 N 格"（否则用户以为整片都染了）
	canvas.bucket_reported.connect(_on_bucket_reported)
	# 手绘轮廓（文档 §3）：画布交出连续点列，这里转成格集写回盘型。
	canvas.outline_drawn.connect(_on_outline_drawn)
	body.add_child(canvas)
	# 热力图不再挂"运行期子节点"：改由画布的正式叠加层 API 承载（`canvas.set_overlay("hotmap", …)`）。
	# 缩放/平移/改盘后的重画由画布自己 `queue_redraw()` 负责 ⇒ 本文件不必再接 `draw/resized`。
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
	# 【模板库接线】新手"照着做就能出一关"的最快入口（文档「九」+「十.6：模板库是主要入门路径」）。
	# 放在工具清单**之前**：第一次打开的人先看到"可以不用从零画"，而不是"一堆工具"。
	_build_template_entry(box)
	box.add_child(_section_label("工具"))
	# 每个工具都要能自己讲清"这是什么、拿来干什么"——用户实测问过"区域选择有什么用吗"，
	# 而它（配合下面的「复制选区 / 粘贴到选区」整块复制格型）在界面上原本一个字都没解释。
	for t in [[EditorCanvas.Tool.PAINT, "画笔", "在格子上涂当前选的格型（按住拖动可连画）", "B / ①"],
			[EditorCanvas.Tool.ERASE, "橡皮", "把格子擦回「空」", "E / ②"],
			[EditorCanvas.Tool.RECT_FILL, "矩形填充", "拖一个方框，整块刷成当前格型（批量摆障碍/已翻开）", "③"],
			[EditorCanvas.Tool.SELECT, "区域选择",
				"先框选一片区域，再用下面的「复制选区 / 粘贴到选区」整块复制格型——例如把一块障碍图案搬到别处", "L / ④"],
			[EditorCanvas.Tool.PAN, "平移（或按住中键）", "拖动整张棋盘看（棋盘很大时用）；也可以直接按住鼠标中键拖",
				"P / ⑤；或按住空格临时平移"],
			# 文档 §3「手绘轮廓」：凭空画一个闭合轮廓，松手即刻成棋盘形状。
			# 参数化形状（方/六边形/三角/圆/星/扇）覆盖不了"我就想要这么个歪形状"。
			[EditorCanvas.Tool.OUTLINE, "手绘轮廓",
				"按住鼠标画一个**闭合轮廓**，松手后整块刻成棋盘形状（撤销 Ctrl+Z；画歪了再画一次即可）",
				"无"]]:
		var tool_btn := _toggle_button(str(t[1]), _tool_group, func() -> void:
			canvas.tool = int(t[0]))
		tool_btn.tooltip_text = "%s（快捷键：%s）" % [str(t[2]), str(t[3])]
		# 按钮下标**不能**当工具号用（见 `_set_tool`）：工具 id 记在 meta 上，加工具不会错位。
		tool_btn.set_meta("tool_id", int(t[0]))
		_tool_btns.append(tool_btn)
		box.add_child(tool_btn)

	# 文档语义落到 tooltip：M=放雷、S=强制安全格（= 初始已翻开）；⑧⑨ 是最常用两型的数字快选。
	box.add_child(_section_label("格型（画笔画什么）"))
	for k in [[EditorCanvas.KIND_MINE, "地雷", "画笔画上去 = 放雷（M / ⑧）"],
			[EditorCanvas.KIND_OBSTACLE, "障碍", "画笔画上去 = 洞 / 格不存在（⑨）"],
			[EditorCanvas.KIND_REVEAL, "初始已翻开", "强制安全格：保证不是雷、开局就翻开（S）"],
			[EditorCanvas.KIND_CLEAR, "清空该格", "把该格擦回空（橡皮同效）"]]:
		var kind_btn := _toggle_button(str(k[1]), _kind_group, func() -> void:
			canvas.paint_kind = str(k[0]))
		kind_btn.tooltip_text = str(k[2])
		_kind_btns.append(kind_btn)
		box.add_child(kind_btn)

	# 显示开关（文档「一/七」）：网格线（G）、显雷（仅编辑态，H）、对称（Ctrl+G 循环）。
	# 三个都是"看一眼就知道现在开没开"的开关（toggle 按钮 + 文案带状态）。
	box.add_child(_section_label("显示"))
	_grid_btn = _action_button("网格线", _toggle_grid)
	_grid_btn.toggle_mode = true
	_grid_btn.button_pressed = true                 # 与画布 `show_grid` 的默认值一致
	_grid_btn.tooltip_text = _bindings.hint("grid_toggle")
	box.add_child(_grid_btn)
	_cheat_btn = _action_button("显示雷/线索（编辑态）", _toggle_cheats)
	_cheat_btn.toggle_mode = true
	_cheat_btn.tooltip_text = _bindings.hint("cheat_toggle")
	box.add_child(_cheat_btn)
	# 猜点热力图（差异化功能）：打开时把 HotMap.build(doc) 的结果涂到棋盘上
	# （红 = 必须猜的格，越深 = 越晚推出）；与"显雷"同一套试玩态强制隐藏判据。
	# 放在「显示」分组：它是**叠加显示**，和网格线/显雷/对称是一类东西。
	_hotmap_btn = _action_button("猜点热力图：关", _toggle_hotmap)
	_hotmap_btn.toggle_mode = true
	_hotmap_btn.tooltip_text = "把棋盘涂成推理热力图：红=必须猜的格，颜色越深=越晚才推出来；试玩态自动隐藏"
	box.add_child(_hotmap_btn)
	_hotmap_note = _plain_label("")
	_hotmap_note.visible = false
	box.add_child(_hotmap_note)
	_sym_btn = _action_button("对称：关", _cycle_symmetry)
	_sym_btn.tooltip_text = _bindings.hint("symmetry_cycle")
	box.add_child(_sym_btn)
	box.add_child(_plain_label("对称开启后，画笔/橡皮画的格子会同时镜像到对称位置（矩形填充/直线/油漆桶不改动）。"))
	# 四象染色预览（文档 §5）：色号逐格复用 `ConstraintEngine.quadrant_of`（core 单一事实来源），
	# 四象限 + 中轴各一色；网格族上四象语义未定义时由「变体×网格矩阵」门禁拒绝并给可读理由。
	_quad_btn = _action_button("四象染色预览：关", _toggle_quadrant_preview)
	_quad_btn.toggle_mode = true
	_quad_btn.tooltip_text = "把棋盘按四象（左上/右上/左下/右下 + 中轴）染色，用来检查对称与染色分区；试玩态自动隐藏"
	box.add_child(_quad_btn)
	_quad_note = _plain_label("")
	_quad_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quad_note.visible = false
	box.add_child(_quad_note)
	# 简单 / 专家渐进披露（文档「九」「十.6」）：新手只看到做一关的必经路径，高级概念渐进披露。
	# 判据全在 `EditorDisclosure.visible_controls`（未知 id 默认可见 ⇒ 加新控件不会被误藏）。
	_mode_btn = _action_button("模式：专家（全部功能可见）", _toggle_editor_mode)
	_mode_btn.tooltip_text = "切到专家模式才显示：显示雷 / 猜点热力图 / 规则原文 / 批量生成 / 异形拼装等进阶功能"
	box.add_child(_mode_btn)
	_apply_cheat_visibility()

	box.add_child(_section_label("布雷"))
	var row := HBoxContainer.new()
	row.add_child(_plain_label("雷数"))
	_mines_spin = _spin(1, 4096, 1)
	_mines_spin.value_changed.connect(func(_v: float) -> void: _on_mines_changed())
	row.add_child(_mines_spin)
	box.add_child(row)
	var rand_btn := _action_button("随机布雷（按上面的雷数）", _random_mines)
	rand_btn.tooltip_text = "%s；Ctrl+N 同效" % _bindings.hint("random_mines")
	box.add_child(rand_btn)
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

	# ---- 缩略图预览（文档 §8）----
	# 存档列表只有文件名，同名 / 相似名的关卡分不出来 ⇒ 给当前关卡一张小图。
	# 用 `_draw()` 涂色块（不建 1024 个 ColorRect），所以控件的 custom_minimum_size 就是它的大小。
	box.add_child(_section_label("缩略图预览（当前关卡）"))
	_thumb_view = THUMB_VIEW.new()
	_thumb_view.custom_minimum_size = Vector2(0, 96)
	box.add_child(_thumb_view)
	_thumb_note = _plain_label("（还没有内容：布好雷就会显示小图）")
	_thumb_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_thumb_note)
	var pack_btn := _action_button("生成分享包", _make_pack)
	# 悬停说明补上"上传哪个文件"：实测小白看到"请手动上传"时不知道要传什么、在哪找。
	pack_btn.tooltip_text = "生成一份 zip 分享包（文件在左栏「打开存档文件夹」里）；本机没接 Steamworks 时要自己上传"
	box.add_child(pack_btn)
	# ---- 短码分享（ShareCode 接线）----
	# 分享包要传文件；小关卡其实一行字就够了（贴聊天/扫码）。含自定义形状或大棋盘时走不了短码，
	# 这时**必须给出可读原因**并让人改用「生成分享包」，不许静默失败。
	box.add_child(_section_label("短码分享（小关卡：贴一行字就能玩）"))
	_share_edit = LineEdit.new()
	_share_edit.custom_minimum_size = Vector2(0, 30)
	_share_edit.placeholder_text = "短码会显示在这里；也可以把别人给的短码粘进来"
	box.add_child(_share_edit)
	var share_row := HBoxContainer.new()
	share_row.add_theme_constant_override("separation", 6)
	var share_out := _action_button("复制短码", _export_share_code)
	share_out.tooltip_text = "把这一关压成一行短码并复制（只服务小关卡；含自定义形状/大棋盘时会说明为什么不行，改用「生成分享包」）"
	share_row.add_child(share_out)
	var share_in := _action_button("载入短码", _import_share_code)
	share_in.tooltip_text = "把上面框里的短码（或剪贴板里的）读成一关；读不出会告诉你具体原因"
	share_row.add_child(share_in)
	box.add_child(share_row)
	_share_note = _plain_label("")
	box.add_child(_share_note)
	# ---- 认证提交（文档 §8 最后一条）：本地队列 + 流转状态（**不假装联网**，文案写「本地审核队列」）----
	box.add_child(_section_label("认证提交（送进审核队列）"))
	box.add_child(_plain_label("把关卡送进审核队列，并看它走到哪一步：已入队 → 审核中 → 已通过 / 已退回。\n"
		+ "（本机队列：没连官方服务时不假装已上传，只记「已加入本地审核队列」。）"))
	_submit_note_edit = LineEdit.new()
	_submit_note_edit.custom_minimum_size = Vector2(0, 30)
	_submit_note_edit.placeholder_text = "给审核者的一句话（可留空）"
	box.add_child(_submit_note_edit)
	var sub_row := HBoxContainer.new()
	sub_row.add_theme_constant_override("separation", 6)
	sub_row.add_child(_action_button("加入审核队列", _submit_to_queue))
	sub_row.add_child(_action_button("刷新队列状态", _refresh_submission))
	box.add_child(sub_row)
	_submit_note = _plain_label("")
	_submit_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_submit_note)
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
		+ "拖动 = 连续画 ｜滚轮 = 缩放 ｜中键拖 = 平移\n"
		+ "快捷键：M 放雷 ｜ S 强制安全格 ｜ B 画笔 ｜ E 橡皮 ｜ G 网格 ｜ Ctrl+G 对称\n"
		+ "选区：R 旋转 90° ｜ Ctrl+R 镜像 ｜ Ctrl+C/V 复制/粘贴 ｜ Ctrl+Z 撤销 ｜ Ctrl+Y 重做 ｜ Ctrl+S 保存"))
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


# ==================== 模板库（TemplateLibrary 接线） ====================
#
# 分工：模板数据 / 概念可见性 / `apply_to_doc` 全在 `core/template_library.gd`（纯数据 + 纯查询，
# 已单测）；本文件只做三件事 —— ① 一个下拉 + 一个按钮；② 应用前过**既有**预算闸门
#（`_budget_allows`，与改尺寸 / 换形状同一道，绝不绕过）；③ 失败给**可读提示**（toast + 常驻说明行）。

## 左栏「从模板开始」入口：下拉（官方示例 + 新手教程）+ 「用这个模板」+ 一行说明。
func _build_template_entry(box: VBoxContainer) -> void:
	box.add_child(_section_label("从模板开始（新手照做就有一关）"))
	box.add_child(_plain_label("先挑一个现成模板铺好棋盘，再改雷位/规则；应用后可按 Ctrl+Z 撤销。"))
	_template_opt = OptionButton.new()
	# 与配方/布局规则下拉同因：长文案不许把左栏/棋盘撑宽。
	_template_opt.fit_to_longest_item = false
	_template_opt.clip_text = true
	_template_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ts := TEMPLATES.all_templates()
	for i in ts.size():
		var t: Dictionary = ts[i]
		_template_opt.add_item(str(t["name"]), i)
		_template_opt.set_item_metadata(i, str(t["id"]))
	_template_opt.item_selected.connect(func(_i: int) -> void: _refresh_template_note())
	box.add_child(_template_opt)
	_template_note = _plain_label("")
	_template_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_template_note)
	var use_btn := _action_button("用这个模板（铺好棋盘）", _apply_selected_template)
	use_btn.tooltip_text = "把选中的模板铺成当前关卡（先过格数预算闸门）；应用后可 Ctrl+Z 撤销"
	box.add_child(use_btn)
	_refresh_template_note()


## 下拉选中项的描述（常驻说明行；也是"应用失败"的提示落点）。
func _refresh_template_note() -> void:
	if _template_opt == null or _template_note == null:
		return
	var idx := _template_opt.selected
	if idx < 0:
		return
	var t := TEMPLATES.find_template(str(_template_opt.get_item_metadata(idx)))
	if t.is_empty():
		_template_note.text = "未知模板（列表可能已变，请重开）。"
		return
	_template_note.text = "%s：%s" % [str(t["name"]), str(t["desc"])]


func _set_template_note(text: String) -> void:
	if _template_note != null:
		_template_note.text = text


## 点「用这个模板」：按 id 取模板 → 套用（未知 id 也给可读原因，不静默）。
func _apply_selected_template() -> void:
	if _template_opt == null:
		return
	var idx := _template_opt.selected
	if idx < 0:
		_set_template_note("还没选模板。")
		return
	var tid := str(_template_opt.get_item_metadata(idx))
	var r := TEMPLATES.apply(tid)
	if not bool(r["ok"]):
		_set_template_note(str(r["reason"]))
		_toast(str(r["reason"]), true, 6.0)
		return
	_apply_template_build(r["doc_build"], _template_opt.get_item_text(idx))


## 把一份 `doc_build` 铺进当前文档。**应用前必过 `_budget_allows`**（超限时它自己弹可读提示）。
## 返回是否真的应用（给测试钉住"超预算被拦"这条）。
func _apply_template_build(doc_build: Dictionary, template_name: String) -> bool:
	if doc == null or doc_build.is_empty():
		_set_template_note("模板内容为空，没有改动文档。")
		return false
	var kind := str(doc_build.get("shape_kind", ""))
	var raw_params: Variant = doc_build.get("shape_params", {})
	var params: Dictionary = raw_params if raw_params is Dictionary else {}
	var est_rows := int(doc_build.get("rows", doc.rows))
	var est_cols := int(doc_build.get("cols", doc.cols))
	# ① 既有预算闸门（改尺寸 / 换形状同一道）。被拦时 `_budget_allows` 已经弹过可读提示，这里补常驻说明。
	if not _budget_allows(kind, params, est_rows, est_cols):
		_set_template_note("模板「%s」超出格数预算，未应用（原因见上方提示；可改用更小的模板）。"
			% template_name)
		return false
	# ② 整份文档替换 ⇒ 记一步快照型撤销（与导入文本 / 清空全部同口径）。
	_push_undo(false)
	TEMPLATES.apply_to_doc(doc, doc_build)
	_sync_declared_total()      # 模板自带实际雷位 ⇒ 声明雷数交回"按实际导出"（-1）
	_current_path = ""          # 这是"新东西" ⇒ 别让下次保存覆盖掉原来那份文件
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()
	_set_template_note("已应用模板「%s」：%d×%d、%d 颗雷（可 Ctrl+Z 撤销）。" % [
		template_name, doc.rows, doc.cols, doc.mine_count()])
	_toast("已套用模板「%s」：可以直接试玩；想重来按 Ctrl+Z" % template_name, false, 4.5)
	return true


# ==================== 形状组合（ShapeBoolean + ShapeDag 接线） ====================
#
# 分工：格集布尔全在 `core/shape_boolean.gd`（并/交/差/异或 + 盘内过滤），依赖图全在
# `core/shape_dag.gd`（加边即成环拒绝、拓扑序、求值计划）。本文件只做三件事：
#   ① 给出"选哪两块形状"的界面；② 把结果按 `ShapeBoolean.apply_to_grid` 的口径写回 `doc`
#   （盘上只保留结果里的格，其余记为障碍 = 格不存在）；③ 失败一律给**常驻可读文案** + toast。

## 形状组合区（属性页「形状」之后）。
func _build_shape_compose(box: VBoxContainer) -> void:
	box.add_child(_section_label("形状组合（并 / 交 / 差 / 异或 · 依赖图）"))
	box.add_child(_plain_label("把两块形状合成一块新盘型。A / B 可以是「整盘 / 框选区域 / 初始翻开格」，"
		+ "也可以是下面依赖图里加的形状。\n"
		+ "「差集」有方向：A − B = 在 A 里但不在 B 里。合成结果会**写回棋盘**"
		+ "（盘上只保留结果里的格，其余格记为「不存在」；写回只算一步，按左栏「撤销」可退回）。"))
	_dag_a_opt = _operand_option()
	_dag_b_opt = _operand_option()
	var arow := HBoxContainer.new()
	arow.add_theme_constant_override("separation", 6)
	arow.add_child(_plain_label("A"))
	arow.add_child(_dag_a_opt)
	box.add_child(arow)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 6)
	brow.add_child(_plain_label("B"))
	brow.add_child(_dag_b_opt)
	box.add_child(brow)
	var ops := GridContainer.new()
	ops.columns = 2
	ops.add_theme_constant_override("h_separation", 6)
	ops.add_theme_constant_override("v_separation", 4)
	for o in [["并集 A ∪ B", SHAPE_BOOLEAN.OP_UNION], ["交集 A ∩ B", SHAPE_BOOLEAN.OP_INTERSECT],
			["差集 A − B", SHAPE_BOOLEAN.OP_DIFFERENCE], ["异或 A ⊕ B", SHAPE_BOOLEAN.OP_XOR]]:
		var op_btn := _action_button(str(o[0]), func() -> void: _compose_boolean(str(o[1])))
		op_btn.tooltip_text = "把 A、B 按「%s」合成，结果写回棋盘（一步撤销）" % str(o[0])
		ops.add_child(op_btn)
	box.add_child(ops)
	# 依赖图：形状可以互相依赖（"B 由 A 算出来"）；成环当场拒绝并给出环路径。
	box.add_child(_plain_label("下面这块表达「一个形状由哪些形状算出来」：先「加形状」，"
		+ "再选 A / B 点「加依赖」，得到「A → B（B 依赖 A）」的链。"
		+ "若加边会形成循环，会**当场拒绝并给出环路径**。"))
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 6)
	_dag_shape_opt = OptionButton.new()
	_dag_shape_opt.clip_text = true
	_dag_shape_opt.fit_to_longest_item = false
	_dag_shape_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for e in [["圆形", "circle"], ["星形（五角）", "star"], ["扇形（90°）", "sector"],
			["正 N 边形（5 边）", "ngon"], ["圆环（外径 = 尺寸，内径 = 一半）", "ring"]]:
		_dag_shape_opt.add_item(str(e[0]), _dag_shape_opt.item_count)
		_dag_shape_opt.set_item_metadata(_dag_shape_opt.item_count - 1, str(e[1]))
	srow.add_child(_dag_shape_opt)
	_dag_shape_size = _spin(2, 40, 1)
	_dag_shape_size.value = 4
	srow.add_child(_dag_shape_size)
	box.add_child(srow)
	box.add_child(_action_button("加形状（按上面的形状与尺寸）", _on_dag_add_shape))
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	drow.add_child(_action_button("加依赖 A → B", _on_dag_add_edge))
	drow.add_child(_action_button("检查有没有环", _on_dag_check_cycle))
	box.add_child(drow)
	box.add_child(_action_button("把 A 求值并写回棋盘", _on_dag_eval))
	_dag_note = _plain_label("依赖图还是空的：先点「加形状」。")
	box.add_child(_dag_note)
	_refresh_dag_opts()


func _operand_option() -> OptionButton:
	var opt := OptionButton.new()
	opt.clip_text = true
	# 长文案不许把右面板撑宽（与 recipe / global 下拉同因：实测会把棋盘挤到一格只剩 29px）
	opt.fit_to_longest_item = false
	opt.custom_minimum_size = Vector2(120, 28)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return opt


## 刷新 A / B 下拉：三个内置集合 + 依赖图里的每个节点（保持原选中项，找不到就回到默认）。
func _refresh_dag_opts() -> void:
	if _dag_a_opt == null or _dag_b_opt == null:
		return
	var keep_a := _opt_key(_dag_a_opt)
	var keep_b := _opt_key(_dag_b_opt)
	for opt in [_dag_a_opt, _dag_b_opt]:
		opt.clear()
		for e in [["整盘形状（当前棋盘）", "__board__"], ["框选区域", "__selection__"],
				["初始翻开格", "__revealed__"]]:
			opt.add_item(str(e[0]), opt.item_count)
			opt.set_item_metadata(opt.item_count - 1, str(e[1]))
		for nid in _dag.node_ids():
			var n: Dictionary = _dag.node(str(nid))
			var idx: int = opt.item_count
			opt.add_item("%s（%s）" % [str(nid), _dag_shape_label(str(n["shape"]))], idx)
			opt.set_item_metadata(idx, str(nid))
	_select_opt_key(_dag_a_opt, keep_a)
	_select_opt_key(_dag_b_opt, keep_b)
	if _dag_a_opt.selected < 0:
		_dag_a_opt.selected = 0
	if _dag_b_opt.selected < 0:
		_dag_b_opt.selected = mini(1, _dag_b_opt.item_count - 1)


func _select_opt_key(opt: OptionButton, key: String) -> void:
	if opt == null or key == "":
		return
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == key:
			opt.selected = i
			return


## 当前选中的键（内置集合名或依赖图节点 id）；没选中 → ""。
func _opt_key(opt: OptionButton) -> String:
	if opt == null or opt.selected < 0 or opt.selected >= opt.item_count:
		return ""
	return str(opt.get_item_metadata(opt.selected))


func _operand_label(opt: OptionButton) -> String:
	if opt == null or opt.selected < 0 or opt.selected >= opt.item_count:
		return "?"
	return opt.get_item_text(opt.selected)


func _set_dag_note(text: String) -> void:
	if _dag_note != null:
		_dag_note.text = text


func _dag_shape_label(shape: String) -> String:
	if shape == "circle":
		return "圆"
	if shape == "star":
		return "星形"
	if shape == "sector":
		return "扇形"
	if shape == "ngon":
		return "正 N 边形"
	if shape == "ring":
		return "圆环"
	if shape == SHAPE_BOOLEAN.OP_UNION:
		return "并集"
	if shape == SHAPE_BOOLEAN.OP_INTERSECT:
		return "交集"
	if shape == SHAPE_BOOLEAN.OP_DIFFERENCE:
		return "差集"
	if shape == SHAPE_BOOLEAN.OP_XOR:
		return "异或"
	return shape


func _bool_label(op: String) -> String:
	return _dag_shape_label(op)


func _dag_params_for(shape: String, dim: int) -> Dictionary:
	if shape == "star":
		return {"points": 5, "outer_radius": dim, "inner_ratio": 0.5}
	if shape == "sector":
		return {"radius": dim, "start_deg": 0.0, "end_deg": 90.0}
	if shape == "ngon":
		return {"sides": 5, "radius": dim}
	if shape == "ring":
		# 本 DAG 的 ring = annulus（内圆挖空）；生成器要求 1 ≤ inner < outer
		return {"outer_radius": dim, "inner_radius": maxi(1, floori(dim / 2.0)), "precision": 24}
	return {"radius": dim, "precision": 24}


## 「加形状」：把当前下拉里的形状（圆 / 星 / 扇 / 正 N 边形 / 圆环）作为一个原子节点加进依赖图。
func _on_dag_add_shape() -> void:
	var shape := _opt_key(_dag_shape_opt)
	var dim := int(_dag_shape_size.value)
	_dag_shape_made += 1
	var id := "s%d" % _dag_shape_made
	var r: Dictionary = _dag.add_primitive(id, shape, _dag_params_for(shape, dim))
	if not bool(r["ok"]):
		_set_dag_note("加形状失败：%s" % str(r["error"]))
		_toast("加形状失败：%s" % str(r["error"]), true, 7.0)
		return
	_refresh_dag_opts()
	_select_opt_key(_dag_a_opt, id)
	_set_dag_note("已加形状 %s：%s（尺寸 %d）。接着可以「加形状」加第二个，或直接选 A / B 做布尔运算。"
		% [id, _dag_shape_label(shape), dim])


## 「加依赖 A → B」：B 依赖 A。成环 / 自依赖 / 重复边由 `ShapeDag.add_edge` 拒绝，**原因原样显示**。
func _on_dag_add_edge() -> void:
	var a := _opt_key(_dag_a_opt)
	var b := _opt_key(_dag_b_opt)
	if not _dag.has_node(a) or not _dag.has_node(b):
		_set_dag_note("「加依赖」只作用于依赖图里的形状：A / B 要选依赖图节点（先用「加形状」建两个）。")
		_toast("加依赖需要 A、B 都是依赖图里的形状", true, 6.0)
		return
	var r: Dictionary = _dag.add_edge(a, b)
	if not bool(r["ok"]):
		_set_dag_note("加依赖被拒：%s" % str(r["error"]))
		_toast("加依赖被拒：%s" % str(r["error"]), true, 8.0)
		return
	_set_dag_note("已加依赖 %s → %s（%s 依赖 %s）。拓扑序 = %s" % [a, b, b, a, str(_dag.topo_order())])


## 「检查有没有环」：无环给出拓扑序；有环给出环路径（依赖图在加边时已拒绝成环，这里主要给用户安心/诊断）。
func _on_dag_check_cycle() -> void:
	if _dag.node_count() == 0:
		_set_dag_note("依赖图还是空的：先点「加形状」。")
		return
	var cyc: Array = _dag.detect_cycle()
	if cyc.is_empty():
		_set_dag_note("检查过了：无环，可以求值。拓扑序 = %s" % str(_dag.topo_order()))
		return
	_set_dag_note("发现循环依赖：%s（有环就没有求值顺序）" % _cycle_text(cyc))


func _cycle_text(cycle: Array) -> String:
	var parts: Array[String] = []
	for id in cycle:
		parts.append(str(id))
	if parts.size() > 0:
		parts.append(parts[0])
	return " → ".join(parts)


## 「把 A 求值并写回棋盘」：解析 A（内置集合或依赖图节点，节点会按其依赖递归求值）。
func _on_dag_eval() -> void:
	var opt := _dag_a_opt
	var cells := _operand_cells(_opt_key(opt))
	if not bool(cells["ok"]):
		_set_dag_note("求值失败：%s" % str(cells["reason"]))
		_toast("求值失败：%s" % str(cells["reason"]), true, 7.0)
		return
	var w := _write_board_shape(cells["cells"], "形状「%s」" % _operand_label(opt))
	if not bool(w["ok"]):
		return
	if not bool(w["changed"]):
		_set_dag_note("形状「%s」的结果与当前盘面一致，没有需要写回的改动。" % _operand_label(opt))
		return
	_set_dag_note("已把形状「%s」写回棋盘：保留 %d 格，盘外丢弃 %d 格，另清掉 %d 颗落在盘外的雷。"
		% [_operand_label(opt), int(w["kept"]), int(w["dropped"]), int(w["removed_mines"])])
	_toast("已按形状「%s」重画盘面（一步撤销，按左栏「撤销」可退回）" % _operand_label(opt), false, 5.0)


## 布尔运算按钮的实现：解析 A、B → `ShapeBoolean` → 写回 doc（成功落地才登记进依赖图）。
func _compose_boolean(op: String) -> void:
	var ra := _operand_cells(_opt_key(_dag_a_opt))
	if not bool(ra["ok"]):
		_set_dag_note("A 端不能用：%s" % str(ra["reason"]))
		_toast("A 端不能用：%s" % str(ra["reason"]), true, 7.0)
		return
	var rb := _operand_cells(_opt_key(_dag_b_opt))
	if not bool(rb["ok"]):
		_set_dag_note("B 端不能用：%s" % str(rb["reason"]))
		_toast("B 端不能用：%s" % str(rb["reason"]), true, 7.0)
		return
	var r: Dictionary = _bool_op(op, ra["cells"], rb["cells"])
	if not bool(r["ok"]):
		_set_dag_note("「%s」失败：%s" % [_bool_label(op), str(r["reason"])])
		_toast("形状「%s」失败：%s" % [_bool_label(op), str(r["reason"])], true, 8.0)
		return
	var w := _write_board_shape(r["cells"], "「%s」的结果" % _bool_label(op))
	if not bool(w["ok"]):
		return                     # 写回被拒：**不登记**依赖图节点（免得图上多一个从未落地的结果）
	if not bool(w["changed"]):
		_set_dag_note("「%s」算出来了，但结果与当前盘面一致，没有需要写回的改动（也没有登记新节点）。"
			% _bool_label(op))
		return
	# 真的落地了才登记：这次运算成为依赖图里的一个节点（"结果由 A、B 算出来"），供后续复用/求值。
	var recorded := _record_boolean(op)
	var tail := "" if recorded == "" else "，并记进依赖图 %s" % recorded
	_set_dag_note("已按「%s」写回棋盘：保留 %d 格，盘外丢弃 %d 格，另清掉 %d 颗落在盘外的雷%s。"
		% [_bool_label(op), int(w["kept"]), int(w["dropped"]), int(w["removed_mines"]), tail])
	_toast("已按「%s」合成并写回棋盘（一步撤销，按左栏「撤销」可退回）" % _bool_label(op), false, 5.0)
	_refresh_dag_opts()            # 新登记的节点要出现在 A / B 下拉里


## 把这次布尔运算登记成依赖图里的一个节点（A、B 必须都是图里的形状才登记）。
## 返回新节点 id；不登记则返回 ""（内置集合做操作数时没有"形状节点"可记）。
func _record_boolean(op: String) -> String:
	var ka := _opt_key(_dag_a_opt)
	var kb := _opt_key(_dag_b_opt)
	if not _dag.has_node(ka) or not _dag.has_node(kb):
		return ""
	_dag_bool_made += 1
	var bid := "b%d" % _dag_bool_made
	if not bool((_dag.add_boolean(bid, op) as Dictionary)["ok"]):
		return ""
	if not bool((_dag.add_edge(ka, bid) as Dictionary)["ok"]):
		return ""
	if not bool((_dag.add_edge(kb, bid) as Dictionary)["ok"]):
		return ""
	return bid


func _bool_op(op: String, a: Variant, b: Variant) -> Dictionary:
	if op == SHAPE_BOOLEAN.OP_UNION:
		return SHAPE_BOOLEAN.union(a, b)
	if op == SHAPE_BOOLEAN.OP_INTERSECT:
		return SHAPE_BOOLEAN.intersect(a, b)
	if op == SHAPE_BOOLEAN.OP_DIFFERENCE:
		return SHAPE_BOOLEAN.difference(a, b)
	if op == SHAPE_BOOLEAN.OP_XOR:
		return SHAPE_BOOLEAN.xor(a, b)
	return {"ok": false, "cells": [], "count": 0, "reason": "未知布尔运算：%s" % op}


## 解析一个操作数 → `{ok, cells, reason}`。内置集合走 doc / 画布；其余键当依赖图节点求值。
func _operand_cells(key: String) -> Dictionary:
	if key == "":
		return {"ok": false, "cells": [], "reason": "还没选中形状（先在 A / B 下拉里选一个）"}
	if key == "__board__":
		return {"ok": true, "cells": doc.grid().all_positions(), "reason": ""}
	if key == "__selection__":
		if canvas.selection.size == Vector2i.ZERO:
			return {"ok": false, "cells": [],
				"reason": "还没框选：用左栏「区域选择」在棋盘上拖一个框"}
		return {"ok": true, "cells": _cells_in_rect(canvas.selection), "reason": ""}
	if key == "__revealed__":
		return {"ok": true, "cells": doc.revealed.keys(), "reason": ""}
	return _dag_eval_cells(key)


## 选区 → 盘内格坐标（与 `_cells_in` 同一套判界：问 `grid.in_board()`，不许用包围盒）。
func _cells_in_rect(rect: Rect2i) -> Array:
	var out: Array = []
	var g := doc.grid()
	for y in range(rect.position.y, rect.position.y + rect.size.y + 1):
		for x in range(rect.position.x, rect.position.x + rect.size.x + 1):
			var p := Vector2i(x, y)
			if g.in_board(p):
				out.append(p)
	return out


## 依赖图节点 → 格集（递归求值）。原子形状查 `ShapeDag.primitive_to_builder` 的**显式映射**，
## 然后**按 `builder_name` 派发**给 `ShapeGenerator.build_*`。
## 【为什么不能把 shape 名直接喂 `ShapeGenerator.to_adjacency_grid()`】两者的命名空间不同：
## `to_adjacency_grid` 的 kind 是**编辑器盘型**，其中 "ring" = 同心环盘；而 DAG 的 "ring" 是
## annulus（build_annulus）。撞名会**静默产出错几何** —— 这正是 shape_dag.gd 顶部「派发纪律」点名要拦的。
## 未登记映射 ⇒ 显式失败（绝不挑近似构建器 / 出空几何）；布尔节点按 `dependencies_of()`
## 的加边顺序折叠（差集是有序运算，顺序就是语义）。
func _dag_eval_cells(id: String) -> Dictionary:
	if not _dag.has_node(id):
		return {"ok": false, "cells": [], "reason": "依赖图里没有节点 %s" % id}
	var n: Dictionary = _dag.node(id)
	var kind := str(n["kind"])
	if kind == "primitive":
		var shape := str(n["shape"])
		var mapping: Dictionary = SHAPE_DAG.primitive_to_builder(shape)
		if not bool(mapping["ok"]):
			return {"ok": false, "cells": [], "reason": str(mapping["reason"])}
		var builder := str(mapping["builder_name"])
		var topo := _call_shape_builder(builder, n["params"])
		if String(topo.get("error", "")) != "":
			return {"ok": false, "cells": [],
				"reason": "形状「%s」（%s）构建失败：%s" % [shape, builder, String(topo["error"])]}
		var g := AdjacencyGrid.new()
		g.setup_from_topo(topo)
		if g.cell_count() == 0:
			return {"ok": false, "cells": [],
				"reason": "形状「%s」（%s）构建出空盘：已拒绝把它写回棋盘" % [shape, builder]}
		return {"ok": true, "cells": g.all_positions(), "reason": ""}
	# 布尔节点
	var deps: Array = _dag.dependencies_of(id)
	if deps.size() < 2:
		return {"ok": false, "cells": [],
			"reason": "布尔节点 %s 需要至少 2 个输入（当前 %d 个）：先用「加依赖」接上形状" % [id, deps.size()]}
	var acc := _dag_eval_cells(str(deps[0]))
	if not bool(acc["ok"]):
		return acc
	for i in range(1, deps.size()):
		var nxt := _dag_eval_cells(str(deps[i]))
		if not bool(nxt["ok"]):
			return nxt
		var r := _bool_op(str(n["shape"]), acc["cells"], nxt["cells"])
		if not bool(r["ok"]):
			return r
		acc = {"ok": true, "cells": r["cells"], "reason": ""}
	return acc


## 按 `ShapeDag.primitive_to_builder()` 给出的 **builder_name** 派发到具体生成器（见上面那条纪律）。
## 返回生成器原始产物：失败时含 `error` 键（与既有族同接口，不要用 `has("error")` 判失败）。
func _call_shape_builder(builder: String, params: Dictionary) -> Dictionary:
	if builder == "build_circle":
		return ShapeGenerator.build_circle(int(params.get("radius", 0)), int(params.get("precision", 24)))
	if builder == "build_star":
		return ShapeGenerator.build_star(int(params.get("points", 0)),
			int(params.get("outer_radius", 0)), float(params.get("inner_ratio", 0.5)))
	if builder == "build_sector":
		return ShapeGenerator.build_sector(int(params.get("radius", 0)),
			float(params.get("start_deg", 0.0)), float(params.get("end_deg", 90.0)))
	if builder == "build_ngon":
		return ShapeGenerator.build_ngon(int(params.get("sides", 0)), int(params.get("radius", 0)))
	if builder == "build_annulus":
		return ShapeGenerator.build_annulus(int(params.get("outer_radius", 0)),
			int(params.get("inner_radius", 0)), int(params.get("precision", 24)))
	return {"error": "本仓没有构建器 %s（形状映射表与生成器漂移了，请反馈）" % builder}


## 把一格集合当作**新的盘面形状**写回 doc：盘上只保留这些格，其余记为「障碍（格不存在）」。
## 先过 `ShapeBoolean.apply_to_grid`（只保留盘内格并如实报告丢弃数）——异形/挖洞盘不能用包围盒判界。
## 成功返回 {ok, changed, kept, dropped, removed_mines}；失败返回 {ok:false, ...} 且**已给出可读提示**。
func _write_board_shape(cells: Array, what: String) -> Dictionary:
	var g := doc.grid()
	var filt: Dictionary = SHAPE_BOOLEAN.apply_to_grid(cells, g)
	if not bool(filt["ok"]):
		_set_dag_note("%s 写回失败：%s" % [what, str(filt["reason"])])
		_toast("%s 写回失败：%s" % [what, str(filt["reason"])], true, 8.0)
		return {"ok": false, "changed": false, "reason": str(filt["reason"])}
	var kept: Array = filt["cells"]
	if kept.is_empty():
		var why := "结果是空的：按它写回会把整盘清成空格盘，已取消（换一个运算，或先加形状 / 先框选）。"
		_set_dag_note("%s %s" % [what, why])
		_toast("%s %s" % [what, why], true, 8.0)
		return {"ok": false, "changed": false, "reason": why}
	# 盘面可用的格 = 当前盘内格 ∪ 现存的障碍格（障碍格本来就属于"底图"，可以被重新放回来）
	var universe := {}
	for p in g.all_positions():
		universe[p] = true
	for p in doc.obstacles:
		universe[p] = true
	var keep := {}
	for p in kept:
		keep[p] = true
	var new_obs: Array = []
	for p in universe:
		if not keep.has(p):
			new_obs.append(p)
	new_obs.sort_custom(_pos_less_xy)
	var obs_set := {}
	for p in new_obs:
		obs_set[p] = true
	var changed := not _same_cells(obs_set, doc.obstacles)
	if not changed:
		return {"ok": true, "changed": false, "kept": kept.size(),
			"dropped": (filt["discarded"] as Array).size(), "removed_mines": 0}
	# 按钮命令 ⇒ 自成一步撤销（不被 700ms 合并窗折进上一个手势）
	_push_undo(false)
	doc.obstacles.clear()
	doc.obstacles.assign(new_obs)
	var kept_mines: Array[Vector2i] = []
	for m in doc.mines:
		if not obs_set.has(m):
			kept_mines.append(m)
	var removed_mines := doc.mines.size() - kept_mines.size()
	doc.mines.assign(kept_mines)
	var kept_rev := {}
	for p in doc.revealed:
		if not obs_set.has(p):
			kept_rev[p] = null
	doc.revealed = kept_rev
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()
	return {"ok": true, "changed": true, "kept": kept.size(),
		"dropped": (filt["discarded"] as Array).size(), "removed_mines": removed_mines}


func _same_cells(a: Dictionary, b: Array[Vector2i]) -> bool:
	if a.size() != b.size():
		return false
	for p in b:
		if not a.has(p):
			return false
	return true


## (y, x) 升序 —— 与 `ShapeBoolean` / `EditorDoc` 的输出口径一致（可复现、diff 友好）。
func _pos_less_xy(p: Vector2i, q: Vector2i) -> bool:
	if p.y != q.y:
		return p.y < q.y
	return p.x < q.x


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

	# 行容量侧栏（文档 §5「每行目标雷数 + 可行性预检」）：结论与不可行行号全部来自
	# `ColoringPreview.row_report`（盘内格数才叫容量；行语义未定义的网格族由矩阵门禁拒绝）。
	box.add_child(_section_label("行容量（每行目标雷数）"))
	var rcrow := HBoxContainer.new()
	rcrow.add_child(_plain_label("每行雷数"))
	_row_target_spin = _spin(1, 99, 1)
	# 默认值不能读 doc：本函数在 _build_ui() 里跑，那时 doc 还是 null（_ready 才赋）。
	_row_target_spin.value = 2
	_row_target_spin.value_changed.connect(func(_v: float) -> void: _refresh_row_capacity())
	rcrow.add_child(_row_target_spin)
	box.add_child(rcrow)
	_row_capacity_label = _plain_label("")
	_row_capacity_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_row_capacity_label)

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

	# 形状族：借 `ShapeGenerator` 的实现（这里接最常用的两族 + 参数化轮廓三族；加族只需再加一个分支）
	box.add_child(_section_label("形状（六边形 / 三角 / 圆 / 星 / 扇）"))
	_shape_opt = OptionButton.new()
	_shape_opt.add_item("方形网格（默认）", 0)
	_shape_opt.add_item("蜂窝六边形", 1)
	_shape_opt.add_item("三角网格", 2)
	_shape_opt.add_item("圆形", 3)
	_shape_opt.add_item("星形（五角）", 4)
	_shape_opt.add_item("扇形（90°）", 5)
	_shape_opt.item_selected.connect(func(_i: int) -> void: _on_shape_selected())
	box.add_child(_shape_opt)
	var srow := HBoxContainer.new()
	srow.add_child(_plain_label("形状尺寸"))
	# 上限 40（原 12）：让"半径过大"的拦截**用户真能触发**（圆/星结构上限 32/35、扇 63），
	# 而不是一段没人走得到的防御代码。超限由 `_budget_allows` → `_shape_upper_bound_reason` 拦住给提示。
	_shape_size = _spin(2, 40, 1)
	_shape_size.value = 4
	_shape_size.value_changed.connect(func(_v: float) -> void: _on_shape_selected())
	srow.add_child(_shape_size)
	box.add_child(srow)
	box.add_child(_plain_label("选形状后，邻域/边界控件不适用；雷位与障碍照常编辑。"
		+ "「形状尺寸」对圆 / 星 / 扇形是半径（格）。"))
	_build_shape_compose(box)
	# 文字转形状（文档 §3，「文字转形状」入口）：core 已单测，这里只补输入与写回。
	_build_text_shape_entry(box)
	# 复合格（MegaCell）：合并/拆分/邻接下钻都在 core，这里只补"进入 / 返回"两个入口。
	_build_mega_drill(box)
	# 骨牌划分 / 统计（直方图）/ 配色锁定 —— 三个 core 能力（都已单测）的界面入口。
	_build_domino_panel(box)
	_build_stats_panel(box)
	_build_color_lock_panel(box)
	scroll.add_child(box)
	return scroll


## 复合格（Mega Cell）下钻区：core（`core/mega_cell.gd`）已有 `drill_in/drill_out/is_inside/drill_path`，
## 缺的是 UI 入口。本块只做三件事：
##   ① 下拉列出当前文档里已有的复合格（`doc.mega_cells.ids()`）；
##   ② 两个按钮 = 进入 / 返回（走 core 的同名 API，不在 UI 里重算层级）；
##   ③ 常驻状态行显示**当前是否在格内 + 层级路径**（如 `#12 › #7`）+ **失败原因原文**。
## 【为什么不写进关卡 JSON】下钻是"我正在看哪一格内部"的**导航状态**，不是关卡内容 ⇒
## 不碰 `doc.to_level_json()`（core 落盘格式一字不改）。
func _build_mega_drill(box: VBoxContainer) -> void:
	box.add_child(_section_label("复合格（把一片格合并成一格；可下钻看内部）"))
	box.add_child(_plain_label("选一个复合格 → 点「进入这一格」看它内部的基础格；"
		+ "点「返回上一层」回到整盘。下钻只是「看」，不改关卡数据。"))
	_mega_opt = OptionButton.new()
	# 同配方/布局规则下拉：长文案不许把右栏撑宽（实测会把棋盘挤到一格只剩 29px）
	_mega_opt.fit_to_longest_item = false
	_mega_opt.clip_text = true
	box.add_child(_mega_opt)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_action_button("进入这一格", _on_mega_drill_in))
	row.add_child(_action_button("返回上一层", _on_mega_drill_out))
	box.add_child(row)
	_mega_state_label = _plain_label("")
	box.add_child(_mega_state_label)
	_mega_note = _plain_label("")
	box.add_child(_mega_note)
	_refresh_mega_ui()


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
	# 难度星级（1~5 星）：`Difficulty.stars_of_steps` 吃**推理轮数**；旧三档文案仍在下一条。
	_verify_stars = _plain_label("")
	_verify_stars.add_theme_font_size_override("font_size", 14)
	box.add_child(_verify_stars)
	_verify_state = _plain_label("")
	box.add_child(_verify_state)
	# ---- 修复建议（RepairSuggest 接线）----
	# 验证告诉用户"这盘要猜"，但"那怎么办"原来只能自己想。这里给出 1~3 条**已复核有效**的单步修法
	# （挪一颗雷 / 加一条初始线索），点「应用」= 一步写进撤销栈（一次算一步，不污染重做链）。
	box.add_child(_section_label("修复建议（要猜的时候，这里给修法）"))
	box.add_child(_plain_label("点「给我修复建议」：编辑器会在**文档副本**上试若干修法，只给出"
		+ "复核过「修完就能不靠猜推完」的 1~3 条（宁少而真）。\n"
		+ "每条点「应用」才真的改关卡，且只算**一步撤销**——按左栏「撤销」就能退回。"))
	_repair_btn = _action_button("给我修复建议", _on_repair)
	box.add_child(_repair_btn)
	_repair_msg = _plain_label("")
	box.add_child(_repair_msg)
	_repair_box = VBoxContainer.new()
	_repair_box.add_theme_constant_override("separation", 3)
	box.add_child(_repair_box)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_verify_issues = VBoxContainer.new()
	_verify_issues.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_verify_issues)
	box.add_child(scroll)

	# 推理链回放（文档「六」）：数据来自 ProofLog，窗口计算/读取在 ReplayModel（纯逻辑、已单测）。
	# **虚拟化**：总高 = 步数 × 行高，但只实例化 `visible_range()` 给出的那几行 ⇒ 万步日志也不会
	# 一次性建上万个节点（H 类内存爆炸的逃生口）。
	# 【为什么放在验证页】它和「开始验证」是同一条路径：先验证，再看"这盘是怎么推出来的"。
	# 【为什么不新开页签】`test_level_editor_smoke` 钉死了"右侧正好 4 页"，本切片不许削弱既有断言。
	box.add_child(_section_label("推理链回放（点一行，把棋盘定位到那一步）"))
	_replay_btn = _action_button("生成推理链回放", _on_replay_build)
	_replay_btn.tooltip_text = "推导一遍这盘的推理链，列成可点列表；点某一行会把棋盘定位到那一步的结论格"
	box.add_child(_replay_btn)
	_replay_banner = _plain_label("")
	_replay_banner.visible = false
	# 截断是**如实透出**的警告，用暖色 + ⚠ 双信号（颜色不能是唯一信号）
	_replay_banner.add_theme_color_override("font_color", Color(1.0, 0.72, 0.2, 1.0))
	box.add_child(_replay_banner)
	_replay_note = _plain_label("点上面的按钮生成；生成后滚动列表，点某一行会定位到那一步的结论格。")
	box.add_child(_replay_note)
	_replay_scroll = ScrollContainer.new()
	_replay_scroll.custom_minimum_size = Vector2(0, 150)
	_replay_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_replay_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# 列表内容是一个**纯 Control**（不用 VBoxContainer）：行按绝对坐标摆放才能只建视口内的行。
	_replay_rows = Control.new()
	_replay_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replay_rows.mouse_filter = Control.MOUSE_FILTER_PASS
	_replay_scroll.add_child(_replay_rows)
	_replay_scroll.get_v_scroll_bar().value_changed.connect(_on_replay_scrolled)
	box.add_child(_replay_scroll)
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
		"circle":
			_shape_opt.selected = 3
			_shape_size.value = int(doc.shape_params.get("radius", 4))
		"star":
			_shape_opt.selected = 4
			_shape_size.value = int(doc.shape_params.get("outer_radius", 4))
		"sector":
			_shape_opt.selected = 5
			_shape_size.value = int(doc.shape_params.get("radius", 4))
		_:
			_shape_opt.selected = 0
	_syncing = false


## 格子数事前估算的**统一闸门**（改尺寸 / 换形状 / 随机布雷共用）。
## 返回 true = 允许继续；false = 硬阻（不执行，已弹提示）。`warn` 档执行但顺手提示。
## 【为什么在 UI 侧而非 doc 侧】doc 是纯数据、没有 toast；"估算了要不要真的做"是交互决策。
##
## 【为什么 estimate 之外还要一道"形状上界"】`EditorDoc.estimate_cells` 对圆/星/扇给的是
## **精确几何格数**，漏掉两堵更严的墙：① `ShapeGenerator.build_*` 建盘前用**闭式上界** `π(r+1)²+1`
## 拒收（超 5000 ⇒ 返回 0 格 ⇒ 盘变空）；② `validate()`/加载器用 `rows*cols > 4096`（形状盘 rows*cols
## = 包围盒面积，与格数无关）⇒ 能编辑、不能玩。故先过 `_shape_upper_bound_reason`（两道取更严）。
func _budget_allows(kind: String, params: Dictionary, est_rows: int, est_cols: int) -> bool:
	var shape_reason := _shape_upper_bound_reason(kind, params)
	if shape_reason != "":
		_toast(shape_reason, true, 7.0)
		return false
	var rep := EditorDoc.check_cell_budget(EditorDoc.estimate_cells(kind, params, est_rows, est_cols))
	if not bool(rep["ok"]):
		_toast_cell_budget_block(rep)
		return false
	if str(rep["level"]) == "warn":
		_toast(str(rep["reason"]), false, 3.5)
	return true


## 圆 / 星 / 扇的**生成器侧格数上界**：与 `ShapeGenerator.build_*` 建盘前那道闸门
## `_budget_reason(_disk_upper_bound(...))` **逐字同入参**（只读复用 core 的权威公式，
## 不在此另立魔数）。返回 0 = 该族没有这道闸门（方阵 / 六边形 / 三角…只在 estimate 层判）。
func _shape_upper_bound(kind: String, params: Dictionary) -> float:
	match kind:
		"circle":
			return ShapeGenerator._disk_upper_bound(float(params.get("radius", 0)))
		"star":
			return ShapeGenerator._disk_upper_bound(float(params.get("outer_radius", 0)))
		"sector":
			var span: float = float(params.get("end_deg", 0.0)) - float(params.get("start_deg", 0.0))
			return ShapeGenerator._disk_upper_bound(float(params.get("radius", 0))) * span / 360.0
	return 0.0


func _shape_radius_of(kind: String, params: Dictionary) -> int:
	return int(params.get("outer_radius", 0)) if kind == "star" else int(params.get("radius", 0))


## 形状盘的真实 rows/cols：与 `EditorDoc.sync_size_to_shape()` **同一口径**（生成器真建一次盘，
## 取归一化包围盒）。返回 (0,0) = 建不出来（非法参数 / 生成器闸门已拒）。
func _shape_bbox_size(kind: String, params: Dictionary) -> Vector2i:
	var g: AdjacencyGrid = ShapeGenerator.to_adjacency_grid(kind, params)
	if g == null:
		return Vector2i.ZERO
	return AdjacencyGrid.normalized(g).size()


## 结构硬上限预检：`EditorDoc.validate()` / `LevelGuard` 都用 `rows*cols > MAX_CELLS(4096)` 硬拒
## （"能编辑、不能玩"，重导入还会被加载器拒收）。形状盘的 rows*cols = **包围盒面积**，与格数无关
## ⇒ 不能拿 `estimate_cells`（格数）去比 4096。先用便宜上界 (2r+1)² 排除，只有它超了才真建一次盘
## 取精确包围盒——所以圆/星只在边界那一两档付这笔钱，常规半径零开销。
func _shape_bbox_over(kind: String, params: Dictionary) -> bool:
	var side := 2 * _shape_radius_of(kind, params) + 1
	if side * side <= EditorDoc.MAX_CELLS:
		return false
	var sz := _shape_bbox_size(kind, params)
	return sz.x * sz.y > EditorDoc.MAX_CELLS


## 该轮廓参数"生成器会产格 **且** 不越结构硬上限" ⇒ 可建（两道闸门取更严的那个）。
func _shape_radius_allowed(kind: String, params: Dictionary) -> bool:
	if int(clampf(_shape_upper_bound(kind, params), 0.0, 9.0e18)) > EditorDoc.MAX_CELL_BUDGET:
		return false
	return not _shape_bbox_over(kind, params)


## 上界预检的可读原因："" = 生成器会照做且结构不超限；非空 = **该半径不可用**。
## 两道闸门各自说清"为什么"，但**共用同一个可用上限数字**（避免用户在 5000 / 4096 两堵墙间来回弹）：
##   A. 生成器闭式上界 > MAX_CELL_BUDGET(5000) ⇒ `build_*` 直接返回 0 格（盘会变空）；
##   B. 包围盒 rows*cols > MAX_CELLS(4096) ⇒ 校验报错、不能试玩/保存、重导入被拒（能编辑、不能玩）。
func _shape_upper_bound_reason(kind: String, params: Dictionary) -> String:
	if kind != "circle" and kind != "star" and kind != "sector":
		return ""
	var label := _shape_kind_label(kind)
	var r := _shape_radius_of(kind, params)
	if int(clampf(_shape_upper_bound(kind, params), 0.0, 9.0e18)) > EditorDoc.MAX_CELL_BUDGET:
		var rmax_gen := _max_usable_shape_radius(kind, params)
		return "%s：当前半径 %d 过大——生成器为避免盘爆炸会直接放弃（返回 0 个格子，盘会变空）。\n" % [
				label, r] + "可用上限约 %d 格：请把「形状尺寸」调到 %d 以内再试。" % [rmax_gen, rmax_gen]
	if _shape_bbox_over(kind, params):
		var sz := _shape_bbox_size(kind, params)
		var rmax := _max_usable_shape_radius(kind, params)
		return "%s：当前半径 %d 过大——盘面 %d×%d 共 %d 格，超过硬上限 %d" % [
				label, r, sz.x, sz.y, sz.x * sz.y, EditorDoc.MAX_CELLS] \
				+ "（能编辑、不能试玩/保存，重新导入会被拒）。\n可用上限约 %d 格：请把「形状尺寸」调到 %d 以内再试。" % [rmax, rmax]
	return ""


## 该轮廓参数下**真正可建**的最大半径——两道闸门取更严（提示里只给这一个数字）。
## 生成器的闭式上界是"安全上界" ⇒ 在 [1, 上界] 上二分（谓词对半径单调），再线性纠正边界。
func _max_usable_shape_radius(kind: String, params: Dictionary) -> int:
	if kind != "circle" and kind != "star" and kind != "sector":
		return 0
	var frac := 1.0
	if kind == "sector":
		frac = maxf((float(params.get("end_deg", 0.0))
			- float(params.get("start_deg", 0.0))) / 360.0, 0.0)
	if frac <= 0.0:
		return 0
	var rkey := "outer_radius" if kind == "star" else "radius"
	var probe := params.duplicate()
	probe[rkey] = 1
	if not _shape_radius_allowed(kind, probe):
		return 0
	var lo := 1
	var hi := maxi(clampi(int(sqrt(maxf((float(EditorDoc.MAX_CELL_BUDGET) - 1.0) / (PI * frac), 0.0))) - 1,
			1, 1000000), 1)
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		probe[rkey] = mid
		if _shape_radius_allowed(kind, probe):
			lo = mid
		else:
			hi = mid - 1
	while lo < 1000000:
		probe[rkey] = lo + 1
		if not _shape_radius_allowed(kind, probe):
			break
		lo += 1
	return lo


func _shape_kind_label(kind: String) -> String:
	match kind:
		"circle":
			return "圆形"
		"star":
			return "星形"
		"sector":
			return "扇形"
	return kind


## 预算硬阻提示：说清"预计多少格"，并把**三条出路**逐条列出来（小白不必自己想办法）。
func _toast_cell_budget_block(rep: Dictionary) -> void:
	var hints: Array = rep.get("hints", [])
	var lines: Array[String] = []
	for i in hints.size():
		lines.append("%d) %s" % [i + 1, str(hints[i])])
	_toast("%s\n可行的出路：%s" % [str(rep.get("reason", "")), "；".join(lines)], true, 7.0)


func _on_size_changed() -> void:
	if _syncing:
		return
	# 事前估算：先按"将要采用"的行/列算格数，超了就不改文档（并把界面拉回文档值）。
	if not _budget_allows(doc.shape_kind, doc.shape_params, int(_rows_spin.value), int(_cols_spin.value)):
		_doc_to_ui()
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


## 选形状 ⇒ 棋盘改由 `ShapeGenerator` 生成（网格族 + 参数化轮廓族均为现成实现），并把
## rows/cols 同步成其包围盒。
## 形状盘上「邻域/边界」不适用（与载入外部拓扑同理，validate 会给出 `shape_active` 提醒）。
func _on_shape_selected() -> void:
	if _syncing:
		return
	# 先按"将要采用"的形状参数估算格数（纯计算，不建盘）：超最高上限就**不动文档**，
	# 把下拉/尺寸拉回当前值，避免界面显示一个没生效的选择。
	var kind := ""
	var params: Dictionary = {}
	# 注意：不得命名为 `size`——会遮蔽 Control 基类的 `size` 属性（test_code_hygiene 会红）。
	var shape_dim := int(_shape_size.value)
	match _shape_opt.selected:
		1:
			kind = "hex"
			params = {"size": shape_dim}
		2:
			kind = "tri_grid"
			params = {"cols": shape_dim, "rows": shape_dim}
		3:
			# 圆：默认 precision 24（与 build_circle 签名默认一致）。
			kind = "circle"
			params = {"radius": shape_dim, "precision": 24}
		4:
			# 星形：五角 + 内外半径比 0.5（合理默认；半径由「形状尺寸」给）。
			kind = "star"
			params = {"points": 5, "outer_radius": shape_dim, "inner_ratio": 0.5}
		5:
			# 扇形：默认 0°→90° 的四分之一扇（顶点在下方）。
			kind = "sector"
			params = {"radius": shape_dim, "start_deg": 0.0, "end_deg": 90.0}
		_:
			kind = ""
			params = {}
	var est_rows := shape_dim if kind != "" else int(_rows_spin.value)
	var est_cols := shape_dim if kind != "" else int(_cols_spin.value)
	# 【已删掉旧的包围盒兜底】那段曾把圆/星/扇的 est_rows/est_cols 覆盖成 (2r+1)²，
	# 但 `EditorDoc.estimate_cells` 现在对这三族**按 shape_params 算精确几何格数**、根本不看
	# 这两个参数 ⇒ 兜底早已失效（只有副作用：让人误以为它是防线）。真正的防线是
	# `_budget_allows` → `_shape_upper_bound_reason`：用生成器同一上界拦住"会返回 0 格"的半径。
	if not _budget_allows(kind, params, est_rows, est_cols):
		_doc_to_ui()
		return
	# 重栅格化（文档 §3「重栅格化的映射」）：手工改过的格**不许静默消失**。
	# 判据走 core 的 `ShapeReflow.reflow`（grid = **新形状盘**；手工格负载无条件优先），
	# 先试算一次、把新形状的格集与原格集对一遍：
	#   · 没有手工格掉出盘外 ⇒ 照旧换形状（自动生成的盘外格按老规矩移走并告知）；
	#   · 有手工格掉出盘外 ⇒ **先还原成旧形状**，列出来让用户在确认条上自己决定（点头才真换）。
	var old_kind := doc.shape_kind
	var old_params := doc.shape_params
	var old_cells := _board_payload()
	_push_undo(false)
	doc.shape_kind = kind
	doc.shape_params = params
	doc.sync_size_to_shape()
	var trial: Dictionary = _reflow_trial(old_cells)
	var dropped_hand: Array = trial["dropped_hand"]
	if not dropped_hand.is_empty():
		doc.shape_kind = old_kind
		doc.shape_params = old_params
		doc.sync_size_to_shape()
		_doc_to_ui()
		_refresh_all()
		_ask_confirm("换形状会丢掉 %d 个你手工改过的格（新形状盘上没有对应位置）：%s。\n"
			% [dropped_hand.size(), _fmt_cells_brief(dropped_hand)]
			+ "点「确认」照换（这些格会被移除、可撤销）；点「取消」保持现在的形状。",
			func() -> void: _apply_shape_change(kind, params, old_cells))
		return
	_apply_shape_change(kind, params, old_cells)


## 真的换形状（确认之后走这里）：换完做一次盘外清理与落盘刷新。
func _apply_shape_change(kind: String, params: Dictionary, old_cells: Dictionary) -> void:
	_push_undo(false)
	doc.shape_kind = kind
	doc.shape_params = params
	doc.sync_size_to_shape()
	var kept_hand: Array = _reflow_trial(old_cells)["kept_hand"]
	var dropped := _drop_off_board()
	_hand_edited.clear()          # 手工格已经映射过一遍：新一轮从空集重新记
	_mark_dirty()
	_doc_to_ui()
	_refresh_all()
	if not kept_hand.is_empty():
		_toast("换了形状：保住了 %d 个手工改过的格" % kept_hand.size(), false, 4.0)
	elif dropped > 0:
		_toast("换了形状：%d 个盘外格（雷/障碍/翻开）已移除（可撤销）" % dropped)


## 盘上"有内容"的格 → 负载（重栅格化的旧格集来源；空盘 ⇒ 空字典，纯计算不建盘）。
func _board_payload() -> Dictionary:
	var out: Dictionary = {}
	if doc == null:
		return out
	for m in doc.mines:
		out[m] = "mine"
	for o in doc.obstacles:
		out[o] = "obstacle"
	for p in doc.revealed.keys():
		out[p] = "revealed"
	return out


## 重栅格化试算：`ShapeReflow.reflow(新盘, 旧格集, 新格集, 手工格)`（口径见 core/shape_reflow.gd）。
func _reflow_trial(old_cells: Dictionary) -> Dictionary:
	var g := doc.grid()
	var new_cells: Dictionary = {}
	for p in g.all_positions():
		new_cells[p] = true
	return REFLOW.reflow(g, old_cells, new_cells, _hand_edited)


## 坐标列表的人话摘要（最多 4 个，其余给个数）——确认条上要能看见"丢的是哪几格"。
func _fmt_cells_brief(cells: Array) -> String:
	var parts: Array[String] = []
	for i in mini(cells.size(), 4):
		var p: Vector2i = cells[i]
		parts.append("(%d,%d)" % [p.x, p.y])
	var s := "、".join(parts)
	if cells.size() > 4:
		s += " 等 %d 格" % cells.size()
	return s


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
	# 手工改过的格记下来：换形状重栅格化时，它是「手工格负载」的唯一来源（ShapeReflow.reflow）。
	_hand_edited[pos] = true
	# 对称（Ctrl+G）：单格手势把同一格型镜像到对称位置（见 `_apply_symmetry` 的范围约束）。
	var mirrored := _apply_symmetry(pos)
	_sync_declared_total()
	_mark_dirty()
	_refresh_preview_around(pos)
	for mp in mirrored:
		_hand_edited[mp] = true
		_refresh_preview_around(mp)
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
	# 【W1】优先记 **diff**（格子级改动只存受影响的格 ≈12B/格）；没有待记改动（改尺寸/换邻域/
	# 随机布雷这类结构或批量动作）才退回 `snapshot()` 兜底 —— 那一步很贵（5000 格 ≈2MB），
	# 所以快照型记录另有更低的上限（见 `_trim_undo`）。`to_level_json()` 不能用（含派生 topology）。
	if doc.has_diff():
		_undo.append({"kind": "diff", "cells": doc.take_diff()})
	else:
		_undo.append({"kind": "snap", "snap": doc.snapshot()})
	_trim_undo()
	_redo.clear()


## 撤销栈裁剪：总数 ≤ `UNDO_LIMIT`，且其中**快照型** ≤ `UNDO_SNAP_LIMIT`（内存硬上限）。
## 两个上限都要：只限总数 ⇒ 200 张快照又是上百 MB；只限快照数 ⇒ 微操作步数不够（清单要求 ≥200）。
func _trim_undo() -> void:
	while _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	var snaps := 0
	for it in _undo:
		if str((it as Dictionary).get("kind", "")) == "snap":
			snaps += 1
	while snaps > UNDO_SNAP_LIMIT:
		for i in _undo.size():
			if str((_undo[i] as Dictionary).get("kind", "")) == "snap":
				_undo.remove_at(i)
				snaps -= 1
				break



func _undo_once() -> void:
	if _undo.is_empty():
		_toast("没有可撤销的操作")
		return
	# 撤销/重做会把整份状态换掉 ⇒ 「手工格」集合跟着作废（继续沿用会误报手工格）。
	_hand_edited.clear()
	_redo.append(_apply_record(_undo.pop_back()))
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()


func _redo_once() -> void:
	_hand_edited.clear()   # 同 _undo_once：换成另一份状态，手工格标记作废
	if _redo.is_empty():
		_toast("没有可重做的操作")
		return
	_undo.append(_apply_record(_redo.pop_back()))
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()


## 应用一条撤销/重做记录，并返回**反向记录**（撤销↔重做共用同一条路径）。
## 两种记录：`{"kind":"diff","cells":PackedInt32Array}` 与 `{"kind":"snap","snap":快照}`。
func _apply_record(rec: Dictionary) -> Dictionary:
	if str(rec.get("kind", "")) == "diff":
		return {"kind": "diff", "cells": doc.apply_diff(rec.get("cells", PackedInt32Array()))}
	var snap: Variant = rec.get("snap", {})
	var back := doc.snapshot()          # 先取"现在"，恢复完再把它当作反向记录
	doc.restore(snap if snap is Dictionary else {})
	return {"kind": "snap", "snap": back}


## 编辑动作之后把"声明的总雷数"改回未声明 ⇒ 以实际雷位为准。
## 不这么做的话：打开任何已保存的关卡（其 total_mines 是导入时的旧值）再增删雷，
## 立刻会报一条**用户没法修**的「声明的总雷数不一致」，并把试玩/打包一起挡住（2026-10-02 实测）。
func _sync_declared_total() -> void:
	doc.sync_declared_total()


func _random_mines() -> void:
	# 事前估算：盘太大就别撒雷（随机布雷是最容易一次建大盘、最该先拦的批量动作）。
	var budget := doc.cell_budget_report()
	if not bool(budget["ok"]):
		_toast_cell_budget_block(budget)
		return
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
	if str(budget["level"]) == "warn":
		_toast(str(budget["reason"]), false, 3.5)


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
		# 【审查遗留修复（A3 同族，真 bug）】原来用**包围盒**判界 `p.x < doc.cols and p.y < doc.rows`：
		#   · 形状盘（蜂窝/三角/环形）上会把**洞格**一起写了（盘外看不见的格）；
		#   · 负数坐标**竟然算通过**（`-1 < cols` 为真）⇒ 往左上角粘贴会直接写到盘外。
		# 与 `editor_canvas._fill_rect` 统一口径：问网格 `in_board()`。
		if doc.grid().in_board(p):
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
			# 同上（A3 同族）：复制也要按**网格**判界 —— 包围盒会把洞格与负坐标都当成"盘内"，
			# 于是剪贴板里会混进盘外格，粘贴时再散布出去。
			if not doc.grid().in_board(p):
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


# ==================== 复合格下钻（MegaCell 接线） ====================
#
# 分层：**core 是唯一权威**（进入/返回/路径/深度判定全在 `core/mega_cell.gd`，已单测）；
# 本文件只做"取选中 id → 调 core → 把 path / reason 画出来"，不重算层级、不复制 core 的判据。
# 失败一律**原文显示 reason**（core 已给可读人话），绝不只说"失败"。

func _mega_registry() -> Variant:
	if doc == null:
		return null
	return doc.mega_cells


func _mega_selected_id() -> int:
	if _mega_opt == null or _mega_opt.item_count == 0 or _mega_opt.selected < 0:
		return 0
	return int(_mega_opt.get_item_id(_mega_opt.selected))


## 重建复合格下拉（换文档 / 合并 / 拆分后都要跟上），并把显示与当前下钻状态对齐。
func _refresh_mega_ui() -> void:
	if _mega_opt == null:
		return
	var keep := _mega_opt.selected
	_mega_opt.clear()
	# 显式 Variant：`_mega_registry()` 返回 Variant，`var x :=` 会被判成"从 Variant 推断"（本工程当错误）
	var inst: Variant = _mega_registry()
	if inst != null:
		for gid in inst.ids():
			_mega_opt.add_item("复合格 #%d（内部 %d 格）" % [gid, inst.size_of(gid)], gid)
	if _mega_opt.item_count == 0:
		# 空下拉在界面上就是"一个没有内容的按钮"（既有可用性用例专门抓这个）⇒ 给一行占位；
		# 点「进入这一格」会拿到 core 的可读拒绝理由（id=0 ⇒ not_mega），而不是静默。
		_mega_opt.add_item("（本关还没有复合格：先合并一片格）", 0)
	else:
		_mega_opt.selected = clampi(keep, 0, _mega_opt.item_count - 1)
	# 文档换了之后，旧的路径可能指向已不存在的复合格 ⇒ 退回顶层（不让界面说谎）。
	if inst != null and MEGA_CELL.is_inside(_mega_drill):
		for gid2 in MEGA_CELL.drill_path(_mega_drill):
			if not inst.has(gid2):
				_mega_drill = MEGA_CELL.drill_state()
				_mega_set_note("复合格 #%d 已不存在，已退回整盘视图" % gid2, true)
				break
	_refresh_mega_state()


## 状态行：**当前是否在格内 + 层级路径**（如 `#12 › #7`）。判据只问 core。
func _refresh_mega_state() -> void:
	if _mega_state_label == null:
		return
	if not MEGA_CELL.is_inside(_mega_drill):
		_mega_state_label.text = "当前：整盘视图（未下钻）"
		return
	var path: Array[int] = MEGA_CELL.drill_path(_mega_drill)
	_mega_state_label.text = "当前：在复合格内部 ｜ 层级路径 %s ｜ 深度 %d" % [
		_mega_path_text(path), path.size()]


## 层级路径文案：由外到内（`#12 › #7`）。
func _mega_path_text(path: Array[int]) -> String:
	var parts: Array[String] = []
	for gid in path:
		parts.append("#%d" % gid)
	return " › ".join(parts)


## 「进入这一格」：真实入口（下拉选中的复合格）。core 拒绝时**原文显示 reason**，且状态不变。
func _on_mega_drill_in() -> void:
	var inst: Variant = _mega_registry()
	if inst == null:
		_mega_set_note("文档未就绪，无法下钻", true)
		return
	var gid := _mega_selected_id()
	var res: Dictionary = inst.drill_in(_mega_drill, gid)
	if not bool(res.get("ok", false)):
		# 失败必须给出 core 的原因原文（非法目标 / 不存在 / 超深…）
		_mega_set_note(str(res.get("reason", "进入失败（core 未给出原因）")), true)
		_refresh_mega_state()
		return
	var inner: Array[Vector2i] = res.get("inner", [])
	_mega_set_note("已进入复合格 #%d（内部 %d 格）" % [gid, inner.size()], false)
	_refresh_mega_state()
	# 下钻后把**内部基础格**高亮出来（「看内部」这件事要真的看得见）
	if canvas != null:
		canvas.set_highlight(inner)
		_toast("已进入复合格 #%d 内部" % gid)


## 「返回上一层」：成功 ⇒ 视图回到整盘；顶层再退 ⇒ 显示 core 的 reason（不许静默）。
func _on_mega_drill_out() -> void:
	var inst: Variant = _mega_registry()
	if inst == null:
		_mega_set_note("文档未就绪，无法返回", true)
		return
	var res: Dictionary = inst.drill_out(_mega_drill)
	if not bool(res.get("ok", false)):
		_mega_set_note(str(res.get("reason", "返回失败（core 未给出原因）")), true)
		_refresh_mega_state()
		return
	_mega_set_note("已返回上一层" + ("" if MEGA_CELL.is_inside(_mega_drill) else "：回到整盘视图"), false)
	_refresh_mega_state()
	# 退出后**视图回到整盘**：把高亮交还给「问题格」（下钻时那组高亮被内部格占用了）。
	if doc != null and canvas != null:
		_refresh_errors()
		_toast("已回到整盘视图")


## 下钻结果提示：失败**原文显示 reason**（颜色 + 文字双信号，颜色不是唯一信号）。
func _mega_set_note(text: String, bad: bool) -> void:
	if _mega_note == null:
		return
	_mega_note.text = ("⚠ " if bad else "· ") + text
	_mega_note.add_theme_color_override("font_color",
		Color(1.0, 0.55, 0.35, 1.0) if bad else _label_color())


## 下钻状态的**显式序列化**（走 core 的 codec，UI 不自造格式）。
func _mega_drill_snapshot() -> Dictionary:
	return MEGA_CELL.drill_to_dict(_mega_drill)


## 用 core 的 codec 还原下钻状态，并把界面同步过去。返回"是否在格内"。
func _mega_drill_restore(d: Variant) -> bool:
	_mega_drill = MEGA_CELL.drill_from_dict(d)
	_refresh_mega_state()
	return MEGA_CELL.is_inside(_mega_drill)


# ==================== 刷新 ====================

func _mark_dirty() -> void:
	_dirty = true
	_last_change_ms = Time.get_ticks_msec()
	# 文档一变，热力图/回放这些"按当时盘面算出来的"派生视图立刻作废（见 `_invalidate_derived_views`）。
	_invalidate_derived_views()


func _refresh_all() -> void:
	_refresh_preview()
	_refresh_errors()
	_refresh_rule_report()
	_refresh_status()
	_refresh_open_list()
	_refresh_global_list()
	_refresh_mega_ui()
	# 2026-10-09 接线：行容量 / 统计 / 配色锁定 跟着每一次全量刷新一起更新（都是纯计算，很便宜）。
	_refresh_row_capacity()
	_refresh_stats()
	_refresh_color_lock()
	_refresh_domino_note()
	_refresh_thumb_preview()


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


## 问题三级（core/editor_doc.gd 的 ISSUE_ERROR / ISSUE_WARN / ISSUE_INFO）在界面上的呈现。
## 键 = core 的 level 取值（唯一权威）；顺序即显示顺序：阻止 → 警告 → 提示（严重到轻）。
## 颜色只用在**分组标题**上（正文保持主题色，避免浅色主题下低对比）。
const ISSUE_LEVEL_UI := [
	{"level": EditorDoc.ISSUE_ERROR, "title": "阻止", "color": Color(0.90, 0.27, 0.24, 1.0)},
	{"level": EditorDoc.ISSUE_WARN, "title": "警告", "color": Color(0.85, 0.60, 0.10, 1.0)},
	{"level": EditorDoc.ISSUE_INFO, "title": "提示", "color": Color(0.25, 0.55, 0.95, 1.0)},
]


## 把 validate() 的结论铺进"本盘问题"列表，**按三级（阻止 / 警告 / 提示）分组**展示。
## 【为什么不按桶名分组】`warnings` 桶是「warn ∪ info」的**兼容超集**（core 刻意保持向后兼容）
## ⇒ 按桶名分三级会把 info 同时塞进「警告」里（重复计数、分级错误）。分组判据只认每条问题的
## `level` 字段（core 的权威分级）。
## 只展示前 12 条：面板是给人看的，超过这个量说明该先修结构性问题而不是刷屏。
func _refresh_issue_list(rep: Dictionary) -> void:
	# ⚠ 必须**立即** `remove_child` 再 `queue_free()`：`queue_free()` 是**帧末延迟删除**，
	# 同一帧里紧接着 `add_child` 新分组头时，旧节点仍留在 `get_children()` 里 ⇒ 新内容被追加在
	# **过期条目之后**，`get_child(0)` 拿到的是上一轮的头（实测：兜底归级用例读到旧节点、
	# `ed_issue_head` 为 null；列表本身也会在下一帧前短暂重复）。
	for c in _issues_box.get_children():
		_issues_box.remove_child(c)
		c.queue_free()
	var rows := _issue_rows(rep)
	if rows.is_empty():
		_issues_box.add_child(_plain_label("没有问题：可以按左上角「试玩」，或存成分享包。"))
		return
	var shown := 0
	for spec in ISSUE_LEVEL_UI:
		var level := str(spec["level"])
		var group: Array = []
		for it in rows:
			if _issue_level_of(it) == level:
				group.append(it)
		if group.is_empty():
			continue
		_issues_box.add_child(_issue_head(spec, group.size()))
		for it in group:
			if shown >= 12:
				break
			var d: Dictionary = it
			var pos: Vector2i = d["pos"]
			var line := "[%s] %s%s" % [
				str(spec["title"]), str(d["text"]),
				"" if pos.x < 0 else "（格 %d,%d）" % [pos.x, pos.y]]
			# 带格坐标的问题 → 做成可点条目，点了把视口**定位到那一格**（文档「六」点击跳转）。
			# 与格无关的问题（pos = (-1,-1)）仍是纯文字。
			if pos.x >= 0:
				var btn := _jump_button(line, pos)
				btn.set_meta("ed_issue_level", level)
				_issues_box.add_child(btn)
			else:
				var lb := _plain_label(line)
				lb.set_meta("ed_issue_level", level)
				_issues_box.add_child(lb)
			shown += 1
		if shown >= 12:
			break
	if shown >= 12:
		_issues_box.add_child(_plain_label("…还有更多，先在画布里逐个修掉高亮格"))


## 单条问题的**归级**：认不出来的一律当**阻止**级。
## 【为什么必须兜底】三级是 core 定的枚举；若将来 core 加了第四级 / 改了取值，而本表没同步，
## 不兜底就会"哪一组都不匹配 ⇒ 该条**静默消失**"。静默丢问题比归错级严重得多（宁严不丢）。
func _issue_level_of(it: Variant) -> String:
	var lv := str((it as Dictionary).get("level", EditorDoc.ISSUE_ERROR))
	for spec in ISSUE_LEVEL_UI:
		if str(spec["level"]) == lv:
			return lv
	return EditorDoc.ISSUE_ERROR


## 统一的问题行（每条带 level）。优先用 core 的 `issues`（三级统一、带 level）；
## 只有在它缺失时才按兼容桶补出 level —— 让只给分桶的旧调用方仍能用（如既有单测）。
func _issue_rows(rep: Dictionary) -> Array:
	var unified: Array = rep.get("issues", [])
	if not unified.is_empty():
		return unified.duplicate()
	var out: Array = []
	var fallback := [["errors", EditorDoc.ISSUE_ERROR], ["warnings", EditorDoc.ISSUE_WARN], ["infos", EditorDoc.ISSUE_INFO]]
	for pair in fallback:
		for it in rep.get(pair[0], []):
			var d: Dictionary = (it as Dictionary).duplicate()
			if not d.has("level"):
				d["level"] = str(pair[1])
			out.append(d)
	return out


## 一级的分组标题（文案 + 条数 + 颜色）。标题**去掉 `ed_label` 标记**：
## `_repaint_labels()` 会把带标记的字色重刷成主题色，那会把三级颜色抹平。
func _issue_head(spec: Dictionary, count: int) -> Label:
	var lb := _plain_label("%s（%d 条）" % [str(spec["title"]), count])
	lb.add_theme_font_size_override("font_size", 13)
	lb.add_theme_color_override("font_color", spec["color"])
	lb.remove_meta("ed_label")
	lb.set_meta("ed_issue_head", str(spec["level"]))
	return lb


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
	# 工具名**必须与 `EditorCanvas.Tool` 逐一对应**：数字快选 1~9 能选到直线/油漆桶，
	# 旧表只有 5 项 ⇒ 会 IndexError（这就是"新工具追加在末尾"要同步的地方）。
	var tool_names := ["画笔", "橡皮", "矩形填充", "区域选择", "平移", "直线", "油漆桶", "手绘轮廓"]
	var kind_names := {"mine": "地雷", "obstacle": "障碍", "reveal": "初始已翻开", "clear": "清空"}
	var err := str(canvas.get_meta("first_error", "")) if canvas != null else ""
	var pos_text := "盘外" if canvas == null or canvas.hover.x < 0 else "(%d,%d)" % [canvas.hover.x, canvas.hover.y]
	_status.text = "坐标 %s ｜ 格 %d×%d ｜ 雷 %d ｜ 密度 %.0f%% ｜ 工具 %s ｜ 格型 %s%s" % [
		pos_text, doc.cols, doc.rows, doc.mine_count(), doc.density() * 100.0,
		tool_names[canvas.tool] if canvas != null and canvas.tool >= 0 and canvas.tool < tool_names.size() else "-",
		kind_names.get(canvas.paint_kind, "-") if canvas != null else "-",
		"" if err == "" else " ｜ ⚠ %s" % err]


func _refresh_open_list() -> void:
	var dir := DirAccess.open(EDITOR_DIR)
	var keep := _open_opt.selected
	_open_opt.clear()
	if dir == null:
		_fill_open_placeholder()
		return
	var names: Array[String] = []
	for f in dir.get_files():
		# 缩略图 sidecar（<存档>.thumb.json）**不是关卡**：按名字排除，别让它出现在「打开这个存档」里。
		if str(f).ends_with(".json") and not str(f).begins_with("_") and not str(f).ends_with(".thumb.json"):
			names.append(str(f))
	names.sort()
	for n in names:
		_open_opt.add_item(n)
	if _open_opt.item_count == 0:
		_fill_open_placeholder()
		return

	if keep >= 0 and keep < _open_opt.item_count:
		_open_opt.selected = keep


## 「还没有存档」的禁用占位项（见 `_refresh_open_list` 的注释）：空 OptionButton 是"无文字无图标"的
## 空盒子，用户看不出这是什么，UI 回归用例也会判红。
func _fill_open_placeholder() -> void:
	if _open_opt == null:
		return
	_open_opt.add_item("（还没有保存过的关卡）")
	_open_opt.set_item_disabled(0, true)
	_open_opt.selected = 0


# ==================== 四象染色预览（文档 §5） ====================
#
# 数据全部由 core 算（`ColoringPreview.quadrant_preview`：色号逐格复用 `ConstraintEngine.quadrant_of`），
# 网格族上四象语义未定义时由「变体×网格矩阵」拒绝；UI 只做两件事：把结果交给画布、把结论/理由说出来。

## 颜色叠加层的层名（与热力图分开：一个看"推理深度"，一个看"四象分区"）。
const QUAD_OVERLAY := "quadrant"


func _set_quad_note(text: String) -> void:
	if _quad_note == null:
		return
	_quad_note.text = text
	_quad_note.visible = text != ""


func _toggle_quadrant_preview() -> void:
	if _quad_btn == null or canvas == null:
		return
	if not _quad_btn.button_pressed:
		canvas.clear_overlay(QUAD_OVERLAY)
		_set_quad_note("")
		return
	var g := doc.grid()
	var rep: Dictionary = COLORING.quadrant_preview(g, g.all_positions(), EditorVerify.grid_kind_of(doc))
	if not bool(rep["ok"]):
		# 打不开就把开关退回去：不许开关显示"开"、画布上却什么都没有（界面在骗人）。
		_quad_btn.button_pressed = false
		_set_quad_note("四象染色预览打不开：%s" % str(rep.get("reason", "")))
		_toast("四象染色预览打不开：%s" % str(rep.get("reason", "")), true, 8.0)
		return
	canvas.set_overlay(QUAD_OVERLAY, rep["cells"], {"colors": COLORING.color_table(), "z": 2, "visible": true})
	_set_quad_note(COLORING.describe_quadrants(rep))
	_toast("已打开四象染色预览")


# ==================== 行容量侧栏（文档 §5） ====================

func _refresh_row_capacity() -> void:
	if _row_capacity_label == null or doc == null:
		return
	var target := int(_row_target_spin.value) if _row_target_spin != null else 0
	var rep: Dictionary = COLORING.row_report(doc.grid(), target, doc.mines, EditorVerify.grid_kind_of(doc))
	var text := COLORING.describe_rows(rep)
	# 不可行的行要**点名 + 给第一条理由**（只报个数，用户不知道改哪里）。
	var bad: Array = rep.get("infeasible", [])
	if not bad.is_empty():
		for r in rep.get("rows", []):
			if not bool((r as Dictionary).get("feasible", true)):
				text += "\n⚠ %s" % str((r as Dictionary).get("reason", ""))
				break
	_row_capacity_label.text = text


# ==================== 文字转形状（文档 §3「文字转形状」） ====================

func _set_text_shape_note(text: String) -> void:
	if _text_shape_note != null:
		_text_shape_note.text = text


func _build_text_shape_entry(box: VBoxContainer) -> void:
	box.add_child(_section_label("文字转形状（打字变成棋盘轮廓）"))
	box.add_child(_plain_label("打一行字（最多 16 个字符；空格不成形状，会被跳过），点「文字转形状」把它刻成棋盘。\n"
		+ "字形用**随包字体**栅格化：同一台机器、同一个输入 ⇒ 每次结果一样；放不下会自动调小，并告诉你调到了几像素。"))
	_text_shape_edit = LineEdit.new()
	_text_shape_edit.custom_minimum_size = Vector2(0, 30)
	_text_shape_edit.placeholder_text = "例如：中国 / AB"
	_text_shape_edit.text_submitted.connect(func(_t: String) -> void: _apply_text_shape())
	box.add_child(_text_shape_edit)
	var row := HBoxContainer.new()
	row.add_child(_plain_label("像素高"))
	_text_shape_px = _spin(6, 96, 1)
	_text_shape_px.value = 24
	row.add_child(_text_shape_px)
	box.add_child(row)
	box.add_child(_action_button("文字转形状（写回棋盘）", _apply_text_shape))
	_text_shape_note = _plain_label("")
	_text_shape_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_text_shape_note)


## 文字 → 格集 → 写回棋盘。栅格化在 `GlyphFont`（纯 CPU、可单测），写回走既有的
## `_write_board_shape`（"把格集变成盘型"的唯一入口 ⇒ 撤销/清雷/刷新都不必在这里重写一遍）。
func _apply_text_shape() -> void:
	if _text_shape_edit == null or doc == null:
		return
	var text := _text_shape_edit.text.strip_edges()
	var px := int(_text_shape_px.value) if _text_shape_px != null else 16
	var r: Dictionary = GLYPH_FONT.text_cells_fit(text, doc.grid(), Vector2i.ZERO, px)
	if not bool(r["ok"]):
		_set_text_shape_note("转不出形状：%s" % str(r.get("reason", "")))
		_toast("文字转形状失败：%s" % str(r.get("reason", "")), true, 8.0)
		return
	var cells: Array = []
	for p in (r["cells"] as Dictionary).keys():
		cells.append(p)
	cells.sort_custom(_pos_less_xy)
	# 缩过档 / 跳过空格**必须说出来**（不许静默变形）——这两条都是 core 明确记账的。
	var extra := ""
	if bool(r.get("shrunk", false)):
		extra += "（自动缩小到 %d 像素才放得下）" % int(r.get("used_px", 0))
	var sp := int(r.get("ignored_spaces", 0))
	if sp > 0:
		extra += "（跳过 %d 个空格：空格不成形状）" % sp
	var w: Dictionary = _write_board_shape(cells, "文字「%s」" % text)
	_set_text_shape_note("文字「%s」：%d 格%s" % [text, cells.size(), extra])
	if bool(w.get("ok", false)):
		_toast("已把「%s」刻成棋盘：%d 格%s" % [text, cells.size(), extra], false, 6.0)



# ==================== 手绘轮廓 → 形状（文档 §3「手绘轮廓」） ====================
#
# 分工（与「文字转形状」同一条链，只是点从哪来不同）：
#   · 画布：只交"一次手势的**连续棋盘坐标**点列"（`ui/editor_canvas.gd` 的 `outline_drawn`）；
#   · core：闭合多边形 → 格集，栅格化与判界全在 `TextToShape.outline_to_cells`
#     （判界一律 `grid.in_board()`，异形 / 挖洞盘不按包围盒猜）；
#   · 写回：复用 `_write_board_shape`（"格集 → 盘型"的唯一入口 ⇒ 撤销 / 清雷 / 刷新不必重写）。

## 画布拖完一个闭合轮廓时调用。失败必须说清**为什么**（点太少 / 自交 / 盘内无格），
## 不许静默丢弃——用户画了半天必须得到一个解释。
func _on_outline_drawn(points: PackedVector2Array) -> void:
	if doc == null:
		return
	# tolerance ≤ 0 ⇒ 取 StrokeLimits.EPSILON（与手绘落盘同口径，见 TextToShape 注释）。
	var r: Dictionary = TTS.outline_to_cells(points, doc.grid(), -1.0)
	if not bool(r.get("ok", false)):
		var why := str(r.get("reason", ""))
		_set_text_shape_note("手绘轮廓转不出形状：%s" % why)
		_toast("手绘轮廓没刻成：%s" % why, true, 8.0)
		return
	var cells: Array = []
	for p in (r["cells"] as Dictionary).keys():
		cells.append(p)
	cells.sort_custom(_pos_less_xy)
	var extra := ""
	var clipped := int(r.get("clipped", 0))
	if clipped > 0:
		extra += "（有 %d 格落在盘外，已裁掉）" % clipped
	var w: Dictionary = _write_board_shape(cells, "手绘轮廓")
	_set_text_shape_note("手绘轮廓：%d 格%s" % [cells.size(), extra])
	if bool(w.get("ok", false)):
		_toast("已把手绘轮廓刻成棋盘：%d 格%s" % [cells.size(), extra], false, 6.0)


# ==================== 骨牌划分编辑器（文档 §5） ====================

func _build_domino_panel(box: VBoxContainer) -> void:
	box.add_child(_section_label("骨牌划分（1×2 骨牌铺满整盘）"))
	box.add_child(_plain_label("把整盘用 1×2 / 2×1 骨牌铺满；划分结果会**跟着关卡一起存**（别的变体也能分享它）。\n"
		+ "面积是奇数、洞格把区域割裂、或存在孤立格时会说明为什么铺不满（逐格给出坐标）。"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(_action_button("自动划分骨牌", _auto_partition_dominoes))
	row.add_child(_action_button("校验现有划分", _verify_dominoes))
	box.add_child(row)
	box.add_child(_action_button("清空骨牌划分", _clear_dominoes))
	_domino_note = _plain_label("")
	_domino_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_domino_note)
	_refresh_domino_note()


func _refresh_domino_note() -> void:
	if _domino_note == null or doc == null:
		return
	_domino_note.text = "骨牌划分：当前 %d 块（盖住 %d 格）。" % [
		doc.dominoes.count(), doc.dominoes.count() * 2]


## 自动划分。**有复合格时先拦**：文档「注意事项（复合格 × 变体）」写明骨牌不许跨复合格，
## 与其给一份半对的结果，不如说清为什么不做。
func _auto_partition_dominoes() -> void:
	if doc == null:
		return
	if doc.mega_cells != null and doc.mega_cells.count() > 0:
		_domino_note.text = "骨牌划分暂不支持：本关有 %d 个复合格（骨牌不许跨复合格，先拆开它们或换个变体）。" % doc.mega_cells.count()
		_toast("有复合格时不做骨牌划分", true, 6.0)
		return
	var rep: Dictionary = doc.dominoes.partition(doc.grid())
	if not bool(rep["ok"]):
		_domino_note.text = "自动划分失败：%s" % str(rep.get("reason", ""))
		_toast("骨牌划分失败：%s" % str(rep.get("reason", "")), true, 8.0)
		return
	var blocks: Array = rep["blocks"]
	var items: Array = []
	var next_id := 1
	for b in blocks:
		items.append({"id": next_id, "cells": b})
		next_id += 1
	_push_undo(false)
	doc.dominoes = DOMINO_MODEL.from_dict({
		"version": DOMINO_MODEL.VERSION, "next_id": next_id, "dominoes": items})
	_mark_dirty()
	_refresh_all()
	_domino_note.text = "已铺满：%d 块骨牌盖住整盘（已存进本关，可撤销）。" % blocks.size()
	_toast("骨牌划分完成：%d 块" % blocks.size())


func _verify_dominoes() -> void:
	if doc == null:
		return
	var blocks: Array = []
	for rec in doc.dominoes.dominoes():
		blocks.append((rec as Dictionary)["cells"])
	if blocks.is_empty():
		_domino_note.text = "还没有骨牌划分：先点「自动划分骨牌」。"
		_toast("还没有骨牌划分")
		return
	var rep: Dictionary = doc.dominoes.verify_partition(doc.grid(), null, blocks)
	if bool(rep["ok"]):
		_domino_note.text = "划分合法：%d 块，每格恰好被盖住一次，且每块都是相邻的 1×2/2×1。" % blocks.size()
		_toast("骨牌划分合法")
		return
	var first := str(rep.get("reason", ""))
	var errs: Array = rep.get("errors", [])
	if not errs.is_empty():
		first = str((errs[0] as Dictionary).get("text", first))
	_domino_note.text = "划分不合法：%s" % first
	_toast("骨牌划分不合法", true, 8.0)


func _clear_dominoes() -> void:
	if doc == null:
		return
	if doc.dominoes.count() == 0:
		_toast("现在没有骨牌划分")
		return
	_push_undo(false)
	doc.dominoes.clear_all()
	_mark_dirty()
	_refresh_all()
	_domino_note.text = "已清空骨牌划分。"
	_toast("已清空骨牌划分")


# ==================== 统计面板（文档 §9） ====================

func _build_stats_panel(box: VBoxContainer) -> void:
	box.add_child(_section_label("统计（雷密度 / 数字分布）"))
	_stats_note = _plain_label("")
	_stats_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_stats_note)


func _refresh_stats() -> void:
	if _stats_note == null or doc == null:
		return
	var lv := doc.to_level_json()
	var dens := HISTOGRAM.mine_density(lv)
	var h: Dictionary = HISTOGRAM.numbers_histogram([lv])
	var dens_text := "—" if dens < 0.0 else "%.1f%%" % (dens * 100.0)
	_stats_note.text = "雷密度：%s（%d 颗 / %d 格）\n数字分布：%s" % [
		dens_text, doc.mine_count(), doc.cell_count(), HISTOGRAM.describe(h)]


# ==================== 配色锁定（文档 §9「变体色锁定」） ====================
#
# 判据全在 `EditorDisclosure.lock_report`（同色组 ≥2 个**不同**变体即冲突；色码解析走 PaletteColor）。
# 登记落在 `custom.variant_colors`：`custom` 是**部分识别容器**（未知子键原样写回）⇒ 跟着关卡存/分享，
# 游戏侧不认识这个键也不会坏（core/editor_doc.gd 的 custom_passthrough 就是为这种"未来字段"留的）。

func _build_color_lock_panel(box: VBoxContainer) -> void:
	box.add_child(_section_label("配色锁定（一个颜色不许被两个变体共用）"))
	box.add_child(_plain_label("给变体登记颜色（色码如 RED / PINK_DARK，或 #ff8800）：同色被两个变体占用时下面会点名。\n"
		+ "登记写在关卡的 custom.variant_colors 里，跟着关卡一起存、一起分享。"))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_variant_id_edit = LineEdit.new()
	_variant_id_edit.custom_minimum_size = Vector2(88, 30)
	_variant_id_edit.placeholder_text = "变体 id"
	row.add_child(_variant_id_edit)
	_variant_color_edit = LineEdit.new()
	_variant_color_edit.custom_minimum_size = Vector2(88, 30)
	_variant_color_edit.placeholder_text = "色码"
	row.add_child(_variant_color_edit)
	box.add_child(row)
	box.add_child(_action_button("登记配色", _register_variant_color))
	_color_lock_note = _plain_label("")
	_color_lock_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_color_lock_note)
	_refresh_color_lock()


func _variant_colors() -> Dictionary:
	if doc == null:
		return {}
	var raw: Variant = doc.custom_passthrough.get("variant_colors", {})
	return raw if raw is Dictionary else {}


func _refresh_color_lock() -> void:
	if _color_lock_note == null or doc == null:
		return
	var colors := _variant_colors()
	if colors.is_empty():
		_color_lock_note.text = "还没有登记配色：现在没有两个变体抢同一个颜色。"
		return
	var rep: Dictionary = DISCLOSURE.lock_report(colors)
	if bool(rep["ok"]):
		_color_lock_note.text = "已登记 %d 个变体配色，各自唯一（没有冲突）。" % colors.size()
		return
	var lines: Array[String] = []
	for c in rep.get("conflicts", []):
		lines.append("%s 被这些变体共用：%s" % [
			str((c as Dictionary).get("color", "")), str((c as Dictionary).get("variants", []))])
	_color_lock_note.text = "⚠ 配色冲突：\n" + "\n".join(lines)


func _register_variant_color() -> void:
	if doc == null or _variant_id_edit == null or _variant_color_edit == null:
		return
	var id := _variant_id_edit.text.strip_edges()
	var code := _variant_color_edit.text.strip_edges()
	if id == "" or code == "":
		_toast("要先填「变体 id」和「色码」", true)
		return
	var colors := _variant_colors()
	colors[id] = code
	_push_undo(false)
	doc.custom_passthrough["variant_colors"] = colors
	_mark_dirty()
	_refresh_color_lock()
	_toast("已登记配色：%s → %s" % [id, code])


# ==================== 认证提交（文档 §8，本地队列） ====================
#
# 仓库没有网络层与账号体系 ⇒ 只做「入口 + 队列 + 流转状态」，文案写「已加入本地审核队列」，
# **不假装已上传官方**。状态机与落盘（原子替换）全在 `SubmissionQueue`。

func _refresh_submission() -> void:
	if _submit_note == null:
		return
	var loaded: Dictionary = SUBMISSION_QUEUE.load_items()
	_submit_note.text = SUBMISSION_QUEUE.status_text(loaded["items"])


func _submit_to_queue() -> void:
	if doc == null:
		return
	var note := _submit_note_edit.text if _submit_note_edit != null else ""
	var r: Dictionary = SUBMISSION_QUEUE.submit(doc.to_level_json(), note)
	if not bool(r["ok"]):
		_toast("加入审核队列失败：%s" % str(r.get("reason", "")), true, 8.0)
		_refresh_submission()
		return
	_toast("已加入本地审核队列：%s" % str(r["id"]), false, 6.0)
	_refresh_submission()


# ==================== 简单 / 专家渐进披露（文档「九」「十.6」） ====================
#
# 【默认档位的取舍·据此改过】文档建议"简单模式默认隐藏高级概念"，但本仓的界面回归用例是按
# "全部可见"写的（说明层要能扫到每个按钮、UI 覆盖率用例按可见按钮计数）。为避免一轮接线把既有
# 200+ 用例打红，这里**默认专家（全部可见）**，切到简单档才折叠 —— 折叠判据仍**单一来源**：
# `EditorDisclosure.visible_controls`（未知 id 默认可见 ⇒ 漏列的控件不会被误藏）。
## id → 按钮文字前缀（同一 id 可能有多个入口，如批量生成在主屏与左栏各有一个）。
const DISCLOSURE_BUTTONS := {
	"cheat_toggle": ["雷/线索："],
	"hotmap": ["猜点热力图："],
	"batch": ["批量生成关卡（按大小 × 档位）", "要做很多关？→ 批量生成关卡"],
	"template": ["从模板开始（新手照做就有一关）", "用这个模板（铺好棋盘）"],
}


func _toggle_editor_mode() -> void:
	_expert_mode = not _expert_mode
	_apply_disclosure()
	_toast("已切到%s" % ("专家模式：全部功能可见" if _expert_mode else "简单模式：进阶功能已折叠（再点一次切回来）"))


func _apply_disclosure() -> void:
	if _mode_btn != null:
		_mode_btn.text = "模式：专家（全部功能可见）" if _expert_mode else "模式：简单（进阶功能已隐藏）"
	var ids: Array = []
	for k in DISCLOSURE_BUTTONS.keys():
		ids.append(str(k))
	var vis: Array = DISCLOSURE.visible_controls(
		DISCLOSURE.EXPERT if _expert_mode else DISCLOSURE.SIMPLE, ids)
	for id in ids:
		var show := vis.has(id)
		for prefix in (DISCLOSURE_BUTTONS[id] as Array):
			for c in find_children("*", "Button", true, false):
				var b := c as Button
				if b != null and b.text.begins_with(str(prefix)):
					b.visible = show
			# 同名的分组标题一起折叠：否则只剩一个标题、下面空着（看着像坏了）。
			for c2 in find_children("*", "Label", true, false):
				var lb := c2 as Label
				if lb != null and lb.text == str(prefix):
					lb.visible = show

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
	# 按岛分别判定（W4）：单岛时 `verify_islands` 内部直接复用 `verify()`（与旧口径逐一一致），
	# 多岛时逐岛给结论。UI 只消费 state/label/reason/stats ⇒ 单岛显示与现在**完全一样**。
	# 【PerfLedger 接线 ①】如实上报本次验证的**实测墙钟耗时**（模块只存/合计，自己不测、不猜）。
	var _verify_t0 := Time.get_ticks_msec()
	var r := EditorVerify.verify_islands(doc)
	_perf.report_ms(PERF_LEDGER.JOB_VERIFY, float(Time.get_ticks_msec() - _verify_t0))
	# 【PerfLedger 接线 ①】下面这几行只是拼统计文本（纯 Label 赋值），也顺手记一下它的耗时（stats 活）。
	var _stats_t0 := Time.get_ticks_msec()
	# 先给"人话结论"（小白只看这一行就够），技术细节放下一行（保留，供作者/再交给 AI 时用）
	if _verify_plain != null:
		_verify_plain.text = _plain_conclusion(str(r["state"]))
	_verify_state.text = "%s\n%s" % [str(r["label"]), str(r["reason"])]
	var st: Dictionary = r["stats"]
	if _verify_stars != null:
		_verify_stars.text = _stars_line(st)
	if not st.is_empty():
		var sol := int(st.get("solutions", -1))
		# 去掉"后端 cpsat"这类黑话（stats 字典里仍保留 backend，测试要用）
		_verify_issues.add_child(_plain_label("推了 %d 轮 ｜ 开局已翻开 %d 格 ｜ 又推出安全格 %d ｜ 又推出雷 %d ｜ 雷的摆法有 %s 种 ｜ 用时 %d 毫秒" % [
			int(st.get("rounds", 0)), int(st.get("revealed_start", 0)), int(st.get("forced_safe", 0)),
			int(st.get("forced_mine", 0)), "未知" if sol < 0 else str(sol),
			int(st.get("elapsed_ms", 0))]))
		# 多岛：逐岛一行（"1 号岛 OK / 2 号岛需盲猜 3 次"）。单岛不加 —— 保持与旧显示一致。
		var islands: Array = st.get("islands", [])
		if islands.size() > 1:
			_verify_issues.add_child(_plain_label("按岛分别判定（共 %d 个岛）：" % islands.size()))
			for it in islands:
				_verify_issues.add_child(_plain_label(_island_line(it)))
	for it in r["issues"]:
		_verify_issues.add_child(_plain_label("· %s" % str((it as Dictionary)["text"])))
	_perf.report_ms(PERF_LEDGER.JOB_STATS, float(Time.get_ticks_msec() - _stats_t0))


## 单个岛的结论一行（"1 号岛：无需猜测可解（10 格 / 1 雷）"）。
func _island_line(it: Dictionary) -> String:
	var head := "%d 号岛：" % int(it.get("id", 0))
	var cells := int(it.get("cell_count", 0))
	var mines := int(it.get("mines", 0))
	var st := str(it.get("state", ""))
	var tail := ""
	match st:
		EditorVerify.STATE_NO_GUESS:
			tail = "OK（不用猜就能推完）"
		EditorVerify.STATE_NEEDS_GUESS:
			var g := int(it.get("guesses", -1))
			var left := int(it.get("left", -1))
			# guesses < 0 = 该岛走的是单岛旧路径（无逐岛盲猜计数）⇒ 只说"要猜"
			if g >= 0:
				tail = "需盲猜 %d 次（还有 %d 格推不出来）" % [g, left]
			else:
				tail = "需要盲猜"
		EditorVerify.STATE_CONTRADICTION:
			tail = "有逻辑矛盾"
		_:
			tail = "未能得出结论"
	return "%s%s ｜ %d 格 / %d 雷" % [head, tail, cells, mines]


## 难度星级行（W5）：`stars_of_steps` 吃推理轮数；旧三档文案（档位名）同时给出，不互相取代。
func _stars_line(st: Dictionary) -> String:
	if st.is_empty():
		return ""
	var rounds := int(st.get("rounds", 0))
	var stars := Difficulty.stars_of_steps(rounds)
	var tier := Difficulty.tier_of_peak(rounds)
	var tier_text := Difficulty.tier_short(tier) if tier != "" else "（未定档）"
	return "难度：%s（%d/5 星） ｜ 档位（按推理轮数近似）：%s ｜ 推理 %d 轮" % [
		Difficulty.stars_text(stars), stars, tier_text, rounds]


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


# ==================== 修复建议（RepairSuggest 接线） ====================
#
# 分工：候选搜索 / 副本试执行 / 复核 / `apply_plan` 全在 `core/repair_suggest.gd`（纯逻辑、已单测）。
# 本文件只负责：① 展示 1~3 条 + 一键应用；② **应用走撤销栈且一次只算一步**；③ 失败给可读文案。
# 【为什么要 async】`suggest()` 内部要跑多轮 verify（有墙钟预算），大棋盘上会卡住主线程 ⇒
# 与「开始验证」同一套做法：先禁用按钮、等一帧让"正在算"画出来，再算。

func _on_repair() -> void:
	if _repair_btn != null:
		_repair_btn.disabled = true
	_clear_repairs()
	_set_repair_msg("正在试各种修法…（棋盘越大越慢，请稍等）")
	await get_tree().process_frame
	var r: Dictionary = REPAIR_SUGGEST.suggest(doc)
	if _repair_btn != null:
		_repair_btn.disabled = false
	var sug: Array = r["suggestions"]
	if not bool(r["ok"]):
		_set_repair_msg("没给出建议：%s" % str(r["reason"]))
		_toast("修复建议：%s" % str(r["reason"]), true, 8.0)
		return
	if sug.is_empty():
		_set_repair_msg("这盘不用修：%s" % str(r["reason"]))
		return
	for s in sug:
		var sd: Dictionary = s
		_repair_plans.append(sd["plan"])
		_add_repair_row(sd, _repair_plans.size() - 1)
	var tail := "" if bool(r["exhaustive"]) else "（候选没搜完，不代表只有这些）"
	_set_repair_msg("给出 %d 条已复核的修法%s：点每条右边的「应用」。" % [sug.size(), tail])


func _set_repair_msg(text: String) -> void:
	if _repair_msg != null:
		_repair_msg.text = text


func _clear_repairs() -> void:
	_repair_plans.clear()
	if _repair_box == null:
		return
	# 同 `_refresh_issue_list`：`queue_free()` 延迟到帧末 ⇒ 必须立刻 `remove_child`。
	for c in _repair_box.get_children():
		_repair_box.remove_child(c)
		c.queue_free()


## 一行建议：人话说明 + 「应用」。按**索引**回调 ⇒ 列表刷新（`_clear_repairs`）后过期索引会显式报错，
## 不会拿旧 plan 去改一份已经变了的文档。
func _add_repair_row(s: Dictionary, idx: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lb := _plain_label(str(s["text"]))
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lb)
	var btn := _action_button("应用", func() -> void: _apply_repair(idx))
	btn.tooltip_text = "把这条修法写进关卡（只算一步撤销）"
	row.add_child(btn)
	_repair_box.add_child(row)


## 「一键应用」：先按当前文档复核 plan 是否还成立（不成立就不动文档、不留空撤销步），
## 再 `_push_undo(false)` + `RepairSuggest.apply_plan`（core 侧落笔前先校验，无半途状态）。
func _apply_repair(idx: int) -> void:
	if idx < 0 or idx >= _repair_plans.size():
		_set_repair_msg("这条建议已过期（盘面变过）：请重新点「给我修复建议」。")
		return
	var plan: Dictionary = _repair_plans[idx]
	var why := _repair_plan_reason(plan)
	if why != "":
		_set_repair_msg("这条修法现在不适用：%s\n（请重新点「给我修复建议」）" % why)
		_toast("这条修法现在不适用：%s" % why, true, 7.0)
		return
	_push_undo(false)                     # 一步：改动前快照
	var r: Dictionary = REPAIR_SUGGEST.apply_plan(doc, plan)
	if not bool(r["ok"]):
		# 复核失败不该留下"什么都没做"的一步：把这步撤掉，保持撤销栈/重做链干净。
		if not _undo.is_empty():
			_undo.pop_back()
		_set_repair_msg("应用失败（未改动关卡）：%s" % str(r["reason"]))
		_toast("应用失败：%s" % str(r["reason"]), true, 8.0)
		return
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()
	_clear_repairs()
	_set_repair_msg("已应用这条修法：%s\n（按左栏「撤销」可一步退回；下面是重跑验证的结果）" % str(r["reason"]))
	await _on_verify()


## plan 在当前文档上是否还成立：判据唯一来源 = `RepairSuggest.can_apply()`（提前问一句才不会白记一步撤销）。
func _repair_plan_reason(plan: Dictionary) -> String:
	# 【2026-10-03 收口：判据只有一份】此前这里抄了 `RepairSuggest._apply` 的同样 5 条判据，理由是
	# "不适用就不该白记一步撤销"（动机对，但两份真相会漂移：改一处忘另一处 ⇒ UI 说能修而 core 拒绝）。
	# 现在判据收进 `core/repair_suggest.gd:can_apply()`（公开纯函数、纯读无副作用），UI 只转发原因。
	var r: Dictionary = REPAIR_SUGGEST.can_apply(plan, doc)
	return "" if bool(r["ok"]) else str(r["reason"])


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


# ==================== 存档占用锁（文档 §8「防事故」前半） ====================
#
# 【要解决什么】两个编辑器窗口同时保存同一关 ⇒ 后写者**静默**覆盖前者（原子替换只保证不写坏文件，
#   不保证「谁的内容」）。这里把「谁在写」变成**在场可见**：别人正开着 ⇒ 本窗口只读打开。
# 【锁粒度】存档平铺在 user://editor，锁这个目录会误伤「编辑别的关」的另一个窗口；
#   所以每份存档锁**自己的隐藏同名子目录**：user://editor/.<存档名>.lock/.level.lock。
#   锁文件只是提示 + 互斥，不含关卡数据；用户删掉它等同强制解锁（可接受，见 file_lock.gd 文件头）。
# 【崩溃不锁死】锁带 TTL（900 秒），过期即视为陈旧、后来者可直接回收 ⇒ 不需要人工清锁。

func _lock_owner_id() -> String:
	# 所有者标识：进程号 + 启动时刻。同一进程内的多个编辑器共用（它们本来就同生共死），
	# 不同进程一定不同 —— 这才是要区分的那一维。
	if _lock_owner == "":
		_lock_owner = "editor-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()]
	return _lock_owner


## 某份存档对应的**锁目录**（隐藏同名子目录；注意不是存档文件所在目录）。
func _lock_dir_for(path: String) -> String:
	if path.strip_edges().is_empty():
		return ""
	return "%s/.%s.lock" % [path.get_base_dir(), path.get_file()]


## 可读的占用说明：acquire / peek 的 reason 已经是人话，这里只兜底。
func _lock_conflict_text(rec: Dictionary) -> String:
	var s := str(rec.get("reason", ""))
	return s if s != "" else "该存档正被其它窗口占用"


## 确保本会话持有该存档的锁；**换目标文件时先释放旧锁**（不占着不放）。
## 返回 LOCK.acquire 的原样结果：{ok, reason, ...}。
func _ensure_lock(path: String) -> Dictionary:
	var dir := _lock_dir_for(path)
	if dir == "":
		return {"ok": false, "reason": "存档路径为空，无法加锁"}
	if dir == _locked_dir:
		# 同一份存档重复保存：acquire 对同 owner 直接放行并续期（TTL 重新计时）。
		return LOCK.acquire(dir, _lock_owner_id())
	if _locked_dir != "":
		LOCK.release(_locked_dir, _lock_owner_id())
		_locked_dir = ""
	var rec := LOCK.acquire(dir, _lock_owner_id())
	if bool(rec.get("ok", false)):
		_locked_dir = dir
	return rec


func _release_lock() -> void:
	if _locked_dir == "":
		return
	LOCK.release(_locked_dir, _lock_owner_id())
	_locked_dir = ""


## 退出时释放锁：不释放的话，下一个窗口要等满 TTL（15 分钟）才能接管。
func _exit_tree() -> void:
	_release_lock()


# ==================== 缩略图（文档 §8「防事故」后半） ====================

## 缩略图 sidecar 路径：<存档>.thumb.json（与存档同目录，便于随存档一起被看见 / 备份）。
## 注意：分享包由 WorkshopPack 按 doc 现算生成、**不扫目录**，所以 sidecar 不会被误当成关卡打进包里。
func _thumb_path_for(path: String) -> String:
	if path.strip_edges().is_empty():
		return ""
	return "%s/%s.thumb.json" % [path.get_base_dir(), path.get_file()]


## 缩略图输入层：**只要**尺寸 + 雷位 + 初始翻开位。
## 不经 doc.to_level_json()：那个会展开派生 topology（64×64 环绕盘上是 MB 级），而本函数每次编辑
## 都要跑 ⇒ 自建这个最小结果层（字段名与关卡 JSON 一致，LevelThumbnail 原样认）。
func _thumb_layer() -> Dictionary:
	var ms: Array = []
	for m in doc.mines:
		ms.append({"r": m.y, "c": m.x})
	var rv: Array = []
	for p in doc.revealed:
		rv.append({"r": p.y, "c": p.x})
	return {"size": {"rows": doc.rows, "cols": doc.cols}, "mines": ms, "revealed": rv}


## 保存成功后写一份缩略图 sidecar。**失败绝不影响存档**（缩略图只是辅助显示）。
func _write_thumb_sidecar(path: String) -> void:
	var tp := _thumb_path_for(path)
	if tp == "" or doc == null:
		return
	var thumb := THUMB.build(_thumb_layer())
	if not bool(thumb.get("ok", false)):
		return          # 生成不出来（尺寸非法等）就不写，也不打扰用户
	var f := FileAccess.open(tp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(THUMB.to_dict(thumb), "  "))
	f.close()


## 刷新缩略图预览（当前编辑内容 → 小图）。编辑中随时可看，不必先保存。
func _refresh_thumb_preview() -> void:
	if _thumb_view == null or doc == null:
		return
	var thumb := THUMB.build(_thumb_layer())
	if not bool(thumb.get("ok", false)):
		_thumb_view.clear()
		if _thumb_note != null:
			_thumb_note.text = "（缩略图：— %s）" % str(thumb.get("reason", "无法生成"))
		return
	# 指纹没变就不重设（避免每次全量刷新都 queue_redraw，白白重绘）。
	if _thumb_view.has_thumb() and _thumb_view.thumb_hash() == str(thumb.get("hash", "")):
		return
	_thumb_view.set_thumb(thumb)
	if _thumb_note != null:
		var cut := ""
		if bool(thumb.get("cropped", false)):
			cut = "（已裁到 %d×%d，原 %d×%d）" % [
				int(thumb["rows"]), int(thumb["cols"]), int(thumb["src_rows"]), int(thumb["src_cols"])]
		_thumb_note.text = "缩略图：%d×%d 格%s；雷 %d 颗、初始翻开 %d 格" % [
			int(thumb["rows"]), int(thumb["cols"]), cut, doc.mine_count(), doc.revealed.size()]


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var path := _target_save_path()

	# 【文档 §8·防事故】只读打开（打开时别人正开着）⇒ 不许覆盖；要留改动只能改标题另存。
	if _read_only and (_read_only_path == "" or _read_only_path == path):
		_toast("这份存档正被别的窗口占用，当前是**只读**打开。\n想保留改动：改一下标题再点保存，会存成新文件。",
			true, 6.0)
		return
	# 【文档 §8·防事故】写盘前拿锁：拿不到就**拦下保存**并说清谁在占（绝不静默覆盖别人）。
	var lk := _ensure_lock(path)
	if not bool(lk.get("ok", false)):
		_toast("保存被拦下：%s" % _lock_conflict_text(lk), true, 6.0)
		return
	# 【清单·一「保存」注意事项】原来手动保存是**直写**目标文件：写到一半崩/断电就留下半截 JSON，
	# 用户下次打开就是坏档。清单明确要求"复用游戏本体那套防损坏写入（临时文件→替换），
	# 编辑器不能自己发明一套"。这里与 `_write_autosave()`、以及游戏本体的
	# `ui/save_coordinator.gd`（TEMP→BAK→MAIN）走同一套**原子写**：先写 `.tmp`，再改名替换。
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_toast("保存失败：%s" % path, true)
		return
	f.store_string(JSON.stringify(doc.to_level_json(), "  "))
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)      # 别留半截临时文件在存档目录里
		_toast("保存失败（新内容没能替换旧文件，错误码 %d）" % err, true, 6.0)
		return
	_current_path = path
	_dirty = false
	# 自己保存过 ⇒ 之后不再按只读处理（文件是我写的，锁也在我手上）。
	_read_only = false
	_read_only_path = ""
	_refresh_open_list()
	# 缩略图 sidecar：给别人 / 给未来的自己一眼认出这份存档是什么样（写失败不影响存档本身）。
	_write_thumb_sidecar(path)
	_refresh_thumb_preview()
	# 只说文件名 + 去哪儿找：原来把 user://editor/level.json 直接甩给用户，小白既看不懂也找不到
	_toast("已保存：%s\n（在左栏「打开存档文件夹」里能看到这个文件；缩略图 %s）" % [
		path.get_file(), _thumb_path_for(path).get_file()], false, 5.0)


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
	# 占位项（item_count==1 但 disabled）也不能被当成可打开的存档。
	if _open_opt.item_count == 0 or _open_opt.is_item_disabled(_open_opt.selected):
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
	# 【文档 §8·防事故】打开前先**只读探测**（peek 不写盘、不抢锁）：别人正开着 ⇒ 本次按只读打开
	#（能看 / 试玩；保存时会被拦下并提示改标题另存 —— 把别人赶走不是编辑器该做的事）。
	var probe := LOCK.peek(_lock_dir_for(path))
	var held := bool(probe.get("held", false)) and not bool(probe.get("stale", false))
	var holder := str(probe.get("owner", ""))
	if held and holder != "" and holder != _lock_owner_id():
		_read_only = true
		_read_only_path = path
		_toast("这份存档正被别的窗口占用，已按**只读**打开（改动只能改标题另存）。", false, 6.0)
	else:
		_read_only = false
		_read_only_path = ""
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
	# 【清单·数据爆炸 I「输入侧异常大数」】粘贴/导入的内容可能是**合法但巨大**的（声明 10 万格）
	# ⇒ 加载即卡死。玩家侧加载器早就有这套闸门，编辑器却绕开了 ⇒ 这里分两道补上，且**先看字节数**
	#（先于解析：巨大文本连 parse_json 都不该跑）。
	var gate := LevelGuardRef.check_text(text)
	if not bool(gate["ok"]):
		_toast("导入被拒：%s" % str(gate["reason"]), true, 7.0)
		return false
	# 安全解析：粘贴/导入的内容读不懂是常态（用户会粘错东西），不该刷 ERROR 日志
	var parsed: Variant = SpecHelper.parse_json_safe(text)
	if not (parsed is Dictionary):
		return false
	# 第二道：看**声明的规模**（尺寸/雷位/障碍/初始翻开），超限直接拒（宁可不导入，也不让编辑器卡死）
	var gate2 := LevelGuardRef.check_level(parsed as Dictionary)
	if not bool(gate2["ok"]):
		_toast("导入被拒：%s" % str(gate2["reason"]), true, 7.0)
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


# ==================== 短码分享（ShareCode 接线） ====================
#
# 分工：编码 / 解码 / 分级 / 校验全在 `core/share_code.gd`（纯本地运算、绝不抛异常，已单测）。
# 本文件只负责：① 导出到剪贴板并回填输入框；② 导入前先过编辑器自己的规模闸门；
# ③ 任何失败都给**可读原因**（toast + 常驻说明行），不静默、不崩。

## 导出短码。含自定义形状 / 自由几何 / 大棋盘时 `ShareCode` 会给可读原因并建议走文件。
func _export_share_code() -> void:
	var r: Dictionary = SHARE_CODE.encode(doc.to_level_json())
	if not bool(r["ok"]):
		_set_share_note("这份关卡做不成短码：%s" % str(r["reason"]))
		_toast("短码导出失败：%s" % str(r["reason"]), true, 8.0)
		return
	var code := str(r["code"])
	if _share_edit != null:
		_share_edit.text = code
	var copied := _clipboard_available()
	if copied:
		DisplayServer.clipboard_set(code)
	_set_share_note("%s（载荷 %d 字节，码长 %d 字符）：贴到聊天窗口，"
		% ["短码已复制到剪贴板" if copied else "短码已生成（本机没有剪贴板，请手动复制上面的码）",
			int(r["bytes"]), code.length()]
		+ "对方粘进上面的框点「载入短码」就能玩。")
	_toast("短码已%s（%d 个字符）" % ["复制到剪贴板" if copied else "生成", code.length()], false, 5.0)


## 当前显示后端有没有剪贴板。**headless（CI / 无头）没有**，此时调 `clipboard_get()` 会让引擎打
## ERROR（实测会污染测试）⇒ 先问一句，没有就只给可读提示。
func _clipboard_available() -> bool:
	return DisplayServer.get_name() != "headless"


## 导入短码。输入框为空时退回剪贴板；非法码一律给可读原因（`ShareCode.decode` 绝不抛异常）。
func _import_share_code() -> void:
	var text := _share_edit.text.strip_edges() if _share_edit != null else ""
	if text == "" and _clipboard_available():
		text = DisplayServer.clipboard_get().strip_edges()
	if text == "":
		_set_share_note("还没短码：把别人给的短码粘到上面的框里（或先复制到剪贴板），再点「载入短码」。")
		_toast("没有短码可载入", true, 5.0)
		return
	var r: Dictionary = SHARE_CODE.decode(text)
	if not bool(r["ok"]):
		_set_share_note("这不是一条能用的短码：%s" % str(r["reason"]))
		_toast("短码不能用：%s" % str(r["reason"]), true, 8.0)
		return
	var lv := _share_level_to_doc_json(r["level"])
	var gate := LevelGuardRef.check_level(lv)
	if not bool(gate["ok"]):
		_set_share_note("短码内容超出编辑上限：%s" % str(gate["reason"]))
		_toast("短码内容超出编辑上限：%s" % str(gate["reason"]), true, 8.0)
		return
	# 载入 = 换一份"新东西"：一步撤销 + 断掉当前文件路径（别让下次保存覆盖原来那份）
	_push_undo(false)
	var lr: Dictionary = doc.load_from(lv)
	if not bool(lr["ok"]):
		if not _undo.is_empty():
			_undo.pop_back()      # 失败不该留一步"什么都没做"的撤销
		_set_share_note("短码内容读不出来：%s" % str(lr["reason"]))
		_toast("短码内容读不出来：%s" % str(lr["reason"]), true, 8.0)
		return
	_current_path = ""
	_doc_to_ui()
	_mark_dirty()
	_refresh_all()
	_set_share_note("已载入短码：%d×%d、%d 颗雷（撤一步可退回原关卡）。" % [
		doc.cols, doc.rows, doc.mine_count()])
	_toast("已载入短码关卡：可以直接试玩", false, 5.0)


## 短码解出的关卡 → `EditorDoc.load_from` 认识的口径。
## `ShareCode` 把规则放在 `rule` 段（{id, level, spec}），而 `EditorDoc` 读的是
## `clue_rule` / `rule_level` / `custom.spec` ⇒ 这里做一次**显式映射**，不让规则在导入时静默丢掉。
func _share_level_to_doc_json(level: Dictionary) -> Dictionary:
	var out := level.duplicate(true)
	var rule: Variant = out.get("rule", null)
	if rule is Dictionary:
		var rd: Dictionary = rule
		out.erase("rule")
		if str(rd.get("id", "")) != "":
			out["clue_rule"] = str(rd["id"])
			out["rule_level"] = true
		if rd.get("spec", null) is Dictionary and not (rd["spec"] as Dictionary).is_empty():
			var custom: Dictionary = {}
			if out.get("custom", null) is Dictionary:
				custom = (out["custom"] as Dictionary).duplicate(true)
			custom["spec"] = (rd["spec"] as Dictionary).duplicate(true)
			out["custom"] = custom
			out["rule_level"] = true
	return out


func _set_share_note(text: String) -> void:
	if _share_note != null:
		_share_note.text = text


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


## 「试玩」按钮：整场景切换（等同正式游戏，HUD 里有「回编辑器」）。
func _playtest() -> void:
	if not _prepare_play_session():
		return
	# 留下回程（2026-10-02 用户反馈："点完试玩就回不来" —— 游戏侧 HUD 唯一的出口是「关卡列表」→ 选关页）。
	# 游戏 HUD 与结算层见到它非空就多显示一个「回编辑器」；正式发售的游戏里它一直是空串。
	GameSession.playtest_return = PLAYTEST_RETURN
	get_tree().change_scene_to_file("res://ui/board_view.tscn")


## 试玩前的公共准备：校验 → 注册规则 → **显式存一手** → 写试玩文件 → 启动会话。
## 【为什么要先存一手】自动存档只在"改动后空闲 1.2 秒"才写；`_playtest` 会切场景销毁编辑器节点，
## 而 `_enter_playtest`（Tab 秒切）则留在本场景 —— 两条路都先把改动落盘/落内存，切回必然不丢。
func _prepare_play_session() -> bool:
	var rep := doc.validate()
	if not bool(rep["ok"]):
		var first := ""
		for it in rep["errors"]:
			first = str((it as Dictionary)["text"])
			break
		_toast("先修好这些问题再试玩：%s" % first, true)
		return false
	var reg := doc.register_rule()
	if not bool(reg["ok"]):
		_toast("规则注册失败：%s" % str(reg["reason"]), true)
		return false
	_write_autosave()
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var f := FileAccess.open(PLAY_PATH, FileAccess.WRITE)
	if f == null:
		_toast("无法写入试玩文件", true)
		return false
	f.store_string(JSON.stringify(doc.to_level_json(), "  "))
	f.close()
	if not GameSession.start_level(PLAY_PATH):
		_toast("试玩加载失败（关卡数据被加载器拒绝）", true)
		return false
	return true


# ==================== Tab 编辑↔试玩秒切（文档「二」） ====================

## Tab：**不切场景**，把棋盘作为一个覆盖层内嵌进编辑器 ⇒ 秒切、编辑器状态（撤销栈/文档/面板）
## 原样留在内存里，切回连 1 ms 都不用等。真正的游戏（HUD/结算/回程）全由 `board_view.tscn` 承担。
## 平台没接好/加载失败时退化成整场景切换（绝不让 Tab "点了没反应"）。
func _toggle_playtest() -> void:
	if _play_overlay != null and is_instance_valid(_play_overlay):
		_exit_playtest()
	else:
		_enter_playtest()


func _enter_playtest() -> void:
	if not _prepare_play_session():
		return
	# 试玩显示的是**整盘**（游戏里没有"下钻"这回事）⇒ 记下当前下钻视图、先退回顶层；
	# 回编辑时再用 core 的 codec 原样还回去（`drill_to_dict` / `drill_from_dict` 往返）。
	_mega_drill_saved = _mega_drill_snapshot()
	_mega_drill = MEGA_CELL.drill_state()
	GameSession.playtest_return = PLAYTEST_RETURN
	var scene: PackedScene = load("res://ui/board_view.tscn")
	if scene == null:
		# 退化路径：内嵌不了就照旧整场景切（行为与「试玩」按钮一致）
		get_tree().change_scene_to_file("res://ui/board_view.tscn")
		return
	var layer := CanvasLayer.new()
	layer.name = "内嵌试玩"
	layer.layer = 50                      # 压在编辑器所有层之上
	layer.add_child(scene.instantiate())
	add_child(layer)
	_play_overlay = layer
	# 状态机切到"试玩态"：作弊信息（雷/线索）**强制隐藏**，且这是唯一判据
	_view_state.set_mode(VIEW_STATE.MODE_PLAY)
	_apply_cheat_visibility()
	_toast("已进入试玩（再按 Tab 回到编辑，改动都在）", false, 4.0)


func _exit_playtest() -> void:
	if _play_overlay != null and is_instance_valid(_play_overlay):
		_play_overlay.queue_free()
	_play_overlay = null
	GameSession.playtest_return = ""
	_view_state.set_mode(VIEW_STATE.MODE_EDIT)
	_apply_cheat_visibility()
	# 回到编辑：把进试玩时暂存的下钻视图还回去（走 core 的 codec，界面随后由 _refresh_all 同步）。
	if not _mega_drill_saved.is_empty():
		_mega_drill_restore(_mega_drill_saved)
	_refresh_all()
	_toast("已回到编辑（改动没有丢）")


func _back_to_select() -> void:
	_write_autosave()
	get_tree().change_scene_to_file("res://ui/level_select.tscn")


# ==================== 自动保存（原子写） ====================

func _write_autosave() -> void:
	# 【PerfLedger 接线 ①】上报本次"序列化 + 原子写盘"的实测耗时（含失败路径，别把失败算成 0）。
	var _auto_t0 := Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(EDITOR_DIR)
	var tmp := AUTOSAVE_PATH + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_perf.report_ms(PERF_LEDGER.JOB_AUTOSAVE, float(Time.get_ticks_msec() - _auto_t0))
		return
	f.store_string(JSON.stringify(doc.to_level_json(), "  "))
	f.close()
	# 三段式原子写：先写 tmp 再改名，避免断电/崩溃留下半截文件
	DirAccess.rename_absolute(tmp, AUTOSAVE_PATH)
	_dirty = false
	_perf.report_ms(PERF_LEDGER.JOB_AUTOSAVE, float(Time.get_ticks_msec() - _auto_t0))


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


# ==================== 快捷键全套（文档「二」） ====================
#
# 【为什么用 `_input` 而不是 `_unhandled_key_input`】两件事必须**抢在 GUI 之前**：
#   ① Tab 秒切 —— 不抢的话 Godot 会把它当"焦点导航"，焦点在控件之间乱跳，秒切根本不触发；
#   ② Alt+点击吸管 —— 不抢的话画布会先把它当"画笔落一格"（`editor_canvas._gui_input` 不看修饰键）。
# 键盘监听归编辑器（界面层），画布只收结果（与 `set_pan_mode` 的分工一致）。
# 【纪律】焦点在文本框里时**一律不抢**：否则在「关卡名字」里打 `b` 会切工具、打 `1` 会换格型。

func _input(event: InputEvent) -> void:
	# 【试玩态】只保留一个属于编辑器的键：Tab（回编辑）。其余键鼠**一律不抢** ——
	# 内嵌的 `board_view` 要用空格/R/方向键（翻开、重开、移动），编辑器若把它们吃掉，
	# 试玩里按 R 会变成"在覆盖层背后随机布雷"（真 bug，不是理论风险）。Tab 要抢：
	# 否则游戏侧没人处理 Tab，玩家回不到编辑态。
	if _view_state.is_play():
		if event is InputEventKey and (event as InputEventKey).pressed \
				and not (event as InputEventKey).echo \
				and _bindings.action_for_event(event as InputEventKey) == "playtest_toggle":
			_toggle_playtest()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		if _handle_mouse_shortcut(event as InputEventMouseButton):
			get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.echo:
		return
	var action := _bindings.action_for_event(k)
	# 空格**抬起**必须在文本焦点之前处理：否则"按空格进平移 → 点进输入框 → 松空格"会让平移态卡住不恢复。
	if not k.pressed and action == "pan_mode":
		if canvas != null:
			canvas.set_pan_mode(false)
		get_viewport().set_input_as_handled()
		return
	if _text_focus_active():
		return
	if action == "":
		return
	if action == "pan_mode":
		# 空格是**按住/抬起**两态：按住 = 左键拖动变成平移，抬起恢复（见 `canvas.set_pan_mode`）
		if canvas != null:
			canvas.set_pan_mode(k.pressed)
		get_viewport().set_input_as_handled()
		return
	if not k.pressed:
		return
	if action == "help" and _help_layer != null:
		_close_help()                        # F1 = 上下文帮助开关（开着再按就收起）
		get_viewport().set_input_as_handled()
		return
	_dispatch(action)
	get_viewport().set_input_as_handled()


## Alt+点击吸管：吸取该格的格型作为当前画笔（不改任何数据）。
func _handle_mouse_shortcut(mb: InputEventMouseButton) -> bool:
	if not mb.pressed or canvas == null or doc == null:
		return false
	if not _bindings.matches_mouse("eyedropper", mb):
		return false
	return _eyedropper_at(canvas.pos_at(canvas.get_local_mouse_position()))


## 焦点是否在文本控件上（在就一律不抢按键 —— 见上面的纪律）。
func _text_focus_active() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var fo := vp.gui_get_focus_owner()
	return fo is LineEdit or fo is TextEdit


## 快捷键动作分发（唯一入口：键盘、按钮、测试都走它）。
func _dispatch(action: String) -> void:
	if action.begins_with("digit_"):
		_digit(int(action.substr(6)))
		return
	match action:
		"playtest_toggle": _toggle_playtest()
		"panel_focus": _cycle_panel_tab()
		"grid_toggle": _toggle_grid()
		"symmetry_cycle": _cycle_symmetry()
		"cheat_toggle": _toggle_cheats()
		"tool_brush": _set_tool(EditorCanvas.Tool.PAINT)
		"tool_erase": _set_tool(EditorCanvas.Tool.ERASE)
		"tool_pan": _set_tool(EditorCanvas.Tool.PAN)
		"tool_select": _set_tool(EditorCanvas.Tool.SELECT)
		# 文档语义：M=放雷、S=强制安全格（= 初始已翻开）。功能不新造数据结构，复用现成格型。
		"kind_mine": _set_kind(EditorCanvas.KIND_MINE)
		"kind_safe": _set_kind(EditorCanvas.KIND_REVEAL)
		"undo": _undo_once()
		"redo": _redo_once()
		"copy": _copy_selection()
		"cut": _cut_selection()
		"paste": _paste_selection()
		"duplicate": _duplicate_selection()
		"save": _save()
		"rotate_selection": _rotate_selection()
		"mirror_selection": _mirror_selection()
		"random_mines": _random_mines()
		"reset_view": _reset_view()
		"help": _toggle_help()
		_: pass


## 数字直选 1~9：① ~ ⑦ = 工具（按 `EditorCanvas.Tool` 顺序），⑧⑨ = 最常用的两个格型。
## 【为什么是"工具+格型"而不是"数字 N 格型"】本仓 `EditorDoc.revealed` 的值恒为 null（线索数字由
## `preview_clues()` 重算，见 core/editor_doc.gd:57）⇒ **没有**"每格存一个数字"的数据结构；
## 文档要的"1~9 直接刷"在此落成"1~9 直选画笔/格型槽位"，不新造字段（团队口径）。
func _digit(n: int) -> void:
	match n:
		1: _set_tool(EditorCanvas.Tool.PAINT)
		2: _set_tool(EditorCanvas.Tool.ERASE)
		3: _set_tool(EditorCanvas.Tool.RECT_FILL)
		4: _set_tool(EditorCanvas.Tool.SELECT)
		5: _set_tool(EditorCanvas.Tool.PAN)
		6: _set_tool(EditorCanvas.Tool.LINE)
		7: _set_tool(EditorCanvas.Tool.BUCKET)
		8: _set_kind(EditorCanvas.KIND_MINE)
		9: _set_kind(EditorCanvas.KIND_OBSTACLE)
		_: pass


## 切工具并**同步左栏互斥按钮的高亮**（否则按键切了、界面还亮着旧的，界面在骗人）。
func _set_tool(p_tool: int) -> void:
	if canvas == null:
		return
	canvas.tool = p_tool
	# 按 meta 里的工具 id 高亮，**不按按钮下标**：LINE / BUCKET 是键盘专用（没有按钮），
	# 一旦再补按钮（本轮补的 OUTLINE），"下标 = 工具号"就会静默点错工具。
	for b in _tool_btns:
		var btn := b as Button
		btn.button_pressed = int(btn.get_meta("tool_id", -1)) == p_tool
	_toast("工具：%s" % _tool_name(p_tool))


func _tool_name(t: int) -> String:
	var names := ["画笔", "橡皮", "矩形填充", "区域选择", "平移", "直线", "油漆桶", "手绘轮廓"]
	return names[t] if t >= 0 and t < names.size() else "?"


func _set_kind(p_kind: String) -> void:
	if canvas == null:
		return
	canvas.paint_kind = p_kind
	var idx := _kind_index(p_kind)
	for i in _kind_btns.size():
		(_kind_btns[i] as Button).button_pressed = (i == idx)
	_toast("格型：%s" % _kind_name(p_kind))


func _kind_index(k: String) -> int:
	match k:
		EditorCanvas.KIND_MINE: return 0
		EditorCanvas.KIND_OBSTACLE: return 1
		EditorCanvas.KIND_REVEAL: return 2
		EditorCanvas.KIND_CLEAR: return 3
	return -1


func _kind_name(k: String) -> String:
	match k:
		EditorCanvas.KIND_MINE: return "地雷"
		EditorCanvas.KIND_OBSTACLE: return "障碍"
		EditorCanvas.KIND_REVEAL: return "初始已翻开"
		EditorCanvas.KIND_CLEAR: return "清空该格"
	return "?"


## G：网格线开关（走画布现成的 `set_show_grid`）。
func _toggle_grid() -> void:
	if canvas == null:
		return
	var on := not canvas.show_grid
	canvas.set_show_grid(on)
	if _grid_btn != null:
		_grid_btn.button_pressed = on
	_toast("网格线：%s" % ("开" if on else "关"))


## Ctrl+G：对称模式循环 关 → 竖轴 → 横轴 → 四象。
func _cycle_symmetry() -> void:
	_sym_mode = (_sym_mode + 1) % 4
	_refresh_sym_btn()
	_toast("对称：%s" % _sym_label(_sym_mode))


func _sym_label(m: int) -> String:
	match m:
		1: return "竖轴镜像"
		2: return "横轴镜像"
		3: return "四象（双轴 + 对角）"
	return "关"


func _refresh_sym_btn() -> void:
	if _sym_btn != null:
		_sym_btn.text = "对称：%s" % _sym_label(_sym_mode)


## 对称镜像目标格（纯函数：只读 `doc.cols/rows` 与 `_sym_mode`，可单测）。
func _symmetry_cells(pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if doc == null:
		return out
	var mx := doc.cols - 1 - pos.x
	var my := doc.rows - 1 - pos.y
	var cand: Array[Vector2i] = []
	match _sym_mode:
		1: cand = [Vector2i(mx, pos.y)]
		2: cand = [Vector2i(pos.x, my)]
		3: cand = [Vector2i(mx, pos.y), Vector2i(pos.x, my), Vector2i(mx, my)]
		_: cand = []
	for p in cand:
		if p != pos and not out.has(p):
			out.append(p)
	return out


## 把刚改的一格镜像到对称位置。**只服务单格手势**（画笔/橡皮）：矩形填充 / 直线 / 油漆桶
## 各有批量语义，镜像它们会让"一步撤销"变成一大片、且与用户的预期（画一片矩形）冲突，故明确不做。
## 返回实际镜像到的格（调用方要顺手刷新这些格的线索预览）。判界一律问 `doc.grid().in_board`。
func _apply_symmetry(pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _sym_mode == 0 or canvas == null or doc == null:
		return out
	if canvas.tool != EditorCanvas.Tool.PAINT and canvas.tool != EditorCanvas.Tool.ERASE:
		return out
	var kind := canvas.cell_kind(pos)
	for p in _symmetry_cells(pos):
		if doc.grid().in_board(p):
			canvas.apply_kind(p, kind)     # 唯一写入口：自带 diff 记账（见 editor_canvas.apply_kind）
			out.append(p)
	return out


## 编辑/试玩两态的"作弊信息"总闸：**只读统一状态机**，不在这里自己拼条件。
func _apply_cheat_visibility() -> void:
	var on := _view_state.is_cheat_visible()
	if _cheat_btn != null:
		_cheat_btn.button_pressed = on
		# 文案写"当前状态"而不是"点了会怎样"：开关按钮的按下态本身就是"开"，文案再写命令会互相打架。
		_cheat_btn.text = "雷/线索：显示（编辑态）" if on else "雷/线索：隐藏（编辑态）"
	# 画布目前没有"显雷"接口（`editor_canvas.gd:_draw` 恒从 `doc.mine_set()` 画雷）⇒
	# 有则转发（duck-typing），没有就先把状态记在统一状态机里、由状态栏如实反映。
	if canvas != null and canvas.has_method("set_show_mines"):
		canvas.call("set_show_mines", on)
	# 热力图归**同一个判据**：试玩态强制隐藏（本文件不许自己拼 `mode == ...`）。
	_apply_hotmap_visibility()


func _toggle_cheats() -> void:
	_view_state.toggle_cheats()
	_apply_cheat_visibility()
	_toast("已隐藏雷/线索（编辑态）" if not _view_state.cheats_on else "已显示雷/线索（编辑态）", false, 3.0)


## Ctrl+Tab：切到右侧下一块面板（Tab 已被秒切占用，焦点切换只能走 Ctrl+Tab）。
func _cycle_panel_tab() -> void:
	var tabs := _right_tabs()
	if tabs == null or tabs.get_tab_count() <= 0:
		return
	tabs.current_tab = (tabs.current_tab + 1) % tabs.get_tab_count()
	# 不 `grab_focus()`：TabContainer 默认 focus_mode = NONE，抓焦点会被引擎拒（真机/CI 都会报错）。
	# 快捷键由 `_input` 全局分发，本来就不依赖焦点在容器上。
	_toast("面板：%s" % tabs.get_tab_title(tabs.current_tab))


## Ctrl+0：重置视图（缩放与平移归位；编辑内容不动）。【2026-10-03】原 Ctrl+R 让给「选区镜像」。
func _reset_view() -> void:
	if canvas == null:
		return
	canvas.zoom = 1.0
	canvas.pan = Vector2.ZERO
	canvas.queue_redraw()
	_toast("视图已重置")


# ==================== 选区旋转 / 镜像（文档：R=选区旋转、Ctrl+R=镜像） ====================
#
# 【选区几何口径】与 `_cells_in` 一致：`Rect2i(P, S)` 覆盖 `P .. P+S`（共 (S.x+1)×(S.y+1) 格）。
# 【为什么必须"格型守恒"】旋转/镜像是**位置重排**，格型多重集必须一格不增不减；所以：
#   · 只做 in_board 格（判界一律 `doc.grid().in_board`）；
#   · 若目标位置会越出盘面 ⇒ **整块不动**并提示（绝不裁剪，裁剪就是丢格型）。
# 【为什么先清后写】旋转后目标块与原块可能不同（非方形矩形），先把"原块 ∪ 新块"清空再落格型，
# 避免旧格残留导致格型数变多。

## 【关键判界口径】"可寻址格" = 盘内格 **或** 障碍格。
##
## 为什么不能用裸 `in_board`：`EditorDoc` 在有障碍时**强制产出邻接表**（`editor_doc.gd:323`
## "有障碍时必须强制产出邻接表：RectGrid 没有'格不存在'的表示法"），障碍格被 `_carve_holes`
## 挖掉 ⇒ `grid().in_board(障碍格) == false`。但障碍格在坐标系里**仍是可写的格**（`.obstacles`
## 就是证据）。旋转/镜像若按裸 `in_board` 判，就会：① 把选区里的障碍漏掉（格型不守恒）；
## ② 目标格恰好是障碍时误判"越界"而整块拒绝 —— 实测就是这条把 `R=旋转` 钉成空操作。
## 形状盘/异形盘上真正的**洞格**既不在盘内、也不是障碍 ⇒ 仍被正确排除（纪律没有被削弱）。
func _addressable(p: Vector2i) -> bool:
	return doc.grid().in_board(p) or doc.obstacles.has(p)


## 选区覆盖块 → {相对坐标: 格型}（口径与 `_cells_in` 相同，但判界走 `_addressable`）。
func _kind_map_in(rect: Rect2i) -> Dictionary:
	var out: Dictionary = {}
	for y in range(rect.position.y, rect.position.y + rect.size.y + 1):
		for x in range(rect.position.x, rect.position.x + rect.size.x + 1):
			var p := Vector2i(x, y)
			if _addressable(p):
				out[p - rect.position] = _kind_of(p)
	return out


## 清空一块选区覆盖格（判界走 `_addressable`，见其注释）。
func _clear_block(rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y + 1):
		for x in range(rect.position.x, rect.position.x + rect.size.x + 1):
			var p := Vector2i(x, y)
			if _addressable(p):
				_apply_kind_at(p, EditorCanvas.KIND_CLEAR)


## R：选区内容整体旋转 90°（顺时针）。非方形选区旋转后块变成 (h×w) 仍锚在左上角。
func _rotate_selection() -> void:
	if canvas == null or doc == null:
		return
	var sel := canvas.selection
	if sel.size == Vector2i.ZERO:
		_toast("先框选一块区域（区域选择工具），再旋转", true)
		return
	var w := sel.size.x + 1
	var h := sel.size.y + 1
	var src := _kind_map_in(sel)
	var dst: Dictionary = {}
	for rel in src:
		var r: Vector2i = rel
		# 顺时针 90°：rel' = (h-1-rel.y, rel.x)（新块 h×w）
		var p := sel.position + Vector2i(h - 1 - r.y, r.x)
		if not _addressable(p):
			_toast("旋转后的区域会超出盘面——先框小一点或挪进盘内", true)
			return
		dst[p] = str(src[rel])
	var new_sel := Rect2i(sel.position, Vector2i(h - 1, w - 1))
	_push_undo(false)
	_clear_block(sel)
	_clear_block(new_sel)
	for p in dst:
		_apply_kind_at(p, str(dst[p]))
	canvas.set_selection(new_sel)
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()
	_toast("选区已旋转 90°（%d 格格型不变）" % dst.size())


## Ctrl+R：选区内容镜像。默认**左右翻转**（水平镜像）；当前对称模式为「横轴镜像」时改**上下翻转**，
## 与文档"可按当前对称轴或默认水平"一致。选区块尺寸不变 ⇒ 只需原位重排。
func _mirror_selection() -> void:
	if canvas == null or doc == null:
		return
	var sel := canvas.selection
	if sel.size == Vector2i.ZERO:
		_toast("先框选一块区域（区域选择工具），再镜像", true)
		return
	var w := sel.size.x + 1
	var h := sel.size.y + 1
	var left_right := _sym_mode != 2      # _sym_mode==2 是「横轴镜像」⇒ 改上下翻转
	var src := _kind_map_in(sel)
	var dst: Dictionary = {}
	for rel in src:
		var r: Vector2i = rel
		var nr := Vector2i(w - 1 - r.x, r.y) if left_right else Vector2i(r.x, h - 1 - r.y)
		var p := sel.position + nr
		if not _addressable(p):
			_toast("镜像后的区域会超出盘面——先框小一点或挪进盘内", true)
			return
		dst[p] = str(src[rel])
	_push_undo(false)
	_clear_block(sel)
	for p in dst:
		_apply_kind_at(p, str(dst[p]))
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()
	_toast("选区已%s镜像（%d 格格型不变）" % ["左右" if left_right else "上下", dst.size()])


## Ctrl+X：剪切选区（复制 + 清空原格）。
func _cut_selection() -> void:
	if canvas.selection.size == Vector2i.ZERO:
		_toast("先框选一个区域（区域选择工具）")
		return
	_clipboard_cells = _cells_in(canvas.selection)
	_push_undo(false)
	for item in _clipboard_cells:
		var p: Vector2i = canvas.selection.position + (item["rel"] as Vector2i)
		if doc.grid().in_board(p):
			_apply_kind_at(p, EditorCanvas.KIND_CLEAR)
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()
	_toast("已剪切 %d 格（可粘贴到别处）" % _clipboard_cells.size())


## Ctrl+D：原地复制一份（往右下偏移 1 格），常用作图手势。
func _duplicate_selection() -> void:
	if canvas.selection.size == Vector2i.ZERO:
		_toast("先框选一个区域（区域选择工具）")
		return
	var cells := _cells_in(canvas.selection)
	if cells.is_empty():
		return
	_push_undo(false)
	for item in cells:
		var src: Vector2i = canvas.selection.position + (item["rel"] as Vector2i)
		var dst := src + Vector2i(1, 1)
		if doc.grid().in_board(dst):
			_apply_kind_at(dst, str(item["kind"]))
	_sync_declared_total()
	_mark_dirty()
	_refresh_all()
	_toast("已复制选区一份（右下偏移 1 格）")


## Alt+点击吸管：把该格的格型吸成当前画笔。返回是否吸到（供 `_input` 判断要不要吃掉事件）。
func _eyedropper_at(pos: Vector2i) -> bool:
	if canvas == null or doc == null or not doc.grid().in_board(pos):
		return false
	_set_kind(canvas.cell_kind(pos))
	return true


## 油漆桶结果提示：截断时**必须说清"仅染了前 N 格"**（否则用户以为整片都染了）。
func _on_bucket_reported(result: Dictionary) -> void:
	var filled := int(result.get("filled", 0))
	if bool(result.get("truncated", false)):
		_toast("油漆桶：区域太大，仅染了前 %d 格（%s）" % [filled, str(result.get("reason", ""))], true, 5.0)
	else:
		_toast("油漆桶：已染 %d 格" % filled)


## 「本盘问题」里带格坐标的条目 → 可点按钮，点了**把视口定位到那一格**。
func _jump_button(text: String, pos: Vector2i) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.custom_minimum_size = Vector2(0, 22)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", 13)
	b.add_theme_color_override("font_color", _label_color())
	b.tooltip_text = "点它：把棋盘定位到这一格"
	b.set_meta("ed_jump_cell", pos)
	b.pressed.connect(func() -> void: _focus_cell(pos))
	return b


## 把视口定位到某格：抬缩放（看得清）→ 居中（复用画布现成的 `center_on_cell`，不另写坐标数学）。
## 【可测性】`center_on_cell` 的几何是纯函数：定位后该格中心 = 画布中心（测试直接断言这一点）。
func _focus_cell(pos: Vector2i) -> void:
	if canvas == null or doc == null:
		return
	if not doc.grid().in_board(pos):
		_toast("这一格不在盘上", true)
		return
	canvas.zoom = maxf(canvas.zoom, 1.5)
	canvas.center_on_cell(pos)
	canvas.hover = pos
	canvas.queue_redraw()
	_toast("已定位到格 (%d,%d)" % [pos.x, pos.y])


# ==================== 猜点热力图（HotMap 接线） ====================
#
# 分工：推理算法全在 `core/hotmap.gd`（纯逻辑、已单测）；本文件只做三件事——
#   ① 一个开关（左栏「显示」分组）；② 把结果交给画布上的叠加层；③ 把不可用/超限的理由**说出来**。
# 判据唯一：可见性只问 `EditorViewState.is_cheat_visible()`（试玩态强制隐藏），本文件不自拼条件。

## 热力图可见性 = **用户开关** × **降级档** × 统一状态机（试玩态恒不可见）——全文件只此一处判"该不该显示"。
## 【PerfLedger 接线 ② + 用户开关/降级档分开呈现】模块作者明确要求：`restore_*` 会**无条件**把
## `is_enabled("hotmap")` 置回 true（见 `core/perf_ledger.gd:140-142`，它自己也承认会覆盖用户手动关闭）。
## 所以本文件把两者**分开**：
##   · `_hotmap_on` = **用户的意图**（点左栏开关才算数，降级动作**从不**改它）；
##   · `_perf.is_enabled("hotmap")` = **降级档**这一侧（由 tick/restore 驱动）。
## 实际可见 = 两者都为真。⇒ 用户手动关掉后，降级恢复（restore_hotmap）打开的是降级档那一侧，
## 而用户意图仍是"关" ⇒ **不会**被私自打开。
func _hotmap_perf_allowed() -> bool:
	return _perf == null or _perf.is_enabled(PERF_LEDGER.JOB_HOTMAP)


func _apply_hotmap_visibility() -> void:
	var perf_allows := _hotmap_perf_allowed()
	if _hotmap_btn != null:
		# 按钮的按下态只跟**用户意图**：点它是切用户开关，不该被降级档"顶"回去。
		_hotmap_btn.button_pressed = _hotmap_on
		if not _hotmap_on:
			_hotmap_btn.text = "猜点热力图：关"
		elif perf_allows:
			_hotmap_btn.text = "猜点热力图：开"
		else:
			_hotmap_btn.text = "猜点热力图：开（性能降级，暂不显示）"
	if canvas == null:
		return
	# 显隐只切画布那一层的 `visible`（**保留 cells**）：试玩态 / 性能降级 / 用户手动关都走这里，
	# 关掉不丢结果 ⇒ 再打开无需重跑求解器（见 `editor_canvas.set_overlay_visible` 的契约）。
	var cells: Dictionary = canvas.get_overlay(HOTMAP_OVERLAY).get("cells", {}) as Dictionary
	var on := _hotmap_on and perf_allows and _view_state.is_cheat_visible() and not cells.is_empty()
	canvas.set_overlay_visible(HOTMAP_OVERLAY, on)


## 降级 / 回爬动作落到界面。本文件只影响热力图（verify 频率 / 自动保存节奏是"读参数"式接线：
## 见 `_process` 与 `rate_of`；无需在这里改控件）。
func _apply_perf_actions(actions: Array) -> void:
	for a in actions:
		var act := str(a)
		if act == PERF_LEDGER.ACT_DISABLE_HOTMAP:
			# 降级关掉热力图：只改可见性，**不动** `_hotmap_on`（用户意图），并在数据仍在时说明原因。
			_apply_hotmap_visibility()
			_show_hotmap_note("性能降级：热力图已暂时隐藏（负载回落后自动恢复）。")
			_toast(PERF_LEDGER.action_reason(act), false, 4.0)
		elif act == PERF_LEDGER.ACT_RESTORE_HOTMAP:
			# 回爬重开热力图：只对**用户本来就想看**的情况恢复；用户手动关着就保持不显示。
			# 判定与"点开关打开"**共用 `_open_hotmap_data`**：数据还在就只恢复可见（不重跑），
			# 数据在降级期间被盘面改动作废过才重算 ⇒ **绝不会把过期热力图显示出来**。
			if _hotmap_on:
				_open_hotmap_data()
			else:
				_apply_hotmap_visibility()
			_toast(PERF_LEDGER.action_reason(act), false, 4.0)
		# 其余动作（降校验频率 / 延后保存 / 恢复它们）由 `_process` + `rate_of` 直接生效，无需 UI 处理。


func _show_hotmap_note(text: String) -> void:
	if _hotmap_note == null:
		return
	_hotmap_note.text = text
	_hotmap_note.visible = text != ""


func _apply_hot_overlay(cells: Dictionary, max_level: int) -> void:
	if canvas == null:
		return
	canvas.set_overlay(HOTMAP_OVERLAY, cells, {"max_level": max_level})
	_apply_hotmap_visibility()


## 清掉热力图的**数据**（盘面改动 / 算不出来时才用；"用户关掉"只隐藏、不清数据）。
func _clear_hot_overlay() -> void:
	if canvas == null:
		return
	canvas.clear_overlay(HOTMAP_OVERLAY)
	_apply_hotmap_visibility()


## 把热力图数据"弄出来"：用户点开关打开 / 性能降级回爬**共用这一份判定**。
## 数据还在（盘面自上次计算后没变，作废只由 `_invalidate_derived_views` 负责）⇒ **只恢复可见、不重跑求解器**；
## 数据不存在（盘面改过 / 上次算不出来）⇒ 才现算。两条路都不允许显示过期热力图。
func _open_hotmap_data() -> void:
	if canvas != null and canvas.has_overlay(HOTMAP_OVERLAY):
		_apply_hotmap_visibility()
		return
	_refresh_hotmap()


## 开/关热力图。关闭时**只隐藏**（保留 cells ⇒ 再打开沿用上次结果、不重跑求解器）。
## 打开时：数据还在就直接显示；否则才**现算一次**（HotMap.build 会跑求解器）。
func _toggle_hotmap() -> void:
	_hotmap_on = not _hotmap_on
	_apply_hotmap_visibility()
	if not _hotmap_on:
		_show_hotmap_note("")
		_toast("已关闭热力图")
		return
	# 降级档正压着热力图：明说"为什么点了没显示"，不许静默（负载回落后由 `_apply_perf_actions` 重算显示）。
	if not _hotmap_perf_allowed():
		_show_hotmap_note("热力图已开启，但当前性能降级中暂不显示（负载回落后自动恢复）。")
		_toast("热力图已开启，但当前性能降级中暂不显示", false, 4.0)
		return
	# 数据还在就只恢复可见、不重跑求解器；被作废过才重算（判定与降级回爬共用同一份）。
	_open_hotmap_data()


## 计算并应用热力图。`ok=false` / 无格 ⇒ 一律给**可读提示**（绝不静默什么都不发生）。
func _refresh_hotmap() -> void:
	if doc == null:
		return
	_hotmap_builds += 1
	var r: Dictionary = HOTMAP.build(doc)
	if not bool(r["ok"]):
		_clear_hot_overlay()
		_show_hotmap_note("热力图不可用：%s" % str(r["reason"]))
		_toast("热力图不可用：%s" % str(r["reason"]), true, 6.0)
		return
	var cells: Dictionary = r["cells"]
	if cells.is_empty():
		_clear_hot_overlay()
		_show_hotmap_note("热力图没有可显示的格：%s" % str(r["reason"]))
		_toast("热力图没有可显示的格", true)
		return
	_apply_hot_overlay(cells, int(r["max_level"]))
	_show_hotmap_note("热力图已显示：红 = 必须猜的格，颜色越深 = 越晚推出。%s" % str(r["reason"]))


## 文档一变：热力图 / 回放这些**按当时盘面算出来**的派生视图立刻作废。
## 这里**不重算**（HotMap / ProofLog 都会跑求解器，拖动时重算会卡死编辑器），只清掉并说清下一步。
func _invalidate_derived_views() -> void:
	# 热力图数据**与开关无关**地作废：即使此刻关着（只是隐藏、数据仍在）也必须清掉，
	# 否则再打开会显示过期结果（"关掉不丢数据"必须靠这一步保住正确性）。
	if canvas != null and canvas.has_overlay(HOTMAP_OVERLAY):
		_clear_hot_overlay()
		if _hotmap_on:
			_show_hotmap_note("盘面已改动，旧热力图已清除——再点一次左栏「猜点热力图」重算。")
	if _replay_model != null and int(_replay_model.step_count()) > 0:
		_clear_replay_rows()
		_replay_model.load({})            # 旧链作废，不拿旧结论骗人
		_show_replay_banner(false, "")
		if _replay_note != null:
			_replay_note.text = "盘面已改动，旧推理链已清除——再点一次「生成推理链回放」。"


# ==================== 推理链回放（ReplayModel 接线） ====================
#
# 分工：窗口计算/读取在 `core/replay_model.gd`（纯算术、已单测）与 `core/proof_log.gd`（产链）。
# 本文件只做**虚拟化渲染**：总高 = 步数 × 行高，只实例化 `visible_range()` 给的行；
# 点某行 ⇒ 复用既有 `_focus_cell`（问题面板点击跳转同一套换算）定位到 `cells[0]`。

## 点「生成推理链回放」：先把"正在…"画出去，再算（与 `_on_verify` 同一手法，避免"点了没反应"）。
func _on_replay_build() -> void:
	if doc == null:
		return
	if _replay_btn != null:
		_replay_btn.disabled = true
	if _replay_note != null:
		_replay_note.text = "正在推导推理链…（棋盘越大越慢，请稍等）"
	await get_tree().process_frame
	_set_replay_log(PROOF_LOG.build(doc.to_level_json()))
	if _replay_btn != null:
		_replay_btn.disabled = false


## 载入一份证明日志并渲染。截断必须**如实透出**（顶部 banner），不许把"只剩前 N 步"当完整链。
func _set_replay_log(log: Dictionary) -> void:
	if _replay_model == null:
		_replay_model = REPLAY.new()
	var r: Dictionary = _replay_model.load(log)
	if not bool(r["ok"]):
		_clear_replay_rows()
		_show_replay_banner(false, "")
		if _replay_note != null:
			_replay_note.text = "回放不可用：%s" % str(r["reason"])
		return
	_show_replay_banner(bool(r["truncated"]), _replay_banner_text(r))
	if _replay_note != null:
		_replay_note.text = "共 %d 步（点一行定位到那一步的结论格）" % int(_replay_model.step_count())
	if _replay_scroll != null:
		_replay_scroll.scroll_vertical = 0
	_rebuild_replay_rows()


func _replay_banner_text(r: Dictionary) -> String:
	if not bool(r["truncated"]):
		return ""
	return "⚠ 日志已截断：仅保留前 %d 步，丢弃 %d 步（%s）" % [
		int(r["kept_steps"]), int(r["dropped_steps"]), str(r["reason"])]


func _show_replay_banner(on: bool, text: String) -> void:
	if _replay_banner == null:
		return
	_replay_banner.visible = on
	_replay_banner.text = text


func _clear_replay_rows() -> void:
	if _replay_rows == null:
		return
	for c in _replay_rows.get_children():
		_replay_rows.remove_child(c)      # 立刻脱离树：再取 child_count 时不会把"待回收"算进来
		c.queue_free()
	_replay_rows.custom_minimum_size = Vector2(0, 0)


## 按当前滚动位置重建可见行。`scroll_y` / `viewport_h` 留作显式参数：测试可在无布局环境里
## 直接喂确定值（滚动条在 headless 下未必真的算过 max，不能让判定依赖它）。
func _rebuild_replay_rows(scroll_y := -1.0, viewport_h := -1.0) -> void:
	if _replay_rows == null or _replay_model == null or _replay_scroll == null:
		return
	for c in _replay_rows.get_children():
		_replay_rows.remove_child(c)
		c.queue_free()
	var total := int(_replay_model.step_count())
	_replay_rows.custom_minimum_size = Vector2(0, float(total) * _replay_row_h)
	if total <= 0:
		return
	var sy := float(_replay_scroll.scroll_vertical) if scroll_y < 0.0 else scroll_y
	var vh := _replay_scroll.size.y if viewport_h < 0.0 else viewport_h
	# 窗口计算全在 ReplayModel 里（纯算术、已单测）——UI 只按它给的行区间实例化。
	var win: Dictionary = _replay_model.visible_range(sy, vh, _replay_row_h, 2)
	var first := int(win["first"])
	var last := int(win["last"])
	for i in range(first, last + 1):
		var at: Dictionary = _replay_model.step_at(i)
		if not bool(at["ok"]):
			continue
		_replay_rows.add_child(_replay_row(i, at["step"]))


## 一行 = 一个可点按钮：正文 = `describe()` 的 title ＋ evidence（依据/规则/说明）；
## 取不到的字段由 describe 记进 missing，这里不编内容（悬停给完整串，窄面板下裁掉的部分能看全）。
func _replay_row(index: int, step: Dictionary) -> Button:
	var d: Dictionary = _replay_model.describe(step)
	var title := str(d["title"])
	var ev := str(d["evidence"])
	var row := Button.new()
	if ev == "":
		row.text = "%d. %s" % [index + 1, title]
	else:
		row.text = "%d. %s ｜ %s" % [index + 1, title, ev]
	row.flat = true
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.clip_text = true
	row.custom_minimum_size = Vector2(84, _replay_row_h)
	row.size = Vector2(maxf(_replay_rows.size.x, 84.0), _replay_row_h)
	row.position = Vector2(0.0, float(index) * _replay_row_h)
	row.add_theme_font_size_override("font_size", 12)
	row.tooltip_text = row.text
	row.pressed.connect(func() -> void: _replay_focus_step(index))
	return row


func _on_replay_scrolled(value: float) -> void:
	_rebuild_replay_rows(float(value))


## 点回放某一行 ⇒ 定位到该步的**结论格**（`describe().cells[0]`，顺序契约见 replay_model.gd）。
## 复用既有 `_focus_cell`（问题面板点击跳转同一套换算），不新写一套坐标数学。
func _replay_focus_step(index: int) -> void:
	if _replay_model == null:
		return
	var at: Dictionary = _replay_model.step_at(index)
	if not bool(at["ok"]):
		_toast("这一步不在日志里：%s" % str(at["reason"]), true)
		return
	var d: Dictionary = _replay_model.describe(at["step"])
	var cells: Array = d["cells"]
	if cells.is_empty():
		_toast("第 %d 步没有可定位的格子（日志缺 pos/sources）" % (index + 1), true)
		return
	var target: Vector2i = cells[0]
	_focus_cell(target)


## ttl：停留秒数。默认 2 秒对短提示够用；但"去哪儿找文件 / 分享包是什么"这类要读完的信息
##（2026-10-02 实测）2 秒根本读不完 ⇒ 调用处显式传更长的 ttl。
func _toast(msg: String, danger: bool = false, ttl := 2.0) -> void:
	if is_inside_tree():
		# 危险提示除了染红，再加一个符号：颜色不能是**唯一**信号
		#（色盲用户、黑白截图、以及"红绿色弱"的人分不出红字与普通字）。
		UI_TOAST.popup(self, ("⚠ " + msg) if danger else msg, danger, ttl)