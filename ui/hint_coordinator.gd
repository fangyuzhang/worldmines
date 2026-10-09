# hint_coordinator.gd —— 提示编排（三档求助深度 + 结论上限 + 一步直推组装）【纯逻辑，无场景依赖】
# 从 game_session.gd 拆出：只读玩家视角约束，不读雷位、不代玩家操作。
#
# 两套“三档”必须分清：
#   · HINT_NORMAL / HINT_WEAK / HINT_DISABLED：设置里的“提示模式”（标准 / 只给线索 / 关闭）；
#   · TIER_REGION / TIER_STEP / TIER_CHAIN：玩家每次求助时选择的“帮助深度”。
# 本文件新增第二套，旧设置口径原样保留，避免把“玩家设置”误当成“本局成绩”。
class_name HintCoordinator
extends RefCounted

## 设置里的提示模式（对标游戏 doc10 §3.2）
const HINT_NORMAL := 0    # 标准：给出结论格 + 依据线索
const HINT_WEAK := 1      # 弱提示：只高亮要用到的线索，不显示可推格
const HINT_DISABLED := 2  # 禁用：完全关闭提示

## 每次提示的帮助深度（玩家主动选择）。
const TIER_REGION := 0    # 只圈出可疑区域：给线索附近待观察的格子，不给结论
const TIER_STEP := 1      # 给一步：沿用旧口径，最多 HINT_MAX_CONCLUSIONS 个必然结论
const TIER_CHAIN := 2     # 给整条链：不截断，一次展示求解器能给出的全部必然步骤
const TIER_NAMES: Array[String] = ["region", "step", "chain"]

## 一次“给一步”给出的结论格上限（2026-09-28 用户决策：统一 2 格）。
const HINT_MAX_CONCLUSIONS := 2


## 组装提示。tier 控制帮助深度；旧调用 compute_hint(board) 默认等价于给一步。
func compute_hint(board: Board, tier: int = TIER_STEP) -> Array[ReasoningStep]:
    var steps: Array[ReasoningStep] = []
    if board == null or SettingsManager.hint_mode == HINT_DISABLED:
        return steps
    var use_tier := clampi(tier, TIER_REGION, TIER_CHAIN)
    var solver := HintSolver.new()
    if board.def_engine != null:
        solver.engine = board.def_engine  # mod 关卡用共享 DefEngine
    if board.clue_def_name != "":
        steps = solver.hint_def(board, board.clue_def_name)
    else:
        steps = solver.hint(board)

    # 旧设置口径：弱提示只保留依据线索，不把结论格交给玩家。
    # 区域档本来就只画线索与未翻开区域，不额外改成 weak，否则 UI 分不清“帮助深度”和“设置模式”。
    if SettingsManager.hint_mode == HINT_WEAK:
        for s in steps:
            if (s as ReasoningStep).tier != "region":
                (s as ReasoningStep).method = "weak"

    if use_tier == TIER_REGION:
        steps = _region_steps(board, steps)
    elif use_tier == TIER_CHAIN:
        _mark_tier(steps, "chain")
    else:
        _mark_tier(steps, "step")
        steps = _limit_hint_budget(steps)

    # 提示断言为“必雷”的格 = 演绎确证 → 记入棋盘的确证雷集。
    for st in steps:
        var step := st as ReasoningStep
        if step != null and step.state == "mine":
            board.mark_proven_mine(step.pos)

    # 终极模式：星号格遮蔽着线索值。能推出安全格则正常提示；确实推不出安全格时揭开全部星号继续。
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


## 把求解器的结论转成“可疑区域”：不泄露结论，只给线索本身和线索邻域中仍未解决的格子。
## 区域档的价值是让玩家知道“该看哪里”，而不是替玩家判断“这格是什么”。
func _region_steps(board: Board, raw: Array[ReasoningStep]) -> Array[ReasoningStep]:
    var out: Array[ReasoningStep] = []
    if raw.is_empty() or board == null or board.grid == null:
        return out
    var cells: Array[Vector2i] = []
    var seen := {}
    for st in raw:
        var step := st as ReasoningStep
        if step == null:
            continue
        _add_region_cell(cells, seen, board, step.pos)
        for src in step.sources:
            _add_region_cell(cells, seen, board, src)
            for n in board.grid.get_neighbors(src):
                _add_region_cell(cells, seen, board, n)
    if cells.is_empty():
        return out
    var region := ReasoningStep.new()
    region.method = "region"
    region.state = "region"
    region.tier = "region"
    region.pos = Vector2i(-1, -1)
    region.rule = "frontier"
    region.proof = "先观察这些线索附近的未翻开格；它们最可能藏着下一步的必然结论。"
    region.sources = cells
    out.append(region)
    return out


func _add_region_cell(cells: Array[Vector2i], seen: Dictionary, board: Board,
        p: Vector2i) -> void:
    if p.x < 0 or p.y < 0 or not board.grid.in_board(p):
        return
    if seen.has(p):
        return
    var c := board.grid.get_cell(p)
    if c == null:
        return
    # 线索格本身也要圈出来；未翻开 / 旗 / 问号格才放进“待观察区域”。
    if c.state == Cell.State.HIDDEN or c.state == Cell.State.FLAGGED or c.state == Cell.State.QUESTION or c.state == Cell.State.REVEALED:
        cells.append(p)
        seen[p] = true


func _mark_tier(steps: Array[ReasoningStep], tier_name: String) -> void:
    for s in steps:
        (s as ReasoningStep).tier = tier_name


## 一次“给一步”的结论上限：截断取前 N 格，沿用求解器确定性产出顺序。
func _limit_hint_budget(steps: Array[ReasoningStep]) -> Array[ReasoningStep]:
    if steps.size() <= HINT_MAX_CONCLUSIONS:
        return steps
    return steps.slice(0, HINT_MAX_CONCLUSIONS)
