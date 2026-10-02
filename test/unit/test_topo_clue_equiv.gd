extends GutTest
## 【主代理验收】异形盘"线索值语义"**不变性**直证
##
## 背景（改动前后的语义边界）：
##   `core/puzzle_generator.gd:494-505` 今天在异形盘上**硬编码**线索值 = 拓扑邻域雷数
##   （`_count_topo_mines(mine_set, topo.get_neighbors(pos))`），**不调用** `clue_rule.compute_clue`。
##   本轮改动引入可选契约 `RulePlugin.compute_clue_topo(...)`（默认实现 = 数拓扑邻域雷数）
##   并让"声明了拓扑能力的规则"走它 ⇒ **必须证明默认实现与旧硬编码逐值同义**，
##   否则形状关（`res://levels/holed_*.json` / `hex_*.json` 那一族）的产出会漂。
##
## 判据：对同一棋盘、同一雷集、每个格，断言
##   `clue_rule.compute_clue_topo(mine_set, pos, topo, size)` == `_count_topo_mines(mine_set, topo.get_neighbors(pos))`
## 覆盖：classic（唯一被形状关使用的线索规则）+ 至少两个非 classic 规则（验证默认实现是**规则无关**的）。

const HEX_SIZE := 7
const MINES := 8


func _hex_topo() -> GridInterface:
	## 蜂窝盘（与 tools/gen_shape_levels.gd 的 SPECS 同族同参：kind="hex", size=7）
	var topo: GridInterface = ShapeGenerator.to_adjacency_grid("hex", {"size": HEX_SIZE})
	assert_not_null(topo, "蜂窝盘构造失败（ShapeGenerator 契约变化？）")
	return topo


func _mine_set(topo: GridInterface, k: int) -> Dictionary:
	## 确定性雷集：按 all_positions() 顺序取前 k 格（不依赖 rng，便于复现）
	var ms := {}
	var n := 0
	for p in topo.all_positions():
		if n >= k:
			break
		ms[p] = true
		n += 1
	return ms


func test_default_compute_clue_topo_equals_legacy_hardcoded_count() -> void:
	var topo: GridInterface = _hex_topo()
	if topo == null:
		return
	var mine_set := _mine_set(topo, MINES)
	var gen := PuzzleGenerator.new()   # 只用它的私有计数函数（旧硬编码口径）
	var reg := RuleRegistry.default()
	var checked_total := 0
	for rule_id in [&"classic", &"o4", &"o5x"]:
		var rule: Object = reg.resolve(rule_id)
		if rule == null:
			pending("规则 %s 不在加载集（本测试跳过该规则，不计入断言）" % rule_id)
			continue
		assert_true(rule.has_method("compute_clue_topo"),
			"规则 %s 必须继承 RulePlugin 的 compute_clue_topo 默认实现（否则形状关无法走统一口径）" % rule_id)
		if not rule.has_method("compute_clue_topo"):
			continue
		for pos in topo.all_positions():
			var legacy: int = int(gen.call("_count_topo_mines", mine_set, topo.get_neighbors(pos)))
			var via_rule: Variant = rule.call("compute_clue_topo", mine_set, pos, topo, Vector2i(HEX_SIZE, HEX_SIZE))
			assert_eq(int(via_rule), legacy,
				"规则 %s 在格 (%d,%d)：新契约默认实现必须等于旧硬编码拓扑计数" % [rule_id, pos.x, pos.y])
			checked_total += 1
	assert_gt(checked_total, 0, "至少要检查到 classic（否则本测试没有判定力）")


func test_topology_clue_values_stay_within_declared_bound() -> void:
	## 附带不变量：拓扑邻域计数不会超过 8（内置规则的 value_upper_bound 语义），
	## 且蜂窝盘（度 ≤6）上必然 ≤ 6 —— 这条能在"邻域语义被换掉"时立刻报警。
	var topo: GridInterface = _hex_topo()
	if topo == null:
		return
	var mine_set := _mine_set(topo, MINES)
	var reg := RuleRegistry.default()
	var rule: Object = reg.resolve(&"classic")
	if rule == null or not rule.has_method("compute_clue_topo"):
		pending("classic 或新契约缺席，跳过上界不变量")
		return
	var max_seen := 0
	for pos in topo.all_positions():
		var v := int(rule.call("compute_clue_topo", mine_set, pos, topo, Vector2i(HEX_SIZE, HEX_SIZE)))
		max_seen = maxi(max_seen, v)
		var deg: int = topo.get_neighbors(pos).size()
		assert_lte(v, deg, "格 (%d,%d) 的拓扑计数不得超过其度（%d）" % [pos.x, pos.y, deg])
	assert_lte(max_seen, 6, "蜂窝盘（度 ≤6）的邻域计数上界应为 6（实测最大 %d）" % max_seen)
