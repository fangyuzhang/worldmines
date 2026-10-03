# difficulty.gd —— 难度分档（P0-B）
# v4.0（2026-09-19）起：玩家档位改用「峰值深度」口径（见文件末 PEAK_WINDOWS / tier_of_peak）；
# 下述标量 difficulty 口径保留作「紧凑度画像」与回退路径，不再用于定档。
# 难度度量 = 序贯演绎的紧凑度 difficulty（Σ(1/批量)，见 puzzle_generator.difficulty_from_stats）。
# 分档基于实际 difficulty 区间（精确），而非生成时的 target（target 是删线索的粗粒度下限，
# 二分删块会让 difficulty 跳跃，target 无法精确命中）。
# 对标「14 种扫雷变体 2」的三档（无标记 / ! / !!），但我们的档位用区间筛选、且对 Mod 规则透明。
class_name Difficulty
extends RefCounted


## 标量 difficulty 区间（左闭右开）——**旧口径画像，v4.1 起不再是玩家档位**。
## 玩家档位 = PEAK_WINDOWS（三档，v4.1 起对齐 14MV2）；本表保留完整四档区间
## （intro 未删）作「紧凑度画像」与旧标量回退路径（batch_all_variants 无窗口参数时的
## 旧模式、hint 预算回退）。因此 PEAK_WINDOWS 是 TIERS 的**子集**，
## 单一事实源测试按子集断言（不再是"同增同减"）。
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
## 依据：52,988 关实测——峰值随尺寸单调增长、与长度近似独立。
## 为什么不用标量 difficulty 定档：它与「步数」秩相关 0.923、与峰值仅 0.475（测长度而非深度）。
##
## v4.1（2026-09-20）改**三档**，对齐《14 Minesweeper Variants 2》难度常量矩阵
## （逆向逐字：普通 MIN2/MAX{5-6×6:2, 7-8×8:3}｜困难 MIN4/MAX{5-7×7:4, 8×8:5}｜
## 噩梦 MIN{5/6×6:5, 7/8×8:6}/MAX20）。改版动机（用户决策）：四档分类过多，
## 且原「入门」档（peak≤2 一步一见）太简单、不值得单独成档。
## 全局窗口 = 对方矩阵的覆盖区间（去重叠）：普通 [2,3] / 困难 [4,5] / 噩梦 [6,20]；
## 上限 20 与对方一致（PEAK_OVER=21 超纲过滤）。
##
## 已知偏差（有意为之，勿当 bug「修复」）：
##   · peak=5 在对方的 5/6×6 判噩梦（MIN=5）、7/8×8 判困难（MAX_HARD=5）；全局窗口
##     归困难——贴大盘判定，也是我们 8×8/9×9 的峰值中位区。尺寸对难度的影响由独立的
##     尺寸轴（5×5→9×9 序列）表达，不重复进窗口。
##   · **peak ≤1 的盘不进任何档**（对方普通档 MIN=2 同语义：纯一眼盘被淘汰、不供给）。
const PEAK_WINDOWS := {
	"easy":   {"label": "普通", "min": 2, "max": 3},
	"normal": {"label": "困难", "min": 4, "max": 5},
	"hard":   {"label": "噩梦", "min": 6, "max": 20},
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


## v4.1 严格难度梯度谓词：该画像是否落在梯度内（即落在某一档窗口内）。
## peak<=1（一眼盘，v4.1 淘汰）与 peak>=21（机器级超纲）都不算在梯度内。
## 生成门禁 / 入库闸门 / 库展示 三层共用这一判据，避免各自为政出现「假梯度」。
static func gradient_ok(dp: Dictionary) -> bool:
	return tier_of_profile(dp) != ""


## 档位显示文案（v4.0 深度口径）：标签 + 峰值窗口。**唯一的档位文案来源**——
## 选关页/主菜单/图鉴都从这里取，禁止再手写第三份档位表（防漂移）。
static func tier_text(tier: String) -> String:
	var w: Dictionary = PEAK_WINDOWS.get(tier, {})
	if w.is_empty():
		return str(TIERS.get(tier, {}).get("label", tier))
	return "%s（%d–%d 条线索）" % [str(w["label"]), int(w["min"]), int(w["max"])]


## 档位短标签（「普通 / 困难 / 噩梦」）。摘要行（如异形页卡片 tooltip 的难度分布）用——
## tier_text 带窗口后缀太长，塞不进一行；两者**同源**（都从 PEAK_WINDOWS 的 label 取），
## 不构成第二份档位表。
static func tier_short(tier: String) -> String:
	var w: Dictionary = PEAK_WINDOWS.get(tier, {})
	return str(w.get("label", tier)) if not w.is_empty() else str(tier)


# ==================== 1~5 星评分（W5，2026-10-03） ====================
#
# 【为什么是"推理步骤"而不是"雷数/密度"】雷多 ≠ 难：5×5 摆 10 颗雷若一步推完，玩家体验是简单；
# 而"每步只能挤出一格、要十几轮"的盘才折磨人。故星级只吃**推理步骤数**
#（= 序贯演绎的轮数/步数，如 `EditorVerify` stats["rounds"]、生成期 stats 的等价量）。
# 旧三档口径（TIERS / PEAK_WINDOWS / tier_of*）一律不动——星级是**叠加**在其上的更细粒度评分，
# 旧字段照旧，调用方要用星级时读新增的 `stars` / 调 `stars_of_steps`。

## 各星阈值（左闭）：steps≥2→2星，≥4→3星，≥7→4星，≥11→5星；steps≤1→1星。
## 阈值按实测密度取整，改这里等于改全仓星级口径（请同步 test_difficulty_stars.gd）。
const STAR_STEPS: Array[int] = [2, 4, 7, 11]


## 推理步骤数 → 1~5 星。单调不减、恒被夹在 [1,5]（steps 为负也返回 1，绝不给 0 星）。
static func stars_of_steps(steps: int) -> int:
	var s := 1
	for b in STAR_STEPS:
		if steps >= b:
			s += 1
	return clampi(s, 1, 5)


## 三档 → 星级**起点**（桥接老调用方：手上只有 tier/peak、没有 steps 时也能给出星级）。
## easy→2 / normal→3 / hard→4；未知档返回 0（= 不给星，而非假装 1 星）。
## 注意：这是回退桥接，**不是**第二事实源——难度真值仍以 PEAK_WINDOWS 为准。
const TIER_BASE_STARS := {"easy": 2, "normal": 3, "hard": 4}


static func stars_of_tier(tier: String) -> int:
	return int(TIER_BASE_STARS.get(tier, 0))


## 星级显示文案（实心/空心星）。0 星（未知）返回全空心。
static func stars_text(stars: int) -> String:
	var n := clampi(stars, 0, 5)
	return "★".repeat(n) + "☆".repeat(5 - n)


## 读画像取星级：优先 profile["inference_steps"]（有则按步骤数）；否则按三档桥接；
## 都没有返回 0（未知）。**不改动传入的 dp**。
static func stars_of_profile(dp: Dictionary) -> int:
	if dp.is_empty():
		return 0
	if dp.has("inference_steps"):
		return stars_of_steps(int(dp.get("inference_steps", 0)))
	return stars_of_tier(tier_of_profile(dp))


## 给画像补一个 `stars` 字段（返回副本，旧字段原样保留）：`inference_steps` 有则按其算，
## 否则回退三档桥接。这是"旧字段不动、新增星级字段"的落地入口。
static func with_stars(dp: Dictionary, inference_steps: int = -1) -> Dictionary:
	var out := dp.duplicate(true)
	var steps := inference_steps
	if steps < 0 and dp.has("inference_steps"):
		steps = int(dp["inference_steps"])
	out["stars"] = stars_of_steps(steps) if steps >= 0 else stars_of_profile(dp)
	return out
