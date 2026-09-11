# win_condition.gd —— 胜负域（文档 23 号 §15.6 WinConditionPlugin ㉕）
# 引擎级原语之一：声明一种胜负判定。默认 = 经典扫雷（GDD R10）。
#
# 这是 P6「胜负原语化」：把 board.gd 里硬编码的判胜（_check_win）与判负（reveal 处
# is_mine → LOST）抽成可覆盖的策略对象。默认实例行为与抽之前**逐字节等价**，零行为变更。
#
# 契约（子类覆盖）：
#   is_won(board) -> bool          胜利是否达成
#   on_reveal_mine(board) -> bool  翻开雷是否判负（默认 true）
# 命名约定：*Plugin + get_*_id()/get_id()/describe()，与 ActionPlugin / RulePlugin 一致。
class_name WinConditionPlugin
extends RefCounted


## 胜负 id（唯一）。子类实现。默认经典。
func get_win_id() -> StringName:
	return &"classic"


## PluginManager 统一注册句柄（映射到胜负 id）。
func get_id() -> StringName:
	return get_win_id()


## 胜利是否达成（GDD R10）：所有雷位被插旗，或剩余未知格数 == 剩余雷数。
## 注意：**不是**「所有非雷格翻开」——安全格可以保持未翻开（R10 与对标游戏的差异点）。
func is_won(board: Board) -> bool:
	var flagged_mines := 0
	var unknown_cells := 0
	for pos in board.grid.all_positions():
		var cell: Cell = board.grid.get_cell(pos)
		if cell == null:
			continue
		if cell.is_mine and cell.state == Cell.State.FLAGGED:
			flagged_mines += 1
		if cell.state == Cell.State.HIDDEN or cell.state == Cell.State.QUESTION:
			unknown_cells += 1
	var remaining_mines: int = board.total_mines - flagged_mines
	return flagged_mines == board.total_mines or unknown_cells == remaining_mines


## 玩家翻开雷时是否判负。默认 true（经典扫雷：翻雷即输）。
## 覆盖场景：无猜教学模式（翻雷只提示、不判负）、生存模式（有生命条）等。
func on_reveal_mine(_board: Board) -> bool:
	return true


## 说明（进规则图鉴 / Mod 信息）。
func describe() -> Dictionary:
	return {"name": get_win_id(), "rule_text": "经典扫雷胜负：翻雷判负，插满全部雷或全盘确定判胜"}
