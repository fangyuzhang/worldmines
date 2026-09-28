# hint_coordinator.gd —— 提示编排（三档 + 结论上限 + 一步直推组装）【纯逻辑，无场景依赖】
# 从 game_session.gd 拆出：只读玩家视角约束，不读雷位、不代玩家操作。
class_name HintCoordinator
extends RefCounted

## 提示三档（对标游戏 doc10 §3.2）
const HINT_NORMAL := 0    # 标准：给出结论格 + 依据线索
const HINT_WEAK := 1      # 弱提示：只高亮要用到的线索，不显示可推格
const HINT_DISABLED := 2  # 禁用：完全关闭提示
## 一次提示给出的结论格上限（2026-09-28 用户决策：**统一 2 格**，取消按档位分档）。
## 历史口径 = 噩梦 3 / 困难 5 / 普通与无画像**不限**——普通档点一次会给出全部可确定格
## （实测几十格 + 一墙推理文字），与「一步一推」的设计意图相悖（GDD 14.2）。
## 现无论档位与盘型，每次只给 1~2 格；要更多就再点一次（提示已不消耗充能，见 compute_hint）。
const HINT_MAX_CONCLUSIONS := 2


## 组装一步提示（doc10 §3）：推理求解 + 弱提示降级 + 结论格上限 +
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
    # 充能消耗已于 2026-09-28 移除（用户决策）：每次提示只给 ≤2 格后，再按 120 秒卡一次
    # 会让提示基本用不动——现可连续点，唯一的限制是「每次 1~2 格」。
    # 弱提示：只高亮「要用到的线索」，结论格不展示（board_view 依 method 跳过）
    if SettingsManager.hint_mode == HINT_WEAK:
        for s in steps:
            (s as ReasoningStep).method = "weak"
    steps = _limit_hint_budget(steps)
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


## 一次提示给出的结论格上限：统一 ≤ HINT_MAX_CONCLUSIONS（2）。
## 旧口径按档位分档、普通档不限 ⇒ 点一次给全部，正是本次要修的问题（见常量处注释）。
## 截断取**前 N 格**：不另立偏好，沿用 solver 的确定性产出顺序（先必雷批、后安全批；
## 同一条线索批量得出时按格序）——同一局面反复点得到同样结论，不会飘。
func _limit_hint_budget(steps: Array[ReasoningStep]) -> Array[ReasoningStep]:
    if steps.size() <= HINT_MAX_CONCLUSIONS:
        return steps
    return steps.slice(0, HINT_MAX_CONCLUSIONS)
