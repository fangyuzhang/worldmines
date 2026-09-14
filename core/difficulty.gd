# difficulty.gd —— 难度分档（P0-B）
# 难度度量 = 序贯演绎的紧凑度 difficulty（Σ(1/批量)，见 puzzle_generator.difficulty_from_stats）。
# 分档基于实际 difficulty 区间（精确），而非生成时的 target（target 是删线索的粗粒度下限，
# 二分删块会让 difficulty 跳跃，target 无法精确命中）。
# 对标「14 种扫雷变体 2」的三档（无标记 / ! / !!），但我们的档位用区间筛选、且对 Mod 规则透明。
class_name Difficulty
extends RefCounted


## 四档定义：difficulty 区间（左闭右开）。
## v3.0（2026-09-14，难度体系 v2）：新增「入门」档——< 0.3 的简单内容不再丢弃，
## 归入门档承接（O5 类信息型简单算子、教学/低难度内容；此类盘此前会作为 tier_empty 白产丢弃）。
## 实测校准（classic，40% 密度）：
##   不删线索 ≈ 0.04｜5×5 各 seed 0.59~1.86｜8×8 删 3s ≈ 2.01｜删 11s ≈ 3.19｜删 18s ≈ 3.95
const TIERS := {
	"intro":  {"label": "入门", "min": 0.0, "max": 0.3},
	"easy":   {"label": "轻松", "min": 0.3, "max": 1.2},
	"normal": {"label": "普通", "min": 1.2, "max": 2.2},
	"hard":   {"label": "挑战", "min": 2.2, "max": 1e9},
}


## 给定难度分，返回档位 id（"intro"/"easy"/"normal"/"hard"；超出全部区间返回 ""——四档下仅负值/异常会返回空）。
static func tier_of(difficulty: float) -> String:
	for id in TIERS:
		var t: Dictionary = TIERS[id]
		if difficulty >= float(t["min"]) and difficulty < float(t["max"]):
			return id
	return ""


## 按难度档筛选关卡（P0-B：运行时零生成，读 difficulty_profile）。
## levels: Array[Dictionary]（已生成关卡，含 difficulty_profile）。
## 返回该档位的关卡（保持原顺序）。
static func filter_by_tier(levels: Array, tier: String) -> Array:
	var t: Dictionary = TIERS.get(tier, {})
	if t.is_empty():
		return levels.duplicate()
	var lo := float(t["min"])
	var hi := float(t["max"])
	var out: Array = []
	for lv in levels:
		var dp: Dictionary = lv.get("difficulty_profile", {})
		var d := float(dp.get("difficulty", 0.0))
		if d >= lo and d < hi:
			out.append(lv)
	return out


## 生成定向（P0-A 的封装）：按档位取 target_difficulty 生成。
## 多 seed 尝试：某盘面天生难度天花板低（5×5 各 seed 天花板 0.59~1.86），
## 单 seed 可能达不到 target——故最多试 10 个 seed，达标即返回，否则返回最难的。
## 注意：target 是「删线索的下限」，二分删块会让实际 difficulty 跳跃 ≥ target。
static func generate_tiered(gen: Object, clue_rule_id: String, globals: Array, size: Vector2i,
		mine_count: int, seed: int, tier: String, timeout_ms: int = 15_000) -> Dictionary:
	var target := float(TIERS.get(tier, {}).get("min", 0.0))
	var best := {}
	var best_diff := -1.0
	for i in 10:
		var lv: Dictionary = gen.generate_with_rules(clue_rule_id, globals, size, mine_count, seed + i, 0, 50, null, timeout_ms, target)
		if lv.is_empty():
			continue
		var dp: Dictionary = lv.get("difficulty_profile", {})
		var d := float(dp.get("difficulty", 0.0))
		if d >= target:
			return lv
		if d > best_diff:
			best = lv
			best_diff = d
	return best
