# cell.gd —— 格子数据（文档 §4.2）
# { state, value, hidden_interval, comps }
# state ∈ { HIDDEN, REVEALED, FLAGGED, QUESTION }
class_name Cell
extends RefCounted

enum State { HIDDEN, REVEALED, FLAGGED, QUESTION }

var state: int = State.HIDDEN
var is_mine: bool = false
var value: int = 0                # 引擎视角真实线索值（仅渲染/终局揭晓/生成器/体检使用）
var hidden_interval: Vector2i = Vector2i(-1, -1)  # ? 格遮蔽区间 [lo, hi]；(-1,-1) = 非 ? 格
var comps: Array[CellComp] = []   # 组件列表，P0 为空，P4 沙箱实装


## 是否「? 线索格」：已翻开 + 带 interval 遮蔽。
func is_hidden_clue() -> bool:
	return state == State.REVEALED and hidden_interval.x >= 0


## 玩家视角约束（文档 §3.3 双视角）。求解/计数/提示的唯一入口。
## 返回：{ "type": "equality", "value": v } 或 { "type": "interval", "lo": a, "hi": b } 或 { "type": "none" }
func get_player_constraint() -> Dictionary:
	if state != State.REVEALED:
		return { "type": "none" }
	if is_hidden_clue():
		return { "type": "interval", "lo": hidden_interval.x, "hi": hidden_interval.y }
	return { "type": "equality", "value": value }
