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
## 缓存对应的推理步总数（用于判断缓存是否过期；每步走一步直推计数）
var _cache_step: int = 0
## 本局被拒次数（统计用）
var _rejected: int = 0


## 新对局开始时清空缓存与计数。不持有 Board 引用——盘面由调用方按次传入，
## 避免「session 换盘（测试直赋 board / 恢复存档）而守卫引用失步」的隐患。
func reset() -> void:
    _safe_cache = {}
    _cache_step = -1
    _rejected = 0


## 猜测被拒时由 session 调用（计数归守卫持有）。
func record_rejection() -> void:
    _rejected += 1


## 被拒绝的猜测次数（本局）。
func rejected_count() -> int:
    return _rejected


## 该格在当前玩家视角下是否「必然安全」（可 100% 推导）。
## 结果按「已推出的结论集大小」做缓存：盘面一变（翻格/插旗）结论集就变，缓存自然失效。
## 注意：只读玩家视角约束（HintSolver 契约），不读真实雷位。
func is_deducible_safe(b: Board, pos: Vector2i) -> bool:
    if b == null:
        return false
    if _cache_step != _deduce_stamp(b):
        _rebuild_cache(b)
    return _safe_cache.has(pos)


## 当前盘面下「可无猜推出的安全格数」（终极模式附加信息用）。
## 复用同一份推导缓存，不额外触发一次求解。
func deducible_safe_count(b: Board) -> int:
    if b == null:
        return 0
    if _cache_step != _deduce_stamp(b):
        _rebuild_cache(b)
    return _safe_cache.size()


## 缓存有效性标记。必须同时覆盖三件事，否则会误命中过期缓存：
##   ① 盘面实例（同关卡重开得到的新 Board 状态图案可能完全相同）；
##   ② 每格的 状态 + 星号位（星号改变玩家可见信息，但不改 state）；
##   ③ 位置（防止「状态计数相同但换位」的情况）。
## 历史 bug：只用「位置 + 状态」哈希 → 星号变化与换 Board 都不失效，
## 实测表现为「新盘面复用了上一局的可断定结论」。
func _deduce_stamp(b: Board) -> int:
    var h := int(b.get_instance_id()) % 2147483647
    var sz: Vector2i = b.grid.size()
    for y in sz.y:
        for x in sz.x:
            var c: Cell = b.grid.get_cell(Vector2i(x, y))
            var st: int = c.state if c != null else -1
            var star: int = 1 if (c != null and c.starred) else 0
            h = (h * 31 + st * 131 + star * 17 + x * 7 + y) % 2147483647
    return h


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
    _cache_step = _deduce_stamp(b)
