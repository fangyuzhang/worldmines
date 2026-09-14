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


## 查询 (clue_id, global_ids, size, mines) 是否数学可行（带缓存）。
static func query(clue_id: String, global_ids: Array, size: int, mines: int) -> bool:
	var gids: Array = []
	for g in global_ids:
		gids.append(str(g))
	var key := "%s|%s|%d|%d" % [clue_id, ",".join(gids), size, mines]
	if _cache.has(key):
		return bool(_cache[key])
	var result := _evaluate(clue_id, gids, size, mines)
	_cache[key] = result
	return result


## 清空缓存（测试隔离 / Mod 热加载换实现后调用）。
static func clear_cache() -> void:
	_cache.clear()


static func _evaluate(clue_id: String, gids: Array, size: int, mines: int) -> bool:
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
	for _i in tries:
		if has_dt:
			for g in gs:
				if g.get_rule_id() == &"dt":
					g.place_mines(rng, size, size, mines)
		var oracle := RuleOracle.new(clue_rule, gs, Vector2i(size, size), mines, null)
		if RuleCpSat.is_feasible(oracle.build_spec({}, [], {})):
			return true
	return false
