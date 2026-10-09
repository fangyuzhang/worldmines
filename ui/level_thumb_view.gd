# level_thumb_view.gd —— 数据缩略图的小预览控件（功能清单 §8「自动缩略图」）
#
# 【它只做一件事】把 `core/level_thumbnail.gd` 产出的**索引网格 + 调色板**涂成色块。
#   不解析关卡 JSON、不参与玩法判定、不渲染 3D —— 缩略图本身是确定性纯数据（headless 可测），
#   本控件只是它的"显示器"，所以两边可以各自单测。
#
# 【为什么用 `_draw()` 而不是一堆 ColorRect】32×32 = 1024 个节点只为画一次预览太重，而且会把
#   节点塞进场景树（UI 用例会扫可见控件）。`_draw()` 只发绘制指令，格子数再多也不建节点。
#
# 【配色口径】颜色只表达"空 / 雷 / 数字深浅"：与主题解耦（主题里没有"缩略图色板"这种槽位，
#   与 ui/level_editor.gd 的 ISSUE_LEVEL_UI 同理：硬编码 + 注释比散落取值更好查）。
extends Control

const THUMB := preload("res://core/level_thumbnail.gd")

## 雷格：红。数字格：浅蓝（小数字）→ 深蓝（大数字）线性插值。空格不涂（保持透明）。
const MINE_COLOR := Color(0.85, 0.24, 0.20, 1.0)
const CLUE_LO := Color(0.74, 0.81, 0.91, 1.0)
const CLUE_HI := Color(0.20, 0.32, 0.55, 1.0)
## 数字归一化的分母：邻雷数 ≥8 就是"最深"（超过不再变深，避免 8 邻域以外没有语义）。
const CLUE_FULL := 8.0
## 每格细边：不画的话相邻同色格会糊成一片（缩略图就只剩个色块，看不出格子）。
const CELL_EDGE := Color(0.0, 0.0, 0.0, 0.16)

var _grid: Array = []
var _palette: Array = []
var _rows := 0
var _cols := 0
var _cropped := false
var _hash := ""


## 载入一份缩略图（`LevelThumbnail.build` 的产物或其 JSON 化字典）。非法输入 ⇒ 清空。
func set_thumb(t: Variant) -> void:
	var d: Dictionary = {}
	if t is Dictionary:
		d = THUMB.from_dict(t)
	if not bool(d.get("ok", false)):
		clear()
		return
	_grid = d["grid"]
	_palette = d["palette"]
	_rows = int(d["rows"])
	_cols = int(d["cols"])
	_cropped = bool(d.get("cropped", false))
	_hash = str(d.get("hash", ""))
	queue_redraw()


func clear() -> void:
	_grid = []
	_palette = []
	_rows = 0
	_cols = 0
	_cropped = false
	_hash = ""
	queue_redraw()


func has_thumb() -> bool:
	return _rows > 0 and _cols > 0 and _grid.size() >= _rows * _cols


func thumb_hash() -> String:
	return _hash


func is_cropped() -> bool:
	return _cropped


func thumb_size() -> Vector2i:
	return Vector2i(_cols, _rows)


func _draw() -> void:
	if not has_thumb():
		return
	var w := size.x / float(_cols)
	var h := size.y / float(_rows)
	for y in _rows:
		for x in _cols:
			var idx := int(_grid[y * _cols + x])
			if idx < 0 or idx >= _palette.size():
				continue
			var c := _color_of(str(_palette[idx]))
			if c.a <= 0.0:
				continue
			var r := Rect2(Vector2(float(x) * w, float(y) * h), Vector2(w, h))
			draw_rect(r, c, true)
			draw_rect(r, CELL_EDGE, false, 1.0)


## 码 → 颜色（**唯一的口径**：码的解析规则在 core 的 LevelThumbnail 常量里，这里只做配色）。
func _color_of(code: String) -> Color:
	if code == THUMB.EMPTY_CODE:
		return Color(0, 0, 0, 0)
	if code == THUMB.MINE_CODE:
		return MINE_COLOR
	if code.begins_with(THUMB.CLUE_PREFIX):
		var n := int(code.substr(THUMB.CLUE_PREFIX.length()))
		return CLUE_LO.lerp(CLUE_HI, clampf(float(n) / CLUE_FULL, 0.0, 1.0))
	return Color(0, 0, 0, 0)