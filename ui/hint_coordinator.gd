# hint_coordinator.gd —— 提示编排（三档 + 充能 + 一步直推组装）【纯逻辑，无场景依赖】
# 从 game_session.gd 拆出：只读玩家视角约束，不读雷位、不代玩家操作。
class_name HintCoordinator
extends RefCounted

## 提示三档（对标游戏 doc10 §3.2）
const HINT_NORMAL := 0    # 标准：给出结论格 + 依据线索
const HINT_WEAK := 1      # 弱提示：只高亮要用到的线索，不显示可推格
const HINT_DISABLED := 2  # 禁用：完全关闭提示
## 免费提示充能周期（秒；对标 FREE_HINT_TIME = 120f）
const HINT_CHARGE_SEC := 120.0

## 提示充能累计（秒）。开启充能时需 ≥ HINT_CHARGE_SEC 才算充满。
var charge_left: float = 0.0
## 未充满就用了提示 → true（供未来「完美通关」判定消费；当前尚无完美判定）
var uncharged_used: bool = false


## 新对局重置充能状态。
func reset() -> void:
    charge_left = 0.0
    uncharged_used = false


## 充能累计（session 的 _tick 每帧调用；计时门控由 session 负责）。
func tick(delta: float) -> void:
    if SettingsManager.hint_charge:
        charge_left = minf(charge_left + delta, HINT_CHARGE_SEC)


## 提示充能进度 0.0~1.0（未开启充能时恒为 1.0）。
## 全项目唯一的充能口径入口：HUD 用它显示百分比、%>=100 判定「已充满」。
func charge_ratio() -> float:
    if not SettingsManager.hint_charge:
        return 1.0
    return clampf(charge_left / HINT_CHARGE_SEC, 0.0, 1.0)


## 组装一步提示（doc10 §3）：推理求解 + 充能消耗 + 弱提示降级 + 结论格上限 +
## 确证雷集回写 + 终极模式揭星。棋盘为 null 或提示被禁用时返回空数组（不报错）。
func compute_hint(board: Board) -> Array[ReasoningStep]:
    var steps: Array[ReasoningStep] = []
    if board == null or SettingsManager.hint_mode == HINT_DISABLED:
        return steps
    var solver := HintSolver.new()
    if board.def_engine != null:
        solver.engine = board.def_engine  # mod 关卡用共享 DefEngine
    if board.clue_def_name != "":
        steps = solver.hint_def(board, board.clue_def_name)
    else:
        steps = solver.hint(board)
    # 充能：未充满就用 → 标记本局「非完美」，并清零重新充能
    if SettingsManager.hint_charge:
        if charge_left < HINT_CHARGE_SEC:
            uncharged_used = true
        charge_left = 0.0
    # 弱提示：只高亮「要用到的线索」，结论格不展示（board_view 依 method 跳过）
    if SettingsManager.hint_mode == HINT_WEAK:
        for s in steps:
            (s as ReasoningStep).method = "weak"
    steps = _limit_hint_budget(board, steps)
    # 提示断言为「必雷」的格 = 演绎确证 → 记入棋盘的确证雷集。
    # 后续提示可复用它（跨调用不再丢信息，避免「只剩 1 格却推不动」的假卡死）；
    # 注意这与玩家插的旗**不是一回事**：错旗永远不参与推理。
    for st in steps:
        if (st as ReasoningStep).state == "mine":
            board.mark_proven_mine((st as ReasoningStep).pos)
    # 终极模式（对标 doc10 §2.4）：星号格遮蔽着线索值。
    # 当前若能推出安全格 → 正常给提示；若确实推不出任何安全格（卡住了）
    # → 揭开全部星号让对局继续（这一步本身就消耗一次提示）。
    if SettingsManager.no_guess_mode == NoGuessGuard.NO_GUESS_ULTIMATE and board.has_stars():
        var has_safe := false
        for st in steps:
            if (st as ReasoningStep).state == "safe":
                has_safe = true
                break
        if not has_safe:
            board.reveal_stars()
            steps.clear()
    return steps


## 一次提示给出的结论格上限（对标游戏 doc10 §3.3 的 maxClues 与难度挂钩）：
## v4.0 深度口径：噩梦(hard) → 3，困难(normal) → 5，普通/入门/无画像 → 不限（-1）。
## 对齐 GDD 14.2「每次提示只给一个推理阶段，绝不一次性给全部答案」。
func _limit_hint_budget(board: Board, steps: Array[ReasoningStep]) -> Array[ReasoningStep]:
    if board == null or steps.is_empty():
        return steps
    var cap := _hint_budget_cap(board)
    if cap < 0 or steps.size() <= cap:
        return steps
    return steps.slice(0, cap)


## 一次提示给出的结论格上限：噩梦 3 / 困难 5 / 普通·入门不限（-1）。
## 依据：档位已切深度口径（峰值深 = 推理链宽），深档应「只给一个推理阶段」，避免一次揭示过多。
## 无深度画像（旧关卡/手工盘）时回退旧标量口径，再没有则不限。
func _hint_budget_cap(board: Board) -> int:
    if board == null:
        return -1
    var tier := board.tier
    if tier == "":
        tier = Difficulty.tier_of(board.difficulty) if board.difficulty >= 0.0 else ""
    match tier:
        "hard":
            return 3
        "normal":
            return 5
        _:
            return -1
