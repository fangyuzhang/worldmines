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

var level_path: String = ""
var board: Board = null
var elapsed: float = 0.0
var timer_started: bool = false
var cursor: Vector2i = Vector2i.ZERO
var exploded_pos: Vector2i = Vector2i(-1, -1)  # 判负引爆格，终局高亮用
var state: int = State.IDLE

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
        board.def_engine = ModService.engine
        board._compute_clues()
    elapsed = 0.0
    timer_started = false
    cursor = Vector2i.ZERO
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    _last_save_ms = -100000  # 新对局首次翻格立即存
    pending_drawing = {}  # 新对局：绘画清空
    _connect_board_signals()
    state = State.PLAYING
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
## 非 PLAYING / 无棋盘 → 空数组（不报错）。
func request_hint() -> Array[ReasoningStep]:
    var steps: Array[ReasoningStep] = []
    if state == State.PLAYING and board != null:
        var solver := HintSolver.new()
        if board.def_engine != null:
            solver.engine = board.def_engine  # mod 关卡用共享 DefEngine
        if board.clue_def_name != "":
            steps = solver.hint_def(board, board.clue_def_name)
        else:
            steps = solver.hint(board)
    hint_ready.emit(steps)
    return steps


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
            SaveCoordinator.save(board, elapsed, level_path, _get_drawing())
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
