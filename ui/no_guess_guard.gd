# no_guess_guard.gd —— 无猜模式守卫（对标游戏 doc10 §2；红线兼容实现）【纯逻辑，无场景依赖】
#
# 对标游戏的「专家模式」用「猜错就重排剩余雷」实现，即**移动雷位**——
# 但本作关卡雷位写死在 JSON，移动会破坏 R01 序贯可解验证与关卡数据（见 25_HANDOFF §13.2
# 「无首次点击保护」条目里的同一矛盾）。
#
# 本实现给出**数学保证相同、但不移动雷位**的等价语义：**拒绝**翻开任何无法从当前
# 玩家视角 100% 推导的格子。玩家同样无法靠猜测蒙混过关，且不碰任何关卡数据。
# 口径差异：对标是「猜了会死」，本作是「根本不让猜」。
#
# 从 game_session.gd 拆出：只读玩家视角约束（HintSolver 契约），不读真实雷位。
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


## 新对局开始时清空缓存与计数。
func reset() -> void:
    _safe_cache = {}
    _cache_valid = false
    _rejected = 0
    # 注意：不清 _bound_board —— 换盘时 _bind_board 自会识别并换绑（见下）。


## 猜测被拒时由 session 调用（计数归守卫持有）。
func record_rejection() -> void:
    _rejected += 1


## 被拒绝的猜测次数（本局）。
func rejected_count() -> int:
    return _rejected


## 该格在当前玩家视角下是否「必然安全」（可 100% 推导）。
## 注意：只读玩家视角约束（HintSolver 契约），不读真实雷位。
func is_deducible_safe(b: Board, pos: Vector2i) -> bool:
    if b == null:
        return false
    _bind_board(b)
    if not _cache_valid:
        _rebuild_cache(b)
    return _safe_cache.has(pos)


## 当前盘面下「可无猜推出的安全格数」（终极模式附加信息用）。
## 复用同一份推导缓存，不额外触发一次求解。
func deducible_safe_count(b: Board) -> int:
    if b == null:
        return 0
    _bind_board(b)
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
func _bind_board(b: Board) -> void:
    if _bound_board == b:
        return
    _bound_board = b
    _cache_valid = false
    if not b.cell_state_changed.is_connected(_on_board_changed):
        b.cell_state_changed.connect(_on_board_changed)


func _on_board_changed(_pos: Vector2i) -> void:
    _cache_valid = false


func _rebuild_cache(b: Board) -> void:
    _safe_cache = {}
    var solver := HintSolver.new()
    if b.def_engine != null:
        solver.engine = b.def_engine
    var steps: Array[ReasoningStep] = []
    if b.clue_def_name != "":
        steps = solver.hint_def(b, b.clue_def_name)
    else:
        steps = solver.hint(b)
    for st in steps:
        if st.state == "safe":
            _safe_cache[st.pos] = true
    _cache_valid = true
