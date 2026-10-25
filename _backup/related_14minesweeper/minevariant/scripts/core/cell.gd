class_name Cell
extends RefCounted
## 单个格子：只存状态，不存显示（显示由线索系统决定）。

enum State { HIDDEN, REVEALED, FLAGGED }

var is_mine: bool = false
var state: State = State.HIDDEN

func is_revealed() -> bool:
	return state == State.REVEALED

func is_flagged() -> bool:
	return state == State.FLAGGED

func is_hidden() -> bool:
	return state == State.HIDDEN
