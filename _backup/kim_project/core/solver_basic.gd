# solver_basic.gd —— 经典规则最小 L0/L1 约束传播（文档 §5.4 / §6.1）
# 纯验证用，不接 UI。只做「一步必推」判定：
#   必安判定：已标旗数 == 线索值，且仍有未翻开格 ⇒ 剩余未翻开格必安全
#   必雷判定：未翻开格数 + 已标旗数 == 线索值，且仍有未翻开格 ⇒ 剩余未翻开格必雷
# ? 格（interval）P0 默认档 [0,max] 恒真，无推理抓手；at_least_one 档 P1 扩展。
class_name SolverBasic
extends RefCounted


## 返回 { "safe": Array[Vector2i], "mine": Array[Vector2i] }
func propagate(board: Board) -> Dictionary:
	var safe: Array[Vector2i] = []
	var mine: Array[Vector2i] = []
	if board.grid == null:
		return { "safe": safe, "mine": mine }

	var size := board.grid.size()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var constraint := board.get_player_constraint(pos)
			if constraint["type"] != "equality":
				continue  # ? 格 P0 不参与一步直推
			var value: int = constraint["value"]

			var flagged := 0
			var hidden: Array[Vector2i] = []
			for nb in board.grid.get_neighbors(pos):
				var nb_cell := board.grid.get_cell(nb)
				if nb_cell.state == Cell.State.FLAGGED:
					flagged += 1
				elif nb_cell.state != Cell.State.REVEALED:
					hidden.append(nb)

			if hidden.is_empty():
				continue
			# 必安判定
			if flagged == value:
				for h in hidden:
					if not safe.has(h):
						safe.append(h)
			# 必雷判定
			elif flagged + hidden.size() == value:
				for h in hidden:
					if not mine.has(h):
						mine.append(h)

	return { "safe": safe, "mine": mine }
