# test_flood_planned.gd —— Board.flood_planned 信号（v3.4「泛洪计划」）
#
# 目的：给 UI 一个「本次泛洪完整计划」的权威来源，取代「同帧唯一格数 ≥ 2」的启发式
#（后者会把终极模式揭星 / chord 误报为 0 格泛洪）。
#
# 覆盖：
#   ① 0 格泛洪 → 收到 flood_planned，zero_flood == true，origin 正确，cells 含起点与全部连锁格；
#   ② 数字格单格翻开 → zero_flood == false（cells 仅自身）；
#   ③ 终极模式揭星 → 不发 flood_planned（不作为 0 格泛洪）；
#   ④ 载入 revealed 0 值格 → 与 reveal() 同语义（真泛洪）；
#   ⑤ chord 逐目标展开数字格 → 每目标各一次且均 zero_flood == false；
#   ⑥ 逻辑未变：泛洪后所有格**立即** REVEALED（同步语义未被破坏）。
extends GutTest

## 5×5、仅 (4,4) 有雷 ⇒ (0,0) 值为 0（reveal 会整片连锁）。
const ZERO_LEVEL := {
	"size": {"rows": 5, "cols": 5},
	"total_mines": 1,
	"mines": [{"r": 4, "c": 4}],
	"revealed": [],
}

## chord 场景：5×5、5 雷；中心 (2,2) 值 = 1（唯一相邻雷 (1,1)，插旗后旗数相符）。
## 其余 4 雷落在 Chebyshev 距离 2 上 ⇒ 中心 8 邻**全为数字格**（无 0 值格），
## 且未全部插旗（不会提前获胜，展开会完整执行）。
const CHORD_LEVEL := {
	"size": {"rows": 5, "cols": 5},
	"total_mines": 5,
	"mines": [
		{"r": 1, "c": 1}, {"r": 0, "c": 2}, {"r": 2, "c": 4}, {"r": 4, "c": 2}, {"r": 2, "c": 0},
	],
	"revealed": [],
}

var _events: Array = []


func _on_plan(origin: Vector2i, cells: Array[Vector2i], zero_flood: bool) -> void:
	_events.append({"origin": origin, "cells": cells, "zero_flood": zero_flood})


func _make_board(level: Dictionary) -> Board:
	var b := Board.new()
	b.load_level(level)
	_events = []
	b.flood_planned.connect(_on_plan)
	return b


func _hidden_number_cell(board: Board) -> Vector2i:
	for p in board.grid.all_positions():
		var c: Cell = board.grid.get_cell(p)
		if c != null and c.state == Cell.State.HIDDEN and c.value is int and int(c.value) > 0:
			return p
	return Vector2i(-1, -1)


# ① 0 格泛洪 → 权威计划
func test_zero_flood_emits_true_plan() -> void:
	var board := _make_board(ZERO_LEVEL)
	var start := Vector2i(0, 0)
	assert_true(board.grid.get_cell(start).is_zero_clue(), "起点应为 0 值格")
	board.reveal(start)

	assert_eq(_events.size(), 1, "一次泛洪应在同步调用内恰好发一次 flood_planned")
	var ev: Dictionary = _events[0]
	assert_eq(ev["origin"], start, "origin 应是泛洪起点")
	assert_eq(ev["zero_flood"], true, "0 格连锁应判定为 zero_flood")
	var cells: Array = ev["cells"]
	assert_true(cells.has(start), "cells 应含起点")
	assert_gt(cells.size(), 1, "0 格泛洪应连锁多格")

	# ⑥ 逻辑未变：无需 await，泛洪格此刻**立即**是 REVEALED。
	for p in cells:
		assert_eq(board.grid.get_cell(p).state, Cell.State.REVEALED, "泛洪格应同步立即翻开")
	# cells 与真实翻开集合一致（不多不少，无遗漏）
	var revealed := 0
	for p in board.grid.all_positions():
		if board.grid.get_cell(p).state == Cell.State.REVEALED:
			revealed += 1
	assert_eq(cells.size(), revealed, "cells 应等于本次实际翻开集合")


# ② 数字格单格翻开 → zero_flood == false
func test_number_reveal_is_not_zero_flood() -> void:
	var board := _make_board(ZERO_LEVEL)
	var target := _hidden_number_cell(board)
	assert_true(target.x >= 0, "应存在未翻开的数字格")
	board.reveal(target)
	assert_eq(_events.size(), 1, "单格翻开也应给出计划（zero_flood=false）")
	var ev: Dictionary = _events[0]
	assert_eq(ev["origin"], target)
	assert_eq(ev["zero_flood"], false, "数字格单格翻开不是 0 格泛洪")
	assert_eq((ev["cells"] as Array).size(), 1, "数字格不扩散，只翻自身")


# ③ 终极模式揭星不产生 flood_planned
func test_ultimate_star_reveal_no_flood_planned() -> void:
	var board := _make_board(ZERO_LEVEL)
	board.hide_new_clues = true
	var target := _hidden_number_cell(board)
	board.reveal(target)
	assert_eq(_events.size(), 1, "打星不得额外产生泛洪计划（打星只发 cell_state_changed）")
	assert_eq(_events[0]["zero_flood"], false)
	_events = []
	var n := board.reveal_stars()
	assert_gt(n, 0, "应有星号格被揭开")
	assert_eq(_events.size(), 0, "揭星绝非 0 格泛洪（不发 flood_planned）")


# ④ 载入 revealed 0 值格 → 与 reveal() 同语义（真泛洪）
func test_initial_zero_reveal_plans_flood() -> void:
	var level := {
		"size": {"rows": 5, "cols": 5}, "total_mines": 1,
		"mines": [{"r": 4, "c": 4}], "revealed": [{"r": 0, "c": 0, "value": 0}],
	}
	var b := Board.new()
	b.flood_planned.connect(_on_plan)
	b.load_level(level)
	assert_eq(_events.size(), 1, "载入含 0 值 revealed 的关卡应规划一次泛洪")
	assert_eq(_events[0]["origin"], Vector2i(0, 0))
	assert_eq(_events[0]["zero_flood"], true, "0 值初始格连锁应判为真泛洪")


# ⑤ chord：逐目标走 reveal()，数字格目标均 zero_flood == false
func test_chord_targets_are_number_reveals_not_zero_flood() -> void:
	var board := Board.new()
	board.load_level(CHORD_LEVEL)
	var anchor := Vector2i(2, 2)
	# 手动构造 chord 前置：锚点已翻开、相邻雷已插旗（旗数 == 锚点值 == 1）。
	assert_eq(int(board.grid.get_cell(anchor).value), 1, "前提：锚点值应为 1")
	board.grid.get_cell(anchor).state = Cell.State.REVEALED
	board.grid.get_cell(Vector2i(1, 1)).state = Cell.State.FLAGGED
	_events = []
	board.flood_planned.connect(_on_plan)

	# 隔离全局副作用（口径同 test_no_guess：autosave 关闭 + 现场还原）。
	var saved_auto: bool = SettingsManager.autosave_enabled
	var saved_state: int = GameSession.state
	var saved_board: Board = GameSession.board
	SettingsManager.autosave_enabled = false
	GameSession.board = board
	GameSession.state = GameSession.State.PLAYING
	var opened := GameSession.chord(anchor)
	GameSession.board = saved_board
	GameSession.state = saved_state
	SettingsManager.autosave_enabled = saved_auto
	SaveCoordinator.clear()

	assert_gt(opened, 0, "旗数相符时 chord 应展开邻格")
	assert_eq(_events.size(), opened, "chord 每个目标各规划一次（逐格 reveal，而非一次批量泛洪）")
	var any_multi_cell := false
	for ev in _events:
		assert_eq(ev["zero_flood"], false, "chord 展开的数字格不得被当成 0 格泛洪")
		if (ev["cells"] as Array).size() > 1:
			any_multi_cell = true
	assert_false(any_multi_cell, "chord 每个目标都应是单格翻开（无连锁）")
