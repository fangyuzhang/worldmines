class_name Solver
extends RefCounted
## 逻辑求解器：验证一个雷阵是否"仅凭数字线索即可唯一确定"。
##
## 用途：BoardGenerator 在生成后调用 is_unique_solution()，若返回 false 则重新生成，
## 从而保证产出的每局都是逻辑可解的（无无解局、无猜雷）。
##
## 算法：模拟玩家从首点开始，先洪水展开（is_flood_seed 种子格全部揭开），
## 再反复应用经典确定性推理：
##   - 某数字格周围未知格中已确定雷数 = 该数字 → 剩余未知格全安全（揭开并可能连锁洪水）
##   - 某数字格周围未确定格数恰好 = 剩余雷数 → 这些未知格全是雷
## 直到无法推进。若仍存在非雷格未知 → 非唯一解，返回 false。
## 这是保守但正确的推理：宁可重生成，绝不把不可解局放行。
##
## reveal_sequence 记录"确定安全并揭开"的格子坐标（供端到端验证用）。

## 已知状态编码
const UNKNOWN := 0
const SAFE := 1
const MINE := 2

var rows: int
var cols: int
var _state: Array = []        # 2D Array[int]
var _count: Array = []        # 2D Array[int]：该格推理雷数，-1 表示未知/不参与
var _board: Board
var _clues: ClueComputer
var reveal_sequence: Array = []  # Array[Vector2i]：按推理顺序确定的安全格

func _init(p_board: Board, p_clues: ClueComputer, _p_mine_count: int) -> void:
	_board = p_board
	_clues = p_clues
	rows = p_board.rows
	cols = p_board.cols
	for r in rows:
		var srow: Array = []
		var crow: Array = []
		for c in cols:
			srow.append(UNKNOWN)
			crow.append(-1)
		_state.append(srow)
		_count.append(crow)

## 取该格参与求解的雷数约束。多 B 叠加取第一个有效值；无有效值返回 -1。
func _constraint(r: int, c: int) -> int:
	if _count[r][c] >= 0:
		return _count[r][c]
	var n := -1
	for clue in _clues.clues_for(_board, r, c):
		if clue.solver_count >= 0:
			n = clue.solver_count
			break
	_count[r][c] = n
	return n

## 主入口：从 (start_r, start_c) 开始，返回 true 表示所有非雷格都能被逻辑确定。
func is_unique_solution(start_r: int, start_c: int) -> bool:
	if _board.is_mine(start_r, start_c):
		return false
	reveal_sequence.clear()
	_flood_open(start_r, start_c)
	while _infer_once():
		pass
	for r in rows:
		for c in cols:
			if _state[r][c] == UNKNOWN and not _board.is_mine(r, c):
				return false
	return true

## 洪水展开：把所有能通过 flood 连锁展开的安全格揭开并记录约束。
func _flood_open(r: int, c: int) -> void:
	var stack: Array[Vector2i] = [Vector2i(r, c)]
	while not stack.is_empty():
		var pos: Vector2i = stack.pop_back()
		if _board.is_mine(pos.x, pos.y) or _state[pos.x][pos.y] != UNKNOWN:
			continue
		_state[pos.x][pos.y] = SAFE
		reveal_sequence.append(pos)
		_constraint(pos.x, pos.y)
		if _clues.is_flood_seed(_board, pos.x, pos.y):
			for nb in _board.neighbor8_coords(pos.x, pos.y):
				if _state[nb.x][nb.y] == UNKNOWN and not _board.is_mine(nb.x, nb.y):
					stack.append(nb)

## 推理一轮。返回 true 表示本轮确定了至少一个新格。
func _infer_once() -> bool:
	var progress := false
	for r in rows:
		for c in cols:
			if _state[r][c] != SAFE:
				continue
			var n := _constraint(r, c)
			if n < 0:
				continue
			var unknown: Array[Vector2i] = []
			var known_mines := 0
			for nb in _board.neighbor8_coords(r, c):
				match _state[nb.x][nb.y]:
					UNKNOWN: unknown.append(nb)
					MINE: known_mines += 1
			if unknown.is_empty():
				continue
			var need := n - known_mines
			if need < 0:
				continue
			if need == 0:
				# 剩余未知格全安全
				for p in unknown:
					_state[p.x][p.y] = SAFE
					reveal_sequence.append(p)
					_constraint(p.x, p.y)
					if _clues.is_flood_seed(_board, p.x, p.y):
						_flood_open(p.x, p.y)
					progress = true
			elif need == unknown.size():
				# 剩余未知格全雷
				for p in unknown:
					if _state[p.x][p.y] == UNKNOWN:
						_state[p.x][p.y] = MINE
						progress = true
	return progress
