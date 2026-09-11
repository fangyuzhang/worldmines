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

var grid: GridInterface = null
var total_mines: int = 0
var state: int = GameState.PLAYING
## 关卡难度画像（生成关落盘的 difficulty_profile.difficulty；-1 = 无画像）。
## 供提示预算等「按难度调节」的能力消费，不参与任何胜负/线索逻辑。
var difficulty: float = -1.0
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
##   · value=0 的 revealed 条目不会被翻开（0 格显示深色空白且锁死点击），
##     见下方 revealed 循环。
##   · known_answers 仅为测试锚点（test_classic_known.gd 直接读 JSON），
##     load_level 不读、运行时不使用。
## 内部坐标 Vector2i(col, row) = Vector2i(c, r)。
func load_level(level: Dictionary) -> void:
        state = GameState.PLAYING
        total_mines = level.get("total_mines", 0)
        # 难度画像：优先顶层 difficulty，其次 difficulty_profile.difficulty
        var prof: Dictionary = level.get("difficulty_profile", {})
        difficulty = float(level.get("difficulty", prof.get("difficulty", -1.0)))
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
        if level.has("dominoes"):
                dominoes = _parse_dominoes(level["dominoes"])
                # DT 底座化：把关卡的骨牌划分同步给 DtRule（规则平台的约束构建用「当前关卡」的划分，
                # 而非上次生成时残留的——跨关卡状态泄漏的根治点）。
                if dominoes.size() > 0:
                        var dt_rule: Object = RuleRegistry.default().resolve(&"dt")
                        if dt_rule != null and dt_rule.has_method("set_dominoes"):
                                dt_rule.set_dominoes(dominoes)

        for m in level.get("mines", []):
                var pos := Vector2i(m["c"], m["r"])
                _static_mines.append(pos)
                grid.get_cell(pos).is_mine = true

        _compute_clues()

        # revealed 条目：带 interval 的是 ? 格（遮蔽），带 value 的是普通数字格。
        # 用 reveal_initial：对 0 值格会连锁扩散（见 reveal_initial 内部 _flood_reveal）。
        # 0 值格不再跳过——历史上「跳过 0 值格」正是残局关孤立空白可点击格的根源。
        for r in level.get("revealed", []):
                var pos := Vector2i(r["c"], r["r"])
                # 手工关 revealed 带的 value 字段引擎并不采用（真值一律来自 _compute_clues），
                # 此处仅做一致性校验：关卡作者手写错值时能立刻发现，而不是静默按计算值跑。
                if r.has("value"):
                        var declared: int = int(r["value"])
                        var actual: Variant = grid.get_cell(pos).value
                        if actual is int and int(actual) != declared:
                                push_warning("关卡 revealed 声明值 %d 与计算值 %d 不符 @(%d,%d)" % [declared, int(actual), pos.x, pos.y])
                if r.has("interval"):
                        var iv: Array = r["interval"]
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
                        cell.value = _count_adj_mines(mine_set, grid.get_neighbors(pos))
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
                cell_state_changed.emit(pos)
                _run_comps_reveal(pos)  # 扩散翻开的格子同样触发组件（P4 沙箱 on_reveal）
                for nb in _flood_neighbors(pos):
                        var ncell: Cell = grid.get_cell(nb)
                        if ncell != null and ncell.state == Cell.State.HIDDEN:
                                stack.append(nb)


## 返回「该格线索值为 0（或等价于无雷）」时保证安全的邻格（变体感知）。
## ? 格不扩散；FR 永不扩散；HV 按 [A,B] 分量分别扩散；其余按线索窗口。
func _flood_neighbors(pos: Vector2i) -> Array[Vector2i]:
        var cell: Cell = grid.get_cell(pos)
        if cell == null or cell.is_hidden_clue():
                return []
        # 自举式规则：0 值扩散邻域由规则自己声明（平台不硬编码窗口；value 交给规则判断）。
        if rule_clue_id != "":
                var rule_obj: Object = RuleRegistry.default().resolve(StringName(rule_clue_id))
                if rule_obj != null:
                        return rule_obj.zero_safe_neighbors(pos, grid.size(), cell.value)
                return []
        # 异形拓扑（邻接表）：0 值扩散走拓扑邻域（无「方向」语义，dirs 偏移不成立）。
        if grid is AdjacencyGrid:
                if cell.is_zero_clue():
                        return grid.get_neighbors(pos)
                return []
        var out: Array[Vector2i] = []
        var size: Vector2i = grid.size()
        match clue_variant:
                ClueEngine.Variant.FR:
                        return []
                ClueEngine.Variant.N4:
                        if cell.is_zero_clue():
                                _append_flood_dirs(out, pos, size, ClueEngine.orthogonal_dirs())
                ClueEngine.Variant.SAME_COLOR:
                        if cell.is_zero_clue():
                                _append_flood_dirs(out, pos, size, ClueEngine.diagonal_dirs())
                ClueEngine.Variant.HV:
                        if cell.value is Array:
                                if cell.value[0] == 0:
                                        _append_flood_dirs(out, pos, size, ClueEngine.orthogonal_dirs())
                                if cell.value[1] == 0:
                                        _append_flood_dirs(out, pos, size, ClueEngine.diagonal_dirs())
                _:
                        # CLASSIC / CLOCK / LOOP_RUNS / DIST_SUM：值 0 ⟹ 8 邻无雷
                        # 统一走 Cell.is_zero_clue()（not is_mine and value is int and == 0），
                        # 避免此处与 cell.gd 各写一套判零口径导致漂移。
                        if cell.is_zero_clue():
                                _append_flood_dirs(out, pos, size, ClueEngine.ring_dirs())
        return out


func _append_flood_dirs(out: Array[Vector2i], pos: Vector2i, size: Vector2i, dirs: Array[Vector2i]) -> void:
        for d in dirs:
                var p := pos + d
                if p.x >= 0 and p.x < size.x and p.y >= 0 and p.y < size.y and not out.has(p):
                        out.append(p)


## 插旗/笔记?/取消 循环标记（右键）。
func toggle_flag(pos: Vector2i) -> void:
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
                        cell.state = Cell.State.QUESTION
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
        # GDD R10：胜利 = 所有雷位被确定（插旗），不是「所有非雷格翻开」；安全格可保持未翻开。
        # 判定①：正确插旗的雷数 == 总雷数；判定②：剩余未知格数 == 剩余雷数（全盘确定）。
        var flagged_mines := 0
        var unknown_cells := 0
        for pos in grid.all_positions():
                var cell: Cell = grid.get_cell(pos)
                if cell == null:
                        continue
                if cell.is_mine and cell.state == Cell.State.FLAGGED:
                        flagged_mines += 1
                if cell.state == Cell.State.HIDDEN or cell.state == Cell.State.QUESTION:
                        unknown_cells += 1
        var remaining_mines: int = total_mines - flagged_mines
        if flagged_mines == total_mines or unknown_cells == remaining_mines:
                state = GameState.WON
                game_won.emit()


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
