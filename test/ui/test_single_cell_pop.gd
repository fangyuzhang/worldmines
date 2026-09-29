# test_single_cell_pop.gd —— 「单格翻开 pop」的渲染侧契约（动效规范两件套之一）
#
# 背景：此前只有「0 格泛洪」的波浪动效，点击单个数字格完全没有动画反馈（用户反馈缺口）。
# 本文件守护新增的单格 pop：p = clamp((now-t0)/0.20,0,1)；e = sin(PI*p/2)；
# scale = 0.86 + 0.14*e；color = lerp(未翻开色, 已翻开色, e)。
#
# ⚠️ 零间隙约束（本项目 cell_px 即格宽、格子间隙 = 0）：规范原式的过冲项
# `+ 0.10*sin(PI*p)` 峰值 1.07 会越线压到邻格 → 实现已砍掉过冲，scale 恒 ∈ [0.86, 1.0]。
# 本文件断言「任何时刻 scale ≤ 1.0、峰值恰为 1.0、谷值恰为 0.86」。
#
# 覆盖（对应交付验收）：
#   ① 单格（数字格）翻开会产生 pop —— 直接回应用户反馈；
#   ② scale 在 0.20s 内从 0.86 单调升到 1.0，且任何时刻 ≤ 1.0（零间隙约束）；
#   ③ pop 结束后该格 scale 恰为 1.0、登记表被移除（无残留、不无限增长）；
#   ④ 总闸关闭时不产生 pop；在途 pop 被立即清除；
#   ⑤ 与波浪并存（0 格泛洪）时两类动效都能观测到，且合成 scale（乘积）≤ 1.0。
#
# 观测手段沿用 test_wave_animation：读 _pops / _pop_cache，并用带默认参的
# _pop_scale_at / _cull_pops / _rebuild_pop_cache 注入时钟；**不新增/改动任何公开 API**。
extends GutTest

## 内存关卡：5×5、仅 (4,4) 有雷 ⇒ (0,0) 值为 0（翻开会整片泛洪）。
const ZERO_LEVEL := {
	"size": {"rows": 5, "cols": 5},
	"total_mines": 1,
	"mines": [{"r": 4, "c": 4}],
	"revealed": [],
}

## 与生产常量一致（测试独立取值，避免把实现常量抄错成「自证」）。
const POP_DUR_MS := 200          # POP_WD = 0.20s
const POP_SCALE_MIN := 0.86      # 起始收缩比

var _view
var _prev_ripple := true
var _prev_theme := ""


func before_each() -> void:
	_prev_ripple = SettingsManager.ripple_enabled
	SettingsManager.ripple_enabled = true  # 测试确定性与用户设置解耦
	# 主题同样要与用户持久化设置解耦：pop 时长读 ThemeManager.pop_duration()
	# （棱镜玻璃主题刻意放宽到 0.42s），settings.cfg 里若存着棱镜，硬编码的
	# POP_DUR_MS=200 全线失准。锁回规范底版 cozy_salt（POP_WD=0.20 的出处）。
	_prev_theme = SettingsManager.theme_mode
	if SettingsManager.theme_mode != "cozy_salt":
		SettingsManager.set_theme_mode("cozy_salt")
		# 300ms 逐色过渡里非 Color 键在首步（≈33ms）吸附目标值；等过渡走完，
		# 保证 pop_duration() 读到的是确定值而非插值中间态。
		await wait_process_frames(12)
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	_view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(_view)


func after_each() -> void:
	SettingsManager.ripple_enabled = _prev_ripple
	if _prev_theme != "" and SettingsManager.theme_mode != _prev_theme:
		SettingsManager.set_theme_mode(_prev_theme)
	GameSession.start_level("res://levels/classic_01.json")  # 复位全局盘面，避免污染其它测试文件


## 用内存关卡替换盘面（只设 GameSession.board 并重连视图信号——最小侵入）。
func _install_board(level: Dictionary) -> Board:
	var b := Board.new()
	b.load_level(level)
	GameSession.board = b
	_view._connect_board()
	return b


## 在盘中找一个「未翻开的数字格」（值 > 0 且非雷）。
func _find_number_cell(board: Board) -> Vector2i:
	for p in board.grid.all_positions():
		var c: Cell = board.grid.get_cell(p)
		if c != null and c.state == Cell.State.HIDDEN and c.value is int and int(c.value) > 0:
			return p
	return Vector2i(-1, -1)


# ---------- ① 单格翻开产生 pop ----------

func test_single_number_reveal_produces_pop() -> void:
	var board: Board = GameSession.board
	var target := _find_number_cell(board)
	assert_true(target.x >= 0, "classic_01 应存在未翻开的数字格")
	board.reveal(target)
	await wait_process_frames(2)
	# 用户反馈的核心缺口：点击数字格此前零动画 → 现在必须登记 pop。
	assert_true(_view._pops.has(target), "单格（数字格）翻开必须登记一次 pop")
	assert_true(_view._ripples.is_empty(), "单格翻开不应产生波浪（两件套相互独立）")
	# 中段确有收缩（scale < 1.0），证明 pop 在动而非只登记不生效。
	assert_lt(_view._pop_scale_at(target), 1.0, "pop 中段应处于收缩态（scale < 1.0）")


# ---------- ② scale 单调 0.86 → 1.0、任何时刻 ≤ 1.0 ----------

func test_pop_scale_monotonic_and_bounded() -> void:
	var board: Board = GameSession.board
	var target := _find_number_cell(board)
	board.reveal(target)
	await wait_process_frames(1)
	assert_true(_view._pops.has(target), "应先登记 pop")
	var t0 := int(_view._pops.get(target))

	var prev := -1.0
	var peak := -1.0
	var valley := 100.0
	for ms in range(0, POP_DUR_MS + 1, 5):
		var s: float = _view._pop_scale_at(target, t0 + ms)
		assert_true(s <= 1.0 + 0.0001, "任何时刻 pop scale 都必须 <= 1.0（零间隙不得压邻格）")
		assert_true(s >= prev - 0.0001, "pop scale 应单调不降（缓出、不回弹）")
		prev = s
		peak = maxf(peak, s)
		valley = minf(valley, s)

	assert_almost_eq(_view._pop_scale_at(target, t0), POP_SCALE_MIN, 0.001, "起点应为 0.86")
	assert_almost_eq(_view._pop_scale_at(target, t0 + POP_DUR_MS), 1.0, 0.001, "0.20s 应归位到 1.0")
	# 砍掉过冲项后的实测峰值/谷值：峰 1.0、谷 0.86（绝不出现规范原式的 1.07）。
	assert_almost_eq(valley, POP_SCALE_MIN, 0.001, "实测谷值应为 0.86（收缩起点）")
	assert_almost_eq(peak, 1.0, 0.001, "实测峰值应恰为 1.0（砍掉过冲，不越线）")


# ---------- ③ 收尾无残留、登记表被移除 ----------

func test_pop_cleared_after_end_no_residue() -> void:
	var board: Board = GameSession.board
	var target := _find_number_cell(board)
	board.reveal(target)
	await wait_process_frames(1)
	assert_true(_view._pops.has(target), "应先登记 pop")
	var t0 := int(_view._pops.get(target))

	# 注入时钟推进到结束后 → 淘汰并从登记表移除（防无限增长）。
	_view._cull_pops(t0 + POP_DUR_MS + 50)
	assert_false(_view._pops.has(target), "pop 结束后应从登记表移除")
	assert_true(_view._pop_cache.is_empty(), "pop 全部结束后缓存应清空（无残留）")

	assert_almost_eq(_view._pop_scale_at(target, t0 + POP_DUR_MS + 60), 1.0, 0.0001, "结束后该格 scale 恰为 1.0")
	assert_almost_eq(_view._pop_progress(target, t0 + POP_DUR_MS + 60), 1.0, 0.0001, "结束后颜色进度应为 1.0（状态色）")
	var rest := Rect2(10.0, 20.0, 48.0, 48.0)
	assert_eq(_view._pop_rect_for(target, rest), rest, "结束后 pop 不改变绘制矩形（回原值）")


# ---------- ④ 总闸控制 ----------

func test_off_suppresses_single_cell_pop() -> void:
	SettingsManager.set_ripple_enabled(false)
	var board: Board = GameSession.board
	var target := _find_number_cell(board)
	board.reveal(target)
	await wait_process_frames(2)
	assert_true(_view._pops.is_empty(), "关闭总闸后单格翻开不得登记 pop")
	assert_true(_view._pop_cache.is_empty(), "关闭总闸后不得留下 pop 缓存")
	assert_almost_eq(_view._pop_scale_at(target), 1.0, 0.0001, "关闭后该格 scale 恒为 1.0")


func test_off_clears_inflight_pop_no_residue() -> void:
	var board: Board = GameSession.board
	var target := _find_number_cell(board)
	board.reveal(target)
	await wait_process_frames(1)
	assert_false(_view._pops.is_empty(), "开启时单格翻开应登记 pop")

	# 在途时关掉总闸 → 立刻丢弃，重绘即静止态。
	SettingsManager.set_ripple_enabled(false)
	_view._process(0.0)
	assert_true(_view._pops.is_empty(), "关闭总闸应清掉在途 pop")
	assert_true(_view._pop_cache.is_empty(), "关闭总闸应清空 pop 缓存")
	assert_almost_eq(_view._pop_scale_at(target), 1.0, 0.0001, "关闭后该格 scale 应回到 1.0")


# ---------- ⑤ 与波浪并存（相乘合成，合成 scale ≤ 1.0） ----------

func test_pop_and_wave_coexist_and_combined_scale_bounded() -> void:
	var board := _install_board(ZERO_LEVEL)
	var start := Vector2i(0, 0)
	assert_true(board.grid.get_cell(start).is_zero_clue(), "起点应为 0 值格")
	board.reveal(start)  # 0 格泛洪（联动）→ 波浪 + 每格 pop
	await wait_process_frames(2)

	assert_false(_view._pops.is_empty(), "0 格泛洪应给被翻开格登记 pop")
	assert_true(_view._pops.has(start), "起点格也应有 pop")
	assert_false(_view._ripples.is_empty(), "0 格泛洪应产生波浪")

	# 注入同一时刻重算两套缓存：两类动效此刻都应可观测（各有 s < 1 的格子）。
	var at: int = int(_view._pops.get(start)) + 60
	_view._rebuild_pop_cache(at)
	_view._rebuild_ripple_cache(int(_view._ripples[0]["t0"]) + 60)

	var pop_deformed := false
	var pop_max := 0.0
	for p in _view._pop_cache:
		var s := float(_view._pop_cache[p]["s"])
		pop_max = maxf(pop_max, s)
		if s < 1.0:
			pop_deformed = true
	assert_true(pop_deformed, "中段单格 pop 应处于收缩态（可观测）")

	var wave_deformed := false
	var wave_max := 0.0
	for p in _view._ripple_cache:
		var s := float(_view._ripple_cache[p]["s"])
		wave_max = maxf(wave_max, s)
		if s < 1.0:
			wave_deformed = true
	assert_true(wave_deformed, "中段波浪应处于收缩态（可观测）")

	# 合成 s_total = s_pop × s_wave；两者都 ≤ 1.0 且都 ≥ 0 → 乘积必 ≤ 1.0（零间隙安全）。
	assert_true(pop_max <= 1.0 + 0.0001, "pop 收缩上限不得超过 1.0")
	assert_true(wave_max <= 1.0 + 0.0001, "波浪收缩上限不得超过 1.0")
	assert_true(pop_max * wave_max <= 1.0 + 0.0001, "合成 scale（乘积）必 <= 1.0")

	# 绘制矩形：合成后必须 ≤ 原格矩形（只收缩、不放大），逐格守护零间隙约束。
	var base := Rect2(_view.board_origin, Vector2(_view.cell_px, _view.cell_px))
	for p in _view._pops:
		var rr: Rect2 = _view._reveal_rect_for(p, base)
		assert_true(rr.size.x <= base.size.x + 0.001, "合成矩形不得比原格宽（不压邻格）")
		assert_true(rr.size.y <= base.size.y + 0.001, "合成矩形不得比原格高（不压邻格）")


func test_composition_is_multiplicative_not_override() -> void:
	# 直接验证合成语义：_reveal_rect_for = 在「波浪矩形」之上再叠加 pop（s_pop × s_wave）。
	var pos := Vector2i(0, 0)
	var now := Time.get_ticks_msec()
	# 造一条真实波浪并把 t0 拨到 60ms 前（否则 t≈0 时环 0 尚未入缓存、波浪不可观测）。
	_view._start_wave(pos)
	assert_false(_view._ripples.is_empty(), "应建立一条波浪用于合成验证")
	_view._ripples[0]["t0"] = float(now - 60)
	# 造一个中段 pop（100ms/200ms → s_pop ∈ (0.86, 1.0)，既在动又不为 0/1）。
	_view._pops = {pos: float(now - 100)}
	_view._pop_cache_ms = -1

	var rect := Rect2(0.0, 0.0, 48.0, 48.0)
	var wave_rect: Rect2 = _view._ripple_rect_for(pos, rect)
	var combined: Rect2 = _view._reveal_rect_for(pos, rect)
	var expected: Rect2 = _view._pop_rect_for(pos, wave_rect)
	assert_lt(wave_rect.size.x, rect.size.x, "前提：该格此刻确实被波浪收缩（wave < 1）")
	# 允许亚毫秒时钟漂移导致的极微小差异。
	assert_almost_eq(combined.size.x, expected.size.x, 0.5, "合成应等于「波浪矩形再乘 pop 缩放」（相乘而非覆盖）")
	assert_almost_eq(combined.position.x, expected.position.x, 0.5, "相乘合成应绕中心收缩")
	assert_lt(combined.size.x, wave_rect.size.x, "pop 在波浪矩形上进一步收缩（两者叠加，非覆盖）")


# ---------- pop 绘制矩形：绕中心相乘（s 作用于给定矩形） ----------

func test_pop_rect_multiplies_on_given_rect() -> void:
	var pos := Vector2i(0, 0)
	var now := Time.get_ticks_msec()
	_view._pops = {pos: float(now)}  # p≈0 → e≈0 → s≈0.86
	_view._pop_cache_ms = -1
	var rect := Rect2(10.0, 20.0, 100.0, 100.0)
	var pr: Rect2 = _view._pop_rect_for(pos, rect)
	assert_almost_eq(pr.size.x, 100.0 * POP_SCALE_MIN, 0.5, "pop 应把给定矩形按 s=0.86 收缩")
	assert_almost_eq(pr.position.x, 10.0 + 100.0 * (1.0 - POP_SCALE_MIN) * 0.5, 0.5, "收缩应绕中心")
