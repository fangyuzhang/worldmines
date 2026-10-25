# main.gd —— P0 经典扫雷可玩主场景（文档 §4.5 验收：翻开/插旗/判负/判胜/计时/终局冻结）
# 矢量自绘（CanvasItem._draw），符合文档 §2.1「矢量 UI」决策与 §8.13 护眼深色配色。
# 棋盘自适应窗口大小（全屏放大），文字/雷/? 精确居中。
extends Control

const LEVELS := ["classic_01", "classic_02", "classic_03", "classic_04", "classic_05", "classic_06", "classic_07", "classic_08", "classic_09", "classic_10"]

const HUD_HEIGHT := 44.0   # 顶部信息条高度
const STATUS_HEIGHT := 44.0  # 底部状态条高度
const BOARD_MARGIN := 24.0   # 棋盘四周留白

# 护眼深色主题（文档 §8.13）
const COL_BG := Color("#1E1E24")
const COL_HIDDEN := Color("#3A3A42")
const COL_REVEALED := Color("#232328")
const COL_TEXT := Color("#E0E0E6")
const COL_MINE := Color("#C0504D")
const COL_FLAG := Color("#C0504D")
const COL_QUESTION := Color("#888892")

const NUMBER_COLORS := {1: Color("#7CB9E8"), 2: Color("#8CCB8C"), 3: Color("#C0504D"), 4: Color("#7A8CCB"), 5: Color("#B58A5A"), 6: Color("#5AA0A0"), 7: Color("#B0B0B0"), 8: Color("#888892")}

var board: Board
var level_index := 0
var timer := 0.0
var _won := false
var _lost := false

# 布局缓存：格子边长、棋盘左上角（窗口尺寸变化时重算）
var _cell := 52.0
var _origin := Vector2.ZERO

@onready var hud_label: Label = $HUD
@onready var status_label: Label = $Status


func _ready() -> void:
	RNGService.self_check()
	load_level(level_index)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_compute_layout()
		queue_redraw()


func load_level(idx: int) -> void:
	level_index = idx
	var id: String = LEVELS[idx]
	var file := FileAccess.open("res://levels/%s.json" % id, FileAccess.READ)
	if file == null:
		push_error("无法加载关卡: " + id)
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()

	board = Board.new()
	board.game_won.connect(_on_won)
	board.game_lost.connect(_on_lost)
	board.load_level(data)

	timer = 0.0
	_won = false
	_lost = false
	status_label.text = ""
	_compute_layout()
	queue_redraw()
	_update_hud()


func _process(delta: float) -> void:
	if board != null and board.state == Board.GameState.PLAYING:
		timer += delta
		_update_hud()


func _update_hud() -> void:
	var stats := board.get_stats()
	hud_label.text = "关卡 %s  雷 %d/%d  剩余 %d  用时 %.1fs" % [LEVELS[level_index], stats["flagged"], board.total_mines, stats["remaining"], timer]


func _on_won() -> void:
	_won = true
	status_label.text = "胜利！用时 %.1fs（按 R 重开，方向键切换关卡）" % timer
	queue_redraw()


func _on_lost() -> void:
	_lost = true
	status_label.text = "踩雷失败（按 R 重开）"
	queue_redraw()


## 根据窗口大小与棋盘尺寸，计算格子边长与棋盘左上角，使棋盘铺满可用区域。
func _compute_layout() -> void:
	if board == null or board.grid == null:
		return
	var gsize := board.grid.size()
	var avail_w := size.x - BOARD_MARGIN * 2.0
	var avail_h := size.y - HUD_HEIGHT - STATUS_HEIGHT - BOARD_MARGIN * 2.0
	# 取宽高方向可容纳的最小边长，保证整盘放下且铺满
	_cell = min(avail_w / gsize.x, avail_h / gsize.y)
	_cell = max(_cell, 4.0)  # 极端缩窗保护
	var board_w := _cell * gsize.x
	var board_h := _cell * gsize.y
	_origin = Vector2((size.x - board_w) * 0.5, HUD_HEIGHT + BOARD_MARGIN + (avail_h - board_h) * 0.5)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), COL_BG)
	if board == null or board.grid == null:
		return

	var gsize := board.grid.size()
	var gap := maxf(1.0, _cell * 0.06)  # 格子间缝隙
	for r in gsize.y:
		for c in gsize.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			var rect := Rect2(_origin + Vector2(c * _cell, r * _cell), Vector2(_cell - gap, _cell - gap))

			match cell.state:
				Cell.State.HIDDEN:
					draw_rect(rect, COL_HIDDEN)
				Cell.State.REVEALED:
					draw_rect(rect, COL_REVEALED)
					if cell.is_mine:
						_draw_centered_text(rect, "💣", COL_MINE)
					elif cell.is_hidden_clue():
						_draw_centered_text(rect, "?", COL_QUESTION)
					elif cell.value > 0:
						_draw_centered_text(rect, str(cell.value), NUMBER_COLORS.get(cell.value, COL_TEXT))
				Cell.State.FLAGGED:
					draw_rect(rect, COL_HIDDEN)
					_draw_centered_text(rect, "🚩", COL_FLAG)
				Cell.State.QUESTION:
					draw_rect(rect, COL_HIDDEN)
					_draw_centered_text(rect, "❓", COL_QUESTION)


## 在格子内精确居中绘制文字（水平用测量宽度，垂直用字体的 ascent/descent 基线）。
func _draw_centered_text(rect: Rect2, text: String, color: Color) -> void:
	var font := get_theme_default_font()
	var fsize := int(_cell * 0.42)
	var text_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize).x
	var x := rect.position.x + (rect.size.x - text_w) * 0.5
	# 垂直居中：基线 = 格子中心 + (ascent - descent) / 2
	var ascent := font.get_ascent(fsize)
	var descent := font.get_descent(fsize)
	var baseline := rect.position.y + (rect.size.y + ascent - descent) * 0.5
	draw_string(font, Vector2(x, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, color)


func _cell_at(mouse: Vector2) -> Vector2i:
	if board == null or board.grid == null:
		return Vector2i(-1, -1)
	var c := int(floor((mouse.x - _origin.x) / _cell))
	var r := int(floor((mouse.y - _origin.y) / _cell))
	return Vector2i(c, r)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var pos := _cell_at(event.position)
		if board != null and board.grid != null and board.grid.in_board(pos):
			match event.button_index:
				MOUSE_BUTTON_LEFT:
					board.reveal(pos)
				MOUSE_BUTTON_RIGHT:
					board.toggle_flag(pos)
			queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_R:
				load_level(level_index)
			KEY_LEFT:
				load_level((level_index - 1 + LEVELS.size()) % LEVELS.size())
			KEY_RIGHT:
				load_level((level_index + 1) % LEVELS.size())
