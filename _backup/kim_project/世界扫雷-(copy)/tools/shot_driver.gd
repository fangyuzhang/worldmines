# shot_driver.gd —— 验收截图驱动（P0 沿用 + P1~P3 变体 + 体验层新页）
# 运行方式（需要真实显示环境，headless 无法渲染）：
#   godot --path <项目根> --resolution 1280x720 -s res://tools/shot_driver.gd
# 产出：res://screenshots/*.png（已存在的 P0 同名文件不覆盖，新图前缀见下）。
# 驱动走真实输入管线（Input.parse_input_event）+ 视口抓帧；关卡用 GameSession.start_level 直开，
# 避免依赖按钮文案（选关页已改为分组浏览，P0 的「第 N 关」按钮不再存在）。
# 技术注记：-s 模式下本脚本先于 autoload 注册编译，故 autoload 用 root.get_node("/root/X") 动态取。
extends SceneTree

const OUT_DIR := "res://screenshots"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_run()


func _gs() -> Node:
	return root.get_node("/root/GameSession")


# ==================== 主流程 ====================

func _run() -> void:
	print("[shot] 驱动开始")
	# 清掉上一次运行遗留的崩溃残留（否则主菜单会弹恢复窗，污染截图）
	SaveCoordinator.clear_temp()

	# ① 主菜单（含新增「规则图鉴」按钮）
	change_scene_to_file("res://ui/main_menu.tscn")
	await _frames(8)
	await _shot("10_main_menu.png")

	# ② 规则图鉴（体验层新页）
	await _click_button("规则图鉴")
	await _frames(6)
	await _shot("11_codex.png")

	# ③ 选关页（六分组 + 已通关进度标记）
	change_scene_to_file("res://ui/main_menu.tscn")
	await _frames(6)
	await _click_button("开始游戏")
	await _frames(8)
	await _shot("12_level_select.png")

	# ④ 经典对局 + 插旗
	await _open_level("res://levels/classic_01.json")
	await _reveal_safe_cells(4)
	await _flag_one_mine()
	await _frames(3)
	await _shot("13_playing_classic.png")

	# ④b 对局内设置弹窗（HUD「设置」按钮）
	await _click_button("设置")
	await _frames(8)
	await _shot("13b_settings_popup.png")
	await _click_button("关闭")
	await _frames(3)

	# ⑤ 提示高亮（布一个必然局面：某已翻开格 value>0 → 标其邻雷 → 请求提示）
	await _make_hint_scene()
	await _frames(2)
	_clear_hover_and_cursor()
	await _frames(2)
	await _shot("14_hint.png")

	# ⑥ 线索混合（4n+sc，一格两个线索值）
	await _open_level("res://levels/4n_sc_01.json")
	await _reveal_safe_cells(2, true)
	await _frames(3)
	await _shot("15_mixed_clue_4n_sc.png")

	# ⑦ 双布局（mx+rl）
	await _open_level("res://levels/mx_rl_01.json")
	await _reveal_safe_cells(2, true)
	await _frames(3)
	await _shot("16_dual_layout_mx_rl.png")

	# ⑧ 骨牌布局（dt）
	await _open_level("res://levels/dt_01.json")
	await _reveal_safe_cells(2, true)
	await _frames(3)
	await _shot("17_domino_dt.png")

	# ⑨ 终局失败（点一颗雷）
	await _open_level("res://levels/classic_02.json")
	await _reveal_safe_cells(3)
	await _click_one_mine()
	await _frames(8)
	await _shot("18_endgame_lose.png")

	# ⑩ 终局胜利（翻完所有安全格）
	await _open_level("res://levels/classic_03.json")
	await _reveal_all_safe()
	await _frames(8)
	await _shot("19_endgame_win.png")

	# ⑪ 崩溃恢复弹窗（留 TEMP 残留后回主菜单）
	await _open_level("res://levels/classic_04.json")
	await _reveal_safe_cells(2)
	await create_timer(5.6).timeout  # 过自动存档防抖窗口
	await _reveal_safe_cells(1)
	_gs().set("state", 0)  # IDLE
	_gs().set("board", null)
	change_scene_to_file("res://ui/main_menu.tscn")
	await _frames(8)
	await _shot("20_restore_dialog.png")

	print("[shot] 全部截图完成")
	quit()


# ==================== 场景操作 ====================

func _open_level(path: String) -> void:
	var ok: bool = _gs().start_level(path)
	if not ok:
		print("[shot] 关卡加载失败: ", path)
		return
	change_scene_to_file("res://ui/board_view.tscn")
	await _frames(8)


func _board() -> Board:
	return _gs().get("board")


## 翻开 n 个安全格。bounded=true 时只揭 value>0 的（避免 0 格扩散翻完全场，便于截变体盘面）
func _reveal_safe_cells(n: int, bounded: bool = false) -> void:
	var b := _board()
	if b == null or b.grid == null:
		return
	var size := b.grid.size()
	var done := 0
	for r in size.y:
		if done >= n:
			break
		for c in size.x:
			if done >= n:
				break
			var pos := Vector2i(c, r)
			var cell := b.grid.get_cell(pos)
			if cell.state != Cell.State.HIDDEN or cell.is_mine:
				continue
			if bounded and (cell.value == 0 or (cell.value is Array and (cell.value as Array).is_empty())):
				continue  # value=0 会 flood 整个盘
			await _click_cell(pos)
			await _frames(1)
			done += 1


## 翻完所有安全格（触发胜利）
func _reveal_all_safe() -> void:
	var b := _board()
	if b == null or b.grid == null:
		return
	var size := b.grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := b.grid.get_cell(pos)
			if cell.state == Cell.State.HIDDEN and not cell.is_mine:
				await _click_cell(pos)


## 给一颗雷插旗（取第一颗雷）
func _flag_one_mine() -> void:
	var b := _board()
	if b == null or b.grid == null:
		return
	var size := b.grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := b.grid.get_cell(pos)
			if cell.is_mine and cell.state == Cell.State.HIDDEN:
				await _right_click_cell(pos)
				return


## 点一颗雷（触发失败）
func _click_one_mine() -> void:
	var b := _board()
	if b == null or b.grid == null:
		return
	var size := b.grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := b.grid.get_cell(pos)
			if cell.is_mine:
				await _click_cell(pos)
				return


## 清掉键盘光标和悬停高亮（避免污染截图）
func _clear_hover_and_cursor() -> void:
	var bv := get_current_scene()
	if bv == null:
		return
	bv.set("hover_pos", Vector2i(-1, -1))
	_gs().set("cursor", Vector2i(-1, -1))


## 构造"必有提示"的局面：找一个 value>0 的已翻开格，把它的雷邻格全标旗 → 剩余邻格必安全。
func _make_hint_scene() -> void:
	var b := _board()
	if b == null or b.grid == null:
		return
	var size := b.grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := b.grid.get_cell(pos)
			if cell.state != Cell.State.REVEALED:
				continue
			var v = cell.value
			if not (v is int) or int(v) <= 0:
				continue
			for d in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
					  Vector2i(-1, 0), Vector2i(1, 0),
					  Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
				var np: Vector2i = pos + d
				if not b.grid.in_board(np):
					continue
				var nc := b.grid.get_cell(np)
				if nc.is_mine and nc.state == Cell.State.HIDDEN:
					await _right_click_cell(np)
			await _frames(2)
			var steps: Array = _gs().request_hint()
			print("[shot] 请求提示 → ", steps.size(), " 步")
			return


# ==================== 基础设施 ====================

func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(fname: String) -> void:
	await process_frame
	await process_frame
	var img: Image = root.get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUT_DIR.path_join(fname))
	var err := img.save_png(path)
	print("[shot] ", fname, " → ", "OK" if err == OK else "失败" + str(err))


func _all_buttons() -> Array:
	var out: Array = []
	_collect_buttons(get_current_scene(), out)
	return out


func _collect_buttons(n: Node, out: Array) -> void:
	if n is Button:
		out.append(n)
	for c in n.get_children():
		_collect_buttons(c, out)


func _click_button(text: String) -> void:
	for b in _all_buttons():
		if text in (b as Button).text:
			await _click((b as Button).get_global_rect().get_center())
			return
	print("[shot] 未找到按钮: ", text)


func _click(pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	var ev2 := ev.duplicate()
	ev2.pressed = false
	Input.parse_input_event(ev2)
	await process_frame


func _right_click(pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	Input.parse_input_event(ev)
	await process_frame
	var ev2 := ev.duplicate()
	ev2.pressed = false
	Input.parse_input_event(ev2)
	await process_frame


func _cell_center(cell: Vector2i) -> Vector2:
	var bv: Control = get_current_scene()
	return bv.board_origin + (Vector2(cell.x, cell.y) + Vector2(0.5, 0.5)) * bv.cell_px


func _click_cell(cell: Vector2i) -> void:
	await _click(_cell_center(cell))


func _right_click_cell(cell: Vector2i) -> void:
	await _right_click(_cell_center(cell))
