# mod_select.gd —— 模组管理页（第二篇 mod 系统）
# 列出 user://mods/ 下的规则包：加载/卸载 + 对已加载 mod 的线索 Def 生成可玩关卡。
extends Control

var _list_vbox: VBoxContainer
# 生成进度弹窗 + 取消标志（v3.1：三处生成循环此前同步阻塞 40 次 attempt，
# UI 冻结无进度不可取消——与 level_select 的 await+取消模式对齐）
var _gen_cancel := false
var _gen_dlg: PopupPanel = null
var _import_dlg: FileDialog = null

## 「把想法告诉 AI，AI 写出 mod」的任务说明（拼进任务包文件头部）。
## 安装路径在运行时用 globalize_path 动态填——玩家不需要知道自己机器上的 user:// 在哪。
const AI_TASK_BRIEF := """【给 AI 的任务说明】
你是本游戏（《世界扫雷》，Godot 4 变体扫雷解谜）的 Mod 开发助手。玩家想给自己的游戏加一个新变体 Mod。
请按以下步骤工作：
1. 通读下方《变体规则编写规范》——它包含完整契约、全部可用原语与已知坑。
2. 听玩家用日常语言描述想法（玩家的下一条消息），然后按规范产出：
   ① manifest.json 全文  ② entry.gd 全文
   ③ 一段「正逆向一致性」说明（为什么 build_*_constraints 与正向计算是同一语义）
   ④ 给玩家的验收步骤（按规范 §7）。
3. 红线：只实现规则语义（RulePlugin 契约）。不要访问文件系统、网络、autoload，
   不要任何与玩法无关的代码——这些代码过不了平台的加载确认与审核。
4. 产出的两个文件，玩家会放到本机器的 Mod 目录（路径见下），然后在游戏的
   「模组管理」页点「加载」即可玩。

【本机器的 Mod 安装目录】
%s

【manifest.json 空白模板】
{
	"id": "my_rule",
	"version": "1.0.0",
	"api_version": "2.9",
	"entry": { "runtime": "gdscript", "path": "entry.gd" }
}
（id 换成你的 Mod 名：小写、无空格、不与已有重复。）
"""

## 规范全文读不到时的内嵌精简版（导出包未包含 .md 的兜底）：最小可玩示例 + 命名契约 + 关键坑。
const AI_GUIDE_MINIMAL := """《变体规则编写规范》精简版（完整版见游戏安装目录的 变体规则编写规范.md）

一个 Mod = 一个文件夹，含两个文件：manifest.json（见上方模板）+ entry.gd（代码入口）。

entry.gd 骨架（线索类）：
    extends RefCounted

    class MyRule:
        extends RulePlugin
        func get_rule_id() -> StringName:
            return &"my_rule"
        func get_kind() -> String:
            return KIND_CLUE
        func describe() -> Dictionary:
            return {"name": "名字", "rule_text": "玩家看到的规则说明"}
        # 正向：雷分布 -> 数字。mine_set: Dictionary(Vector2i -> true)
        func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
            ...
        # 逆向：给定数字 -> 约束。b 为 RuleBuilder；value 即正向返回值
        func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
            var nbs := b.neighbors(pos, DIRS)          # DIRS 自定义邻域 Vector2i 列表
            b.add_eq(b.sum(b.cell_vars(nbs)), int(value))   # 计数型标准写法
        # 值 0 时保证安全的邻格（连锁展开）；语义不成立就删掉这个方法
        func zero_safe_neighbors(pos, grid_size, value = null) -> Array[Vector2i]:
            if value != 0: return []
            return RulePlugin.dirs_to_neighbors(pos, grid_size, DIRS)

    func on_load() -> bool:
        RuleRegistry.default().register(MyRule.new())
        return true

棋盘级约束类规则：get_kind() 返回 KIND_GLOBAL，实现 build_global_constraints(b)
（可读 b.rows / b.cols / b.total_mines），可选实现 place_mines(rng, cols, rows, count)
构造式布雷（一次成型，不许"随机撒+拒绝重采"，返回数量必须 == count，空数组=交给平台随机）。

RuleBuilder 常用原语：cell_var(r,c)（注意行在前）/ cell_vars(数组) / bool_var() /
sum(xs) / wsum(ws, xs) / add_eq / add_le / add_imp / add_iff / add_bool_or / not_lit / in_board(r,c)。

命名契约：o*/s*/z* 是官方保留前缀；id 小写无空格无 + 号。
常见坑：正逆向语义必须一致（平台会用随机布雷双向校验）；行列写反（cell_var(pos.y, pos.x)）；
计数型线索建议 supports_mask() 返回 true 并实现 build_interval_constraints。
"""


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	_build_ui()


func _build_ui() -> void:
	var top := HBoxContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_top = 12
	top.add_theme_constant_override("separation", 16)
	add_child(top)

	var title := Label.new()
	title.text = "模组管理"
	title.add_theme_font_size_override("font_size", 28)
	top.add_child(title)

	# 本地导入：从文件夹安装 Mod（创意工坊「本地导入」最小闭环；联网上传后续接
	# 同一个 ModAPI.install_from_dir 入口，无需改 UI 流程）
	var imp := Button.new()
	imp.text = "导入 Mod（文件夹）"
	imp.focus_mode = Control.FOCUS_NONE
	imp.custom_minimum_size = Vector2(190, 40)
	if OS.has_feature("web"):
		# Web 导出无文件系统访问权限（审计 M3）：禁用并说明，不让入口静默失效
		imp.disabled = true
		imp.tooltip_text = "Web 版暂不支持本地导入，请在桌面版中使用"
	imp.pressed.connect(_open_import_dialog)
	top.add_child(imp)

	# 「把想法告诉 AI，AI 写出 mod」的最短路径：一键生成自包含任务文件
	#（完整编写规范 + 空白模板 + 本机安装路径），用户丢给任意 AI 即可产出可安装的 mod
	var ai := Button.new()
	ai.text = "AI Mod 任务包"
	ai.focus_mode = Control.FOCUS_NONE
	ai.custom_minimum_size = Vector2(170, 40)
	ai.pressed.connect(_export_ai_task_pack)
	top.add_child(ai)

	# 创意工坊同步（P1 读取侧）：只在装了 GodotSteam 时出现；Steam 不可用（无客户端/无 appid）
	# 时同步会返回可读原因并 toast 提示——不崩不弹错（降级逻辑见 core/steam_workshop.gd）
	if SteamWorkshop.plugin_present():
		var ws := SteamWorkshop.new()
		var wbtn := Button.new()
		wbtn.text = "同步创意工坊"
		wbtn.focus_mode = Control.FOCUS_NONE
		wbtn.custom_minimum_size = Vector2(170, 40)
		wbtn.tooltip_text = "把创意工坊订阅的 Mod 同步到本地（需 Steam 客户端运行；已装的不覆盖）"
		wbtn.pressed.connect(func():
			var ir: Dictionary = ws.init()
			if not bool(ir.get("ok", false)):
				_toast("Steam 不可用：%s（需从 Steam 启动游戏，或本机运行 Steam 客户端）" % str(ir.get("reason", "")))
				return
			var sr: Dictionary = ws.poll_subscriptions(ModAPI)
			var errs: Array = sr.get("errors", [])
			_toast("工坊同步：新增 %d · 已存在 %d · 失败 %d%s" % [
					(sr.get("synced", []) as Array).size(), (sr.get("skipped", []) as Array).size(),
					errs.size(), ("" if errs.is_empty() else "（%s）" % str(errs[0]))],
					not bool(sr.get("ok", false)))
			_rebuild_list())
		top.add_child(wbtn)

	# 返回按钮：统一右上角（独立定位）
	var back := Button.new()
	back.text = "返回"
	back.focus_mode = Control.FOCUS_NONE
	back.custom_minimum_size = Vector2(96, 40)
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	back.offset_left = -120
	back.offset_top = 12
	back.offset_right = -24
	back.offset_bottom = 52
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://ui/main_menu.tscn"))
	add_child(back)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = 64
	scroll.offset_bottom = -16
	scroll.offset_left = 280
	scroll.offset_right = -280
	add_child(scroll)

	_list_vbox = VBoxContainer.new()
	_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(_list_vbox)

	_rebuild_list()
	_apply_theme()


func _rebuild_list() -> void:
	for c in _list_vbox.get_children():
		c.queue_free()

	var hint := Label.new()
	hint.text = "规则包目录：user://mods/<名称>/defs/*.json（线索/约束 Def）"
	hint.add_theme_font_size_override("font_size", 15)
	_list_vbox.add_child(hint)

	# 内置示例规则包：一键安装，避免玩家面对空模组页无从下手
	var ex_row := HBoxContainer.new()
	ex_row.add_theme_constant_override("separation", 12)
	var ex_lb := Label.new()
	ex_lb.text = "示例规则包（四邻和线索 + 左右镜像约束）%s" % ("（已安装）" if ExampleMod.is_installed() else "")
	ex_lb.custom_minimum_size = Vector2(360, 40)
	ex_lb.add_theme_font_size_override("font_size", 17)
	ex_row.add_child(ex_lb)
	var ex_btn := Button.new()
	ex_btn.text = "安装"
	ex_btn.focus_mode = Control.FOCUS_NONE
	ex_btn.custom_minimum_size = Vector2(100, 40)
	ex_btn.pressed.connect(func():
		var r: Dictionary = ExampleMod.install()
		if bool(r.get("ok", false)):
			_toast("已安装示例规则包（%d 个 Def），点「加载」启用" % int(r.get("count", 0)), false)
		else:
			_toast("安装失败：%s" % r.get("reason", ""))
		_rebuild_list())
	ex_row.add_child(ex_btn)
	_list_vbox.add_child(ex_row)

	# demo 代码 Mod 示例（自举式：GDScript 入口 + on_load 注册规则）
	var demo_row := HBoxContainer.new()
	demo_row.add_theme_constant_override("separation", 12)
	var demo_lb := Label.new()
	demo_lb.text = "代码 Mod 示例（双倍对角规则 x2diag）%s" % ("（已安装）" if ExampleMod.demo_rule_mod_installed() else "")
	demo_lb.custom_minimum_size = Vector2(360, 40)
	demo_lb.add_theme_font_size_override("font_size", 17)
	demo_row.add_child(demo_lb)
	var demo_btn := Button.new()
	demo_btn.text = "安装"
	demo_btn.focus_mode = Control.FOCUS_NONE
	demo_btn.custom_minimum_size = Vector2(100, 40)
	demo_btn.pressed.connect(func():
		var dr: Dictionary = ExampleMod.install_demo_rule_mod()
		if bool(dr.get("ok", false)):
			_toast("已安装代码 Mod 示例，点「加载」启用后见「自定义规则」区")
		else:
			_toast("安装失败：%s" % dr.get("reason", ""))
		_rebuild_list())
	demo_row.add_child(demo_btn)
	_list_vbox.add_child(demo_row)

	var mods := ModAPI.scan_mods()
	if mods.is_empty():
		var empty_lb := Label.new()
		empty_lb.text = "未找到可用模组（把规则包放入 user://mods/ 后重进本页）"
		empty_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lb.custom_minimum_size = Vector2(0, 48)
		_list_vbox.add_child(empty_lb)
	else:
		for m in mods:
			_list_vbox.add_child(_make_mod_row(m))

	# 自定义规则（自举式平台：mod 经 entry.gd 注册的 RulePlugin 线索规则）
	#
	# 官方三轴 22 席**本身也是 mod**（demo/mods/ 自举），所以它们也会出现在
	# `custom_ids()` 里 —— 但它们的关卡内容随包预置在 `levels_lib/`，玩家不需要、
	# 也不应该在这里重新生成（生成出的是「按种子的临时盘」，与库里正式关卡两套并存，
	# 且 9×9 单盘可达十几秒）。官方席位若库里没有，选关页会**优雅降级**自动现生成，
	# 所以这个入口也不需要。
	# 不静默消失：末尾给一行说明（项目交互原则「此处不适用也要说明原因」）。
	var custom := RuleRegistry.default().custom_ids()
	var official := _official_seat_ids()
	var has_rule := false
	for rid in custom:
		var rule: Object = RuleRegistry.default().resolve(StringName(rid))
		if rule == null or rule.get_kind() != RulePlugin.KIND_CLUE:
			continue
		if official.has(str(rid)):
			continue
		if not has_rule:
			var sec := Label.new()
			sec.text = "自定义规则（自举式）"
			sec.add_theme_font_size_override("font_size", 19)
			_list_vbox.add_child(sec)
			has_rule = true
		_list_vbox.add_child(_make_rule_row(str(rid)))
	if not official.is_empty():
		var off_lb := Label.new()
		off_lb.text = "官方变体（%d 席）的关卡随包内置，不在此列出；要玩请直接去选关页。" % official.size()
		off_lb.add_theme_font_size_override("font_size", 14)
		off_lb.set_meta("secondary", true)
		_list_vbox.add_child(off_lb)
	_apply_theme()


## 官方三轴席位 id 集合 —— 这些席位的关卡内容随包预置（`levels_lib/`），
## 不在模组页提供「重新生成」入口（否则玩家会生成出第二套与库并存的临时盘）。
static func _official_seat_ids() -> Dictionary:
	var out := {}
	for id in VariantCatalog.OBS_IDS + VariantCatalog.STRUCT_IDS + VariantCatalog.CONSERVE_IDS:
		out[str(id)] = true
	return out


func _make_mod_row(mod_name: String) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 6)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var loaded: bool = ModAPI.list_mods().has(mod_name)
	var lb := Label.new()
	lb.text = "%s  %s" % [mod_name, "（已加载）" if loaded else ""]
	lb.custom_minimum_size = Vector2(320, 40)
	lb.add_theme_font_size_override("font_size", 19)
	row.add_child(lb)
	var btn := Button.new()
	btn.text = "卸载" if loaded else "加载"
	btn.focus_mode = Control.FOCUS_NONE
	btn.custom_minimum_size = Vector2(100, 40)
	btn.pressed.connect(func():
		if ModAPI.list_mods().has(mod_name):
			ModAPI.unload_mod(mod_name)
			_rebuild_list()
			return
		# 代码 Mod 无沙箱（审计 H1）：GDScript 入口加载即以游戏全部权限执行。
		# 加载前二次确认——工坊上线前作者与来源无法核实，玩家有权知道自己在同意什么。
		if FileAccess.file_exists("user://mods/%s/entry.gd" % mod_name):
			UiConfirm.ask(self,
					"「%s」是代码 Mod：加载后它将以本游戏的全部权限运行（可读写文件）。\n只加载你信任来源的 Mod。确定加载吗？" % mod_name,
					"信任并加载", "取消",
					func():
						var r2: Dictionary = ModAPI.load_mod("user://mods/%s" % mod_name)
						if not r2.get("ok", false):
							_toast("加载失败：%s" % r2.get("reason", ""))
						_rebuild_list())
			return
		var r: Dictionary = ModAPI.load_mod("user://mods/%s" % mod_name)
		if not r.get("ok", false):
			_toast("加载失败：%s" % r.get("reason", ""))
		_rebuild_list())
	row.add_child(btn)
	block.add_child(row)

	# 已加载 → 列出线索 Def + 生成关卡按钮
	if loaded:
		# wasm mod：黑盒生成入口（P0-T7 收尾——沙箱接线此前已完成，此处补生产 UI 入口）
		if ModAPI.get_sandbox(mod_name) != null:
			block.add_child(_make_wasm_row(mod_name))
		for def_name in _clue_defs_of(mod_name):
			block.add_child(_make_def_row(mod_name, def_name))
	return block


func _clue_defs_of(mod_name: String) -> Array:
	# 扫描 mod 的 defs/*.json，筛出 type=clue 的 defName
	var defs_dir := "user://mods/%s/defs" % mod_name
	var out: Array = []
	var dir := DirAccess.open(defs_dir)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			var f := FileAccess.open(defs_dir.path_join(fname), FileAccess.READ)
			if f != null:
				var data: Variant = JSON.parse_string(f.get_as_text())
				f.close()
				if data is Dictionary and data.get("type", "") == "clue":
					out.append(str(data.get("defName", "")))
		fname = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


## wasm mod 生成行（P0-T7 收尾）：黑盒生成「线索关」+「约束关」两个入口。
func _make_wasm_row(mod_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.offset_left = 24
	var lb := Label.new()
	lb.text = "wasm 黑盒生成"
	lb.custom_minimum_size = Vector2(240, 34)
	lb.add_theme_font_size_override("font_size", 16)
	row.add_child(lb)
	for kind in [["clue", "线索关"], ["global", "约束关"]]:
		var btn := Button.new()
		btn.text = "生成%s" % kind[1]
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(110, 34)
		btn.pressed.connect(func(): _generate_wasm_levels(mod_name, kind[0]))
		row.add_child(btn)
	return row


## 生成进度弹窗：告知「程序在忙」并给取消出口（与 level_select 同模式）。
func _open_gen_dialog(title: String) -> void:
	_gen_cancel = false
	var dlg := PopupPanel.new()
	dlg.exclusive = true
	var vb := VBoxContainer.new()
	dlg.add_child(vb)
	var lb := Label.new()
	lb.text = title
	lb.add_theme_font_size_override("font_size", 16)
	vb.add_child(lb)
	var sub := Label.new()
	sub.text = "生成中（CP-SAT 单次求解不可中断，界面按尝试逐次响应取消）"
	vb.add_child(sub)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.custom_minimum_size = Vector2(0, 40)
	cancel.pressed.connect(func():
		_gen_cancel = true
		dlg.hide())
	vb.add_child(cancel)
	add_child(dlg)
	dlg.hide()   # Window 默认 visible=true
	dlg.popup_centered()
	_gen_dlg = dlg


func _close_gen_dialog() -> void:
	if _gen_dlg != null and is_instance_valid(_gen_dlg):
		_gen_dlg.queue_free()
	_gen_dlg = null


## wasm 黑盒生成：clue → generate_clue；global → generate_global。
## 注意：黑盒完备穷举仅小盘可行（≤6×6 少量雷），大盘会超时/超 MAX_COMBOS。
func _generate_wasm_levels(mod_name: String, kind: String) -> void:
	var sb := ModAPI.get_sandbox(mod_name)
	if sb == null:
		_toast("wasm 沙箱不可用")
		return
	_open_gen_dialog("正在为 %s 生成 wasm 关卡…" % mod_name)
	var gen := WasmLevelGenerator.new()
	var out_dir := "user://mods/%s/levels" % mod_name
	DirAccess.make_dir_recursive_absolute(out_dir)
	var produced := 0
	for t in 40:
		await get_tree().process_frame
		if _gen_cancel or produced >= 5:
			break
		var level: Dictionary
		if kind == "global":
			level = gen.generate_global(sb, Vector2i(5, 5), 5, t + 1)
		else:
			level = gen.generate_clue(sb, Vector2i(5, 5), 5, t + 1)
		if level.is_empty():
			continue
		var f := FileAccess.open("%s/%s_%s_%02d.json" % [out_dir, kind, mod_name, produced + 1], FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(level, "  "))
			f.close()
			produced += 1
	_close_gen_dialog()
	_gen_cancel = false
	_toast(("已取消" if _gen_cancel else "已为 %s 生成 %d 个 wasm %s关" % [mod_name, produced, "约束" if kind == "global" else "线索"]),
			produced == 0)


func _make_def_row(mod_name: String, def_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.offset_left = 24
	var lb := Label.new()
	lb.text = "线索 %s" % def_name
	lb.custom_minimum_size = Vector2(240, 34)
	lb.add_theme_font_size_override("font_size", 16)
	row.add_child(lb)
	var gen_btn := Button.new()
	gen_btn.text = "生成 5 关"
	gen_btn.focus_mode = Control.FOCUS_NONE
	gen_btn.custom_minimum_size = Vector2(120, 34)
	gen_btn.pressed.connect(func(): _generate_levels(mod_name, def_name))
	row.add_child(gen_btn)
	return row


func _generate_levels(mod_name: String, def_name: String) -> void:
	_open_gen_dialog("正在为 %s 生成关卡…" % def_name)
	var gen := PuzzleGenerator.new()
	var out_dir := "user://mods/%s/levels" % mod_name
	DirAccess.make_dir_recursive_absolute(out_dir)
	# P0-A：mod 声明 board.json → 异形拓扑生成；否则回退 5×5 矩形。
	var board_info := _mod_board(mod_name)
	var topo: GridInterface = board_info["topo"]
	var size: Vector2i = board_info["size"]
	var mine_count := int(topo.cell_count() * 0.2) if topo != null else 5
	var produced := 0
	for t in 40:
		await get_tree().process_frame
		if _gen_cancel or produced >= 5:
			break
		var level := gen.generate_with_engine(ModAPI.defs, def_name, "", size, mine_count, t + 1, topo)
		if level.is_empty():
			continue
		var f := FileAccess.open("%s/%s_%02d.json" % [out_dir, def_name, produced + 1], FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(level, "  "))
			f.close()
			produced += 1
	_close_gen_dialog()
	_gen_cancel = false
	_toast("已取消" if produced == 0 and _gen_cancel else "已为 %s 生成 %d 关" % [def_name, produced], produced == 0)


## 自定义规则行（自举式：RulePlugin 线索规则 + 生成关卡按钮）。
func _make_rule_row(rule_id: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.offset_left = 24
	var rule: Object = RuleRegistry.default().resolve(StringName(rule_id))
	var desc := rule_id
	if rule != null and rule.has_method("describe"):
		var d: Dictionary = rule.describe()
		desc = "%s（%s）" % [str(d.get("name", rule_id)), rule_id]
	var lb := Label.new()
	lb.text = "规则 %s" % desc
	lb.custom_minimum_size = Vector2(240, 34)
	lb.add_theme_font_size_override("font_size", 16)
	row.add_child(lb)
	var gen_btn := Button.new()
	gen_btn.text = "生成 5 关"
	gen_btn.focus_mode = Control.FOCUS_NONE
	gen_btn.custom_minimum_size = Vector2(120, 34)
	gen_btn.pressed.connect(func(): _generate_rule_levels(rule_id))
	row.add_child(gen_btn)
	return row


## 用自举式规则平台（generate_with_rules）为指定规则生成关卡。
func _generate_rule_levels(rule_id: String) -> void:
	_open_gen_dialog("正在为规则 %s 生成关卡…" % rule_id)
	var gen := PuzzleGenerator.new()
	var out_dir := "user://mods/_custom/levels"
	DirAccess.make_dir_recursive_absolute(out_dir)
	# P0-A：规则归属的 mod 若声明 board.json → 异形拓扑生成；否则回退 5×5 矩形。
	var owner := ModAPI.find_rule_owner(rule_id)
	var board_info := _mod_board(owner)
	var topo: GridInterface = board_info["topo"]
	var size: Vector2i = board_info["size"]
	var mine_count := int(topo.cell_count() * 0.2) if topo != null else 5
	var produced := 0
	for t in 40:
		await get_tree().process_frame
		if _gen_cancel or produced >= 5:
			break
		var level := gen.generate_with_rules(rule_id, [], size, mine_count, t + 1, 0, 50, topo)
		if level.is_empty():
			continue
		var f := FileAccess.open("%s/%s_%02d.json" % [out_dir, rule_id, produced + 1], FileAccess.WRITE)
		if f != null:
			# 生成器的产出契约不含 name（标准关由 gen_standard_levels 事后补写）。
			# 此处落盘前补齐，否则选关页回退显示文件名、丢失规则语义。
			level["name"] = "%s %02d" % [rule_id, produced + 1]
			f.store_string(JSON.stringify(level, "  "))
			f.close()
			produced += 1
	_close_gen_dialog()
	_gen_cancel = false
	_toast("已取消" if produced == 0 and _gen_cancel else "已为规则 %s 生成 %d 关" % [rule_id, produced], produced == 0)


## P0-A：读 mod 声明的棋盘拓扑（board.json），返回 {topo: AdjacencyGrid|null, size: Vector2i}。
## 无声明/解析失败 → {topo: null, size: 5×5}（回退矩形）。
func _mod_board(mod_name: String) -> Dictionary:
	var board: Dictionary = ModAPI.get_board(mod_name) if mod_name != "" else {}
	if board.is_empty():
		return {"topo": null, "size": Vector2i(5, 5)}
	var topo := AdjacencyGrid.new()
	topo.setup_from_topo(board)
	if topo.all_positions().is_empty():
		return {"topo": null, "size": Vector2i(5, 5)}
	# P0-A：坐标归一化到非负（Mod 可用任意坐标含负值；CP-SAT cell 索引从 0 起）
	topo = AdjacencyGrid.normalized(topo)
	var max_c := 0
	var max_r := 0
	for p in topo.all_positions():
		max_c = maxi(max_c, p.x)
		max_r = maxi(max_r, p.y)
	return {"topo": topo, "size": Vector2i(max_c + 1, max_r + 1)}


## toast 统一走 UiToast（原先本页与 skin_browser / settings_panel / main_menu
## 各实现了一份同构的 Label+Timer，行为与配色已经开始分叉）。
## 生成「AI Mod 任务包」：一份自包含文件（任务说明 + 完整编写规范 + 空白模板 +
## **本机真实安装路径**），落到 user:// 并复制进剪贴板。玩家把它丢给任意 AI，
## AI 不需要接触游戏源码即可产出可直接安装的 Mod。
## 「简单到 AI 都会写」的关键不在 SDK 面多大，而在 AI 能否在玩家机器上**自举**——
## 找到规范、读懂契约、装对位置；任务包把这三件事一次给全，还附上本机真实路径，
## 等价于玩家「把游戏路径告诉 AI」，且不暴露任何源码。
## 规范全文优先读 res://（开发期/导出包含时）；读不到回退内嵌精简版。
func _export_ai_task_pack() -> void:
	var guide := ""
	if FileAccess.file_exists("res://变体规则编写规范.md"):
		guide = FileAccess.get_file_as_string("res://变体规则编写规范.md")
	if guide.is_empty():
		guide = AI_GUIDE_MINIMAL
	var brief := AI_TASK_BRIEF % ProjectSettings.globalize_path("user://mods")
	var doc := "%s\n\n%s\n" % [brief, guide]
	var path := "user://MOD_TASK_FOR_AI.txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_toast("任务包写盘失败: %s" % path)
		return
	f.store_string(doc)
	f.close()
	DisplayServer.clipboard_set(doc)
	_toast("任务包已生成（内容已复制到剪贴板）：把剪贴板或该文件发给 AI，写完把两个文件放进上述 Mod 目录",
			false)
	OS.shell_open(ProjectSettings.globalize_path("user://"))


## 本地导入：从文件夹安装 Mod（创意工坊「本地导入」最小闭环）。
## 真正的安装/校验逻辑在 ModAPI.install_from_dir（可 headless 测试），这里只负责选目录与提示。
func _open_import_dialog() -> void:
	if _import_dlg == null:
		_import_dlg = FileDialog.new()
		_import_dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_import_dlg.access = FileDialog.ACCESS_FILESYSTEM
		_import_dlg.title = "选择 Mod 文件夹（需含 manifest.json 与 entry.gd）"
		_import_dlg.dir_selected.connect(_on_import_dir)
		add_child(_import_dlg)
	_import_dlg.popup_centered(Vector2i(760, 520))


func _on_import_dir(path: String) -> void:
	var r: Dictionary = ModAPI.install_from_dir(path)
	if bool(r.get("ok", false)):
		_toast("已导入 Mod「%s」，点「加载」启用" % str(r.get("id", "")), false)
		_rebuild_list()
	else:
		_toast("导入失败：%s" % str(r.get("reason", "")))


func _toast(msg: String, danger: bool = true) -> void:
	UiToast.popup(self, msg, danger)


func _apply_theme() -> void:
	for n in get_children():
		if n is HBoxContainer:
			for c in n.get_children():
				if c is Label:
					c.add_theme_color_override("font_color", ThemeManager.text())
				elif c is Button:
					_style_button(c)
		elif n is ScrollContainer:
			for sc in n.get_children():
				if sc is VBoxContainer:
					for c in sc.get_children():
						_style_recursive(c)
	queue_redraw()


func _style_recursive(n: Node) -> void:
	if n is Button:
		_style_button(n)
	elif n is Label:
		n.add_theme_color_override("font_color", ThemeManager.text_secondary())
	elif n is VBoxContainer or n is HBoxContainer:
		for c in n.get_children():
			_style_recursive(c)


func _style_button(btn: Button) -> void:
	UiTheme.style_button(btn)


func _on_theme_changed() -> void:
	_apply_theme()
