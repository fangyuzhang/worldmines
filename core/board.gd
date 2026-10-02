# board.gd —— 棋盘核心（文档 §3.2/§3.3/§3.4/§4.2）【人工锁死】
# 双视角隔离：求解器/提示器只准通过 get_player_constraint(pos) 获取玩家视角约束。
# 判负唯一入口：is_mine(pos)。get_mine_positions() 注释锁死 P4 语义：返回 _static ∪ _dynamic。
class_name Board
extends RefCounted

enum GameState { PLAYING, WON, LOST }

signal game_won
signal game_lost
## 〔plan1.1 §10.2.3〕唯一许可的新增信号：单格状态变更（渲染/动效监听）。不得触碰判负/判胜逻辑。
signal cell_state_changed(pos: Vector2i)
## 〔v3.4 动效计划〕一次泛洪的完整计划（整批，一次性发出）——给 UI 一个「本次泛洪」的
## **权威来源**，取代 UI 侧「同帧唯一格数 ≥ 2」的启发式（后者会把终极模式揭星 / chord 误报）。
##
## 与 cell_state_changed 的分工：前者是**逐格状态事实**（渲染 / 单格 pop 用），本信号是
## **整批计划**（波浪分环 / 错峰排队用）。时序：本次泛洪的逐格 cell_state_changed 全部发完后，
## 在**同一个同步调用内**发一次本信号（不引入跨帧 / 不延迟；泛洪同步语义不变）。
##
## 载荷：
##   origin     —— 泛洪起点（玩家点的那一格 / 初始 revealed 声明的格 / chord 的目标格）
##   cells      —— 本次实际由 HIDDEN → REVEALED 的全部格（含 origin；不含已翻开格与雷格）
##   zero_flood —— 是否「真·0 格泛洪」：本次确实发生了**多格连锁展开**（cells.size() >= 2）。
##                 false = 只是单格翻开（数字格 / FR 的 0 / 孤立 0 格：邻域无未翻开安全格）。
##
## zero_flood 判定依据（覆盖全部调用来源）：
##   · 唯一实现点 _flood_reveal 只在起点为「零值安全格」时才会把邻格压栈——内置变体由
##     ClueEngine.zero_safe_dirs 裁决、规则关卡由 RulePlugin.zero_safe_neighbors 裁决
##     （FR 的 0 = 右邻必雷，永不扩散）；故 cells.size() >= 2 当且仅当
##     「由变体语义下的 0 值格引发了一次真正的连锁」。
##   · reveal()（玩家点击 / chord 逐目标）→ 0 值格连锁 true、数字格 false；
##   · reveal_initial()（关卡载入 revealed 列表）→ 与 reveal() 同语义（0 值格 true）；
##   · reveal_stars() / _star_new_revealed()（终极模式揭星）→ **不经过 _flood_reveal**，
##     只发 cell_state_changed，故**不会**发出本信号（不会被误判为 0 格泛洪）。
signal flood_planned(origin: Vector2i, cells: Array[Vector2i], zero_flood: bool)

var grid: GridInterface = null
var total_mines: int = 0
var state: int = GameState.PLAYING
## 胜负判定（P6 胜负原语化）。默认经典扫雷（GDD R10）；自定义模式可替换为其它实现。
## 这是把硬编码判胜/判负抽出的策略对象——见 core/win_condition.gd。
var win_condition: WinConditionPlugin = WinConditionPlugin.new()
## 关卡难度画像（生成关落盘的 difficulty_profile.difficulty；-1 = 无画像）。
## 供提示预算等「按难度调节」的能力消费，不参与任何胜负/线索逻辑。
var difficulty: float = -1.0
## 深度画像（v4.0）：peak = 单步最大必要线索数；tier = 由峰值定的档位（供提示预算/UI 用）。
var peak := -1
var tier := ""
## **已被演绎确证的雷**（pos -> true）。只由提示/求解器的必然结论写入，
## **绝不等于玩家插的旗**——玩家可能插错，而这里的每一格都是在「当时全部玩家视角约束下
## 所有模型里恒成立的雷」。
##
## 为什么需要它：`HintSolver.hint_rule` 的零信任不动点迭代只在**单次调用内**有效，
## 跨调用会丢掉这批结论 → 出现「只剩 1 个隐藏格却推不动」的假卡死
##（实测 classic_07：14 翻开 + 10 确证雷，最后 1 格本可由「总雷数已满」直接判安全，
## 但因为确证雷没被记住，CP-SAT 仍认为该格有两种可能）。
## 这正是 25_HANDOFF §13.2 给出的正解：「先零信任推理出必然雷集，再只把集合内的旗计入」。
var proven_mines: Dictionary = {}


## 登记一格「演绎确证的雷」。
func mark_proven_mine(pos: Vector2i) -> void:
        proven_mines[pos] = true


## 终极模式（对标 doc10 §2.4）：**玩家新翻开的线索格一律打星号**（值隐藏），
## 直到玩家点提示且当前确实无可推格时才由 reveal_stars() 揭开。
## 只影响「玩家视角」（get_player_constraint）与显示，不影响引擎真值/胜负/离线验证。
var hide_new_clues: bool = false

# 变体配置（默认经典）。clue 见 ClueEngine.Variant，constraint 见 ConstraintEngine.Variant（-1 = 无）。
var clue_variant: int = ClueEngine.Variant.CLASSIC
var clue_variant2: int = -1       # 第二线索型（-1 = 无，E 类线索混合）
var constraint_variant: int = -1
var constraint_variant2: int = -1  # 双布局第二全局约束（-1 = 无，F 类）
var dominoes: Array = []  # G5 骨牌划分数据（Array[Array[Vector2i]]），仅 DT 用

# mod 自定义规则（第二篇）：def_name 优先于内置枚举。空 = 用内置变体。
var clue_def_name: String = ""
var constraint_def_name: String = ""
var def_engine: DefEngine = null
# ★ 自举式规则平台：关卡可声明 clue_rule（规则 id，内置与 mod 同源），
# 优先于 clue_def（有限原子）与内置变体枚举。
var rule_clue_id: String = ""
var rule_global_ids: Array = []

# 静态雷位（P0 唯一来源）。P4 扩展为 _static ∪ _dynamic，但本字段不更名。
var _static_mines: Array[Vector2i] = []


## 从预置关卡 JSON 构造棋盘。
## 关卡格式（用户版）：
##   { "size": {"rows":R, "cols":C}, "total_mines":N,
##     "mines": [{"r":r,"c":c}, ...],
##     "revealed": [{"r":r,"c":c} 或 {"r":r,"c":c,"interval":[lo,hi]}, ...], }
##
## 关卡格式口径（v2.9.3 核实，此前文档与实现不符，勿再按旧文档写）：
##   · revealed[].value 为**历史遗留可选字段**，引擎一律用 _compute_clues 的计算值，
##     不读它；若存在且与计算值不符会 push_warning（仅作校验，不影响运行）。
##     → 生成关（generated_*.json）不写 value；手工关写了也只当注释。
##   · value=0 的 revealed 条目**会被正常翻开并连锁扩散**（v2.9.3 修复：
##     历史上跳过 0 值格导致「孤立空白可点击格」用户 bug；生成器亦不再排除 0 值格）。
##     见下方 revealed 循环（统一走 reveal_initial）。
##   · known_answers 仅为测试锚点（test_classic_known.gd 直接读 JSON），
##     load_level 不读、运行时不使用。
## 内部坐标 Vector2i(col, row) = Vector2i(c, r)。
func load_level(level: Dictionary) -> void:
        state = GameState.PLAYING
        total_mines = level.get("total_mines", 0)
        # 难度画像：优先顶层 difficulty，其次 difficulty_profile.difficulty
        var prof: Dictionary = level.get("difficulty_profile", {})
        difficulty = float(level.get("difficulty", prof.get("difficulty", -1.0)))
        peak = int(prof.get("max_complexity", -1))
        tier = Difficulty.tier_of_profile(prof)
        _static_mines.clear()
        # 变体配置复位为经典（经典关卡无 variant 字段 ⇒ 向后兼容）。
        clue_variant = ClueEngine.Variant.CLASSIC
        clue_variant2 = -1
        constraint_variant = -1
        constraint_variant2 = -1
        dominoes = []
        clue_def_name = ""
        constraint_def_name = ""
        rule_clue_id = ""
        rule_global_ids = []
        proven_mines = {}  # 新关卡：确证雷集必须清空，否则会带着上一局的结论推理

        # ★ P3 自举式规则：读取 rule_level / clue_rule / global_rules 字段。
        # 规则由 RuleRegistry 解析（内置 + mod 注册同源）；命中即优先于 variant/def。
        if bool(level.get("rule_level", false)):
                var rid: String = str(level.get("clue_rule", ""))
                if rid != "" and RuleRegistry.default().resolve(StringName(rid)) != null:
                        rule_clue_id = rid
                # 全局约束独立于线索规则：clue_rule 缺失/未注册时也必须保留，
                # 否则 get_player_global_constraints 静默丢约束，求解器/提示器在错误前提下工作。
                rule_global_ids = level.get("global_rules", [])

        # ★ P1：读取变体字段（variant 码 → clue_variant + constraint_variant + constraint_variant2 + dominoes）。
        # 支持混合码 "布局+线索"（C 类）与 "布局+布局"（F 类双布局）。
        var vcode: String = str(level.get("variant", ""))
        if vcode != "":
                var def: Dictionary = VariantRegistry.resolve(vcode)
                if not def.is_empty():
                        clue_variant = def["clue"]
                        clue_variant2 = int(def.get("clue2", -1))
                        constraint_variant = def["constraint"]
                        constraint_variant2 = int(def.get("constraint2", -1))
                        # 骨牌解析延后到 grid 建好之后（见下方）：需要盘面尺寸才能做越界校验。

        # ★ P2 mod：读取 clue_def / constraint_def 字段（自定义规则包，第二篇）。
        # 仅当 def_engine 已注入且 Def 已注册时生效；否则回退内置变体。
        var cdef: String = str(level.get("clue_def", ""))
        var cdef2: String = str(level.get("constraint_def", ""))
        if cdef != "" and def_engine != null and def_engine.clue_defs.has(cdef):
                clue_def_name = cdef
        if cdef2 != "" and def_engine != null and def_engine.constraint_defs.has(cdef2):
                constraint_def_name = cdef2

        var sz: Dictionary = level.get("size", {})
        var rows: int = sz.get("rows", 0)
        var cols: int = sz.get("cols", 0)
        # ★ 拓扑注入：关卡可声明 topology（邻接表）→ 异形/六边形/自定义棋盘；
        # 否则回退矩形 RectGrid（向后兼容全部现有关卡）。
        if level.has("topology"):
                var ag: AdjacencyGrid = AdjacencyGrid.new()
                ag.setup_from_topo(level["topology"])
                grid = ag
        else:
                var rg: RectGrid = RectGrid.new()
                rg.setup(rows, cols)
                grid = rg

        # 骨牌（DT 变体）：须在 grid 建好后解析，才能校验坐标是否落在盘内。
        var dt_rule: Object = RuleRegistry.default().resolve(&"dt")
        if level.has("dominoes"):
                dominoes = _parse_dominoes(level["dominoes"])
                # DT 底座化：把关卡的骨牌划分同步给 DtRule（规则平台的约束构建用「当前关卡」的划分，
                # 而非上次生成时残留的——跨关卡状态泄漏的根治点）。
                if dominoes.size() > 0 and dt_rule != null and dt_rule.has_method("set_dominoes"):
                        dt_rule.set_dominoes(dominoes)
        elif dt_rule != null and dt_rule.has_method("set_dominoes") and rule_global_ids.has("dt"):
                # 共享单例防残留（v3.1）：规则关卡声明 dt 但不带 dominoes 数据时显式清空——
                # 否则上一关（DT）的划分残留，hint/生成在错误划分上演绎（违反 R02）。
                dt_rule.set_dominoes([])

        # ★ 隐藏态恢复（2026-09-16，HANDOFF 已知坑 #18）：读取 level["hidden_state"] 并分发给
        # 对应规则实例——否则 o4/o5x 等隐藏态规则载盘后 compute_clue 用空/残留状态 → 数字全错。
        # 与 DT 骨牌 set_dominoes 同为「载盘状态同步」；顺序必须在 _compute_clues() 之前。
        if level.has("hidden_state"):
                var hs: Dictionary = level.get("hidden_state", {})
                for rid in hs:
                        var hr: Object = RuleRegistry.default().resolve(StringName(rid))
                        if hr != null and hr.has_method("import_hidden_state"):
                                hr.call("import_hidden_state", hs[rid])

        for m in level.get("mines", []):
                var pos := Vector2i(m["c"], m["r"])
                # 防御纵深：越界雷条目直接跳过（与 revealed 越界守卫同语义）——
                # get_cell 返回 null 时 `.is_mine = true` 会空引用中止整个加载。
                if not grid.in_board(pos):
                        push_warning("关卡 mines 越界条目已跳过: (%d,%d)" % [pos.x, pos.y])
                        continue
                _static_mines.append(pos)
                grid.get_cell(pos).is_mine = true

        _compute_clues()

        # revealed 条目：带 interval 的是 ? 格（遮蔽），带 value 的是普通数字格。
        # 用 reveal_initial：对 0 值格会连锁扩散（见 reveal_initial 内部 _flood_reveal）。
        # 0 值格不再跳过——历史上「跳过 0 值格」正是残局关孤立空白可点击格的根源。
        for r in level.get("revealed", []):
                var pos := Vector2i(r["c"], r["r"])
                # 防御纵深（v2.9.3）：越界条目直接跳过——LevelLoader 已前置拦截 UI 路径，
                # 此处兜底直调 board.load_level 的路径（get_cell 返回 null 会造成空引用错误）。
                if not grid.in_board(pos):
                        push_warning("关卡 revealed 越界条目已跳过: (%d,%d)" % [pos.x, pos.y])
                        continue
                # 手工关 revealed 带的 value 字段引擎并不采用（真值一律来自 _compute_clues），
                # 此处仅做一致性校验：关卡作者手写错值时能立刻发现，而不是静默按计算值跑。
                if r.has("value"):
                        var declared: int = int(r["value"])
                        var actual: Variant = grid.get_cell(pos).value
                        if actual is int and int(actual) != declared:
                                push_warning("关卡 revealed 声明值 %d 与计算值 %d 不符 @(%d,%d)" % [declared, int(actual), pos.x, pos.y])
                if r.has("interval"):
                        var iv: Array = r["interval"]
                        # 防御纵深：畸形 interval（长度 < 2）忽略设置但格照常翻开——
                        # LevelLoader 已前置拦截携带畸形 interval 的文件（返回 null），
                        # 此处兜底直调路径（iv[0]/iv[1] 直接下标会越界中止脚本）。
                        if iv.size() < 2:
                                push_warning("关卡 ? 格 (%d,%d) interval 畸形已忽略: %s" % [pos.x, pos.y, str(iv)])
                                reveal_initial(pos)
                                continue
                        var cell: Cell = grid.get_cell(pos)
                        var iv_lo: int = int(iv[0])
                        var iv_hi: int = int(iv[1])
                        # ? 格区间口径统一（v2.9.3）：手工关历史上写 [0, hi]（几乎无信息），
                        # 生成关写 [1, hi]（含「≥1」）。同为「?」符号但难度不可比。
                        # ? 的语义是「这是个线索格、值未知」，真值 0 不可能是有意义的 ? 格，
                        # 故真值 ≥1 时把下界抬到 1。
                        # 安全护栏：真值确为 0 时保持原区间并告警——抬高会让该关卡无解，
                        # 宁可保住可解性，把「作者该改数据」明确报出来。
                        if iv_lo == 0:
                                if cell.value is int and int(cell.value) >= 1:
                                        iv_lo = 1
                                else:
                                        push_warning("关卡 ? 格 (%d,%d) 真值为 %s，保留区间 [0,%d]（口径未统一，建议改关卡数据）" % [pos.x, pos.y, str(cell.value), iv_hi])
                        cell.hidden_interval = Vector2i(iv_lo, iv_hi)
                reveal_initial(pos)


## 线索值分派（自举式规则平台）：规则 > def > 内置变体。
## 规则由 RuleRegistry 解析——内置规则与第三方 mod 规则同源、同 API。
func _clue_value_dispatch(mine_set: Dictionary, pos: Vector2i, size: Vector2i) -> Variant:
        if rule_clue_id != "":
                var rule: Object = RuleRegistry.default().resolve(StringName(rule_clue_id))
                if rule != null:
                        return rule.compute_clue(mine_set, pos, size)
        if clue_def_name != "" and def_engine != null and def_engine.clue_defs.has(clue_def_name):
                return def_engine.compute_clue(clue_def_name, mine_set, pos, size)
        return ClueEngine.compute(clue_variant, mine_set, pos, size)


## 计算全盘线索值（按当前变体线索型）。
func _compute_clues() -> void:
        var size: Vector2i = grid.size()
        var mine_set := _mine_set_dict()
        var rule: Object = RuleRegistry.default().resolve(StringName(rule_clue_id)) if rule_clue_id != "" else null
        # 异形拓扑（邻接表）：线索 = 拓扑邻域计数，邻域来自邻接表而非 dirs 偏移。
        var is_adj: bool = grid is AdjacencyGrid
        for pos in grid.all_positions():
                var cell: Cell = grid.get_cell(pos)
                if cell == null or cell.is_mine:
                        continue
                if is_adj:
                        # 【2026-10-01 组合缺口修复】拓扑盘上的线索值**优先交给规则自己**（新契约
                        # `compute_clue_topo`，基类默认实现 = 拓扑邻域雷数 ⇒ 内置 classic 逐位不变）。
                        # 为什么必须问规则：生成期已按规则的语义求值（`puzzle_generator.gd` 同一契约），
                        # 载入侧若仍硬编码"邻域计数"，加权/压缩值域的规则（如声明式规格的 wsum）
                        # 就会出现「生成对、装载错」——玩家看到的数字与提示推导不一致，
                        # 正是"棋盘可用 + 变体可用 ⇒ 组合出问题"的那一类。
                        var v_adj: Variant
                        if rule != null and rule.has_method("compute_clue_topo"):
                                v_adj = rule.call("compute_clue_topo", mine_set, pos, grid, size)
                        else:
                                v_adj = _count_adj_mines(mine_set, grid.get_neighbors(pos))
                        cell.value = v_adj
                        continue
                # 规则可声明「本规则不适用于该格」（applies_to）：生成器据此把该格排除在线索集外。
                # 加载侧必须同样排除，否则出现「生成时不算线索、显示时却有数字」的分叉。
                if rule != null and not rule.applies_to(pos, size):
                        # 哨兵 -1：该格「不携带线索」。Cell.value 默认 0，若不置哨兵，
                        # 会被 is_zero_clue() 误判为空格并错误扩散（mod 规则覆盖 applies_to 时触发）。
                        cell.value = -1
                        continue
                if clue_def_name != "" and def_engine != null and def_engine.clue_defs.has(clue_def_name):
                        cell.value = def_engine.compute_clue(clue_def_name, mine_set, pos, size)
                else:
                        cell.value = _clue_value_dispatch(mine_set, pos, size)
                if clue_variant2 >= 0:
                        cell.value2 = ClueEngine.compute(clue_variant2, mine_set, pos, size)


## 拓扑邻域雷计数（异形棋盘线索：等价 classic 的「周围格」，窗口来自邻接表）。
static func _count_adj_mines(mine_set: Dictionary, neighbors: Array) -> int:
        var n := 0
        for p in neighbors:
                if mine_set.has(p):
                        n += 1
        return n


## 翻开格子。第一行必须检查 state == PLAYING。
func reveal(pos: Vector2i) -> void:
        if state != GameState.PLAYING:
                return
        if grid == null or not grid.in_board(pos):
                return
        var cell: Cell = grid.get_cell(pos)
        if cell.state == Cell.State.REVEALED:
                return
        # 插旗格受保护：左键不翻开（防止误触引爆玩家已标记的雷）。
        # UI 层（game_session）已拦截，此处是引擎层兜底——scenes/main.gd 等
        # 直调 board.reveal 的路径绕过了 UI 检查，此前会清旗并当场判负。
        if cell.state == Cell.State.FLAGGED:
                return
        # 笔记（?）格不是保护态：清除标记后正常翻开
        if cell.state == Cell.State.QUESTION:
                cell.state = Cell.State.HIDDEN

        if cell.is_mine:
                cell.state = Cell.State.REVEALED
                cell_state_changed.emit(pos)
                # 判负交给胜负策略（默认经典 = 翻雷即输；教学模式可覆盖为不判负）
                if win_condition.on_reveal_mine(self):
                        state = GameState.LOST
                        game_lost.emit()
                return

        var before := _revealed_snapshot() if hide_new_clues else {}
        _flood_reveal(pos)
        _run_comps_reveal(pos)
        if hide_new_clues:
                _star_new_revealed(before)
        _check_win()


## 已翻开格快照（键为 pos），供星号打标做差集。
func _revealed_snapshot() -> Dictionary:
        var snap := {}
        for p in grid.all_positions():
                var c: Cell = grid.get_cell(p)
                if c != null and c.state == Cell.State.REVEALED:
                        snap[p] = true
        return snap


## 给「本次新翻开的非雷格」打星号（终极模式）。已带 ? 遮蔽的格不打星（? 本身即遮蔽语义）。
func _star_new_revealed(before: Dictionary) -> void:
        for p in grid.all_positions():
                if before.has(p):
                        continue
                var c: Cell = grid.get_cell(p)
                if c == null or c.state != Cell.State.REVEALED or c.is_mine:
                        continue
                if c.is_hidden_clue():
                        continue
                c.starred = true
                cell_state_changed.emit(p)


## 揭开全部星号（终极模式：玩家卡住时点提示，星号变回线索）。
## 返回揭开的格数；0 表示当前没有星号格。
func reveal_stars() -> int:
        var n := 0
        for p in grid.all_positions():
                var c: Cell = grid.get_cell(p)
                if c != null and c.starred:
                        c.starred = false
                        n += 1
                        cell_state_changed.emit(p)
        return n


## 是否存在星号格（UI/逻辑查询用）。
func has_stars() -> bool:
        for p in grid.all_positions():
                var c: Cell = grid.get_cell(p)
                if c != null and c.starred:
                        return true
        return false


## 初始翻开（不连锁扩散）：仅翻开该格本身。
## 加载关卡时精确翻开 revealed 列表声明的格子；玩家点击才走 reveal()（触发 0 格扩散）。
## 若初始格也扩散，会翻开关卡未声明的格子（手工关/生成关初始状态错乱的根因）。
func reveal_initial(pos: Vector2i) -> void:
        if state != GameState.PLAYING:
                return
        if grid == null or not grid.in_board(pos):
                return
        var cell: Cell = grid.get_cell(pos)
        if cell.state == Cell.State.REVEALED:
                return
        if cell.state == Cell.State.FLAGGED or cell.state == Cell.State.QUESTION:
                cell.state = Cell.State.HIDDEN

        if cell.is_mine:
                cell.state = Cell.State.REVEALED
                cell_state_changed.emit(pos)
                state = GameState.LOST
                game_lost.emit()
                return

        # 初始翻开同样连锁扩散（与玩家点击 reveal 同语义）：_flood_reveal 对非 0 格只翻本身、
        # 对 0 值格递归扩散邻域。历史 bug：这里手动 REVEALED 不扩散，导致 0 值格显示
        # 深色空白孤立格，进而逼出「生成器排除 0 值格」的 workaround，最终表现为
        # 「空白可点击孤立格」（用户反复报告的 bug 根源）。
        _flood_reveal(pos)
        _run_comps_reveal(pos)
        _check_win()


## 0 格连锁扩散（变体感知，plan1.9 §7.2）。
## 「值 0 ⇒ 邻域安全」的语义随变体不同：N4 只扩散 4 正交、SC 只扩散 4 对角、
## HV 按 [A,B] 分量分别扩散、FR 永不扩散（值 0 = 右邻必雷）、其余（CLASSIC/CLOCK/
## LOOP_RUNS/DIST_SUM）扩散 8 邻。雷格绝不参与扩散（is_mine 守卫）。
func _flood_reveal(start: Vector2i) -> void:
        var stack: Array[Vector2i] = [start]
        var visited := {}
        # 〔v3.4〕收集本次泛洪实际翻开的格，结束后一次性告知 UI（见 flood_planned 信号）。
        var cells: Array[Vector2i] = []
        while not stack.is_empty():
                var pos: Vector2i = stack.pop_back()
                if visited.has(pos):
                        continue
                visited[pos] = true
                var cell: Cell = grid.get_cell(pos)
                if cell == null or cell.state != Cell.State.HIDDEN:
                        continue
                if cell.is_mine:
                        continue
                cell.state = Cell.State.REVEALED
                cells.append(pos)
                cell_state_changed.emit(pos)
                _run_comps_reveal(pos)  # 扩散翻开的格子同样触发组件（P4 沙箱 on_reveal）
                for nb in _flood_neighbors(pos):
                        var ncell: Cell = grid.get_cell(nb)
                        if ncell != null and ncell.state == Cell.State.HIDDEN:
                                stack.append(nb)
        _emit_flood_planned(start, cells)


## 〔v3.4〕泛洪结束后同帧发出「本次泛洪计划」（详见 flood_planned 信号注释）。
## zero_flood = cells.size() >= 2：_flood_reveal 仅当起点为变体语义下的「0 值安全格」时才会
## 把邻格压栈，故「多格」⟺「真·0 格泛洪」；单格（数字格 / FR 的 0 / 孤立 0 格）→ false。
## cells 为空（起点不可翻：非 HIDDEN 或雷格）时不发，避免 UI 收到空计划。
func _emit_flood_planned(origin: Vector2i, cells: Array[Vector2i]) -> void:
        if cells.is_empty():
                return
        flood_planned.emit(origin, cells, cells.size() >= 2)


## 返回「该格线索值为 0（或等价于无雷）」时保证安全的邻格（变体感知）。
## ? 格不扩散；FR 永不扩散；HV 按 [A,B] 分量分别扩散；其余按线索窗口。
func _flood_neighbors(pos: Vector2i) -> Array[Vector2i]:
        var cell: Cell = grid.get_cell(pos)
        # is_mine 守卫与原 Cell.is_zero_clue() 口径一致（雷格永不扩散）
        if cell == null or cell.is_mine or cell.is_hidden_clue():
                return []
        # 异形拓扑（邻接表）：0 值扩散**必须优先**走拓扑邻域——本分支必须在规则分支之前。
        # 审计修复（2026-09-21）：内置规则（如 ClassicRule.zero_safe_neighbors）按 ring_dirs()
        # 的 8 邻偏移算邻域，而形状关的线索值是**拓扑邻域**计数：蜂窝盘 HEX6 不含对角
        # (±1,±1) 方向 ⇒ 0 值格会"免费翻开"非拓扑邻域的格（越过线索保证范围、与提示结论
        # 不一致、实际难度低于生成画像）。原顺序下本分支对带 rule_clue_id 的形状关是死代码。
        if grid is AdjacencyGrid:
                # 【2026-10-02 补齐"值接了、扩散没接"】拓扑盘上**先问规则**的拓扑扩散契约
                # （`RulePlugin.zero_safe_neighbors_topo`）：
                # 基类默认实现 = 0 值 ⇒ 拓扑邻格（＝下面这行硬编码原样搬过去，classic 逐位不变）；
                # 加权/压缩型规格应覆写为空（"值是 0"只保证被引用的邻居安全，不代表邻格都安全）。
                # 顺序纪律不变：本分支仍然**优先于**矩形规则分支（见下方审计修复的注释）。
                if rule_clue_id != "":
                        var topo_rule: Object = RuleRegistry.default().resolve(StringName(rule_clue_id))
                        if topo_rule != null and topo_rule.has_method("zero_safe_neighbors_topo"):
                                # 鸭子类型返回可能是无类型 Array ⇒ 显式转成 Array[Vector2i] 再返回
                                #（直接 return Variant 会在强类型返回处抛 "same element type" 错）
                                var flood: Array[Vector2i] = []
                                flood.assign(topo_rule.call("zero_safe_neighbors_topo", pos, grid, cell.value))
                                return flood
                if cell.is_zero_clue():
                        return grid.get_neighbors(pos)
                return []
        # 自举式规则：0 值扩散邻域由规则自己声明（平台不硬编码窗口；value 交给规则判断）。
        if rule_clue_id != "":
                var rule_obj: Object = RuleRegistry.default().resolve(StringName(rule_clue_id))
                if rule_obj != null:
                        return rule_obj.zero_safe_neighbors(pos, grid.size(), cell.value)
                return []
        # 内置变体的 0 值语义：**单点定义在 ClueEngine.zero_safe_dirs**（v2.9.3 收敛）。
        # 此前这段 match 与 hint_solver 的零值特判各写一套，新增变体易漏改一处。
        var out: Array[Vector2i] = []
        _append_flood_dirs(out, pos, grid.size(), ClueEngine.zero_safe_dirs(clue_variant, cell.value))
        return out


func _append_flood_dirs(out: Array[Vector2i], pos: Vector2i, size: Vector2i, dirs: Array[Vector2i]) -> void:
        for d in dirs:
                var p := pos + d
                if p.x >= 0 and p.x < size.x and p.y >= 0 and p.y < size.y and not out.has(p):
                        out.append(p)


## 插旗/笔记?/取消 循环标记（右键）。
##
## allow_question=false 时**跳过 ? 态**，循环变成两态：HIDDEN → FLAGGED → HIDDEN。
## 是否启用由上层（GameSession 读 SettingsManager）传入 —— core 不直接引用 UI autoload。
##
## ⚠️ QUESTION → HIDDEN 这条分支**任何设置下都必须保留**：玩家关掉 ? 之后，盘上残留的
## 问号格仍要能被清掉，否则会留下一批右键永远消不掉的格子（静默死锁，且不报错）。
func toggle_flag(pos: Vector2i, allow_question: bool = true) -> void:
        if state != GameState.PLAYING:
                return
        if grid == null or not grid.in_board(pos):
                return
        var cell: Cell = grid.get_cell(pos)
        if cell.state == Cell.State.REVEALED:
                return
        match cell.state:
                Cell.State.HIDDEN:
                        cell.state = Cell.State.FLAGGED
                Cell.State.FLAGGED:
                        cell.state = Cell.State.QUESTION if allow_question else Cell.State.HIDDEN
                Cell.State.QUESTION:
                        cell.state = Cell.State.HIDDEN
        cell_state_changed.emit(pos)
        _run_comps_flag(pos)


## 【双视角唯一入口】玩家视角约束集。调用方仅限求解器/提示器。
func get_player_constraint(pos: Vector2i) -> Dictionary:
        if grid == null or not grid.in_board(pos):
                return { "type": "none" }
        return grid.get_cell(pos).get_player_constraint()


## 【双视角入口】玩家视角全局约束集（声明式描述，不含雷位）。
## 求解器/提示器通过此入口读取"当前关卡有哪些全局约束"，避免直接读字段破坏双视角隔离。
## 返回 Array[Dictionary]，每项 { "type": "mx"|"rl"|"pf"|"qd"|"dt"|"ep"|"4c"|"custom", ...参数 }。
func get_player_global_constraints() -> Array:
        var out: Array = []
        if constraint_variant >= 0:
                out.append(_constraint_desc(constraint_variant, dominoes))
        if constraint_variant2 >= 0:
                out.append(_constraint_desc(constraint_variant2, []))
        if constraint_def_name != "":
                out.append({"type": "custom", "def_name": constraint_def_name})
        for gid in rule_global_ids:
                out.append({"type": "rule", "rule_id": str(gid)})
        if rule_clue_id != "":
                out.append({"type": "rule", "rule_id": rule_clue_id, "clue": true})
        return out


## 内置约束枚举 → 声明式描述（与 ConstraintEngine.Variant 对齐）。
func _constraint_desc(variant: int, p_dominoes: Array) -> Dictionary:
        match variant:
                ConstraintEngine.Variant.MX:
                        return {"type": "mx"}
                ConstraintEngine.Variant.RL:
                        return {"type": "rl"}
                ConstraintEngine.Variant.PF:
                        return {"type": "pf"}
                ConstraintEngine.Variant.QD:
                        return {"type": "qd"}
                ConstraintEngine.Variant.DT:
                        return {"type": "dt", "dominoes": p_dominoes}
                ConstraintEngine.Variant.EP:
                        return {"type": "ep"}
                ConstraintEngine.Variant.FOUR_COLOR:
                        return {"type": "4c"}
                _:
                        return {"type": "none"}


## 判负唯一入口。P4 注释锁死：返回 _static ∪ _dynamic。
func is_mine(pos: Vector2i) -> bool:
        if grid == null or not grid.in_board(pos):
                return false
        return grid.get_cell(pos).is_mine


## 雷位全集。P4 语义 = _static ∪ _dynamic。
func get_mine_positions() -> Array[Vector2i]:
        return _static_mines.duplicate()


## 雷位字典（Vector2i -> true），供线索计算 / 约束检查 / 生成器使用。
func _mine_set_dict() -> Dictionary:
        var d := {}
        for m in _static_mines:
                d[m] = true
        return d


## 解析骨牌划分（JSON → Array[Array[Vector2i]]），DT 变体用。
func _parse_dominoes(arr: Array) -> Array:
        var out: Array = []
        var size: Vector2i = grid.size()
        for d in arr:
                var pair: Array[Vector2i] = []
                for p in d:
                        # 结构防御 + 越界过滤：畸形/越界骨牌此前会被 constraint_engine 静默漏检，
                        # 导致 DT 约束在错误数据上「恒真」。
                        if not (p is Dictionary) or not (p.has("c") and p.has("r")):
                                continue
                        var cp := Vector2i(int(p["c"]), int(p["r"]))
                        if cp.x < 0 or cp.x >= size.x or cp.y < 0 or cp.y >= size.y:
                                push_warning("dominoes 坐标越界，已忽略: (%d,%d)" % [cp.x, cp.y])
                                continue
                        pair.append(cp)
                if pair.size() >= 2:
                        out.append(pair)
        return out


## 设置变体配置（线索型 + 可选全局约束 + 可选第二全局约束）。
func set_variant(clue: int, constraint: int = -1, p_dominoes: Array = [], constraint2: int = -1, clue2: int = -1) -> void:
        clue_variant = clue
        clue_variant2 = clue2
        constraint_variant = constraint
        constraint_variant2 = constraint2
        dominoes = p_dominoes


# ============ CellComp 组件钩子（P4 组件行为系统） ============

## 翻开后触发该格组件 on_reveal（仅声明了 reveal 效果的组件）。
func _run_comps_reveal(pos: Vector2i) -> void:
        var cell: Cell = grid.get_cell(pos)
        if cell == null or cell.comps.is_empty():
                return
        for comp in cell.comps:
                if comp.effectDecl().get("reveal", false):
                        comp.on_reveal(cell, self)


## 插旗/切换标记后触发该格组件 on_flag（仅声明了 flag 效果的组件）。
func _run_comps_flag(pos: Vector2i) -> void:
        var cell: Cell = grid.get_cell(pos)
        if cell == null or cell.comps.is_empty():
                return
        for comp in cell.comps:
                if comp.effectDecl().get("flag", false):
                        comp.on_flag(cell, self)


func _check_win() -> void:
        if state != GameState.PLAYING:
                return
        # GDD R10 胜负判定已抽到 win_condition（core/win_condition.gd）。
        # 胜利 = 所有雷位被确定（插旗），不是「所有非雷格翻开」；安全格可保持未翻开。
        if win_condition.is_won(self):
                state = GameState.WON
                game_won.emit()


# ==== v3.1 新增公共 API（对局会话用；新增方法不触碰锁死接口的字段/签名）====

## 撤回踩雷：引爆格恢复 HIDDEN，棋盘状态回 PLAYING（仅 LOST 态生效）。
## UI 不再直写 cell.state / board.state（引擎内部状态封装）。
## 返回 true = 状态已回 PLAYING（引爆格不在盘内/非翻开态时只做状态回转，与旧语义一致）。
func undo_explode(exploded: Vector2i) -> bool:
        if state != GameState.LOST:
                return false
        if grid != null and grid.in_board(exploded):
                var cell: Cell = grid.get_cell(exploded)
                if cell != null and cell.state == Cell.State.REVEALED:
                        cell.state = Cell.State.HIDDEN
                        cell_state_changed.emit(exploded)
        state = GameState.PLAYING
        return true


## 从存档快照恢复盘面状态：全盘重置 HIDDEN 后应用 revealed/flagged（存档 [row, col] 格式）。
## 异形洞格守卫内置（get_cell 为 null 的格跳过）；UI 不再直写 cell.state。
func restore_cell_states(revealed: Array, flagged: Array) -> void:
        for pos in grid.all_positions():
                var cell: Cell = grid.get_cell(pos)
                if cell != null:
                        cell.state = Cell.State.HIDDEN
        for p in revealed:
                if p is Array and p.size() == 2:
                        var pos := Vector2i(int(p[1]), int(p[0]))
                        if grid.in_board(pos):
                                grid.get_cell(pos).state = Cell.State.REVEALED
        for p in flagged:
                if p is Array and p.size() == 2:
                        var pos := Vector2i(int(p[1]), int(p[0]))
                        if grid.in_board(pos):
                                grid.get_cell(pos).state = Cell.State.FLAGGED


## 撤销恢复通道（v3.3 新增，纯增量不改既有接口）：按 {pos: [state, starred]} 逐格恢复。
## 与 restore_cell_states 同性质的引擎公共恢复 API——历史栈由 session 层持有，
## 每步记录「变化格子 → 该步之前的状态」，撤销时交回本函数还原并广播 cell_state_changed。
func apply_cell_states(changes: Dictionary) -> void:
        for pos in changes:
                if grid == null or not grid.in_board(pos):
                        continue
                var cell: Cell = grid.get_cell(pos)
                if cell == null:
                        continue
                var before: Array = changes[pos]
                cell.state = before[0]
                cell.starred = before[1]
                cell_state_changed.emit(pos)


## 判胜补评估（公共入口）：恢复对局等场景下盘面可能已满足胜利条件。
## 内部委托 _check_win（PLAYING 态守卫 + win_condition 策略）。
func evaluate_win() -> void:
        _check_win()


## 统计信息（供 HUD / 统计使用）。
func get_stats() -> Dictionary:
        var positions: Array[Vector2i] = grid.all_positions()
        var revealed_count := 0
        var flagged_count := 0
        for pos in positions:
                var cell: Cell = grid.get_cell(pos)
                if cell == null:
                        continue
                match cell.state:
                        Cell.State.REVEALED:
                                revealed_count += 1
                        Cell.State.FLAGGED:
                                flagged_count += 1
        var total_non_mine := positions.size() - total_mines
        return {
                "revealed": revealed_count,
                "flagged": flagged_count,
                "total_non_mine": total_non_mine,
                "remaining": total_non_mine - revealed_count,
        }
