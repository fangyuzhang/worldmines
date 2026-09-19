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
## 猜测被拒绝时广播（UI 用于提示玩家「本模式不允许猜测」）
signal guess_rejected(pos: Vector2i)

enum State { IDLE, PLAYING, PAUSED, ENDED }

## 提示三档（对标游戏 doc10 §3.2）—— 转发常量：外部/UI/测试引用方零改动
const HINT_NORMAL := HintCoordinator.HINT_NORMAL
const HINT_WEAK := HintCoordinator.HINT_WEAK
const HINT_DISABLED := HintCoordinator.HINT_DISABLED
## 免费提示充能周期（秒；对标 FREE_HINT_TIME = 120f）
const HINT_CHARGE_SEC := HintCoordinator.HINT_CHARGE_SEC

## 无猜模式三档（对标 doc10 §2）—— 转发常量：外部/UI/测试引用方零改动
const NO_GUESS_OFF := NoGuessGuard.NO_GUESS_OFF
const NO_GUESS_EXPERT := NoGuessGuard.NO_GUESS_EXPERT
const NO_GUESS_ULTIMATE := NoGuessGuard.NO_GUESS_ULTIMATE

var level_path: String = ""
var board: Board = null
var elapsed: float = 0.0
var timer_started: bool = false
var cursor: Vector2i = Vector2i.ZERO
var exploded_pos: Vector2i = Vector2i(-1, -1)  # 判负引爆格，终局高亮用
var state: int = State.IDLE
## 最近一次终局的胜负（覆盖层可能在终局之后才实例化——如「开局即胜」的盘在 start_level
## 内就 _finish，而 game_over 覆盖层要等 board_view._ready 才创建——那时 game_ended 早已
## emit 过，覆盖层只能靠本字段补显结算，见 game_over.gd 的 _ready 自同步）。
var last_result_won := false
## 提示充能累计（秒）。委托给 HintCoordinator 持有（hud.gd 等外部读取入口不变）。
var hint_charge_left: float:
    get: return _hints.charge_left
    set(v): _hints.charge_left = v
## 未充满就用了提示 → true（委托给 HintCoordinator 持有）。
var hint_uncharged_used: bool:
    get: return _hints.uncharged_used
    set(v): _hints.uncharged_used = v

## 拆分后的协作组件（§拆分 2026-09：无猜守卫 / 提示编排从本类抽出）
var _guard := NoGuessGuard.new()
var _hints := HintCoordinator.new()

var _last_save_ms: int = -100000  # 自动存档防抖（首次翻格立即存）
var _last_reveal_pos: Vector2i = Vector2i(-1, -1)  # 引爆格追踪

# 绘画数据采集回调（board_view 创建绘画层后注册）+ 恢复时待载入的绘画数据。
# autoload 不直接持有 UI 节点类型（依赖倒置）：采集走 provider，恢复走纯数据 pending_drawing。
var _drawing_provider: Callable = Callable()
var pending_drawing: Dictionary = {}


## board_view 在绘画层就绪后注册采集闭包（如 func(): return _drawing.get_save_data()）。
func set_drawing_provider(p: Callable) -> void:
    _drawing_provider = p


func _ready() -> void:
    # 预留：无事可做（autoload 顺序 Settings→Theme→GameSession 已保证）
    pass


func _process(delta: float) -> void:
    _tick(delta)


## 计时门控（§10.7.8）：state == PLAYING 且 timer_started 才累计；充能累计委托给 _hints。
func _tick(delta: float) -> void:
    if state == State.PLAYING and timer_started:
        elapsed += delta
        _hints.tick(delta)


# ============ 对局生命周期 ============

## 开始关卡。失败返回 false（调用方停留本页 + toast，不切场景）。
func start_level(path: String) -> bool:
    level_path = path
    board = LevelLoader.load_level(path)
    if board == null:
        push_error("关卡加载失败: " + path)
        state = State.IDLE
        return false
    # mod 关卡（user:// + clue_def/constraint_def 字段）：Board 构造时 def_engine 为 null，
    # load_level 内的 def 分支不成立 → clue_def_name 恒空（旧判断是死分支，关卡静默按
    # 经典 8 邻计算、数字全错）。此处读 JSON 探测 def 字段，注入共享 DefEngine 后按原始
    # 数据重建棋盘（load_level 先复位再走全流程，def 分支此时生效）。
    if path.begins_with("user://") and ModAPI != null:
        var d := _read_level_dict(path)
        if not d.is_empty() and (str(d.get("clue_def", "")) != "" or str(d.get("constraint_def", "")) != ""):
            board.def_engine = ModAPI.defs
            board.load_level(d)
    elapsed = 0.0
    timer_started = false
    cursor = Vector2i.ZERO
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    # 终极模式：本次对局的「玩家新翻开线索格一律打星号」开关
    board.hide_new_clues = SettingsManager.no_guess_mode == NO_GUESS_ULTIMATE
    _hints.reset()
    _guard.reset()
    _last_save_ms = -100000  # 新对局首次翻格立即存
    _move_history.clear()  # 新对局：操作撤销栈清空
    # 绘画草稿按关卡持久化（v3.3）：开启「绘画草稿存入存档」→ 载入本关草稿
    #（通关后重进仍在）；关闭 → 全新开始（草稿不载入、后续也不保存）。
    pending_drawing = SaveCoordinator.load_drawing(path) if SettingsManager.drawing_in_save else {}
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
## v3.3：重开 = 本关进度与绘画草稿一并清空（有草稿时确认弹窗会提示，可勾选「不再提示」）。
func restart() -> void:
    SaveCoordinator.clear_drawing(level_path)
    start_level(level_path)


## 撤回踩雷：撤销引爆格，恢复到踩雷前状态（仅失败终局可撤；胜局不撤）。
## 引爆格恢复 HIDDEN；board/session 状态回 PLAYING 继续计时。
func undo() -> bool:
    if state != State.ENDED or board == null:
        return false
    if board.state != Board.GameState.LOST:
        return false
    # 引擎公共 API：引爆格恢复 + 状态回转（UI 不再直写 cell.state/board.state）
    if not board.undo_explode(exploded_pos):
        return false
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    state = State.PLAYING
    timer_started = true  # 撤回后继续计时
    # 撤回后立即重写主档（清掉 ended=true 的终局档）——否则「判负→撤回→直接退出」
    # 会把败局档留在 MAIN，下次「继续」被拒，撤回救回的进度丢失。
    _last_save_ms = -100000
    _maybe_autosave()
    session_restored.emit()
    return true


# ============ 操作撤销（v3.3：可一路撤销到关卡开始；与绘画撤销完全独立） ============
#
# 历史栈由 session 持有：每个玩家动作（reveal/toggle_flag）之前做全盘格状态快照，
# 动作之后差分出「变化格子 → 之前状态」入栈。撤销 = 弹栈 + board.apply_cell_states 还原。
# 终局步不入栈（判负另有 undo() 撤回通道）→ 栈内任何一步都可安全回退到 PLAYING。
# 绘画撤销是 DrawingLayer 自己的栈（Ctrl+Z 仅在绘画模式生效），两者互不干扰。

## 操作历史：Array of Dictionary（{pos: [state, starred]}），栈顶 = 最近一步。
var _move_history: Array = []


## 全盘格状态快照（撤销记录用）：{pos: [state, starred]}。
func _snapshot_cells() -> Dictionary:
    var snap := {}
    if board == null or board.grid == null:
        return snap
    for p in board.grid.all_positions():
        var c: Cell = board.grid.get_cell(p)
        if c != null:
            snap[p] = [c.state, c.starred]
    return snap


## 差分入栈：只记录状态真正变化过的格子；无变化 / 已终局不入栈。
func _record_move(before: Dictionary) -> void:
    if board == null or board.grid == null or board.state != Board.GameState.PLAYING:
        return
    var changes := {}
    for p in board.grid.all_positions():
        var c: Cell = board.grid.get_cell(p)
        if c == null:
            continue
        var prev: Array = before.get(p, [Cell.State.HIDDEN, false])
        if prev[0] != c.state or prev[1] != c.starred:
            changes[p] = prev
    if not changes.is_empty():
        _move_history.append(changes)


## 撤销上一步玩家操作（翻开 / 插旗 / ? 标记）。连按可一路退到关卡开始的状态。
## 与绘画撤销（DrawingLayer 自有栈，仅绘画模式 Ctrl+Z）互相独立、互不影响。
func undo_move() -> bool:
    if state != State.PLAYING or board == null or _move_history.is_empty():
        return false
    var changes: Dictionary = _move_history.pop_back()
    board.apply_cell_states(changes)
    _maybe_autosave()
    return true


## 是否还有可撤销的操作（HUD 按钮状态用）。
func can_undo_move() -> bool:
    return state == State.PLAYING and board != null and not _move_history.is_empty()


## 本关是否有已持久化的绘画草稿（重开确认弹窗的「草稿将清除」提示用）。
func has_saved_draft() -> bool:
    if SettingsManager == null or not SettingsManager.drawing_in_save:
        return false
    return not SaveCoordinator.load_drawing(level_path).is_empty()


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
    if SettingsManager.no_guess_mode == NO_GUESS_EXPERT and not _guard.is_deducible_safe(board, pos):
        _guard.record_rejection()
        guess_rejected.emit(pos)
        AudioManager.play("flag")
        return
    _last_reveal_pos = pos
    var before := _snapshot_cells()  # 撤销历史：记录本步之前的全盘格状态
    board.reveal(pos)
    _record_move(before)
    # 判负由 game_lost 信号播爆炸声；此处只播普通翻开声
    if board.state != Board.GameState.LOST:
        AudioManager.play("reveal")
    # board.state 由引擎信号保证同步；翻格后仍 PLAYING 则起表
    if state == State.PLAYING and board.state == Board.GameState.PLAYING and not timer_started:
        timer_started = true
    _maybe_autosave()
    # 翻完这一格可能已经推不动了 → 终极档自动揭星（若开启）
    if board.state == Board.GameState.PLAYING:
        _maybe_auto_ultimate_hint()


## 一键展开（chord，市面扫雷标配，本作此前缺失）：
## 在**已翻开的数字格**上，若邻域已插旗数 == 该格线索值，则翻开其余未翻开的邻格。
##
## 设计取舍：
##   · 只接受**整数值**线索（HV 返回分量对、FR 返回 "inf"）→ 语义不明时拒绝，绝不猜；
##   · 每一格仍走 reveal() 统一入口 → 无猜-专家档的「推不出来就拒绝」、
##     音效、自动存档、终局判定全部复用同一套逻辑，不引入第二条路径；
##   · 旗插错时按标准扫雷语义处理（翻开即可能踩雷）——错旗是玩家的判断，不是系统的猜测，
##     不违反 R01（R01 约束的是关卡本身序贯可解，不是玩家操作）。
## 返回实际翻开的格数（0 = 条件不满足）。
func chord(pos: Vector2i) -> int:
    if state != State.PLAYING or board == null or board.grid == null:
        return 0
    if not board.grid.in_board(pos):
        return 0
    var cell: Cell = board.grid.get_cell(pos)
    if cell == null or cell.state != Cell.State.REVEALED:
        return 0
    if not (cell.value is int):
        return 0
    var need: int = int(cell.value)
    var flagged := 0
    var targets: Array[Vector2i] = []
    for p in board.grid.get_neighbors(pos):
        var c: Cell = board.grid.get_cell(p)
        if c == null:
            continue
        if c.state == Cell.State.FLAGGED:
            flagged += 1
        elif c.state == Cell.State.HIDDEN:
            targets.append(p)
    if flagged != need or targets.is_empty():
        return 0
    var opened := 0
    for p in targets:
        reveal(p)
        var c2: Cell = board.grid.get_cell(p)
        if c2 != null and c2.state == Cell.State.REVEALED:
            opened += 1
        if board.state != Board.GameState.PLAYING:
            break  # 已终局（踩雷/胜利）立即停手
    return opened


func toggle_flag(pos: Vector2i) -> void:
    if state != State.PLAYING or board == null:
        return
    if not board.grid.in_board(pos):
        return
    var cell := board.grid.get_cell(pos)
    if cell.state != Cell.State.HIDDEN and cell.state != Cell.State.FLAGGED and cell.state != Cell.State.QUESTION:
        return
    var before := _snapshot_cells()  # 撤销历史：记录本步之前的全盘格状态
    # 右键是否走「? 」三态由设置决定（默认只有 标雷/取消 两态）。
    # 判空：测试里 SettingsManager 可能是手工实例或未注册，不能假定它一定在。
    var allow_q: bool = true if SettingsManager == null else SettingsManager.question_mark_enabled
    board.toggle_flag(pos, allow_q)
    _record_move(before)
    AudioManager.play("flag")
    _maybe_autosave()


# ============ 提示（一步直推，只读玩家视角约束，不读雷位、不代玩家操作） ============

## 请求一步提示。返回 ReasoningStep 数组（可能为空），并广播 hint_ready 供 UI 高亮。
## 非 PLAYING / 无棋盘 / 提示被禁用 → 空数组（不报错）。
## 推理步骤组装/充能消耗/降级/上限/揭星全部委托 HintCoordinator（见 hint_coordinator.gd）。
func request_hint() -> Array[ReasoningStep]:
    var steps: Array[ReasoningStep] = []
    if state == State.PLAYING:
        steps = _hints.compute_hint(board)
    hint_ready.emit(steps)
    return steps


## 提示充能进度 0.0~1.0（未开启充能时恒为 1.0）。
## 全项目唯一的充能口径入口：HUD 用它显示百分比、%>=100 判定「已充满」。
## （原先并存的 hint_charged() 是无调用者的死代码，已删除——两个同义 API 只会各自漂移。）
func hint_charge_ratio() -> float:
    return _hints.charge_ratio()


# ============ 无猜模式（对标游戏 doc10 §2） ============
#
# 推导缓存 / 拒绝计数 / 可推安全格判定全部委托 NoGuessGuard（见 no_guess_guard.gd）。
# 本节注释保留在守卫文件头部；此处只做薄委托，对外 API 签名不变。


## 该格在当前玩家视角下是否「必然安全」（可 100% 推导）。
func is_deducible_safe(pos: Vector2i) -> bool:
    return _guard.is_deducible_safe(board, pos)


## 被拒绝的猜测次数（本局）。
func rejected_guess_count() -> int:
    return _guard.rejected_count()


## 当前盘面下「可无猜推出的安全格数」（终极模式附加信息用）。
func deducible_safe_count() -> int:
    return _guard.deducible_safe_count(board)


## 终极模式附加开关（doc10 §2.3 AddOnAutoReveal）：可推格数为 0 时自动按下提示
## ——即自动揭开星号让对局继续，免去玩家手动点提示。
## 注意：提示被设为「禁用」时不做自动化（尊重玩家的显式关闭）。
func _maybe_auto_ultimate_hint() -> void:
    if SettingsManager.no_guess_mode != NO_GUESS_ULTIMATE:
        return
    if not SettingsManager.ult_auto_reveal:
        return
    if board == null or not board.has_stars():
        return
    if _guard.deducible_safe_count(board) > 0:
        return
    request_hint()


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

    # 雷位以关卡文件为准（同文件同雷位）；盘面状态 = 存档快照覆盖。
    # v3.1：改走引擎公共 API restore_cell_states（封装全盘重置 + revealed/flagged 应用 +
    # 异形洞格守卫），UI 不再直写 cell.state。
    fresh.restore_cell_states(d.get("revealed_cells", []), d.get("flagged_cells", []))

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

    # 终极模式开关与星号 / 确证雷集恢复：此前 restore 丢失 hide_new_clues（新翻格不再打星、
    # 已星格的线索值直接暴露），proven_mines 不恢复则「只剩 1 格却推不动」的假卡死复现。
    fresh.hide_new_clues = SettingsManager != null and SettingsManager.no_guess_mode == NO_GUESS_ULTIMATE
    for p in meta.get("starred", []):
        if p is Array and p.size() == 2:
            var spos := Vector2i(int(p[1]), int(p[0]))
            if fresh.grid.in_board(spos):
                fresh.grid.get_cell(spos).starred = true
    for p in meta.get("proven_mines", []):
        if p is Array and p.size() == 2:
            var ppos := Vector2i(int(p[1]), int(p[0]))
            if fresh.grid.in_board(ppos):
                fresh.mark_proven_mine(ppos)
    board = fresh
    level_path = path
    elapsed = float(d.get("timer_seconds", 0.0))
    timer_started = true  # 恢复对局从存档续走（§10.7.8 计时规则）
    cursor = Vector2i.ZERO
    exploded_pos = Vector2i(-1, -1)
    _last_reveal_pos = Vector2i(-1, -1)
    _move_history.clear()  # 恢复对局：撤销栈清空（历史只属于本进程内的操作序列）
    # 恢复绘画数据：统一取按关草稿库（v3.3 起草稿真值来源；save.json 内 drawing 仅为旧档兼容）
    pending_drawing = SaveCoordinator.load_drawing(path) if SettingsManager.drawing_in_save else {}
    state = State.PLAYING
    _connect_board_signals()
    # 恢复后的盘面可能已满足胜利条件（存档快照直接覆盖 state，不走 reveal），
    # 而恢复流程本身不判胜负 → 补判一次（信号此时已连接，回调可正常触发）。
    board.evaluate_win()
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
    # 记录终局结果：覆盖层可能在终局之后才实例化（board_view._ready 里才创建 game_over），
    # 那时 game_ended 已 emit 过，覆盖层靠本字段补显结算（game_over.gd 自同步）。
    last_result_won = won
    state = State.ENDED
    # 进度写「序列键」而不是 level_path：选关页打勾/解锁与 LevelSequence.has_next
    # 都按序列键读取。历史上这里传 level_path（user://gen_levels/*.json），
    # 写的与读的不是同一个键 → 通关了不打勾、下一关一直锁着（见 LevelSequence.progress_key）。
    var key := LevelSequence.progress_key(level_path)
    if won:
        ProgressStore.record_clear(key, elapsed)  # 通关进度（最佳用时取最小）
        # 胜局 = 对局已完结，无可续进度 → 连 MAIN 一起清（MAIN 里残留的本局自动档
        # 未带 ended 标记，留着会被下次启动的自动恢复误当成「未完成对局」复活）。
        SaveCoordinator.clear()
    else:
        ProgressStore.record_attempt(key)  # 失败也算一次尝试
        if SettingsManager != null and SettingsManager.autosave_enabled:
            # 终局盘：打 ended 标记，restore_from_save 会拒绝恢复（禁止 SL 复活失败局）。
            SaveCoordinator.save(board, elapsed, level_path, _get_drawing(), true)
        SaveCoordinator.clear_temp()
    game_ended.emit(won)


# ============ 自动存档（§10.10.2：首次翻格立即，后续 1s 防抖；绘画变化同通道） ============

func _maybe_autosave() -> void:
    if SettingsManager == null or not SettingsManager.autosave_enabled:
        return
    # 只在 PLAYING 自动存档。ENDED 由 _finish 按胜负各自处置（终局档带 ended 标记），
    # 此前放行 ENDED 会用无标记的常规档覆盖终局档 → 失败局可被「恢复」复活（SL 作弊通道）。
    if state != State.PLAYING:
        return
    # 防御：level_path 为空 = 测试直赋 board 等非正常开局路径，写出的档必然无法恢复
    #（restore_from_save 空路径即拒）→ 曾因此产生「存档已损坏」误报，直接跳过。
    if level_path == "":
        return
    var now := Time.get_ticks_msec()
    # 1s 防抖（v3.2 由 5s 收紧）：翻格/插旗等动作后 1 秒内必落盘，
    # 保证「随时退出 → 下次进来还是这个进度」；chord 连翻等爆发由防抖合并。
    if now - _last_save_ms < 1000:
        return
    _last_save_ms = now
    SaveCoordinator.save(board, elapsed, level_path, _get_drawing())


## 自动存档请求入口（供绘画层 changed 等外部信号触发；与 _maybe_autosave 同一防抖口径）。
func request_autosave() -> void:
    _maybe_autosave()


## 立即落盘当前对局（忽略防抖；回主菜单/选关等主动离开对局时调用）。
## 非 PLAYING / 无棋盘 / 无有效关卡路径 → 不写（与 _maybe_autosave 同口径）。
func save_now() -> void:
    if SettingsManager == null or not SettingsManager.autosave_enabled:
        return
    if state != State.PLAYING or board == null or level_path == "":
        return
    _last_save_ms = Time.get_ticks_msec()
    SaveCoordinator.save(board, elapsed, level_path, _get_drawing())


## 取当前绘画层数据（provider 未注册 / 用户关闭「绘画草稿存入存档」→ {}）
##
## ⚠️ 不能只判 `_drawing_provider.is_valid()`：provider 是 board_view 注册的闭包，
## 其宿主（board_view / 绘画层）被释放后，**Callable 本身仍是 valid**，
## 一旦调用就会在引擎层炸 "Condition \"slot >= slot_max\" is true"（实测于
## test_game_session_logic::test_t11b —— 前一个用例的 board_view 已释放）。
## 因此必须再验一次闭包宿主是否还活着。
func _get_drawing() -> Dictionary:
    if SettingsManager != null and not SettingsManager.drawing_in_save:
        return {}
    if not _drawing_provider.is_valid():
        return {}
    var host: Object = _drawing_provider.get_object()
    if host != null and not is_instance_valid(host):
        _drawing_provider = Callable()   # 宿主已释放 → 注销，别再留着
        return {}
    return _drawing_provider.call()


## 读关卡 JSON 为 Dictionary（mod clue_def 注入探测用；失败/非对象返回 {}）。
func _read_level_dict(path: String) -> Dictionary:
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return {}
    var v: Variant = JSON.parse_string(f.get_as_text())
    f.close()
    return v if v is Dictionary else {}
