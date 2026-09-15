# mod_select.gd —— 模组管理页（第二篇 mod 系统）
# 列出 user://mods/ 下的规则包：加载/卸载 + 对已加载 mod 的线索 Def 生成可玩关卡。
extends Control

var _list_vbox: VBoxContainer


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
	var custom := RuleRegistry.default().custom_ids()
	var has_rule := false
	for rid in custom:
		var rule: Object = RuleRegistry.default().resolve(StringName(rid))
		if rule == null or rule.get_kind() != RulePlugin.KIND_CLUE:
			continue
		if not has_rule:
			var sec := Label.new()
			sec.text = "自定义规则（自举式）"
			sec.add_theme_font_size_override("font_size", 19)
			_list_vbox.add_child(sec)
			has_rule = true
		_list_vbox.add_child(_make_rule_row(str(rid)))
	_apply_theme()


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
		else:
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


## wasm 黑盒生成：clue → generate_clue；global → generate_global。
## 注意：黑盒完备穷举仅小盘可行（≤6×6 少量雷），大盘会超时/超 MAX_COMBOS。
func _generate_wasm_levels(mod_name: String, kind: String) -> void:
	var sb := ModAPI.get_sandbox(mod_name)
	if sb == null:
		_toast("wasm 沙箱不可用")
		return
	var gen := WasmLevelGenerator.new()
	var out_dir := "user://mods/%s/levels" % mod_name
	DirAccess.make_dir_recursive_absolute(out_dir)
	var produced := 0
	for t in 40:
		if produced >= 5:
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
	_toast("已为 %s 生成 %d 个 wasm %s关" % [mod_name, produced, "约束" if kind == "global" else "线索"],
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
		if produced >= 5:
			break
		var level := gen.generate_with_engine(ModAPI.defs, def_name, "", size, mine_count, t + 1, topo)
		if level.is_empty():
			continue
		var f := FileAccess.open("%s/%s_%02d.json" % [out_dir, def_name, produced + 1], FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(level, "  "))
			f.close()
			produced += 1
	_toast("已为 %s 生成 %d 关" % [def_name, produced], produced == 0)


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
		if produced >= 5:
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
	_toast("已为规则 %s 生成 %d 关" % [rule_id, produced], produced == 0)


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
