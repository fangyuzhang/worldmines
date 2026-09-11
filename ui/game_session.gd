# game_session.gd —— 对局编排（输入路由 / 计时 / 计数 / 存档触发）【plan1.1 §10.7.5】
# 状态机与场景切换矩阵见 §10.7.8；存档时序见 §10.10。
# 判负唯一入口 = board.is_mine() / 引擎 game_lost 信号；session 不读雷位判逻辑。
# 引爆格坐标：引擎 game_lost 信号不带 pos（Step 0 核对结论），由 session 记录
# 「最后一次 reveal 的格子」得到 exploded_pos（终局高亮渲染用，非判负逻辑）。
extends Node
## autoload 名：GameSession

signal session_started
signal game_ended(won: bool)
## 提示结果广播（steps 为空 = 当前无必然可推的一步）
signal hint_ready(steps: Array)
## 撤回后广播（UI 隐藏终局覆盖层 + 重绘棋盘）
signal session_restored

enum State { IDLE, PLAYING, PAUSED, ENDED }

## 提示三档（对标游戏 doc10 §3.2）
const HINT_NORMAL := 0    # 标准：给出结论格 + 依据线索
const HINT_WEAK := 1      # 弱提示：只高亮要用到的线索，不显示可推格
const HINT_DISABLED := 2  # 禁用：完全关闭提示
## 免费提示充能周期（秒；对标 FREE_HINT_TIME = 120f）
const HINT_CHARGE_SEC := 120.0

## 无猜模式三档（对标 doc10 §2）
const NO_GUESS_OFF := 0      # 关闭（默认）
const NO_GUESS_EXPERT := 1   # 专家：禁止猜测（拒绝翻开推不出来的格）
const NO_GUESS_ULTIMATE := 2 # 终极：新翻开的线索格打星号（值隐藏），卡住时点提示揭开

var level_path: String = ""
var board: Board = null
var elapsed: float = 0.0
var timer_started: bool = false
var cursor: Vector2i = Vector2i.ZERO
var exploded_pos: Vector2i = Vector2i(-1, -1)  # 判负引爆格，终局高亮用
var state: int = State.IDLE
## 提示充能累计（秒）。开启充能时需 ≥ HINT_CHARGE_SEC 才算充满。
var hint_charge_left: float = 0.0
## 未充满就用了提示 → true（供未来「完美通关」判定消费；当前尚无完美判定）
var hint_uncharged_used: bool = false

var _last_save_ms: int = -100000  # 自动存档防抖（首次翻格立即存）
var _last_reveal_pos: Vector2i = Vector2i(-1, -1)  # 引爆格追踪

# 绘画层引用（board_view 注入）+ 恢复时待载入的绘画数据
var drawing_layer: DrawingLayer = null
var pending_drawing: Dictionary = {}


func _ready() -> void:
    # 预留：无事可做（autoload 顺序 Settings→Theme→GameSession 已保证）
    pass


func _process(delta: float) -> void:
    _tick(delta)


## 计时门控（§10.7.8）：state == PLAYING 且 timer_started 才累计。
func _tick(delta: float) -> void:
    if state == State.PLAYING and timer_started:
        elapsed += delta
        if SettingsManager.hint_charge:
            hint_charge_left = minf(hint_charge_left + delta, HINT_CHARGE_SEC)


# ============ 对局生命周期 ============

## 开始关卡。失败返回 false（调用方停留本页 + toast，不切场景）。
func start_level(path: String) -> bool:
    level_path = path
    board = LevelLoader.load_level(path)
    if board == null:
        push_error("关卡加载失败: " + path)
        state = State.IDLE
        return false
    # mod 关卡（user:// 路径 + clue_def 字段）：注入共享 DefEngine 后重算线索
    if path.begins_with("user://") and board.clue_def_name != "":
        board.def_engine = ModAPI.defs
        board._compute_clues()
    elapsed = 0.0
    timer_started = false
    cursor = Vector2i.ZERO
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    # 终极模式：本次对局的「玩家新翻开线索格一律打星号」开关
    board.hide_new_clues = SettingsManager.no_guess_mode == NO_GUESS_ULTIMATE
    hint_charge_left = 0.0
    hint_uncharged_used = false
    _ng_safe_cache = {}
    _ng_cache_step = -1
    _ng_rejected = 0
    _last_save_ms = -100000  # 新对局首次翻格立即存
    pending_drawing = {}  # 新对局：绘画清空
    _connect_board_signals()
    state = State.PLAYING
    # 关卡加载期就可能已达终局：reveal_initial 内部会调 _check_win，而当时信号尚未连接，
    # 终局信号会丢失 → 玩家卡在「已胜/已负但无结算覆盖层」。此处补判一次。
    if board.state == Board.GameState.WON:
        _on_game_won()
    elif board.state == Board.GameState.LOST:
        _on_game_lost()
    session_started.emit()
    return true


## 重开当前关（R / HUD / 重新开始）。计时归零。
func restart() -> void:
    start_level(level_path)


## 撤回踩雷：撤销引爆格，恢复到踩雷前状态（仅失败终局可撤；胜局不撤）。
## 引爆格恢复 HIDDEN；board/session 状态回 PLAYING 继续计时。
func undo() -> bool:
    if state != State.ENDED or board == null:
        return false
    if board.state != Board.GameState.LOST:
        return false
    if board.grid.in_board(exploded_pos):
        var cell := board.grid.get_cell(exploded_pos)
        if cell.state == Cell.State.REVEALED:
            cell.state = Cell.State.HIDDEN
            board.cell_state_changed.emit(exploded_pos)
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    board.state = Board.GameState.PLAYING
    state = State.PLAYING
    timer_started = true  # 撤回后继续计时
    session_restored.emit()
    return true


func reveal(pos: Vector2i) -> void:
    if state != State.PLAYING or board == null:
        return
    if not board.grid.in_board(pos):
        return
    var cell := board.grid.get_cell(pos)
    if cell.state != Cell.State.HIDDEN:
        return  # 旗/? 格不响应左键（引擎虽会清标翻开，session 层拦截）
    # 无猜-专家档：拒绝翻开「当前信息推不出来」的格（红线兼容实现，见下方小节注释）。
    # 终极档不禁止猜测（它的难度来自星号遮蔽，不是禁止操作）。
    if SettingsManager.no_guess_mode == NO_GUESS_EXPERT and not is_deducible_safe(pos):
        _ng_rejected += 1
        guess_rejected.emit(pos)
        AudioManager.play("flag")
        return
    _last_reveal_pos = pos
    board.reveal(pos)
    # 判负由 game_lost 信号播爆炸声；此处只播普通翻开声
    if board.state != Board.GameState.LOST:
        AudioManager.play("reveal")
    # board.state 由引擎信号保证同步；翻格后仍 PLAYING 则起表
    if state == State.PLAYING and board.state == Board.GameState.PLAYING and not timer_started:
        timer_started = true
    _maybe_autosave()


func toggle_flag(pos: Vector2i) -> void:
    if state != State.PLAYING or board == null:
        return
    if not board.grid.in_board(pos):
        return
    var cell := board.grid.get_cell(pos)
    if cell.state != Cell.State.HIDDEN and cell.state != Cell.State.FLAGGED and cell.state != Cell.State.QUESTION:
        return
    board.toggle_flag(pos)
    AudioManager.play("flag")
    _maybe_autosave()


# ============ 提示（一步直推，只读玩家视角约束，不读雷位、不代玩家操作） ============

## 请求一步提示。返回 ReasoningStep 数组（可能为空），并广播 hint_ready 供 UI 高亮。
## 非 PLAYING / 无棋盘 / 提示被禁用 → 空数组（不报错）。
func request_hint() -> Array[ReasoningStep]:
    var steps: Array[ReasoningStep] = []
    if state == State.PLAYING and board != null and SettingsManager.hint_mode != HINT_DISABLED:
        var solver := HintSolver.new()
        if board.def_engine != null:
            solver.engine = board.def_engine  # mod 关卡用共享 DefEngine
        if board.clue_def_name != "":
            steps = solver.hint_def(board, board.clue_def_name)
        else:
            steps = solver.hint(board)
        # 充能：未充满就用 → 标记本局「非完美」，并清零重新充能
        if SettingsManager.hint_charge:
            if hint_charge_left < HINT_CHARGE_SEC:
                hint_uncharged_used = true
            hint_charge_left = 0.0
        # 弱提示：只高亮「要用到的线索」，结论格不展示（board_view 依 method 跳过）
        if SettingsManager.hint_mode == HINT_WEAK:
            for s in steps:
                (s as ReasoningStep).method = "weak"
        steps = _limit_hint_budget(steps)
        # 终极模式（对标 doc10 §2.4）：星号格遮蔽着线索值。
        # 当前若能推出安全格 → 正常给提示；若确实推不出任何安全格（卡住了）
        # → 揭开全部星号让对局继续（这一步本身就消耗一次提示）。
        if SettingsManager.no_guess_mode == NO_GUESS_ULTIMATE and board.has_stars():
            var has_safe := false
            for st in steps:
                if (st as ReasoningStep).state == "safe":
                    has_safe = true
                    break
            if not has_safe:
                board.reveal_stars()
                steps.clear()
    hint_ready.emit(steps)
    return steps


## 一次提示给出的结论格上限（对标游戏 doc10 §3.3 的 maxClues 与难度挂钩）：
## easy → 3，normal → 5，hard / 无难度画像 → 不限（-1）。
## 对齐 GDD 14.2「每次提示只给一个推理阶段，绝不一次性给全部答案」。
func _limit_hint_budget(steps: Array[ReasoningStep]) -> Array[ReasoningStep]:
    if board == null or steps.is_empty():
        return steps
    var cap := _hint_budget_cap()
    if cap < 0 or steps.size() <= cap:
        return steps
    return steps.slice(0, cap)


func _hint_budget_cap() -> int:
    if board == null or board.difficulty < 0.0:
        return -1
    match Difficulty.tier_of(board.difficulty):
        "easy":
            return 3
        "normal":
            return 5
        _:
            return -1


## 提示是否已充满（未开启充能时恒为 true）。
func hint_charged() -> bool:
    if not SettingsManager.hint_charge:
        return true
    return hint_charge_left >= HINT_CHARGE_SEC


# ============ 无猜模式（对标游戏 doc10 §2；红线兼容实现） ============
#
# 对标游戏的「专家模式」用「猜错就重排剩余雷」实现，即**移动雷位**——
# 但本作关卡雷位写死在 JSON，移动会破坏 R01 序贯可解验证与关卡数据（见 25_HANDOFF §13.2
# 「无首次点击保护」条目里的同一矛盾）。
#
# 本实现给出**数学保证相同、但不移动雷位**的等价语义：**拒绝**翻开任何无法从当前
# 玩家视角 100% 推导的格子。玩家同样无法靠猜测蒙混过关，且不碰任何关卡数据。
# 口径差异：对标是「猜了会死」，本作是「根本不让猜」。

## 猜测被拒绝时广播（UI 用于提示玩家「本模式不允许猜测」）
signal guess_rejected(pos: Vector2i)

## 推导结果缓存：Vector2i -> true（当前盘面下必然安全）
var _ng_safe_cache: Dictionary = {}
## 缓存对应的推理步总数（用于判断缓存是否过期；每步走一步直推计数）
var _ng_cache_step: int = 0
## 本局被拒次数（统计用）
var _ng_rejected: int = 0


## 该格在当前玩家视角下是否「必然安全」（可 100% 推导）。
## 结果按「已推出的结论集大小」做缓存：盘面一变（翻格/插旗）结论集就变，缓存自然失效。
## 注意：只读玩家视角约束（HintSolver 契约），不读真实雷位。
func is_deducible_safe(pos: Vector2i) -> bool:
    if board == null:
        return false
    if _ng_cache_step != _deduce_stamp():
        _rebuild_ng_cache()
    return _ng_safe_cache.has(pos)


## 缓存有效性标记：全盘「位置 + 状态」滚动哈希（任一格状态变化即失效）。
## 不用「计数」代替——一增一减的换位会让计数不变而约束已变，缓存会错误命中。
func _deduce_stamp() -> int:
    var h := 17
    var sz: Vector2i = board.grid.size()
    for y in sz.y:
        for x in sz.x:
            var c: Cell = board.grid.get_cell(Vector2i(x, y))
            var st: int = c.state if c != null else -1
            h = (h * 31 + st * 131 + x * 7 + y) % 2147483647
    return h


func _rebuild_ng_cache() -> void:
    _ng_safe_cache = {}
    var solver := HintSolver.new()
    if board.def_engine != null:
        solver.engine = board.def_engine
    var steps: Array[ReasoningStep] = []
    if board.clue_def_name != "":
        steps = solver.hint_def(board, board.clue_def_name)
    else:
        steps = solver.hint(board)
    for st in steps:
        if st.state == "safe":
            _ng_safe_cache[st.pos] = true
    _ng_cache_step = _deduce_stamp()


## 被拒绝的猜测次数（本局）。
func rejected_guess_count() -> int:
    return _ng_rejected


# ============ 状态机转换（§10.7.8；非法组合忽略 + push_warning，不崩溃） ============

func set_paused(v: bool) -> void:
    if v and state == State.PLAYING:
        state = State.PAUSED
    elif not v and state == State.PAUSED:
        state = State.PLAYING
    else:
        push_warning("非法状态转换请求: set_paused(%s) 于 state=%s" % [v, state])


## 从主档恢复对局。成功 → clear_temp + session_started + true；失败 → false（调用方 quarantine + toast）。
func restore_from_save() -> bool:
    var d: Dictionary = SaveCoordinator.load_save()
    if d.is_empty() or not d.has("metadata"):
        return false
    var meta: Dictionary = d["metadata"]
    if not meta.has("level_path") or str(meta["level_path"]) == "":
        return false
    # 终局盘（失败后落盘）不可恢复：否则已引爆的雷会连同 PLAYING 状态一起读回，
    # 玩家可用「失败→回主菜单→继续」复活对局，绕过判负。
    if bool(meta.get("ended", false)):
        return false
    var path := str(meta["level_path"])

    # 关卡还在吗（关卡被删/改名 → 恢复失败走坏档路径）
    var fresh: Board = LevelLoader.load_level(path)
    if fresh == null:
        return false

    # 雷位以关卡文件为准（同文件同雷位）；盘面状态 = 存档快照覆盖
    var size := fresh.grid.size()  # Vector2i(cols, rows)
    for r in size.y:
        for c in size.x:
            var pos := Vector2i(c, r)
            var cell := fresh.grid.get_cell(pos)
            cell.state = Cell.State.HIDDEN
    for p in d.get("revealed_cells", []):
        if p is Array and p.size() == 2:
            var pos := Vector2i(int(p[1]), int(p[0]))  # 存档 [row, col]（save_data.gd 约定）
            if fresh.grid.in_board(pos):
                fresh.grid.get_cell(pos).state = Cell.State.REVEALED
    for p in d.get("flagged_cells", []):
        if p is Array and p.size() == 2:
            var pos := Vector2i(int(p[1]), int(p[0]))
            if fresh.grid.in_board(pos):
                fresh.grid.get_cell(pos).state = Cell.State.FLAGGED

    # 一致性校验：存档雷位与关卡雷位必须一致（关卡被改过 → 拒绝恢复）
    var saved_mines := {}
    for p in d.get("mine_positions", []):
        if p is Array and p.size() == 2:
            saved_mines[Vector2i(int(p[1]), int(p[0]))] = true
    var fresh_mines := {}
    for m in fresh.get_mine_positions():
        fresh_mines[m] = true
    if saved_mines.size() != fresh_mines.size():
        return false
    for k in saved_mines:
        if not fresh_mines.has(k):
            return false

    board = fresh
    level_path = path
    elapsed = float(d.get("timer_seconds", 0.0))
    timer_started = true  # 恢复对局从存档续走（§10.7.8 计时规则）
    cursor = Vector2i.ZERO
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    pending_drawing = meta.get("drawing", {})  # 恢复绘画数据
    state = State.PLAYING
    _connect_board_signals()
    # 恢复后的盘面可能已满足胜利条件（存档快照直接覆盖 state，不走 reveal），
    # 而恢复流程本身不判胜负 → 补判一次（信号此时已连接，回调可正常触发）。
    board._check_win()
    SaveCoordinator.clear_temp()
    session_started.emit()
    return true


# ============ 引擎信号接线（Board 是新实例，每次 start/restart/restore 都重连） ============

func _connect_board_signals() -> void:
    if board == null:
        return
    if not board.game_won.is_connected(_on_game_won):
        board.game_won.connect(_on_game_won)
    if not board.game_lost.is_connected(_on_game_lost):
        board.game_lost.connect(_on_game_lost)


func _on_game_won() -> void:
    AudioManager.play("win")
    _finish(true)


func _on_game_lost() -> void:
    exploded_pos = _last_reveal_pos  # 引擎信号不带 pos（Step 0 结论），由 session 追踪
    AudioManager.play("explode")
    _finish(false)


## 终局处置（§10.10.2）：胜 → 不存 + clear_temp；负 → 存终局盘（autosave 时）+ clear_temp。
func _finish(won: bool) -> void:
    state = State.ENDED
    if won:
        ProgressStore.record_clear(level_path, elapsed)  # 通关进度（最佳用时取最小）
        SaveCoordinator.clear_temp()
    else:
        ProgressStore.record_attempt(level_path)  # 失败也算一次尝试
        if SettingsManager != null and SettingsManager.autosave_enabled:
            # 终局盘：打 ended 标记，restore_from_save 会拒绝恢复（禁止 SL 复活失败局）。
            SaveCoordinator.save(board, elapsed, level_path, _get_drawing(), true)
        SaveCoordinator.clear_temp()
    game_ended.emit(won)


# ============ 自动存档（§10.10.2：首次翻格立即，后续 5s 防抖） ============

func _maybe_autosave() -> void:
    if SettingsManager == null or not SettingsManager.autosave_enabled:
        return
    if state != State.PLAYING and state != State.ENDED:
        return
    var now := Time.get_ticks_msec()
    if now - _last_save_ms < 5000:
        return
    _last_save_ms = now
    SaveCoordinator.save(board, elapsed, level_path, _get_drawing())


## 取当前绘画层数据（无绘画层或空则返回 {}）
func _get_drawing() -> Dictionary:
    if drawing_layer != null and is_instance_valid(drawing_layer):
        return drawing_layer.get_save_data()
    return {}
