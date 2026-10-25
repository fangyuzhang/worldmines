# no_guess_guard.gd —— 无猜模式守卫（对标游戏 doc10 §2；红线兼容实现）【纯逻辑，无场景依赖】
#
# 对标游戏的「专家模式」用「猜错就重排剩余雷」实现，即**移动雷位**——
# 但本作关卡雷位写死在 JSON，移动会破坏 R01 序贯无猜验证与关卡数据（见 25_HANDOFF §13.2
# 「无首次点击保护」条目里的同一矛盾）。
#
# 本实现给出**数学保证相同、但不移动雷位**的等价语义：**拒绝**翻开任何无法从当前
# 玩家视角 100% 推导的格子。玩家同样无法靠猜测蒙混过关，且不碰任何关卡数据。
# 口径差异：对标是「猜了会死」，本作是「根本不让猜」。
#
# 从 game_session.gd 拆出：只读玩家视角约束（HintSolver 契约），不读真实雷位。
#
# 【2026-10-25 后台线程化（坑表 #44 专项）】
# 重活（CP-SAT 不动点）搬到后台线程做**投机预计算**：盘面一失效就在后台重建，
# 玩家下一次点击时通常已算完 → 主线程不再为整段求解停帧。语义契约不变：
#   · is_deducible_safe 仍**同步**回答；后台未算完时等待并采用（或回退同步重算），
#     最坏情况 = 旧实现的同帧求解成本，只有投机收益、没有语义风险；
#   · 线程边界 = HintSolver 的三段拆分（prepare 主线程快照 / solve 纯函数后台 /
#     finish 主线程过滤）。线程内不触碰 Board：active/masked/proven 为纯容器拷贝，
#     topo（AdjacencyGrid）与规则插件为盘后只读共享（实测无写点），
#     C# RuleSolver 无静态可变状态；
#   · 世代号（_gen）：任何盘面变化 +1；后台结果回来时世代不匹配则整体丢弃
#     （过期结论一格都不采用——宁可重算，不给错答案）；
#   · 单飞 + 合并：同一时刻至多一个求解线程；线程忙期间的新失效只保留**最新**快照，
#     线程结束立即接力（中间态丢弃，不排队）。
class_name NoGuessGuard
extends RefCounted

## 无猜模式三档（对标 doc10 §2）
const NO_GUESS_OFF := 0      # 关闭（默认）
const NO_GUESS_EXPERT := 1   # 专家：禁止猜测（拒绝翻开推不出来的格）
const NO_GUESS_ULTIMATE := 2 # 终极：新翻开的线索格打星号（值隐藏），卡住时点提示揭开

## 推导结果缓存：Vector2i -> true（当前盘面下必然安全）
var _safe_cache: Dictionary = {}
## 缓存是否仍然有效（2026-09-25 审计重写：由 Board 信号驱动失效，见 _bind_board）。
var _cache_valid := false
## 当前绑定的 Board（用于信号连接与换盘检测）。
var _bound_board: Board = null
## 本局被拒次数（统计用）
var _rejected: int = 0

## —— 线程化状态 ——
## 盘面世代号：每次失效 +1；后台结果携带启动时的世代，不匹配即弃。
var _gen := 0
## 守卫是否被真正使用过（首次 is_deducible_safe 后置位）——只在使用中的会话做投机预计算，
## 普通模式（NO_GUESS_OFF）不为无关盘面白烧 CPU。
var _armed := false
var _thread: Thread = null
## 线程忙时待接力的最新快照（Dictionary 或空）。
var _pending_prep: Dictionary = {}
## 后台线程是否正在运行（Thread.is_started 在 wait_to_finish 后为 false，此标志补齐窗口期）。
var _solving := false
## 投机启用开关（测试可关；线程不可用时自动走同步路径）。
var async_enabled := true


## 新对局开始时清空缓存与计数（并安全回收后台线程）。
func reset() -> void:
	_join_background()
	_pending_prep = {}
	_safe_cache = {}
	_cache_valid = false
	_rejected = 0
	# 【09-28 审计修复 R8】原注释"不清 _bound_board —— 换盘时 _bind_board 自会识别并换绑"只覆盖了
	# **换到新盘**的情形，没覆盖**本局结束**：`Board extends RefCounted`，被 `_bound_board` 强引用后
	# 永不释放（每重开/换关泄漏一块 Board 及其 Cell/Grid），而且守卫仍挂在所有历史盘的
	# `cell_state_changed` 上。此处显式断开并置空；下次 `is_deducible_safe` 会重新绑定
	# （`_bind_board` 本身幂等：同盘直接 return）。
	if _bound_board != null:
		if _bound_board.cell_state_changed.is_connected(_on_board_changed):
			_bound_board.cell_state_changed.disconnect(_on_board_changed)
		_bound_board = null


## 猜测被拒时由 session 调用（计数归守卫持有）。
func record_rejection() -> void:
	_rejected += 1


## 被拒绝的猜测次数（本局）。
func rejected_count() -> int:
	return _rejected


## 该格在当前玩家视角下是否「必然安全」（可 100% 推导）。
## 注意：只读玩家视角约束（HintSolver 契约），不读真实雷位。
## 同步契约不变：后台投机未命中时等待/重算，保证答案永远针对**当前**盘面。
func is_deducible_safe(b: Board, pos: Vector2i) -> bool:
	if b == null:
		return false
	_armed = true
	_bind_board(b)
	if not _cache_valid:
		_join_background()
		if not _cache_valid:
			_rebuild_cache(b)
	return _safe_cache.has(pos)


## 当前盘面下「可无猜推出的安全格数」（终极模式附加信息用）。
## 复用同一份推导缓存，不额外触发一次求解。
func deducible_safe_count(b: Board) -> int:
	if b == null:
		return 0
	_armed = true
	_bind_board(b)
	if not _cache_valid:
		_join_background()
		if not _cache_valid:
			_rebuild_cache(b)
	return _safe_cache.size()


## 把守卫绑定到当前 Board，并挂上「盘面变化即失效」的信号（2026-09-25 审计重写）。
##
## 原实现每次调用都**全盘遍历**算一个哈希来判断缓存是否过期（O(格数)），且盘面一变就
## 触发一次全盘 CP-SAT 求解 —— 在「无猜-专家」档，每翻一格都付这两笔钱（chord 还会
## 逐格调用 reveal，一次 chord 多次求解），大盘上表现为「点了没反应」。
##
## 现改为信号驱动：`Board.cell_state_changed` 覆盖全部影响玩家可见信息的变更点
## （reveal / 插旗 / 问号 / **星号** / undo 恢复 / 引爆 —— 已逐点核对 core/board.gd），
## 信号一来把缓存标记失效。零遍历、语义等价，也不会再有「换位哈希碰撞」这类隐患。
## 【2026-10-25】失效同时顺手**踢一脚投机预计算**（见类头注释）。
func _bind_board(b: Board) -> void:
	if _bound_board == b:
		return
	_join_background()
	_bound_board = b
	_cache_valid = false
	_gen += 1
	if not b.cell_state_changed.is_connected(_on_board_changed):
		b.cell_state_changed.connect(_on_board_changed)


func _on_board_changed(_pos: Vector2i) -> void:
	_cache_valid = false
	_gen += 1
	_kick_speculative()


## 投机预计算入口：主线程做快照（prepare），重活交后台。
## 规则路子不通（def / E 类混合）的盘不投机——那两条链仍是纯同步（与旧行为一致）。
func _kick_speculative() -> void:
	if not async_enabled or not _armed or _bound_board == null:
		return
	var solver := HintSolver.new()
	if _bound_board.def_engine != null:
		solver.engine = _bound_board.def_engine
	var prep := solver.prepare_rule_inputs(_bound_board)
	if not bool(prep.get("ok", false)):
		return
	if _solving:
		_pending_prep = prep   # 单飞：线程忙 → 只留最新快照，跑完接力
		return
	_start_background(prep)


func _start_background(prep: Dictionary) -> void:
	var th := Thread.new()
	_thread = th
	_solving = true
	var gen := _gen
	var ok := th.start(func() -> void:
		var result: Dictionary = HintSolver.new().solve_rule_fixpoint(prep)
		_apply_background.call_deferred(gen, prep, result, th))
	if not ok:
		# 线程启动失败（资源耗尽等）：立即回到同步路径，不破坏契约。
		_solving = false
		if _thread == th:
			_thread = null


## 后台结果回主线程（call_deferred）：世代不匹配整体丢弃；匹配则按当前盘面过滤入缓存。
## th 通过闭包传入——本回调触发时 _thread 可能已被新线程顶替或被 join 清空，
## 只回收「属于自己的那个」线程句柄。
func _apply_background(gen: int, prep: Dictionary, result: Dictionary, th: Thread) -> void:
	_solving = false
	if _thread == th:
		_thread = null
		if th.is_started():
			th.wait_to_finish()
	# 接力优先：最新快照先跑起来，本函数余下部分只处理「这一代」的落地。
	if not _pending_prep.is_empty():
		var next := _pending_prep
		_pending_prep = {}
		_start_background(next)
	if gen != _gen or _bound_board == null or _cache_valid:
		return  # 过期结果（盘面已变 / 已被同步重算覆盖）——一格都不采用
	var solver := HintSolver.new()
	if _bound_board.def_engine != null:
		solver.engine = _bound_board.def_engine
	_safe_cache = {}
	for st in solver.finish_rule_steps(_bound_board, prep, result):
		if st.state == "safe":
			_safe_cache[st.pos] = true
	if gen == _gen:
		_cache_valid = true


## 同步兜底/后台等待后的主路径：行为与旧实现一致（含 def / E 类混合的旧链）。
func _rebuild_cache(b: Board) -> void:
	_safe_cache = {}
	var solver := HintSolver.new()
	if b.def_engine != null:
		solver.engine = b.def_engine
	var steps: Array[ReasoningStep] = []
	var prep := solver.prepare_rule_inputs(b)
	if bool(prep.get("ok", false)):
		steps = solver.finish_rule_steps(b, prep, solver.solve_rule_fixpoint(prep))
	elif b.clue_def_name != "":
		steps = solver.hint_def(b, b.clue_def_name)
	else:
		steps = solver.hint(b)
	for st in steps:
		if st.state == "safe":
			_safe_cache[st.pos] = true
	_cache_valid = true


## 等待后台线程结束并落地其结果（若仍新鲜）。is_deducible_safe 的同步兜底调用；
## 也用于 reset / 换盘前的安全回收（此时结果直接丢弃——世代必不匹配）。
func _join_background() -> void:
	var th := _thread
	if th == null:
		return
	if th.is_started():
		th.wait_to_finish()
	_thread = null
	_solving = false
	# wait_to_finish 后，线程内的 call_deferred 已入队但可能尚未执行；
	# _gen 在主线程只会因盘面变化而 +1（本函数不增），留给下一帧的 _apply_background
	# 自行做世代判定即可——这里不重复应用，避免双重过滤。
