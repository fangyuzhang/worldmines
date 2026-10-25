extends Control
## 棋盘视图：用 _draw 自绘格子，处理左键揭开/右键插旗/中键和弦。
## 纯数据→显示，不持有对局逻辑（逻辑在 GameController）。

var controller: GameController
var cell_size := 36.0
var spacing := 1.0
var font_size := 16

# 配色（GDD §8.1.2）
const COLOR_BG := Color("#1a1a2e")
const COLOR_HIDDEN := Color("#3a3a5c")
const COLOR_REVEALED := Color("#252540")
const COLOR_FLAG := Color("#ffb74d")
const COLOR_MINE := Color("#f44336")
const COLOR_NUMBERS := {
	1: Color("#4fc3f7"), 2: Color("#81c784"), 3: Color("#e57373"),
	4: Color("#ba68c8"), 5: Color("#ffb74d"), 6: Color("#4db6ac"),
	7: Color("#90a4ae"), 8: Color("#e0e0e0"),
}

func set_controller(gc: GameController) -> void:
	controller = gc
	custom_minimum_size = Vector2(
		cell_size * controller.cols, cell_size * controller.rows)
	queue_redraw()

func _draw() -> void:
	if controller == null or controller.board == null:
		return
	var board := controller.board
	for r in board.rows:
		for c in board.cols:
			_draw_cell(board, r, c)

func _draw_cell(board: Board, r: int, c: int) -> void:
	var rect := Rect2(Vector2(c * (cell_size + spacing), r * (cell_size + spacing)),
		Vector2(cell_size, cell_size))
	var cell := board.cell(r, c)

	if cell.is_revealed():
		draw_rect(rect, COLOR_REVEALED)
		if board.is_mine(r, c):
			# 失败时显示所有雷；踩雷点红圆+爆点，其余灰
			var is_lost := controller.status == GameController.Status.LOST
			var mine_color := Color("#8b8b9e")
			if is_lost and controller.lost_pos == Vector2i(r, c):
				mine_color = COLOR_MINE
			draw_circle(rect.get_center(), cell_size * 0.28, mine_color)
			return
		_draw_text(controller.display_text(r, c), rect, Color.WHITE)
	else:
		draw_rect(rect, COLOR_HIDDEN)
		draw_rect(rect.grow(-3), Color("#4a4a6c"))  # 轻微凸起效果
		if cell.is_flagged():
			# 失败后：错旗标红X，正确旗保持橙色
			if controller.status == GameController.Status.LOST and not board.is_mine(r, c):
				_draw_text("X", rect, Color("#f44336"))
			else:
				# 旗：杆 + 三角旗
				var base := rect.position + Vector2(cell_size * 0.3, cell_size * 0.75)
				draw_rect(Rect2(base.x - 1, base.y - cell_size * 0.55, 2, cell_size * 0.55), COLOR_FLAG)
				var pole_top := Vector2(base.x, base.y - cell_size * 0.55)
				draw_colored_polygon(PackedVector2Array([
					pole_top, pole_top + Vector2(cell_size * 0.35, cell_size * 0.12),
					pole_top + Vector2(0, cell_size * 0.28)]), COLOR_FLAG)
		elif controller.status == GameController.Status.LOST and board.is_mine(r, c):
			# 失败时漏标的雷：浅红显示
			draw_circle(rect.get_center(), cell_size * 0.28, Color("#c94f4f"))

func _draw_text(txt: String, rect: Rect2, color: Color) -> void:
	if txt.is_empty():
		return
	var font := get_theme_default_font()
	# 多行线索（如 HV "2/1"）拆分绘制
	var lines := txt.split("/")
	var line_h := font_size + 2
	var start_y := rect.get_center().y - line_h * (lines.size() - 1) * 0.5
	for i in lines.size():
		var ln: String = lines[i]
		var text_size := font.get_string_size(ln, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		var pos := Vector2(rect.get_center().x - text_size.x * 0.5,
			start_y + i * line_h + font_size * 0.4)
		draw_string(font, pos, ln, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _gui_input(event: InputEvent) -> void:
	if controller == null:
		return
	if event is InputEventMouseButton and event.pressed:
		var pos := Vector2i(
			int(event.position.y / (cell_size + spacing)),
			int(event.position.x / (cell_size + spacing)))
		if not controller.board.in_bounds(pos.x, pos.y):
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				controller.reveal(pos.x, pos.y)
			MOUSE_BUTTON_RIGHT:
				controller.toggle_flag(pos.x, pos.y)
			MOUSE_BUTTON_MIDDLE:
				controller.chord(pos.x, pos.y)
		queue_redraw()
		get_viewport().set_input_as_handled()