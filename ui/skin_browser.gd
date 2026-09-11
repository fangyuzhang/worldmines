# skin_browser.gd —— 皮肤浏览页（设置面板「皮肤」选项卡）
# 网格展示内置主题 + Mod 皮肤；点击切换、删除（内置不可删）、导入 .zip。
# 激活皮肤卡片显示强调边框 + 「使用中」角标；预览缺失时显示 accent 色块。
extends Control

const PREVIEW_SIZE := Vector2(160, 90)

var _grid: GridContainer
var _cards: Dictionary = {}   # skin_id -> {"card": PanelContainer, "badge": Label}


func _ready() -> void:
	add_to_group("themed")
	ThemeManager.theme_changed.connect(_on_theme_changed)
	SkinService.skins_changed.connect(_rebuild)
	_build_ui()
	_rebuild()


func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 16
	vbox.offset_right = -16
	vbox.offset_top = 12
	vbox.offset_bottom = -12
	vbox.add_theme_constant_override("separation", 12)
	add_child(vbox)

	# 工具条
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 12)
	var tip := Label.new()
	tip.text = "皮肤可全局换肤；内置主题不可删除。"
	tip.add_theme_font_size_override("font_size", 14)
	tip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(tip)
	var import_btn := Button.new()
	import_btn.text = "导入皮肤"
	import_btn.focus_mode = Control.FOCUS_NONE
	import_btn.pressed.connect(_on_import)
	bar.add_child(import_btn)
	vbox.add_child(bar)

	# 滚动网格
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)


func _rebuild() -> void:
	if _grid == null:
		return
	for c in _grid.get_children():
		c.queue_free()
	_cards.clear()
	for skin in SkinService.skins:
		_grid.add_child(_make_card(skin))
	_apply_card_styles()


func _make_card(skin: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(220, 168)
	card.mouse_filter = Control.MOUSE_FILTER_STOP

	# 中间容器：PanelContainer 只允许一个子节点，角标放这里
	var inner := Control.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.add_child(inner)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 10
	vb.offset_right = -10
	vb.offset_top = 10
	vb.offset_bottom = -10
	vb.add_theme_constant_override("separation", 6)
	inner.add_child(vb)

	# 预览（或 accent 色块）
	var img := Image.load_from_file(skin.get("preview", "")) if FileAccess.file_exists(skin.get("preview", "")) else null
	if img != null:
		var tex := TextureRect.new()
		tex.custom_minimum_size = PREVIEW_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.texture = ImageTexture.create_from_image(img)
		tex.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		vb.add_child(tex)
	else:
		var sw := ColorRect.new()
		sw.custom_minimum_size = PREVIEW_SIZE
		sw.color = ThemeManager.accent()
		sw.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		vb.add_child(sw)

	# 名称
	var name_lb := Label.new()
	name_lb.text = skin["name"]
	name_lb.add_theme_font_size_override("font_size", 16)
	name_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_lb)

	# 作者 · 版本
	var meta_lb := Label.new()
	meta_lb.text = "%s · v%s" % [skin["author"], skin["version"]]
	meta_lb.add_theme_font_size_override("font_size", 12)
	meta_lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(meta_lb)

	# 底部按钮行
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	if not skin["builtin"]:
		var del := Button.new()
		del.text = "删除"
		del.focus_mode = Control.FOCUS_NONE
		del.pressed.connect(_on_delete.bind(skin["id"], skin["name"]))
		row.add_child(del)
	var info := Button.new()
	info.text = "i"
	info.focus_mode = Control.FOCUS_NONE
	info.tooltip_text = "详情"
	info.pressed.connect(_on_info.bind(skin))
	row.add_child(info)
	vb.add_child(row)

	# 使用中角标（右上角）
	var badge := Label.new()
	badge.text = "使用中"
	badge.add_theme_font_size_override("font_size", 11)
	badge.anchor_left = 1.0
	badge.anchor_right = 1.0
	badge.offset_left = -62
	badge.offset_top = 8
	badge.offset_right = -8
	badge.offset_bottom = 28
	badge.visible = false
	inner.add_child(badge)

	# 点击切换
	card.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			SkinService.activate(skin["id"])
			_apply_card_styles())

	_cards[skin["id"]] = {"card": card, "badge": badge}
	return card


## 更新所有卡片样式与「使用中」角标（皮肤切换/主题变化时调用）。
func _apply_card_styles() -> void:
	for id in _cards:
		var entry: Dictionary = _cards[id]
		var card: PanelContainer = entry["card"]
		var badge: Label = entry["badge"]
		var active: bool = SkinService.active_skin_id == id
		var sb := StyleBoxFlat.new()
		sb.bg_color = ThemeManager.card()
		sb.set_corner_radius_all(12)
		if active:
			sb.set_border_width_all(2)
			sb.border_color = ThemeManager.accent()
		else:
			sb.set_border_width_all(1)
			sb.border_color = ThemeManager.grid_line()
		card.add_theme_stylebox_override("panel", sb)
		badge.visible = active
		badge.add_theme_color_override("font_color", ThemeManager.accent())


func _on_delete(skin_id: String, skin_name: String) -> void:
	var dlg := ConfirmationDialog.new()
	dlg.dialog_text = "删除皮肤「%s」？此操作不可恢复。" % skin_name
	dlg.ok_button_text = "删除"
	dlg.cancel_button_text = "取消"
	dlg.confirmed.connect(func():
		var r := SkinService.remove(skin_id)
		_toast("皮肤已删除" if r["ok"] else "删除失败：%s" % r["reason"]))
	add_child(dlg)
	dlg.popup_centered()


func _on_info(skin: Dictionary) -> void:
	var kind := "内置主题" if skin["builtin"] else "Mod 皮肤"
	var dlg := AcceptDialog.new()
	dlg.dialog_text = "名称：%s\n作者：%s\n版本：%s\n底版：%s\n类型：%s" % [
		skin["name"], skin["author"], skin["version"], skin.get("base", "dark"), kind]
	dlg.ok_button_text = "关闭"
	add_child(dlg)
	dlg.popup_centered()


func _on_import() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.zip", "皮肤包 (*.zip)")
	fd.file_selected.connect(func(path: String):
		var r := SkinService.import_zip(path)
		_toast("皮肤已导入" if r["ok"] else "导入失败：%s" % r["reason"]))
	add_child(fd)
	fd.popup_centered()


func _toast(msg: String) -> void:
	var lb := Label.new()
	lb.text = msg
	lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", 16)
	lb.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	lb.offset_top = -40
	lb.custom_minimum_size = Vector2(0, 32)
	add_child(lb)
	var timer := Timer.new()
	timer.wait_time = 2.0
	timer.one_shot = true
	timer.timeout.connect(lb.queue_free)
	timer.timeout.connect(timer.queue_free)
	add_child(timer)
	timer.start()


func _on_theme_changed() -> void:
	_apply_card_styles()
