class_name GameController
extends RefCounted
## 对局控制：连接 A 类生成器与 B 类线索计算器，处理揭开/插旗/洪水填充/胜负。
##
## 这是一局游戏的"运行时心脏"：board 是数据，clue_computer 是数字规则，
## 本类把这些整合成玩家可交互的完整对局。

enum Status { READY, PLAYING, WON, LOST }

var rows: int
var cols: int
var mine_count: int
var board: Board
var generator: BoardGenerator
var clues: ClueComputer
var status: Status = Status.READY
var first_click_done := false
var revealed_count := 0
## 调试/验证：最近一次生成时 Solver 是否确认"逻辑唯一可解"，及推理揭示覆盖的安全格数
var last_solvable := false
var last_solvable_coverage := 0
## 统计（GDD §2.4.2）：点击次数、插旗动作次数、游戏用时（秒）
var click_count := 0
var flag_actions := 0
var start_time := -1.0
var elapsed := 0.0
## 踩雷位置（失败时记录，GDD §8.5.2）
var lost_pos := Vector2i(-1, -1)

func _init(p_rows: int, p_cols: int, p_mine_count: int,
		gen_ids: Array = [], num_ids: Array = []) -> void:
	rows = p_rows
	cols = p_cols
	mine_count = p_mine_count
	generator = BoardGenerator.from_ids(gen_ids)
	clues = ClueComputer.from_ids(num_ids)
	# 启用唯一解过滤：保证生成的棋盘逻辑可解（无猜雷、无无解局）
	generator.solvable_clues = clues
	start_new()

## 新开一局（随机布局，不保证首点安全——首点安全在首次揭开时处理）
func start_new() -> void:
	board = generator.generate(rows, cols, mine_count)
	last_solvable = false
	last_solvable_coverage = 0
	if board != null:
		var solver := Solver.new(board, clues, mine_count)
		var sr := rows / 2
		var sc := cols / 2
		for dr in range(rows):
			for dc in range(cols):
				var rr := (sr + dr) % rows
				var cc := (sc + dc) % cols
				if not board.is_mine(rr, cc):
					last_solvable = solver.is_unique_solution(rr, cc)
					last_solvable_coverage = solver.reveal_sequence.size()
					dr = rows
					break
	status = Status.READY
	first_click_done = false
	revealed_count = 0
	click_count = 0
	flag_actions = 0
	start_time = -1.0
	elapsed = 0.0
	lost_pos = Vector2i(-1, -1)

## 是否生成成功（无解的变体组合可能生成失败，返回 false）
func is_ready() -> bool:
	return board != null

## 左键揭开。返回 false 表示点击无效（未开始/已结束/不可揭开）。
func reveal(r: int, c: int) -> bool:
	if status != Status.READY and status != Status.PLAYING:
		return false
	if not board.in_bounds(r, c):
		return false
	var cell := board.cell(r, c)
	if not cell.is_hidden():
		return false
	if cell.is_flagged():
		return false

	# 首次点击安全（GDD §2.1.4）
	click_count += 1
	if not first_click_done:
		first_click_done = true
		status = Status.PLAYING
		start_time = Time.get_ticks_msec() / 1000.0
		var safe := generator.ensure_first_click_safe(board, r, c)
		if safe == null:
			# 无法满足首点安全（组合无解概率过高），回退为不可用状态
			first_click_done = false
			status = Status.READY
			return false
		board = safe

	# 点到雷 → 失败
	if board.is_mine(r, c):
		status = Status.LOST
		lost_pos = Vector2i(r, c)
		_stop_timer()
		return true

	_flood_reveal(r, c)
	_check_win()
	return true

## 洪水填充（GDD §2.1.5）：揭开该格，若其线索为"全安全"则递归展开邻居。
## 展开条件交给线索计算器：该格所有 B 类线索都标记 is_flood。
func _flood_reveal(r: int, c: int) -> void:
	var stack: Array[Vector2i] = [Vector2i(r, c)]
	while not stack.is_empty():
		var pos: Vector2i = stack.pop_back()
		var cell := board.cell(pos.x, pos.y)
		if not cell.is_hidden() or cell.is_flagged() or board.is_mine(pos.x, pos.y):
			continue
		cell.state = Cell.State.REVEALED
		revealed_count += 1
		# 是否全安全展开
		var all_flood := true
		var clue_list := clues.clues_for(board, pos.x, pos.y)
		for clue in clue_list:
			if not clue.is_flood:
				all_flood = false
				break
		if all_flood and not clue_list.is_empty():
			for nb in board.neighbor8_coords(pos.x, pos.y):
				stack.append(nb)

## 右键插旗/取消旗
func toggle_flag(r: int, c: int) -> void:
	if status != Status.PLAYING:
		return
	if not board.in_bounds(r, c):
		return
	var cell := board.cell(r, c)
	if cell.is_revealed():
		return
	flag_actions += 1
	if cell.is_flagged():
		cell.state = Cell.State.HIDDEN
	else:
		cell.state = Cell.State.FLAGGED

## 中键和弦：已揭开数字格，若周围旗数=数字值则揭开周围未插旗格
func chord(r: int, c: int) -> bool:
	if status != Status.PLAYING:
		return false
	if not board.in_bounds(r, c):
		return false
	var cell := board.cell(r, c)
	if not cell.is_revealed() or board.is_mine(r, c):
		return false
	var flag_count := 0
	for nb in board.neighbor8_coords(r, c):
		if board.cell(nb.x, nb.y).is_flagged():
			flag_count += 1
	var number := board.adjacent_mines(r, c)
	if flag_count != number:
		return false
	var hit_mine := false
	for nb in board.neighbor8_coords(r, c):
		var nb_cell := board.cell(nb.x, nb.y)
		if nb_cell.is_hidden() and not nb_cell.is_flagged():
			if board.is_mine(nb.x, nb.y):
				status = Status.LOST
				lost_pos = Vector2i(nb.x, nb.y)
				_stop_timer()
				hit_mine = true
			else:
				_flood_reveal(nb.x, nb.y)
	if not hit_mine:
		_check_win()
	return true

func _check_win() -> void:
	# 胜利：所有非雷格被揭开
	if revealed_count >= rows * cols - mine_count:
		status = Status.WON
		_stop_timer()

func flag_count() -> int:
	var n := 0
	for r in rows:
		for c in cols:
			if board.cell(r, c).is_flagged():
				n += 1
	return n

## 棋盘上某格要显示的文本（已揭开且非雷时才有意义）
func display_text(r: int, c: int) -> String:
	return clues.display_text(board, r, c)

func clues_for(r: int, c: int) -> Array[VariantClue]:
	return clues.clues_for(board, r, c)

## 刷新计时（由 UI 每帧调用）；返回当前用时秒
func update_timer() -> float:
	if status == Status.PLAYING and start_time >= 0.0:
		elapsed = Time.get_ticks_msec() / 1000.0 - start_time
	return elapsed

func _stop_timer() -> void:
	if start_time >= 0.0:
		elapsed = Time.get_ticks_msec() / 1000.0 - start_time