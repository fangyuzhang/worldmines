# cell.gd —— 格子数据（文档 §4.2）
# { state, value, hidden_interval, comps }
# state ∈ { HIDDEN, REVEALED, FLAGGED, QUESTION }
# value 为 Variant：int（单值线索）/ Array[A,B]（HV 双值）/ String "inf"（FR 无雷）。
class_name Cell
extends RefCounted

enum State { HIDDEN, REVEALED, FLAGGED, QUESTION }

var state: int = State.HIDDEN
var is_mine: bool = false
var value: Variant = 0           # 引擎视角真实线索值（int / Array / "inf"）
var value2: Variant = null       # 第二线索值（E 类线索混合；null = 无第二线索）
var hidden_interval: Vector2i = Vector2i(-1, -1)  # ? 格遮蔽区间 [lo, hi]；(-1,-1) = 非 ? 格
## 终极模式「星号格」（对标 doc10 §2.4）：已翻开但**线索值对玩家隐藏**。
## 引擎仍持有真实 value（判负/胜负/离线验证不受影响），只是玩家视角无线索 → 不能拿它推理。
var starred: bool = false
var comps: Array[CellComp] = []   # 组件列表，P0 为空，P4 沙箱实装


## 是否「? 线索格」：已翻开 + 带 interval 遮蔽。
func is_hidden_clue() -> bool:
	return state == State.REVEALED and hidden_interval.x >= 0


## 玩家视角约束（文档 §3.3 双视角）。求解/计数/提示的唯一入口。
## 返回：
##   { "type": "equality", "value": v }        单值线索（含 FR 的 "inf"）
##   { "type": "equality_pair", "a": A, "b": B } HV 双值线索
##   { "type": "interval", "lo": a, "hi": b }  ? 遮蔽格
##   { "type": "none" }                        未翻开
func get_player_constraint() -> Dictionary:
	if state != State.REVEALED:
		return { "type": "none" }
	# 星号格：值对玩家隐藏 → 玩家视角无线索（这正是终极模式的难度来源）
	if starred:
		return { "type": "none" }
	if is_hidden_clue():
		return { "type": "interval", "lo": hidden_interval.x, "hi": hidden_interval.y }
	if value2 != null:
		# E 类线索混合：一格同时给出两个线索约束，按 items 顺序对应 clue / clue2。
		return { "type": "equality_multi", "items": [_single_constraint(value), _single_constraint(value2)] }
	return _single_constraint(value)


## 单个线索值 → 约束 dict（供单线索与线索混合复用）。
func _single_constraint(v: Variant) -> Dictionary:
	if v is Array:
		return { "type": "equality_pair", "a": v[0], "b": v[1] }
	return { "type": "equality", "value": v }


## 线索值是否为"邻域无雷"（用于连锁扩散判定）。双值/射线不参与自动扩散。
## plan1.9 §7.2：雷格的 value 默认 0，须用 is_mine 排除，否则雷格会被误判为零线索。
func is_zero_clue() -> bool:
	return not is_mine and value is int and value == 0
