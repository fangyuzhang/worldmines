# test_wave_animation.gd —— 开格波浪（0 间隙方案）的渲染侧契约
#
# 覆盖（对应交付验收）：
#   ① 触发条件：单格（数字格）翻开不产生波浪；0 格泛洪产生波浪；
#   ② 时间模型：环 0 与环 1 同时开始、第 2 环晚 WS、同环内延迟相同；
#   ③ 收尾：推进到超过总时长后，缓存清空、矩形回到原值（无残留脏状态）；
#   ④ 渐隐：cover 生效时波及格数 <= target + 跨环格数，且跨环振幅被 frac 衰减。
#
# 观测手段：读 _ripples / _ripple_cache，并用 _rebuild_ripple_cache(at_ms) /
# _cull_waves(now_ms) 注入时钟。这两个内部函数带默认参，不影响线上调用路径；
# **不新增/改动任何公开 API**。
extends GutTest

## 内存关卡：5×5、仅 (4,4) 有雷 ⇒ (0,0) 值为 0（翻开会整片泛洪）。
const ZERO_LEVEL := {
	"size": {"rows": 5, "cols": 5},
	"total_mines": 1,
	"mines": [{"r": 4, "c": 4}],
	"revealed": [],
}

var _view
var _prev_ripple := true


func before_each() -> void:
	_prev_ripple = SettingsManager.ripple_enabled
	SettingsManager.ripple_enabled = true  # 测试确定性与用户设置解耦
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	_view = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(_view)


func after_each() -> void:
	SettingsManager.ripple_enabled = _prev_ripple
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


# ---------- ① 触发条件 ----------

func test_single_number_reveal_no_wave() -> void:
	var board: Board = GameSession.board
	var target := _find_number_cell(board)
	assert_true(target.x >= 0, "classic_01 应存在未翻开的数字格")
	board.reveal(target)
	await wait_process_frames(2)
	assert_true(_view._ripples.is_empty(), "单格（数字格）翻开不得产生波浪")


func test_zero_flood_produces_wave() -> void:
	var board := _install_board(ZERO_LEVEL)
	var start := Vector2i(0, 0)
	assert_true(board.grid.get_cell(start).is_zero_clue(), "起点应为 0 值格")
	board.reveal(start)
	await wait_process_frames(2)
	assert_false(_view._ripples.is_empty(), "0 格泛洪应产生波浪")
	var rec: Dictionary = _view._ripples[0]
	assert_eq(rec["pos"], start, "环 0 起点应是触发泛洪的那一格")
	assert_gt(int(rec["cells"]), 1, "泛洪应波及多格")


# ---------- ② 时间模型（图距离分环的相位差） ----------

func test_time_model_ring_delays() -> void:
	# classic_01 为 5×5，从角落 (0,0) 起波：至少 3 环（环大小 1/3/5…）。
	var start := Vector2i(0, 0)
	_view._start_wave(start)
	assert_false(_view._ripples.is_empty(), "应构建出波浪")
	var rec: Dictionary = _view._ripples[0]
	var ring_of: Dictionary = rec["ring_of"]
	assert_eq(int(ring_of[start]), 0, "起点应落在环 0")

	var r1 := Vector2i(-1, -1)
	var r1b := Vector2i(-1, -1)
	var r2 := Vector2i(-1, -1)
	for p in ring_of:
		var ring := int(ring_of[p])
		if ring == 1:
			if r1.x < 0:
				r1 = p
			elif r1b.x < 0:
				r1b = p
		elif ring == 2 and r2.x < 0:
			r2 = p
	assert_true(r1.x >= 0 and r2.x >= 0, "角落起波应有环 1 与环 2")
	var t0 := int(rec["t0"])

	# 环 0 与环 1 同时开始（delay_of(0) == delay_of(1) == 0）。
	_view._rebuild_ripple_cache(t0 + 5)
	assert_true(_view._ripple_cache.has(start), "环 0 应在 t0+5ms 已开始")
	assert_true(_view._ripple_cache.has(r1), "环 1 应与环 0 同时开始")

	# 第 2 环晚 WS(40ms)：35ms 时还没开始，45ms 时已开始。
	_view._rebuild_ripple_cache(t0 + 35)
	assert_false(_view._ripple_cache.has(r2), "环 2 在 35ms（< WS）时不应开始")
	_view._rebuild_ripple_cache(t0 + 45)
	assert_true(_view._ripple_cache.has(r2), "环 2 应在 40ms（WS）之后开始")

	# 同一环内延迟相同：两格强度一致。
	if r1b.x >= 0:
		var g1: float = float(_view._ripple_cache[r1]["g"])
		var g1b: float = float(_view._ripple_cache[r1b]["g"])
		assert_almost_eq(g1, g1b, 0.0001, "同一环内格子的延迟/强度应相同")


# ---------- ③ 收尾无残留 ----------

func test_wave_returns_to_rest() -> void:
	_view._start_wave(Vector2i(0, 0))
	assert_false(_view._ripples.is_empty())
	var rec: Dictionary = _view._ripples[0]
	var t0 := int(rec["t0"])

	# 中段确有形变（s < 1），证明波浪在动。
	_view._rebuild_ripple_cache(t0 + 10)
	assert_false(_view._ripple_cache.is_empty(), "波浪中段应有受波及格")
	var deformed := false
	for p in _view._ripple_cache:
		if float(_view._ripple_cache[p]["s"]) < 1.0:
			deformed = true
			break
	assert_true(deformed, "中段格子应处于收缩态（s < 1.0）")

	# 超过总时长 → 淘汰并清缓存 → 精确回到静止态。
	_view._cull_waves(t0 + int(rec["total_ms"]) + 50)
	assert_true(_view._ripples.is_empty(), "超过总时长应淘汰波浪")
	assert_true(_view._ripple_cache.is_empty(), "波浪结束后缓存必须清空（无残留）")
	var rest := Rect2(3.0, 4.0, 10.0, 10.0)
	assert_eq(_view._ripple_rect_for(Vector2i(0, 0), rest), rest, "结束后应返回原矩形（s 回到 1.0）")


# ---------- ④ cover 渐隐 ----------

func test_cover_fade_bounds_and_attenuation() -> void:
	_view._start_wave(Vector2i(0, 0))
	assert_false(_view._ripples.is_empty())
	var rec: Dictionary = _view._ripples[0]
	var cells := int(rec["cells"])
	var target := int(rec["target"])
	var ring_sizes: Array = rec["ring_sizes"]
	assert_gt(ring_sizes.size(), 0, "应至少有一环")
	var last := int(ring_sizes[ring_sizes.size() - 1])
	assert_true(cells <= target + last, "波及格数应 <= target + 跨环格数（渐隐为连续参数）")

	# 跨过目标的那一环被 frac 衰减（振幅 < 1），避免阶跃。
	var min_amp := 1.0
	for p in rec["amp_of"]:
		min_amp = minf(min_amp, float(rec["amp_of"][p]))
	assert_lt(min_amp, 1.0, "被 cover 截断的环振幅应 < 1（避免阶跃）")
