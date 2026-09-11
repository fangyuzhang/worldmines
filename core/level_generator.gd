# level_generator.gd —— 生成门面（组合方案 A/B/C/D）
# 唯一生成入口：矩形与异形统一委托规则平台（PuzzleGenerator.generate_with_rules）。
# 异形棋盘（邻接表）现在也拿到 CP-SAT 序贯可解保证（A2）。
# 说明：异形线索语义 = 拓扑邻域计数（等价 classic），方向型变体（4n/sc/clock）不适用。
class_name LevelGenerator
extends RefCounted


func generate(recipe: SeedRecipe) -> Dictionary:
	if recipe == null:
		return {}
	if recipe.topology_kind == "rect":
		return _generate_rect(recipe)
	return _generate_adjacency(recipe)


## 矩形：委托规则平台（dogfood 底座，大盘走 CP-SAT 不受 MAX_COMBOS 限制）。
func _generate_rect(recipe: SeedRecipe) -> Dictionary:
	var cols := int(recipe.topology_params.get("cols", 5))
	var rows := int(recipe.topology_params.get("rows", 5))
	var gen := PuzzleGenerator.new()
	return gen.generate_with_rules(
		recipe.clue_rule_id,
		recipe.global_rule_ids,
		Vector2i(cols, rows),
		recipe.mine_count,
		recipe.seed,
		recipe.mask_count
	)


## 异形/邻接表：构建拓扑 → 委托规则平台（A2，CP-SAT 序贯可解 + 洞格约束）。
func _generate_adjacency(recipe: SeedRecipe) -> Dictionary:
	var topo := AdjacencyGrid.new()
	topo.setup_from_topo(recipe.topology_params)
	if topo.all_positions().is_empty():
		return {}
	# P0-A：坐标归一化到非负（拓扑可用任意坐标含负值；CP-SAT cell 索引从 0 起）。
	topo = AdjacencyGrid.normalized(topo)
	# size = 坐标范围（max_c+1, max_r+1）。洞格（包围盒内不在拓扑的格子）
	# 由 RuleOracle.build_spec 固定为非雷，CP-SAT 据此排除洞格。
	var size := _coord_range(topo)
	var gen := PuzzleGenerator.new()
	return gen.generate_with_rules(
		recipe.clue_rule_id,
		recipe.global_rule_ids,
		size,
		recipe.mine_count,
		recipe.seed,
		recipe.mask_count,
		50,
		topo
	)


## 坐标范围（max+1），供 CP-SAT 的 (r,c) 二维索引使用。
static func _coord_range(topo: GridInterface) -> Vector2i:
	var max_c := 0
	var max_r := 0
	for p in topo.all_positions():
		max_c = maxi(max_c, p.x)
		max_r = maxi(max_r, p.y)
	return Vector2i(max_c + 1, max_r + 1)
