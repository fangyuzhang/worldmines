extends GutTest
## 【主代理集成验收】声明式规格 × 内置规则：**端到端逐字段等价**
##
## 为什么必须有这一层（而不是只靠适配器自己的单测）：
##   单测证明的是"零件像"（`compute_clue` 逐值一致 / IR 结构等价），**不证明整条生成管线产出一致**。
##   本测试用 spec 复刻 `classic`（8 邻 + 求和），对**同一个 (size, mines, seed)** 各生成一关，
##   再逐字段比较 ⇒ 规格适配器只要有**任何**语义偏差（邻域顺序、越界处理、约束形态、aux 编号），
##   这里立刻红。这是"用户写规格 == 我们自己的规则"这句承诺的**可执行判据**。
##
## 镜像目标（必须逐条对齐，否则等价性无从谈起）：
##   · `core/rule_registry.gd:171-184`（ClassicRule）
##       compute_clue            = RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.ring_dirs())
##       build_clue_constraints  = add_eq(sum(cell_vars(neighbors(pos, ring_dirs()))), value)
##   · 方位序 `core/clue_engine.gd:22-31`：上/右上/右/右下/下/左下/左/左上
##   ⇒ spec 的 `refs` 按**同一顺序**给出，`expr` 用 `sum` 汇总同一批 ref，才可能逐位一致。
##
## 刻意**不**比的字段：标识类（`clue_rule`/`name` —— spec 规则 id 必然不同）与计时类
## （`seed_ms`/`last_call_stats` —— 删线索按墙钟判停，有已知波动，见 docs §18.1）。

const SPEC_ID := &"spec_classic_probe"
const SPEC_JSON := """
{
  "spec_version": 1,
  "id": "spec_classic_probe",
  "title": "规格复刻：经典（8 邻求和）",
  "clue": {
    "refs": [
      {"dx": 0, "dy": -1}, {"dx": 1, "dy": -1}, {"dx": 1, "dy": 0}, {"dx": 1, "dy": 1},
      {"dx": 0, "dy": 1}, {"dx": -1, "dy": 1}, {"dx": -1, "dy": 0}, {"dx": -1, "dy": -1}
    ],
    "expr": {"t": "sum", "xs": [
      {"t": "ref", "i": 0}, {"t": "ref", "i": 1}, {"t": "ref", "i": 2}, {"t": "ref", "i": 3},
      {"t": "ref", "i": 4}, {"t": "ref", "i": 5}, {"t": "ref", "i": 6}, {"t": "ref", "i": 7}
    ]},
    "max": 8,
    "empty_value": 0
  },
  "geometry": "rect_only"
}
"""

const SIZE := Vector2i(6, 6)
const MINES := 14
const SEED := 1
const TIMEOUT_MS := 90_000


func after_each() -> void:
	# 测试隔离：注册的 spec 规则必须注销，避免污染其它用例。
	# 用动态调用而非静态调用：RuleRegistry 的注销入口若改名，本测试不应因此**编译失败**。
	var reg: Object = RuleRegistry.default()
	if reg != null and reg.has_method("unregister") and reg.resolve(SPEC_ID) != null:
		reg.call("unregister", SPEC_ID)


func test_spec_reproduces_classic_level_field_by_field() -> void:
	var r: Dictionary = SpecRulePlugin.register_from_json(SPEC_JSON)
	assert_true(bool(r.get("ok", false)),
		"spec 注册应成功；errors=%s" % str(r.get("errors", [])))
	if not bool(r.get("ok", false)):
		return
	var spec_id: StringName = SPEC_ID if r.get("id", SPEC_ID) == null else StringName(str(r.get("id", SPEC_ID)))

	# 判据前置：先确认内置 classic 在该 seed 确有产出，否则整条等价断言没有意义
	var gen_ref := PuzzleGenerator.new()
	var ref_lv: Dictionary = gen_ref.generate_with_rules(
		&"classic", [], SIZE, MINES, SEED, 0, 1, null, TIMEOUT_MS)
	assert_false(ref_lv.is_empty(),
		"内置 classic 在 (%dx%d, %d 雷, seed %d) 必须有产出——否则本测试无法判定（先修语料/预算）"
			% [SIZE.x, SIZE.y, MINES, SEED])
	if ref_lv.is_empty():
		return

	var gen_spec := PuzzleGenerator.new()
	var spec_lv: Dictionary = gen_spec.generate_with_rules(
		spec_id, [], SIZE, MINES, SEED, 0, 1, null, TIMEOUT_MS)
	assert_false(spec_lv.is_empty(),
		"规格复刻规则必须产出同一关（空返回 ⇒ 适配器语义偏差；stats=%s）"
			% JSON.stringify(gen_spec.last_call_stats))
	if spec_lv.is_empty():
		return

	# 语义核心逐字段比较（顺序敏感：mines/revealed 由同一条管线产出，顺序也应一致）
	for k in ["total_mines", "mines", "revealed", "hidden_state", "difficulty_profile"]:
		if ref_lv.has(k) and spec_lv.has(k):
			assert_eq(JSON.stringify(spec_lv[k]), JSON.stringify(ref_lv[k]),
				"字段 %s 必须与内置 classic 逐字节一致（不一致 ⇒ 规格适配器引入了偏差）" % k)

	# 分档唯一依据（峰值）必须一致——这条独立再断言一次，因为档位是下游一切的门槛
	var pr: Dictionary = ref_lv.get("difficulty_profile", {})
	var ps: Dictionary = spec_lv.get("difficulty_profile", {})
	assert_eq(int(ps.get("max_complexity", -1)), int(pr.get("max_complexity", -1)),
		"峰值 max_complexity 必须一致（分档只看它）")


## 载入侧接线验收（取代 impl-spec 原先的 pending「加载/验收侧未接 compute_clue_topo」）。
##
## 判据设计：用一个**测试替身规则**，其 `compute_clue_topo` 返回一个"不可能是邻域计数"的常数
## （777）——于是"Board 载入后该格 value 是否 = 777"就能**决定性**区分两条实现：
##   · 走新契约（问规则）⇒ 777；
##   · 退回旧硬编码（数拓扑邻域雷数）⇒ 0..度(≤6) ⇒ 必红。
## 这样即使将来有人把载入侧改回硬编码，本测试也会立刻抓住（这正是"生成对、装载错"的组合缺陷）。
func test_board_load_side_uses_rule_topo_clue_values() -> void:
	## 测试替身：把所有格的拓扑线索值固定为 777（实现见文件末尾 inner class）
	var dummy := _ConstTopoClueRule.new()
	var dummy_id := StringName(dummy.get_rule_id())
	var reg: RuleRegistry = RuleRegistry.default()
	if reg.resolve(dummy_id) == null:
		assert_true(reg.register(dummy), "替身规则注册应成功")
	if reg.resolve(dummy_id) == null:
		return
	var topo: GridInterface = ShapeGenerator.to_adjacency_grid("hex", {"size": 5})
	assert_not_null(topo, "蜂窝盘构造失败")
	if topo == null:
		return
	var level := {
		"size": {"rows": topo.size().y, "cols": topo.size().x},
		"total_mines": 0,
		"mines": [],
		"revealed": [],
		"topology": _topo_to_level_dict(topo),
	}
	var b := Board.new()
	b.load_level(level)
	assert_true(b.grid is AdjacencyGrid,
		"带 topology 的关卡载入后应为邻接表网格（否则本测试没有触到异形盘路径）")
	if not (b.grid is AdjacencyGrid):
		return
	b.rule_clue_id = String(dummy_id)
	b._compute_clues()
	var checked := 0
	for pos in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(pos)
		if c == null or c.is_mine:
			continue
		assert_eq(int(c.value), 777,
			"格 (%d,%d)：拓扑盘载入侧必须走规则的 compute_clue_topo（收到 %s；若为 0..度 的小整数 ⇒ 退回了旧硬编码）"
				% [pos.x, pos.y, str(c.value)])
		checked += 1
	assert_gt(checked, 0, "至少应检查到 1 个非雷格（否则本测试没有判定力）")
	if reg.has_method("unregister"):
		reg.call("unregister", dummy_id)


## 【主代理】topo 形态 refs 的**跨序列化稳定性**：同一棋盘、邻接表项顺序整体反转（模拟
## "生成期内存序" vs "载入时按边表重建序"的差异），线索值必须**逐格不变**。
## 若实现直接绑定 `topo.get_neighbors()` 的插入序，本测试必红；这是"生成期验证过、载入后不可解"
## 那类静默缺陷的唯一防线。
func test_topo_refs_stable_under_adjacency_reorder() -> void:
	var spec_json := """
	{
	  "spec_version": 1,
	  "id": "spec_test_reorder",
	  "title": "稳定性探针：topo refs（加权，ref0 权重 5）",
	  "clue": {
	    "refs": "topo",
	    "expr": {"t": "wsum", "ws": [5, 1, 1, 1, 1, 1, 1, 1], "xs": [
	      {"t": "ref", "i": 0}, {"t": "ref", "i": 1}, {"t": "ref", "i": 2}, {"t": "ref", "i": 3},
	      {"t": "ref", "i": 4}, {"t": "ref", "i": 5}, {"t": "ref", "i": 6}, {"t": "ref", "i": 7}
	    ]},
	    "max": 20,
	    "empty_value": 0
	  },
	  "geometry": "adj_generic"
	}
	"""
	var r: Dictionary = SpecRulePlugin.from_json(spec_json)
	assert_true(bool(r.get("ok", false)), "topo refs 规格应合法：%s" % str(r.get("errors", [])))
	if not bool(r.get("ok", false)):
		return
	var rule: Object = r["rule"]
	var topo_a: GridInterface = ShapeGenerator.to_adjacency_grid("hex", {"size": 7})
	assert_not_null(topo_a, "蜂窝盘构造失败")
	if topo_a == null:
		return
	var topo_b: GridInterface = _topo_with_reversed_adjacency(topo_a)
	assert_not_null(topo_b, "邻接表顺序反转后的盘构造失败")
	if topo_b == null:
		return
	# 确定性雷集（取前 8 个位置；两盘格集相同）
	var ms := {}
	var n := 0
	for p in topo_a.all_positions():
		if n >= 8:
			break
		ms[p] = true
		n += 1
	var size := topo_a.size()
	var checked := 0
	var nonzero := 0
	for pos in topo_a.all_positions():
		var va: Variant = rule.call("compute_clue_topo", ms, pos, topo_a, size)
		var vb: Variant = rule.call("compute_clue_topo", ms, pos, topo_b, size)
		assert_eq(int(vb), int(va),
			"格 (%d,%d)：邻接表项顺序变化不得改变线索值（否则生成期与载入期 ref i 指向不同邻居 ⇒ 静默不可解）"
				% [pos.x, pos.y])
		if int(va) != 0:
			nonzero += 1
		checked += 1
	assert_gt(checked, 0, "应检查到格子（否则本测试没有判定力）")
	assert_gt(nonzero, 0, "应有非零线索值（全零则无法区分「稳定」与「恒错」）")


## 用 `AdjacencyGrid.setup_from_topo` 重建同一棋盘，但把 adjacency 项**整体反转**
## （模拟载入侧按不同边序重建内存邻接表）。
func _topo_with_reversed_adjacency(topo: GridInterface) -> GridInterface:
	var d := _topo_to_level_dict(topo)
	var adj: Array = d["adjacency"]
	adj.reverse()
	d["adjacency"] = adj
	var g := AdjacencyGrid.new()
	g.setup_from_topo(d)
	return g


## 拓扑 → 关卡 JSON 的 `topology` 字段（与 `core/puzzle_generator.gd` 的 `_topology_to_dict` 同形）。
## 这里**自己拼**而不调那个私有函数：测试要对"关卡格式"这一契约有独立表述，
## 避免与生产实现同源同错（这正是黄金网/独立 diff 的同一纪律）。
func _topo_to_level_dict(topo: GridInterface) -> Dictionary:
	var positions: Array = []
	for p in topo.all_positions():
		positions.append({"x": p.x, "y": p.y})
	var adjacency: Array = []
	var seen := {}
	for p in topo.all_positions():
		for nb in topo.get_neighbors(p):
			var key := "%d,%d|%d,%d" % [p.x, p.y, nb.x, nb.y]
			if seen.has(key):
				continue
			seen["%d,%d|%d,%d" % [nb.x, nb.y, p.x, p.y]] = true
			adjacency.append({"a": {"x": p.x, "y": p.y}, "b": {"x": nb.x, "y": nb.y}})
	return {"positions": positions, "adjacency": adjacency}


## 测试替身规则：拓扑线索值恒为 777（**不可能是**邻域计数，见上面那条测试的判据设计）。
class _ConstTopoClueRule:
	extends RulePlugin

	const CONST_VALUE := 777

	func get_rule_id() -> StringName:
		return &"test_const_topo_clue"

	func get_kind() -> String:
		return KIND_CLUE

	func supports_topology() -> bool:
		return true

	func compute_clue_topo(_mine_set: Dictionary, _pos: Vector2i, _topo: GridInterface,
			_grid_size: Vector2i) -> Variant:
		return CONST_VALUE


func test_spec_compute_clue_matches_classic_value_by_value() -> void:
	## 独立复核（不依赖适配器自己的单测）：线索值求值必须与 ClassicRule 逐值相同。
	var r: Dictionary = SpecRulePlugin.register_from_json(SPEC_JSON)
	if not bool(r.get("ok", false)):
		assert_true(false, "spec 注册失败，无法继续：%s" % str(r.get("errors", [])))
		return
	var reg: RuleRegistry = RuleRegistry.default()
	var spec_rule: Object = reg.resolve(SPEC_ID)
	var ref_rule: Object = reg.resolve(&"classic")
	assert_not_null(spec_rule, "spec 规则应已在注册表里")
	assert_not_null(ref_rule, "内置 classic 必须在册")
	if spec_rule == null or ref_rule == null:
		return
	# 构造一个确定的雷集（位置取盘内前 14 个格，确定性、与 rng 无关）
	var mine_set := {}
	var placed := 0
	for y in SIZE.y:
		for x in SIZE.x:
			if placed >= MINES:
				break
			mine_set[Vector2i(x, y)] = true
			placed += 1
	var checked := 0
	for y in SIZE.y:
		for x in SIZE.x:
			var pos := Vector2i(x, y)
			var a: Variant = ref_rule.call("compute_clue", mine_set, pos, SIZE)
			var b: Variant = spec_rule.call("compute_clue", mine_set, pos, SIZE)
			assert_eq(int(b), int(a), "格 (%d,%d) 的线索值必须与 classic 一致" % [x, y])
			checked += 1
	assert_eq(checked, SIZE.x * SIZE.y, "应覆盖全盘每格（越界邻域由 refs 的越界→0 语义处理）")
