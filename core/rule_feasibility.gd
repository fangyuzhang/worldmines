# rule_feasibility.gd —— 变体×尺寸可行性查询（唯一真值入口，v2.9.3）
#
# 真值来源：RuleCpSat.is_feasible（CP-SAT 对「全部规则约束 + 精确雷数」判可满足性）。
# **不维护任何手写 UNSAT 规则表**——内置与 Mod 变体自动获得正确结论。
#
# 覆盖三处调用：
#   ① UI 选尺寸前查询（历史 bug：rl 6×6 / qd 6×6/8×8 数学无解却漏进 UI 选择器，
#      玩家选中后生成器永远返回空、界面转圈；手写规则表漏一处就重现——改真值查询治本）；
#   ② 批量生成预筛（batch_all_variants）；③ Mod 变体自检（tools/mod_selfcheck.gd）。
#
# dt（骨牌）特殊：其约束依赖随机骨牌划分，单次采样不可靠——多次采样取 OR
# （实测 mx_dt 5×5 划分可行率 ~72%，5 次采样 OR 后误判率 <1%）。
# 无 C# 后端 / 未知规则：乐观放行（true）——不可行组合会走生成失败路径，
# 由生成器的雷数硬校验与序贯验证兜底，不会产出坏关。
class_name RuleFeasibility
extends RefCounted

const DT_RESAMPLE := 5

## 异形盘雷数口径（v4.x）：异形棋盘没有 CANDIDATES 的明确档位，按密度基准取整。
## 为什么是 0.40：与生成侧形状关设计密度（DENSITY_CAP=0.35）同量级且略高，留出 ±2 的试探余量。
const TOPO_DENSITY := 0.40
const TOPO_TOLERANCE := 2

static var _cache: Dictionary = {}

## ==== 候选雷数列表（v3.0，GDD 终版 §8.1）====
## 守恒算子的整除/奇偶要求常与 R07 标准雷数互斥（如「相邻行锁」6×6 需奇数雷、
## 「四象」需 4 的倍数、「等差行」需行数的倍数）——标准值首选、其余按序回退。
## 5×5 全兼容；6×6 候选依据：Z2 需奇（13/15）、Z3 需 4 倍数（12/16）、Z5 需 3 倍数（12/15/18）；
## 7×7 需 7 的倍数（14/21）；8×8 需 4 的倍数/偶（24/28）；9×9 需 9 的倍数（27/36）。
const CANDIDATES := {
	5: [10],
	6: [14, 12, 15, 16, 18, 13],
	7: [20, 14, 21],
	8: [26, 24, 28],
	9: [32, 27, 36],
}

## 标准雷数（候选列表首项）。
static func standard_mines(size: int) -> int:
	var list: Array = CANDIDATES.get(size, [])
	return int(list[0]) if not list.is_empty() else -1


## 解析该组合×尺寸的可用雷数：按候选列表顺序取第一个可行值。
## 返回 {mines: int（-1 = 全候选不可行）, standard: bool（是否标准值）}。
## 旧行为（仅标准值）等价于 standard==true 分支；批量/UI/门禁按此统一入口接线。
static func resolve_mines(clue_id: String, global_ids: Array, size: int) -> Dictionary:
	var list: Array = CANDIDATES.get(size, [])
	for i in list.size():
		var m := int(list[i])
		if query(clue_id, global_ids, size, m):
			return {"mines": m, "standard": i == 0}
	return {"mines": -1, "standard": false}


## 异形盘雷数解析（v4.x）。雷数口径必须可解释，故写进 reason：
##   按存活格数 cells 取 round(cells * 0.40) 为基准，再在 [m-2, m+2] 内逐值试（基准优先、± 交替）。
## 返回 {"mines": int(-1 = 不可行), "standard": bool, "reason": String}。
static func resolve_mines_topo(clue_id: String, global_ids: Array, topo: GridInterface) -> Dictionary:
	if topo == null:
		return {"mines": -1, "standard": false, "reason": "topology 为空：异形盘雷数口径不适用"}
	var cells: int = topo.cell_count()
	if cells <= 1:
		return {"mines": -1, "standard": false, "reason": "棋盘格数 %d 过小，无可用雷数" % cells}
	var base: int = int(round(float(cells) * TOPO_DENSITY))
	var tried: Array = []
	for d in [0, -1, 1, -TOPO_TOLERANCE, TOPO_TOLERANCE]:
		var m: int = base + int(d)
		if m < 1 or m > cells - 1:
			continue
		tried.append(m)
		if query_topo(clue_id, global_ids, topo, m):
			return {"mines": m, "standard": int(d) == 0,
				"reason": "异形盘雷数口径：round(存活格 %d × %.2f) = %d 为基准，[%d,%d] 内逐值试，命中 %d（已试 %s）" % [
					cells, TOPO_DENSITY, base, base - TOPO_TOLERANCE, base + TOPO_TOLERANCE, m, str(tried)]}
	return {"mines": -1, "standard": false,
		"reason": "异形盘雷数口径：round(存活格 %d × %.2f) = %d 为基准，[%d,%d] 内（%s）均不可行" % [
			cells, TOPO_DENSITY, base, base - TOPO_TOLERANCE, base + TOPO_TOLERANCE, str(tried)]}


## 查询 (clue_id, global_ids, size, mines) 是否数学可行（带缓存）。size 为正方形边长。
static func query(clue_id: String, global_ids: Array, size: int, mines: int) -> bool:
	return _query(clue_id, global_ids, Vector2i(size, size), mines, null)


## 异形棋盘的可行性查询（v4.x）：topo 的包围盒即 CP-SAT 索引范围，邻域由邻接表定义。
## 内部与生成期共用同一口径（RuleOracle 传 topology + build_spec），保证不变量
## 「生成期判可行 ⇒ 判据不许说不可行」。
## topo == null 时退化为无拓扑的矩形求值（与旧 query 共享同一条 _evaluate 路径，行为等价）。
static func query_topo(clue_id: String, global_ids: Array, topo: GridInterface, mines: int) -> bool:
	var size := Vector2i.ZERO
	if topo != null:
		size = topo.size()
	return _query(clue_id, global_ids, size, mines, topo)


static func _query(clue_id: String, global_ids: Array, size: Vector2i, mines: int, topo: GridInterface) -> bool:
	var gids: Array = []
	for g in global_ids:
		gids.append(str(g))
	# 缓存键必须含棋盘指纹：结论依赖棋盘几何（洞格/邻接），旧键只有尺寸 ⇒ 不同棋盘会串结论。
	var key := "%s|%s|%s|%d" % [clue_id, ",".join(gids), _board_segment(topo, size), mines]
	if _cache.has(key):
		return bool(_cache[key])
	var result := _evaluate(clue_id, gids, size, mines, topo)
	_cache[key] = result
	return result


## 清空缓存（测试隔离 / Mod 热加载换实现后调用）。
static func clear_cache() -> void:
	_cache.clear()


## 棋盘指纹：格数 + 邻接边的稳定哈希。
## 为什么必须进缓存键：query 的结论依赖棋盘几何（洞格/邻接），旧键 "%s|%s|%d|%d" 只有尺寸
## ⇒ 同一变体在不同棋盘上复用同一个（可能错误的）结论 —— 本函数修复的正是这条。
## null（矩形盘无拓扑对象）返回 "rect:null"；矩形盘的尺寸段由 _board_segment 另拼 "rect:WxH"。
static func board_key(topo: GridInterface) -> String:
	if topo == null:
		return "rect:null"
	if topo is RectGrid:
		var s := topo.size()
		return "rect:%dx%d" % [s.x, s.y]
	# 异形：格数 + 邻接表稳定哈希。排序后再 join，跨运行稳定（不依赖字典遍历序）。
	var lines: Array[String] = []
	for p in topo.all_positions():
		var nbs: Array[String] = []
		for n in topo.get_neighbors(p):
			nbs.append("%d,%d" % [n.x, n.y])
		nbs.sort()
		lines.append("%d,%d>%s" % [p.x, p.y, ",".join(nbs)])
	lines.sort()
	return "topo:%d:%d" % [topo.cell_count(), _stable_hash(",".join(lines))]


## 缓存键的棋盘段：拓扑优先；矩形（topo == null）用尺寸拼稳定串 "rect:WxH"。
static func _board_segment(topo: GridInterface, size: Vector2i) -> String:
	if topo != null:
		# 【2026-10-01 复审加固】显式并入 size：`_evaluate` 会用 size 做 dt 骨牌平铺
		#（`dt_rule.place_mines(rng, size.x, size.y, mines)`），而 `board_key` 只覆盖「cells + 邻接」
		# ⇒ 若「同 cells 但声明 size 不同」的两个盘共存，缓存键会相同而结论可能不同（静默串结论）。
		# 今天 `AdjacencyGrid.size()` 是由 cells 反推的包围盒 ⇒ 该情形不可达；此处只是把这条
		# 推理负担从"每个读代码的人"移到键里（成本 = 键变长几个字符）。
		return "%s:%dx%d" % [board_key(topo), size.x, size.y]
	return "rect:%dx%d" % [size.x, size.y]


## FNV-1a 64 位（自实现，不依赖引擎 hash() 的跨版本稳定性）。
## 【2026-10-01 复审加固】原为 32 位截断（`&= 0xFFFFFFFF`）：本函数的产物进**正确性缓存键**
##（`_query` 的 key），碰撞 = 把 A 盘的结论误用于 B 盘（静默误判，正是本函数注释里说要修的那类）。
## 32 位在"每会话几十个盘"下实际不可达，但升到 64 位成本近乎为零。
## 末位掩码到 0x7FFF…：GDScript int 是 64 位**有符号**，掩码后恒为正，键串不会带负号。
static func _stable_hash(s: String) -> int:
	var h: int = 1469598103934665603
	for i in s.length():
		h = (h ^ s.unicode_at(i)) * 1099511628211
		h &= 0x7FFFFFFFFFFFFFFF
	return h


static func _evaluate(clue_id: String, gids: Array, size: Vector2i, mines: int, topo: GridInterface) -> bool:
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(StringName(clue_id))
	if clue_rule == null:
		return true  # 未知规则交给生成/加载侧报错，不在此拦
	var gs: Array = []
	var has_dt := false
	for gid in gids:
		var g: Object = reg.resolve(StringName(str(gid)))
		if g == null or g.get_kind() != RulePlugin.KIND_GLOBAL:
			continue
		gs.append(g)
		if g.get_rule_id() == &"dt":
			has_dt = true
	if gs.is_empty():
		return true  # 无全局约束：常规布雷总可行（生成侧已 clamp 雷数）
	if not RuleCpSat.available():
		return true  # 无 C# 后端乐观放行（失败走生成失败路径，不产坏关）
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5EED  # 固定：查询结果可复现（与生成无关，仅用于 dt 骨牌重采样）
	var tries: int = DT_RESAMPLE if has_dt else 1
	# 共享单例防污染（v3.1）：dt 的 place_mines 会覆写 DtRule._dominoes 单例状态——
	# evaluate 结束后必须恢复原值，否则重采样残留的划分会在下一次构建 dt 约束时
	#（hint / 生成）用错误前提演绎（违反 R02）。
	var dt_rule: Object = null
	var saved_dominoes: Array = []
	if has_dt:
		for g in gs:
			if g.get_rule_id() == &"dt":
				dt_rule = g
				saved_dominoes = g.get_dominoes()
	for _i in tries:
		if has_dt and dt_rule != null:
			# dt 骨牌划分沿用生成期口径（按包围盒行列平铺，与 _place_mines_rules_raw 一致）。
			dt_rule.place_mines(rng, size.x, size.y, mines)
		var oracle := RuleOracle.new(clue_rule, gs, size, mines, topo)
		if RuleCpSat.is_feasible(oracle.build_spec({}, [], {})):
			if dt_rule != null:
				dt_rule.set_dominoes(saved_dominoes)
			return true
	if dt_rule != null:
		dt_rule.set_dominoes(saved_dominoes)
	return false
