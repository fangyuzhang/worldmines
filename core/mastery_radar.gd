# mastery_radar.gd —— 掌握度雷达：三轴通关画像（纯计算，无 I/O，无 class_name）
#
# 用户口径（2026-10-09）：「按观测 / 结构 / 守恒三轴统计通关数，画出你是什么类型的解谜者」。
#
# 统计口径（刻意选择的规则，写死在这里而不是散在 UI 里）：
#   · **一关可以同时计入多个轴** —— 混合档（o1_s3）本来就是「同时用两种能力」，
#     强行归到某一轴会让画像失真；
#   · 只统计 **cleared=true** 的关卡（跳过 / 只开局不算）；
#   · 轴归属由 core/level_tags.gd 从进度键的 mode 段解析 —— 与成就系统同一份事实源；
#   · 「其它」（classic / combo / 4c / dt 等无官方轴席位的关卡）单独计数，不塞进任何一轴，
#     否则三轴的相对高低会被一批无关关卡抹平。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Radar := preload("res://core/mastery_radar.gd")。
extends RefCounted


const Tags := preload("res://core/level_tags.gd")

## 三轴的展示元数据（顺序 = 雷达图顶点顺序，从正上方顺时针：观测 → 结构 → 守恒）。
const AXES := [
	{"id": "observe", "name": "观测", "hint": "读数与线索：把数字读成结论"},
	{"id": "structure", "name": "结构", "hint": "形状与拓扑：先看棋盘长什么样"},
	{"id": "conserve", "name": "守恒", "hint": "计数与平衡：总量对不上就是线索"},
]

## 各型画像。key = 主导轴 id（"balanced" / "none" 另算）。
const PERSONAS := {
	"observe": {
		"title": "观测型解谜者",
		"blurb": "你更相信格子上的数字。别人先看形状，你先读读数——\n"
			+ "所以你在纯线索关卡里往往比平均快，但遇到「形状本身就是线索」的盘面时要记得抬头。",
	},
	"structure": {
		"title": "结构型解谜者",
		"blurb": "你先看轮廓。棋盘哪里被挖空、哪里折起来、哪两条边其实是同一条边——\n"
			+ "这些在你眼里比数字更响亮。补一补读数关，你的成功率会再上一截。",
	},
	"conserve": {
		"title": "守恒型解谜者",
		"blurb": "你习惯先数总量。别人在局部纠结时，你已经用「一共有几颗雷」把范围砍掉了大半。\n"
			+ "遇到没有全局计数的关卡时，试着把这个习惯换成「先假设、再看矛盾」。",
	},
	"balanced": {
		"title": "均衡型解谜者",
		"blurb": "三条轴上的通关数很接近——你不挑盘面，什么来打什么。\n"
			+ "想再进一步的话，挑你现在最弱的那一轴做专项，收益比继续平均铺开更大。",
	},
	"none": {
		"title": "还没定型的解谜者",
		"blurb": "盘面样本还不够，这张图现在只是一条线。\n"
			+ "先去打几关（任意轴都行），这里会长出你自己的形状。",
	},
}


static func axis_ids() -> Array[String]:
	var out: Array[String] = []
	for a in AXES:
		out.append(str((a as Dictionary)["id"]))
	return out


static func axis_name(id: String) -> String:
	for a in AXES:
		if str((a as Dictionary)["id"]) == id:
			return str((a as Dictionary)["name"])
	return id


## 进度表（ProgressStore 的 levels 字典）→ 三轴通关数。
## 返回 {"observe": n, "structure": n, "conserve": n, "other": n, "total": n, "capped": n}
##   capped = 只统计 cleared 的条数（用于自检：total 应等于 cleared 数）。
static func counts_from_levels(levels: Dictionary) -> Dictionary:
	var c := {"observe": 0, "structure": 0, "conserve": 0, "other": 0, "total": 0, "capped": 0}
	for k in levels:
		var rec = levels[k]
		if not (rec is Dictionary):
			continue
		if not bool((rec as Dictionary).get("cleared", false)):
			continue
		c["total"] = int(c["total"]) + 1
		c["capped"] = int(c["capped"]) + 1
		var ax := Tags.axes_of(str(k))
		var hit := false
		for a in ax:
			var kind := ""
			if a.begins_with("o"):
				kind = "observe"
			elif a.begins_with("s"):
				kind = "structure"
			else:
				kind = "conserve"
			if c.has(kind):
				c[kind] = int(c[kind]) + 1
				hit = true
		if not hit:
			c["other"] = int(c["other"]) + 1
	return c


## 归一化比例（相对三轴最大值；全 0 时返回全 0，避免除零）。
## 返回与 axis_ids() 同序的 float 数组，元素 ∈ [0, 1]。
static func ratios(counts: Dictionary) -> Array:
	var vals: Array = []
	for id in axis_ids():
		vals.append(float(counts.get(id, 0)))
	var mx := 0.0
	for v in vals:
		mx = maxf(mx, float(v))
	var out: Array = []
	for v in vals:
		out.append(0.0 if mx <= 0.0 else float(v) / mx)
	return out


## 主导轴 / 画像判定。
## · 样本不足（三轴合计 < 3）→ "none"
## · 最大与最小之差 ≤ 1 且合计 ≥ 6 → "balanced"
## · 否则取最大值那一轴（并列时按 AXES 顺序，观测优先）
static func dominant(counts: Dictionary) -> String:
	var vals: Array = []
	var total := 0
	for id in axis_ids():
		var v := int(counts.get(id, 0))
		vals.append(v)
		total += v
	if total < 3:
		return "none"
	var mx := 0
	var mn := 1 << 30
	for v in vals:
		mx = maxi(mx, int(v))
		mn = mini(mn, int(v))
	if total >= 6 and mx - mn <= 1:
		return "balanced"
	for i in vals.size():
		if int(vals[i]) == mx:
			return str(axis_ids()[i])
	return "balanced"


## 画像文案（标题 + 一段话）。
static func persona(counts: Dictionary) -> Dictionary:
	var key := dominant(counts)
	var p: Dictionary = (PERSONAS.get(key, PERSONAS["none"]) as Dictionary).duplicate(true)
	p["key"] = key
	var mx := 0
	for id in axis_ids():
		mx = maxi(mx, int(counts.get(id, 0)))
	p["max_axis_count"] = mx
	return p


## 雷达多边形顶点（纯数学，便于离线断言）：center + 半径 × ratio × 单位方向。
## 顶点从正上方开始顺时针，与 AXES 同序。
static func polygon_points(ratios_in: Array, center: Vector2, radius: float, start_angle := -PI / 2.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(ratios_in.size(), 1)
	for i in ratios_in.size():
		var r := clampf(float(ratios_in[i]), 0.0, 1.0)
		var ang := start_angle + TAU * float(i) / float(n)
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius * r)
	return pts


## 网格环顶点（第 k 环，k ∈ (0, 1]）：画三圈参考三角形用。
static func ring_points(center: Vector2, radius: float, k: float, sides := 3, start_angle := -PI / 2.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in sides:
		var ang := start_angle + TAU * float(i) / float(sides)
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius * clampf(k, 0.0, 1.0))
	return pts
