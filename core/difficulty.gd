# difficulty.gd —— 难度分档（P0-B）
# v4.0（2026-09-19）起：玩家档位改用「峰值深度」口径（见文件末 PEAK_WINDOWS / tier_of_peak）；
# 下述标量 difficulty 口径保留作「紧凑度画像」与回退路径，不再用于定档。
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
	"easy":   {"label": "普通", "min": 0.3, "max": 1.2},
	"normal": {"label": "困难", "min": 1.2, "max": 2.2},
	"hard":   {"label": "噩梦", "min": 2.2, "max": 1e9},
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
	var out: Array = []
	for lv in levels:
		var dp: Dictionary = lv.get("difficulty_profile", {})
		if Difficulty.tier_of_profile(dp) == tier:
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


## 深度窗口（v4.0，2026-09-19）：以「峰值 = 单步最大必要线索数」定档。
## 依据：52,988 关实测——窗口占比 44.1/22.8/21.7/11.1%，峰值随尺寸单调增长、与长度近似独立。
## 为什么不用标量 difficulty 定档：它与「步数」秩相关 0.923、与峰值仅 0.475（测长度而非深度）。
const PEAK_WINDOWS := {
	"intro":  {"label": "入门", "min": 0,  "max": 2},
	"easy":   {"label": "普通", "min": 3,  "max": 4},
	"normal": {"label": "困难", "min": 5,  "max": 8},
	"hard":   {"label": "噩梦", "min": 9,  "max": 20},
}
const PEAK_OVER := 21  ## >= 此值 = 「超纲」（机器级），不进任何档


## 峰值 → 档位；超纲/无画像返回 ""。
static func tier_of_peak(peak: int) -> String:
	if peak < 0 or peak >= PEAK_OVER:
		return ""
	for id in PEAK_WINDOWS:
		var w: Dictionary = PEAK_WINDOWS[id]
		if peak >= int(w["min"]) and peak <= int(w["max"]):
			return id
	return ""


## 读 difficulty_profile 定档（无 max_complexity → ""）。
static func tier_of_profile(dp: Dictionary) -> String:
	if dp.is_empty() or not dp.has("max_complexity"):
		return ""
	var mc: Variant = dp.get("max_complexity")
	if mc == null:
		return ""
	return tier_of_peak(int(mc))


## 窗口谓词（量产 / 自举平台的验收判据）：闭区间 [lo, hi]。
static func in_window(peak: int, lo: int, hi: int) -> bool:
	return peak >= lo and peak <= hi


## 档位 → 窗口 [min, max]（Vector2i）。
static func tier_range(tier: String) -> Vector2i:
	var w: Dictionary = PEAK_WINDOWS.get(tier, {})
	if w.is_empty():
		return Vector2i(-1, -1)
	return Vector2i(int(w["min"]), int(w["max"]))


## 档位显示文案（v4.0 深度口径）：标签 + 峰值窗口。**唯一的档位文案来源**——
## 选关页/主菜单/图鉴都从这里取，禁止再手写第三份档位表（防漂移）。
static func tier_text(tier: String) -> String:
	var w: Dictionary = PEAK_WINDOWS.get(tier, {})
	if w.is_empty():
		return str(TIERS.get(tier, {}).get("label", tier))
	return "%s（%d–%d 条线索）" % [str(w["label"]), int(w["min"]), int(w["max"])]
