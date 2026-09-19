# test_wave_stagger.gd —— 「0 格泛洪 → 按环错峰」的渲染侧契约（v3.4 权威计划版）
#
# 背景：波浪触发从 UI 侧「同帧唯一格数 >= 2」的启发式，改为 Board.flood_planned 的**权威计划**
# （origin / cells / zero_flood）。本文件守护：
#   ① 触发源 + 解耦：0 格泛洪在**同一个同步调用内**（无 await）即建波，且此刻 cells 全部 REVEALED
#      —— 证明错峰动画只是演出，绝不拖住状态；
#   ② 只波及真正翻开的格：波浪环集合 ⊆ 本次泛洪集合（不再点亮未翻开格）；
#   ③ 错峰：环起播延迟单调不降、环 1 < 环 2 严格递增，且末环延迟与总时长都有硬上限；
#   ④ 不打架：错峰进行中再来一次 flood_planned → 只有一条波浪、无旧记录残留；
#   ⑤ zero_flood=false（数字格单格）不进入环序错峰，仍走单格 pop；
#   ⑥ 收尾质感：末环渐慢长尾（末环比同起点的环 0 更晚归零）。
#
# 观测手段沿用 test_wave_animation：读 _ripples / _ripple_cache，并用带默认参的
# _rebuild_ripple_cache(at_ms) 注入时钟；**不新增/改动任何公开 API**。
#
# ⚠️ 已知取舍（见交付报告）：RippleRings 的时间模型刻意让**环 0 与环 1 同时起播**
# （`delay_of(0)==delay_of(1)==0`，起点弹跳与紧邻一圈平移是一个整体动作），既有
# test_wave_animation 的断言是底线。故本文件断言「单调不降 + 环 1 起严格递增」，
# 而非「环 0 < 环 1」。若要改成严格 0<1<2，需同时改 core/ 的 delay_of 与既有断言。
extends GutTest

## 内存关卡：5×5、仅 (4,4) 有雷 ⇒ (0,0) 值为 0（翻开会整片泛洪）。
const ZERO_LEVEL := {
	"size": {"rows": 5, "cols": 5},
	"total_mines": 1,
	"mines": [{"r": 4, "c": 4}],
	"revealed": [],
}

## 7×7：第 3 行是「矿 + 数字」隔断墙（x=0/2/4/6 为雷，x=1/3/5 为数字），
## 行 0-1 与行 4-6 是两片互不连通的 0 值区域 → 可连做两次互不重叠的泛洪。
const TWO_REGIONS_LEVEL := {
	"size": {"rows": 7, "cols": 7},
	"total_mines": 4,
	"mines": [{"r": 3, "c": 0}, {"r": 3, "c": 2}, {"r": 3, "c": 4}, {"r": 3, "c": 6}],
	"revealed": [],
}

## 与生产常量一致（测试独立取值，避免抄实现常量成「自证」）。
const WS := 0.040          # WAVE_WS：每环延迟
const DELAY_CAP := 0.12    # WAVE_DELAY_CAP：错峰延迟上限
const WD := 0.30           # WAVE_WD：单格时长
const TAIL_MULT := 1.5     # WAVE_TAIL_MULT：末环长尾倍率

var _view
var _prev_ripple := true
var _plans: Array = []


func before_each() -> void:
	_prev_ripple = SettingsManager.ripple_enabled
	SettingsManager.ripple_enabled = true  # 测试确定性与用户设置解耦
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	_view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(_view)


func after_each() -> void:
	SettingsManager.ripple_enabled = _prev_ripple
	GameSession.start_level("res://levels/classic_01.json")  # 复位全局盘面，避免污染其它测试文件


func _on_plan(origin: Vector2i, cells: Array[Vector2i], zero_flood: bool) -> void:
	_plans.append({"origin": origin, "cells": cells, "zero_flood": zero_flood})


## 用内存关卡替换盘面（只设 GameSession.board 并重连视图信号——最小侵入），
## 并额外监听 board.flood_planned 以便断言「权威计划」的载荷。
func _install_board(level: Dictionary) -> Board:
	var b := Board.new()
	b.load_level(level)
	b.flood_planned.connect(_on_plan)
	GameSession.board = b
	_view._connect_board()
	_plans = []
	return b


## 在盘中找一个「未翻开的数字格」（值 > 0 且非雷）。
func _find_number_cell(board: Board) -> Vector2i:
	for p in board.grid.all_positions():
		var c: Cell = board.grid.get_cell(p)
		if c != null and c.state == Cell.State.HIDDEN and c.value is int and int(c.value) > 0:
			return p
	return Vector2i(-1, -1)


## 从波浪记录里取一个落在指定环上的格（无则返回 (-1,-1)）。
func _ring_cell(rec: Dictionary, ring: int) -> Vector2i:
	var ring_of: Dictionary = rec["ring_of"]
	for p in ring_of:
		if int(ring_of[p]) == ring:
			return p
	return Vector2i(-1, -1)


# ---------- ① 触发源 + 状态/演出解耦 ----------

func test_zero_flood_wave_synchronous_and_state_final() -> void:
	var board := _install_board(ZERO_LEVEL)
	var start := Vector2i(0, 0)
	assert_true(board.grid.get_cell(start).is_zero_clue(), "起点应为 0 值格")
	board.reveal(start)

	# 无 await：flood_planned 在逐格 cell_state_changed 之后、同一同步调用内发出。
	assert_eq(_plans.size(), 1, "一次泛洪应恰好收到一次 flood_planned")
	assert_eq(_plans[0]["origin"], start, "计划 origin 应是泛洪起点")
	assert_eq(_plans[0]["zero_flood"], true, "多格连锁应是真·0 格泛洪")
	var cells: Array = _plans[0]["cells"]

	assert_false(_view._ripples.is_empty(), "同步信号即应建立波浪（不需要等任何帧）")
	var rec: Dictionary = _view._ripples[0]
	assert_eq(rec["pos"], start, "环 0 起点应是权威 origin（而非「首个 emit 的格」）")

	# 状态与演出解耦：信号发出的那一刻，cells 内全部格**已经**是最终态。
	for p in cells:
		assert_eq(board.grid.get_cell(p).state, Cell.State.REVEALED, "泛洪格应立即已是 REVEALED（动画不拖状态）")

	# ② 波浪只波及真正翻开的格（不点亮未翻开 / 未泛洪的格）。
	var ring_of: Dictionary = rec["ring_of"]
	assert_true(ring_of.size() > 1, "0 格泛洪应波及多格")
	for p in ring_of:
		assert_eq(board.grid.get_cell(p).state, Cell.State.REVEALED, "波浪不得波及未翻开格")
		assert_true(cells.has(p), "波浪环集合必须是本次泛洪集合的子集")
	assert_true(int(rec["cells"]) <= cells.size(), "波及格数不得超过泛洪格数")


# ---------- ③ 环序错峰：单调 + 封顶 ----------

func test_ring_delays_monotonic_and_capped() -> void:
	var board := _install_board(ZERO_LEVEL)
	board.reveal(Vector2i(0, 0))
	var rec: Dictionary = _view._ripples[0]
	var delays: Array = rec["ring_delays"]
	assert_true(delays.size() >= 3, "5×5 角落起波应至少 3 环（0/1/2）")
	assert_almost_eq(float(delays[0]), 0.0, 0.0001, "环 0 立即起播")
	# 环 0 与环 1 刻意并列（RippleRings 时间模型 + 既有断言底线，见文件头取舍说明）。
	assert_almost_eq(float(delays[1]), 0.0, 0.0001, "环 1 与环 0 同时起播（刻意设计）")
	# 从环 1 起严格递增：第 2 环晚于第 1 环、第 3 环晚于第 2 环……即「一圈推开」。
	for i in range(2, delays.size()):
		assert_gt(float(delays[i]), float(delays[i - 1]), "环 %d 应严格晚于上一环起播" % i)
	# 封顶：末环延迟 ≤ WAVE_DELAY_CAP；总时长 ≤ 硬上限（错峰 + 收尾都有界）。
	var last_delay: float = float(delays[delays.size() - 1])
	assert_true(last_delay <= DELAY_CAP + 0.0001, "末环延迟应被 WAVE_DELAY_CAP 封顶")
	var bound_ms := (DELAY_CAP + WD * TAIL_MULT) * 1000.0
	assert_true(float(rec["total_ms"]) <= bound_ms + 1.0, "总时长不得超过（封顶延迟 + 末环长尾）")


func test_ring_delay_function_caps_large_rings() -> void:
	# 大范围泛洪在盘上会被 cover 截断，故直接对纯函数断言封顶生效（否则环号一大就等几秒）。
	assert_almost_eq(_view._ring_delay_sec(0), 0.0, 0.0001, "环 0 延迟为 0")
	assert_almost_eq(_view._ring_delay_sec(1), 0.0, 0.0001, "环 1 延迟为 0")
	assert_almost_eq(_view._ring_delay_sec(2), WS, 0.0001, "环 2 延迟为一个 WS")
	assert_almost_eq(_view._ring_delay_sec(3), 2.0 * WS, 0.0001, "环 3 延迟为两个 WS")
	assert_almost_eq(_view._ring_delay_sec(50), DELAY_CAP, 0.0001, "大环号被硬封顶（不会等几秒）")
	var prev := -1.0
	for r in range(0, 24):
		var d: float = _view._ring_delay_sec(r)
		assert_true(d >= prev - 0.0001, "环延迟应单调不降")
		assert_true(d <= DELAY_CAP + 0.0001, "环延迟应被 WAVE_DELAY_CAP 封顶")
		prev = d


# ---------- ④ 错峰进行中再来一次 flood_planned：覆盖而非叠加，无残留 ----------

func test_second_flood_replaces_wave_without_residue() -> void:
	var board := _install_board(TWO_REGIONS_LEVEL)
	var first_origin := Vector2i(0, 0)
	var second_origin := Vector2i(0, 6)
	assert_true(board.grid.get_cell(first_origin).is_zero_clue(), "上区起点应为 0 值格")
	assert_true(board.grid.get_cell(second_origin).is_zero_clue(), "下区起点应为 0 值格")

	board.reveal(first_origin)
	assert_eq(_view._ripples.size(), 1, "第一条波浪应建立")
	var first_rec: Dictionary = _view._ripples[0]
	assert_eq(first_rec["pos"], first_origin)
	var first_cell := Vector2i(1, 1)                 # 只属于上区（第一次泛洪）
	assert_true(first_rec["ring_of"].has(first_cell), "前提：(1,1) 应在上区波浪环内")

	# 错峰还没跑完（未 await 任何帧）→ 立刻再来一次 0 格泛洪。
	board.reveal(second_origin)
	assert_eq(_view._ripples.size(), 1, "新泛洪应覆盖旧波浪（同一时间只有一条，不叠加）")
	var second_rec: Dictionary = _view._ripples[0]
	assert_eq(second_rec["pos"], second_origin, "留下的应是第二次泛洪的 origin")
	assert_false(second_rec["ring_of"].has(first_cell), "第二次泛洪的下区环不应包含上区格")
	assert_true(float(second_rec["t0"]) >= float(first_rec["t0"]), "新波浪 t0 不早于旧波浪")
	assert_eq(_view._ripple_cache_ms, -1, "新波浪应作废几何缓存，强制按新记录重算")

	# 重算后：缓存里只应有「第二次泛洪」的格，绝无第一条波浪的残留。
	# 注入 t0+20ms（t=0 时 waveE=sin(0)=0，本就不入缓存，故必须错开极早期）。
	_view._rebuild_ripple_cache(int(second_rec["t0"]) + 20)
	assert_false(_view._ripple_cache.is_empty(), "新波浪中段应可观测")
	assert_false(_view._ripple_cache.has(first_cell), "旧波浪的格不得在缓存里残留")
	for p in _view._ripple_cache:
		assert_true(second_rec["ring_of"].has(p), "缓存只应来自当前这条波浪")


# ---------- ⑤ zero_flood=false 不进错峰，仍走单格 pop ----------

func test_number_reveal_not_staggered_still_pops() -> void:
	var board := _install_board(ZERO_LEVEL)
	var target := _find_number_cell(board)
	assert_true(target.x >= 0, "应存在未翻开的数字格")
	board.reveal(target)
	assert_eq(_plans.size(), 1, "数字格单格翻开也应给出计划（zero_flood=false）")
	assert_eq(_plans[0]["zero_flood"], false, "数字格单格不是 0 格泛洪")
	assert_true(_view._ripples.is_empty(), "zero_flood=false 不得进入环序错峰（不建波浪）")
	assert_true(_view._pops.has(target), "zero_flood=false 仍走单格 pop 路径")


# ---------- ⑥ 收尾质感：末环渐慢长尾 ----------

func test_last_ring_has_slow_tail() -> void:
	var board := _install_board(ZERO_LEVEL)
	board.reveal(Vector2i(0, 0))
	var rec: Dictionary = _view._ripples[0]
	var last: int = int(rec["total_rings"])
	assert_gt(last, 0, "0 格泛洪至少应有两环（环 0 + 至少一环）")
	var tail_cell := _ring_cell(rec, last)
	var seed: Vector2i = rec["pos"]               # 环 0（非末环 → 无长尾，时长 WD）
	assert_true(tail_cell.x >= 0, "应能取到末环上的格")

	var t0: int = int(rec["t0"])
	var delays: Array = rec["ring_delays"]
	var delay_last_ms: float = float(delays[last]) * 1000.0
	# 选一个「非末环（WD）已结束、而末环（WD*TAIL_MULT）仍在继续」的时刻。
	var at: int = t0 + int(delay_last_ms) + int(WD * 1000.0) + 20
	_view._rebuild_ripple_cache(at)

	# 前提：末环此刻已超过单格时长 WD —— 若无长尾，它的 waveE 应已归零。
	var t_rel_last: float = float(at - t0) / 1000.0 - float(delays[last])
	assert_gt(t_rel_last, WD, "前提：末环此刻应已超过 WD")
	assert_true(_view._ripple_cache.has(tail_cell), "末环应因渐慢长尾仍在收缩")
	assert_gt(float(_view._ripple_cache[tail_cell]["g"]), 0.1, "末环长尾振幅应仍明显（超过 WD 仍未归零）")
	# 同刻内环（非末环，时长 WD）已收束到≈0（sin(PI*1) 的浮点残差量级）。
	var seed_g := 0.0
	if _view._ripple_cache.has(seed):
		seed_g = float(_view._ripple_cache[seed]["g"])
	assert_lt(seed_g, 0.01, "环 0（非末环）此刻应已收束归零")
