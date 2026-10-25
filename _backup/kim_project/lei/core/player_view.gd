# player_view.gd —— PlayerView 双视角隔离（文档 23 号 §7 / 21 号 R30/R34）
# Mod 唯一合法视图：只含玩家可见信息（状态 / 线索值 / 遮蔽区间），不含任何雷位。
# ⛔ 结构上不存在 is_mine / mine_positions / answer_board —— 这是安全边界，不是约定。
class_name PlayerView
extends RefCounted


# 与 Cell.State 对齐（HIDDEN/REVEALED/FLAGGED/QUESTION）。
const STATE_HIDDEN := 0
const STATE_REVEALED := 1
const STATE_FLAGGED := 2
const STATE_QUESTION := 3


var _grid_size := Vector2i.ZERO
var _states: Dictionary = {}       # Vector2i -> state
var _clues: Dictionary = {}        # Vector2i -> 线索值（仅 REVEALED 且非 ? 格）
var _intervals: Dictionary = {}    # Vector2i -> Vector2i（? 格遮蔽区间 [lo,hi]）
var _total_mines := 0
var _revealed_count := 0
var _flagged_count := 0


## 从 Board 构建只读视图（只拷贝玩家可见信息，绝不拷贝 is_mine）。
static func from_board(board: Board) -> PlayerView:
	var view := PlayerView.new()
	var sz: Vector2i = board.grid.size()
	view._grid_size = sz
	view._total_mines = board.total_mines
	for y in sz.y:
		for x in sz.x:
			var pos := Vector2i(x, y)
			var cell: Cell = board.grid.get_cell(pos)
			if cell == null:
				continue
			view._states[pos] = cell.state
			if cell.state == Cell.State.REVEALED:
				view._revealed_count += 1
				if cell.is_hidden_clue():
					view._intervals[pos] = cell.hidden_interval
				else:
					view._clues[pos] = cell.value
			elif cell.state == Cell.State.FLAGGED:
				view._flagged_count += 1
	return view


func size() -> Vector2i:
	return _grid_size


func get_state(pos: Vector2i) -> int:
	return int(_states.get(pos, STATE_HIDDEN))


func is_revealed(pos: Vector2i) -> bool:
	return int(_states.get(pos, STATE_HIDDEN)) == STATE_REVEALED


func is_flagged(pos: Vector2i) -> bool:
	return int(_states.get(pos, STATE_HIDDEN)) == STATE_FLAGGED


## 线索值（仅已翻开且非 ? 格有值；否则 null）。
func get_clue(pos: Vector2i) -> Variant:
	return _clues.get(pos, null)


## ? 格遮蔽区间（非 ? 格返回 Vector2i(-1,-1)）。
func get_interval(pos: Vector2i) -> Vector2i:
	return _intervals.get(pos, Vector2i(-1, -1))


## 玩家视角约束（与 Cell.get_player_constraint 同构，但由本视图数据构造，不经 Cell 对象）。
func get_player_constraint(pos: Vector2i) -> Dictionary:
	if not _states.has(pos):
		return {"type": "none"}
	if int(_states[pos]) != STATE_REVEALED:
		return {"type": "none"}
	if _intervals.has(pos):
		var iv: Vector2i = _intervals[pos]
		return {"type": "interval", "lo": iv.x, "hi": iv.y}
	return {"type": "equality", "value": _clues.get(pos)}


func revealed_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for pos in _states:
		if int(_states[pos]) == STATE_REVEALED:
			out.append(pos)
	return out


func flagged_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for pos in _states:
		if int(_states[pos]) == STATE_FLAGGED:
			out.append(pos)
	return out


func total_mines() -> int:
	return _total_mines


func remaining_mines() -> int:
	return _total_mines - _flagged_count


func revealed_count() -> int:
	return _revealed_count


func flag_count() -> int:
	return _flagged_count
