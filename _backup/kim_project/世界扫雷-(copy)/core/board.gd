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

var grid: RectGrid = null
var total_mines: int = 0
var state: int = GameState.PLAYING

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

# 静态雷位（P0 唯一来源）。P4 扩展为 _static ∪ _dynamic，但本字段不更名。
var _static_mines: Array[Vector2i] = []


## 从预置关卡 JSON 构造棋盘。
## 关卡格式（用户版）：
##   { "size": {"rows":R, "cols":C}, "total_mines":N,
##     "mines": [{"r":r,"c":c}, ...],
##     "revealed": [{"r":r,"c":c,"value":v} 或 {"r":r,"c":c,"interval":[lo,hi]}, ...],
##     "known_answers": {"r,c": value} }
## 内部坐标 Vector2i(col, row) = Vector2i(c, r)。
func load_level(level: Dictionary) -> void:
        state = GameState.PLAYING
        total_mines = level.get("total_mines", 0)
        _static_mines.clear()
        # 变体配置复位为经典（经典关卡无 variant 字段 ⇒ 向后兼容）。
        clue_variant = ClueEngine.Variant.CLASSIC
        clue_variant2 = -1
        constraint_variant = -1
        constraint_variant2 = -1
        dominoes = []
        clue_def_name = ""
        constraint_def_name = ""

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
                        if level.has("dominoes"):
                                dominoes = _parse_dominoes(level["dominoes"])

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
        grid = RectGrid.new()
        grid.setup(rows, cols)

        for m in level.get("mines", []):
                var pos := Vector2i(m["c"], m["r"])
                _static_mines.append(pos)
                grid.get_cell(pos).is_mine = true

        _compute_clues()

        # revealed 条目：带 interval 的是 ? 格（遮蔽），带 value 的是普通数字格。
        for r in level.get("revealed", []):
                var pos := Vector2i(r["c"], r["r"])
                if r.has("interval"):
                        var iv: Array = r["interval"]
                        var cell := grid.get_cell(pos)
                        cell.hidden_interval = Vector2i(iv[0], iv[1])
                reveal(pos)


## 计算全盘线索值（按当前变体线索型）。
func _compute_clues() -> void:
        var size := grid.size()
        var mine_set := _mine_set_dict()
        for r in size.y:
                for c in size.x:
                        var pos := Vector2i(c, r)
                        var cell := grid.get_cell(pos)
                        if cell.is_mine:
                                continue
                        if clue_def_name != "" and def_engine != null and def_engine.clue_defs.has(clue_def_name):
                                cell.value = def_engine.compute_clue(clue_def_name, mine_set, pos, size)
                        else:
                                cell.value = ClueEngine.compute(clue_variant, mine_set, pos, size)
                        if clue_variant2 >= 0:
                                cell.value2 = ClueEngine.compute(clue_variant2, mine_set, pos, size)


## 翻开格子。第一行必须检查 state == PLAYING。
func reveal(pos: Vector2i) -> void:
        if state != GameState.PLAYING:
                return
        if grid == null or not grid.in_board(pos):
                return
        var cell := grid.get_cell(pos)
        if cell.state == Cell.State.REVEALED:
                return
        # 插旗/笔记格的翻开语义：先清除标记（P0 简化：直接翻开）
        if cell.state == Cell.State.FLAGGED or cell.state == Cell.State.QUESTION:
                cell.state = Cell.State.HIDDEN

        if cell.is_mine:
                cell.state = Cell.State.REVEALED
                cell_state_changed.emit(pos)
                state = GameState.LOST
                game_lost.emit()
                return

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
                var cell := grid.get_cell(pos)
                if cell == null or cell.state != Cell.State.HIDDEN:
                        continue
                if cell.is_mine:
                        continue
                cell.state = Cell.State.REVEALED
                cell_state_changed.emit(pos)
                for nb in _flood_neighbors(pos):
                        var ncell := grid.get_cell(nb)
                        if ncell != null and ncell.state == Cell.State.HIDDEN:
                                stack.append(nb)


## 返回「该格线索值为 0（或等价于无雷）」时保证安全的邻格（变体感知）。
## ? 格不扩散；FR 永不扩散；HV 按 [A,B] 分量分别扩散；其余按线索窗口。
func _flood_neighbors(pos: Vector2i) -> Array[Vector2i]:
        var cell := grid.get_cell(pos)
        if cell == null or cell.is_hidden_clue():
                return []
        var out: Array[Vector2i] = []
        var size := grid.size()
        match clue_variant:
                ClueEngine.Variant.FR:
                        return []
                ClueEngine.Variant.N4:
                        if cell.value == 0:
                                _append_flood_dirs(out, pos, size, ClueEngine.orthogonal_dirs())
                ClueEngine.Variant.SAME_COLOR:
                        if cell.value == 0:
                                _append_flood_dirs(out, pos, size, ClueEngine.diagonal_dirs())
                ClueEngine.Variant.HV:
                        if cell.value is Array:
                                if cell.value[0] == 0:
                                        _append_flood_dirs(out, pos, size, ClueEngine.orthogonal_dirs())
                                if cell.value[1] == 0:
                                        _append_flood_dirs(out, pos, size, ClueEngine.diagonal_dirs())
                _:
                        # CLASSIC / CLOCK / LOOP_RUNS / DIST_SUM：值 0 ⟹ 8 邻无雷
                        if cell.value == 0:
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
        var cell := grid.get_cell(pos)
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
        for d in arr:
                var pair: Array[Vector2i] = []
                for p in d:
                        pair.append(Vector2i(int(p["c"]), int(p["r"])))
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
        var cell := grid.get_cell(pos)
        if cell == null or cell.comps.is_empty():
                return
        for comp in cell.comps:
                if comp.effectDecl().get("reveal", false):
                        comp.on_reveal(cell, self)


## 插旗/切换标记后触发该格组件 on_flag（仅声明了 flag 效果的组件）。
func _run_comps_flag(pos: Vector2i) -> void:
        var cell := grid.get_cell(pos)
        if cell == null or cell.comps.is_empty():
                return
        for comp in cell.comps:
                if comp.effectDecl().get("flag", false):
                        comp.on_flag(cell, self)


func _check_win() -> void:
        if state != GameState.PLAYING:
                return
        var size := grid.size()
        for r in size.y:
                for c in size.x:
                        var cell := grid.get_cell(Vector2i(c, r))
                        if not cell.is_mine and cell.state != Cell.State.REVEALED:
                                return
        state = GameState.WON
        game_won.emit()


## 统计信息（供 HUD / 统计使用）。
func get_stats() -> Dictionary:
        var size := grid.size()
        var revealed_count := 0
        var flagged_count := 0
        var total_non_mine := size.x * size.y - total_mines
        for r in size.y:
                for c in size.x:
                        var cell := grid.get_cell(Vector2i(c, r))
                        match cell.state:
                                Cell.State.REVEALED:
                                        revealed_count += 1
                                Cell.State.FLAGGED:
                                        flagged_count += 1
        return {
                "revealed": revealed_count,
                "flagged": flagged_count,
                "total_non_mine": total_non_mine,
                "remaining": total_non_mine - revealed_count,
        }
