# achievement_catalog.gd —— 内置成就目录（纯数据 + 纯判定，无 I/O，无 class_name）
#
# 为什么与 achievement_registry.gd 分开：
#   · 注册表是**机制**（注册 / 查重 / 判解锁 / 存盘），它不该知道「有哪些成就」；
#   · 目录是**内容**（60~80 条策划案），改文案、加条目不该碰机制代码；
#   · 判定写成纯函数 `evaluate(cond, ctx)`，于是「会不会误解锁」可以离线断言
#     （见 test/unit/test_achievement_catalog.gd：空上下文下**任何**成就都不得解锁）。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Catalog := preload("res://core/achievement_catalog.gd")。
#
# 判定 DSL（cond 字典，可任意嵌套）：
#   {"all": [cond, ...]}        全部成立
#   {"any": [cond, ...]}        任一成立
#   {"not": cond}               取反
#   {"flag": "won"}             上下文布尔为真（默认要 true）
#   {"metric": "cleared_count", "gte": 10}
#   {"axis": "o1", "gte": 1}        该轴通关数（cleared_axis）
#   {"series": "iso", "gte": 1}     该错觉系列通关数（illusion_series_cleared）
#   比较符：gte / gt / lte / lt / eq
#
# ⚠️ 只允许用 gte / gt 做「达成」判定：lte / eq 在**空上下文**下对 0 值天然成立，
#    会写出「新玩家一进游戏就跳成就」的假解锁。目录自检用例会挡住这种写法。
extends RefCounted


const GROUPS := [
	{"id": "start", "name": "起点", "desc": "第一次坐下来的那几件事"},
	{"id": "explore", "name": "探索", "desc": "通关数量与关卡类型"},
	{"id": "observe", "name": "观测轴", "desc": "O 轴：每格一个数字"},
	{"id": "structure", "name": "结构轴", "desc": "S 轴：棋盘级形状与拓扑"},
	{"id": "conserve", "name": "守恒轴", "desc": "Z 轴：棋盘级计数平衡"},
	{"id": "illusion", "name": "错觉收藏", "desc": "看见什么 ≠ 是什么"},
	{"id": "mastery", "name": "掌控", "desc": "星级、提示与速度"},
	{"id": "craft", "name": "工艺", "desc": "编辑器与创作闭环"},
]

const DEFINITIONS := [
	# ---------- 起点（4） ----------
	{"id": "first_win", "name": "初次破局", "group": "start", "desc": "赢下任意一关。",
		"cond": {"flag": "won"}},
	{"id": "first_star3", "name": "一丝不苟", "group": "start", "desc": "不用任何提示拿到三星。",
		"cond": {"all": [{"flag": "won"}, {"metric": "stars", "gte": 3}]}},
	{"id": "first_region", "name": "圈定范围", "group": "start", "desc": "第一次用「圈出可疑区域」并赢下这一关。",
		"cond": {"all": [{"flag": "won"}, {"metric": "hint_tier", "eq": 0}]}},
	{"id": "first_chain", "name": "照单全收", "group": "start", "desc": "第一次看完一整条推理链并赢下这一关。",
		"cond": {"all": [{"flag": "won"}, {"metric": "hint_tier", "gte": 2}]}},

	# ---------- 探索（12） ----------
	{"id": "clear_1", "name": "开张", "group": "explore", "desc": "通关 1 关。",
		"cond": {"metric": "cleared_count", "gte": 1}},
	{"id": "clear_3", "name": "入门", "group": "explore", "desc": "通关 3 关。",
		"cond": {"metric": "cleared_count", "gte": 3}},
	{"id": "clear_8", "name": "渐入佳境", "group": "explore", "desc": "通关 8 关。",
		"cond": {"metric": "cleared_count", "gte": 8}},
	{"id": "clear_15", "name": "熟手", "group": "explore", "desc": "通关 15 关。",
		"cond": {"metric": "cleared_count", "gte": 15}},
	{"id": "clear_30", "name": "常客", "group": "explore", "desc": "通关 30 关。",
		"cond": {"metric": "cleared_count", "gte": 30}},
	{"id": "clear_50", "name": "半百", "group": "explore", "desc": "通关 50 关。",
		"cond": {"metric": "cleared_count", "gte": 50}},
	{"id": "clear_80", "name": "八十关", "group": "explore", "desc": "通关 80 关。",
		"cond": {"metric": "cleared_count", "gte": 80}},
	{"id": "clear_120", "name": "百二十", "group": "explore", "desc": "通关 120 关。",
		"cond": {"metric": "cleared_count", "gte": 120}},
	{"id": "clear_manual", "name": "手工关第一步", "group": "explore", "desc": "通关 1 个官方手工编排关卡。",
		"cond": {"metric": "cleared_manual", "gte": 1}},
	{"id": "clear_lib_5", "name": "关卡库常客", "group": "explore", "desc": "通关 5 个关卡库关卡。",
		"cond": {"metric": "cleared_lib", "gte": 5}},
	{"id": "clear_gen_10", "name": "生成器之友", "group": "explore", "desc": "通关 10 个生成关卡。",
		"cond": {"metric": "cleared_gen", "gte": 10}},
	{"id": "runs_20", "name": "坐得住", "group": "explore", "desc": "累计开局 20 次（成功失败都算）。",
		"cond": {"metric": "runs_total", "gte": 20}},

	# ---------- 观测轴 O1~O10（12） ----------
	{"id": "obs_kind_1", "name": "第一个数字", "group": "observe", "desc": "通关 1 种观测轴算子。",
		"cond": {"metric": "obs_kinds", "gte": 1}},
	{"id": "obs_kind_3", "name": "读数习惯", "group": "observe", "desc": "通关 3 种观测轴算子。",
		"cond": {"metric": "obs_kinds", "gte": 3}},
	{"id": "obs_kind_5", "name": "观测员", "group": "observe", "desc": "通关 5 种观测轴算子。",
		"cond": {"metric": "obs_kinds", "gte": 5}},
	{"id": "obs_kind_7", "name": "读数专家", "group": "observe", "desc": "通关 7 种观测轴算子。",
		"cond": {"metric": "obs_kinds", "gte": 7}},
	{"id": "obs_kind_10", "name": "全部观测席", "group": "observe", "desc": "十种观测轴算子各通关至少 1 关。",
		"cond": {"metric": "obs_kinds", "gte": 10}},
	{"id": "obs_o1", "name": "邻域直觉", "group": "observe", "desc": "通关 O1。",
		"cond": {"axis": "o1", "gte": 1}},
	{"id": "obs_o3", "name": "差值之眼", "group": "observe", "desc": "通关 O3。",
		"cond": {"axis": "o3", "gte": 1}},
	{"id": "obs_o5x", "name": "双向读数", "group": "observe", "desc": "通关 O5X。",
		"cond": {"axis": "o5x", "gte": 1}},
	{"id": "obs_o7", "name": "成对推理", "group": "observe", "desc": "通关 O7。",
		"cond": {"axis": "o7", "gte": 1}},
	{"id": "obs_o10", "name": "环游读数", "group": "observe", "desc": "通关 O10。",
		"cond": {"axis": "o10", "gte": 1}},
	{"id": "obs_clear_20", "name": "读数二百", "group": "observe", "desc": "观测轴关卡累计通关 20 关。",
		"cond": {"metric": "obs_cleared", "gte": 20}},
	{"id": "obs_no_hint", "name": "只靠读数", "group": "observe", "desc": "观测轴关卡拿到一次三星。",
		"cond": {"all": [{"flag": "won"}, {"metric": "stars", "gte": 3}, {"metric": "axes_hit_obs", "gte": 1}]}},

	# ---------- 结构轴 S1~S7（9） ----------
	{"id": "struct_kind_1", "name": "形状入门", "group": "structure", "desc": "通关 1 种结构轴算子。",
		"cond": {"metric": "struct_kinds", "gte": 1}},
	{"id": "struct_kind_3", "name": "看轮廓", "group": "structure", "desc": "通关 3 种结构轴算子。",
		"cond": {"metric": "struct_kinds", "gte": 3}},
	{"id": "struct_kind_5", "name": "结构师", "group": "structure", "desc": "通关 5 种结构轴算子。",
		"cond": {"metric": "struct_kinds", "gte": 5}},
	{"id": "struct_kind_7", "name": "全部结构席", "group": "structure", "desc": "七种结构轴算子各通关至少 1 关。",
		"cond": {"metric": "struct_kinds", "gte": 7}},
	{"id": "struct_s1", "name": "局部禁形", "group": "structure", "desc": "通关 S1。",
		"cond": {"axis": "s1", "gte": 1}},
	{"id": "struct_s4", "name": "走到第四席", "group": "structure", "desc": "通关 S4。",
		"cond": {"axis": "s4", "gte": 1}},
	{"id": "struct_s7", "name": "第七席", "group": "structure", "desc": "通关 S7。",
		"cond": {"axis": "s7", "gte": 1}},
	{"id": "struct_clear_15", "name": "结构标本室", "group": "structure", "desc": "结构轴关卡累计通关 15 关。",
		"cond": {"metric": "struct_cleared", "gte": 15}},
	{"id": "struct_no_hint", "name": "形状自己会说话", "group": "structure", "desc": "结构轴关卡拿到一次三星。",
		"cond": {"all": [{"flag": "won"}, {"metric": "stars", "gte": 3}, {"metric": "axes_hit_struct", "gte": 1}]}},

	# ---------- 守恒轴 Z1~Z5（7） ----------
	{"id": "cons_kind_1", "name": "数一数", "group": "conserve", "desc": "通关 1 种守恒轴算子。",
		"cond": {"metric": "cons_kinds", "gte": 1}},
	{"id": "cons_kind_2", "name": "两个天平", "group": "conserve", "desc": "通关 2 种守恒轴算子。",
		"cond": {"metric": "cons_kinds", "gte": 2}},
	{"id": "cons_kind_3", "name": "平衡感", "group": "conserve", "desc": "通关 3 种守恒轴算子。",
		"cond": {"metric": "cons_kinds", "gte": 3}},
	{"id": "cons_kind_5", "name": "全部守恒席", "group": "conserve", "desc": "五种守恒轴算子各通关至少 1 关。",
		"cond": {"metric": "cons_kinds", "gte": 5}},
	{"id": "cons_z1", "name": "镜像计数", "group": "conserve", "desc": "通关 Z1。",
		"cond": {"axis": "z1", "gte": 1}},
	{"id": "cons_z3", "name": "四象平衡", "group": "conserve", "desc": "通关 Z3。",
		"cond": {"axis": "z3", "gte": 1}},
	{"id": "cons_z5", "name": "最后一座天平", "group": "conserve", "desc": "通关 Z5。",
		"cond": {"axis": "z5", "gte": 1}},

	# ---------- 错觉收藏（12） ----------
	{"id": "illu_1", "name": "看错了没关系", "group": "illusion", "desc": "通关 1 个错觉策展关卡。",
		"cond": {"metric": "illusion_cleared", "gte": 1}},
	{"id": "illu_3", "name": "眼睛会骗人", "group": "illusion", "desc": "通关 3 个错觉策展关卡。",
		"cond": {"metric": "illusion_cleared", "gte": 3}},
	{"id": "illu_6", "name": "收藏家", "group": "illusion", "desc": "通关 6 个错觉策展关卡。",
		"cond": {"metric": "illusion_cleared", "gte": 6}},
	{"id": "illu_12", "name": "错觉鉴赏", "group": "illusion", "desc": "通关 12 个错觉策展关卡。",
		"cond": {"metric": "illusion_cleared", "gte": 12}},
	{"id": "illu_20", "name": "眼见为虚", "group": "illusion", "desc": "通关 20 个错觉策展关卡。",
		"cond": {"metric": "illusion_cleared", "gte": 20}},
	{"id": "illu_kind_1", "name": "换一种看错", "group": "illusion", "desc": "在 1 个错觉系列里通关。",
		"cond": {"metric": "illusion_series_kinds", "gte": 1}},
	{"id": "illu_kind_3", "name": "三种错觉", "group": "illusion", "desc": "在 3 个错觉系列里通关。",
		"cond": {"metric": "illusion_series_kinds", "gte": 3}},
	{"id": "illu_kind_all", "name": "看见什么 ≠ 是什么", "group": "illusion", "desc": "在全部错觉系列里各通关至少 1 关。",
		"cond": {"metric": "illusion_series_kinds", "gte": 6}},
	{"id": "illu_iso", "name": "立方体是假的", "group": "illusion", "desc": "通关 1 个错觉立方体。",
		"cond": {"series": "iso", "gte": 1}},
	{"id": "illu_iso_all", "name": "五个立方体", "group": "illusion", "desc": "通关全部 5 个错觉立方体。",
		"cond": {"series": "iso", "gte": 5}},
	{"id": "illu_fold", "name": "把棋盘折起来", "group": "illusion", "desc": "通关 1 个折叠盘面。",
		"cond": {"series": "fold", "gte": 1}},
	{"id": "illu_wormhole", "name": "穿过虫洞", "group": "illusion", "desc": "通关 1 个虫洞关卡。",
		"cond": {"series": "wormhole", "gte": 1}},

	# ---------- 掌控（12） ----------
	{"id": "perfect_1", "name": "第一次满分", "group": "mastery", "desc": "达成 1 次三星通关。",
		"cond": {"metric": "cleared_no_hint", "gte": 1}},
	{"id": "perfect_10", "name": "十个满分", "group": "mastery", "desc": "10 关达成三星。",
		"cond": {"metric": "cleared_no_hint", "gte": 10}},
	{"id": "perfect_25", "name": "二十五个满分", "group": "mastery", "desc": "25 关达成三星。",
		"cond": {"metric": "cleared_no_hint", "gte": 25}},
	{"id": "perfect_50", "name": "五十个满分", "group": "mastery", "desc": "50 关达成三星。",
		"cond": {"metric": "cleared_no_hint", "gte": 50}},
	{"id": "avg_star_25", "name": "稳定发挥", "group": "mastery", "desc": "通关 5 关以上且平均星级 ≥ 2.5。",
		"cond": {"all": [{"metric": "cleared_count", "gte": 5}, {"metric": "avg_stars_x10", "gte": 25}]}},
	{"id": "avg_star_29", "name": "几乎满分", "group": "mastery", "desc": "通关 10 关以上且平均星级 ≥ 2.9。",
		"cond": {"all": [{"metric": "cleared_count", "gte": 10}, {"metric": "avg_stars_x10", "gte": 29}]}},
	{"id": "speed_60", "name": "一分钟", "group": "mastery", "desc": "在 60 秒内通关任意一关。",
		"cond": {"all": [{"flag": "won"}, {"metric": "elapsed", "lte": 60.0}, {"metric": "cleared_count", "gte": 1}]}},
	{"id": "speed_30", "name": "半分钟", "group": "mastery", "desc": "在 30 秒内通关任意一关。",
		"cond": {"all": [{"flag": "won"}, {"metric": "elapsed", "lte": 30.0}, {"metric": "cleared_count", "gte": 1}]}},
	{"id": "speed_15", "name": "十五秒", "group": "mastery", "desc": "在 15 秒内通关任意一关。",
		"cond": {"all": [{"flag": "won"}, {"metric": "elapsed", "lte": 15.0}, {"metric": "cleared_count", "gte": 1}]}},
	{"id": "speed_30_no_hint", "name": "又快又稳", "group": "mastery", "desc": "不用提示，且 45 秒内三星通关。",
		"cond": {"all": [{"flag": "won"}, {"metric": "stars", "gte": 3}, {"metric": "elapsed", "lte": 45.0}]}},
	{"id": "retry_3", "name": "再来一次", "group": "mastery", "desc": "同一关失败多次后仍然拿下它（该关累计尝试 ≥ 3 次）。",
		"cond": {"all": [{"flag": "won"}, {"metric": "level_plays", "gte": 3}]}},
	{"id": "deep_diver", "name": "深潜", "group": "mastery", "desc": "通关 25 关，其中至少 10 关是三星。",
		"cond": {"all": [{"metric": "cleared_count", "gte": 25}, {"metric": "cleared_no_hint", "gte": 10}]}},

	# ---------- 工艺（10） ----------
	{"id": "teach_1", "name": "看过一页", "group": "craft", "desc": "读完 1 页教学。",
		"cond": {"metric": "tutorials_seen", "gte": 1}},
	{"id": "teach_5", "name": "按章学习", "group": "craft", "desc": "读完 5 页教学。",
		"cond": {"metric": "tutorials_seen", "gte": 5}},
	{"id": "teach_15", "name": "通读", "group": "craft", "desc": "读完 15 页教学。",
		"cond": {"metric": "tutorials_seen", "gte": 15}},
	{"id": "teach_30", "name": "教学全勤", "group": "craft", "desc": "读完 30 页教学。",
		"cond": {"metric": "tutorials_seen", "gte": 30}},
	{"id": "mod_1", "name": "装上一个 Mod", "group": "craft", "desc": "本地安装 1 个 Mod。",
		"cond": {"metric": "craft_mods", "gte": 1}},
	{"id": "mod_3", "name": "收藏夹", "group": "craft", "desc": "本地安装 3 个 Mod。",
		"cond": {"metric": "craft_mods", "gte": 3}},
	{"id": "pub_1", "name": "第一次发布", "group": "craft", "desc": "在创作中心登记 1 个作品版本。",
		"cond": {"metric": "craft_published", "gte": 1}},
	{"id": "pub_3", "name": "更新狂", "group": "craft", "desc": "累计登记 3 个作品版本。",
		"cond": {"metric": "craft_published", "gte": 3}},
	{"id": "fb_1", "name": "第一位测试者", "group": "craft", "desc": "导入 1 条玩家反馈。",
		"cond": {"metric": "craft_feedback", "gte": 1}},
	{"id": "fb_5", "name": "听得进意见", "group": "craft", "desc": "累计导入 5 条玩家反馈。",
		"cond": {"metric": "craft_feedback", "gte": 5}},
]


## 全部成就（副本；调用方不得改到本表）。
static func all() -> Array:
	var out: Array = []
	for d in DEFINITIONS:
		out.append((d as Dictionary).duplicate(true))
	return out


static func count() -> int:
	return DEFINITIONS.size()


static func groups() -> Array:
	var out: Array = []
	for g in GROUPS:
		out.append((g as Dictionary).duplicate(true))
	return out


static func group_name(id: String) -> String:
	for g in GROUPS:
		if str((g as Dictionary)["id"]) == id:
			return str((g as Dictionary)["name"])
	return id


static func by_id(id: String) -> Dictionary:
	for d in DEFINITIONS:
		if str((d as Dictionary)["id"]) == id:
			return (d as Dictionary).duplicate(true)
	return {}


## 全部条件里用到的 metric / axis / series 名字（自检与文档用）。
static func used_metrics() -> Array[String]:
	var out: Array[String] = []
	_collect_metrics(DEFINITIONS, out)
	out.sort()
	return out


static func _collect_metrics(node: Variant, out: Array[String]) -> void:
	if node is Array:
		for x in node:
			_collect_metrics(x, out)
		return
	if not (node is Dictionary):
		return
	var d: Dictionary = node
	if d.has("metric"):
		var m := str(d["metric"])
		if not out.has(m):
			out.append(m)
	if d.has("axis"):
		out.append("axis:" + str(d["axis"]))
	if d.has("series"):
		out.append("series:" + str(d["series"]))
	# 必须带上 "cond"：DEFINITIONS 每个条目的条件都挂在 cond 键下，
	# 少了它整份目录一条 metric 都收不到（used_metrics() 会**静默返回空**）。
	for k in ["all", "any", "not", "cond"]:
		if d.has(k):
			_collect_metrics(d[k], out)


## 纯判定：cond 成立返回 true。ctx 见文件头。
static func evaluate(cond: Variant, ctx: Dictionary) -> bool:
	if cond == null:
		return false
	if cond is Array:
		return evaluate({"all": cond}, ctx)
	if not (cond is Dictionary):
		return false
	var c: Dictionary = cond
	if c.has("all"):
		for sub in (c["all"] as Array):
			if not evaluate(sub, ctx):
				return false
		return true
	if c.has("any"):
		for sub in (c["any"] as Array):
			if evaluate(sub, ctx):
				return true
		return false
	if c.has("not"):
		return not evaluate(c["not"], ctx)
	if c.has("flag"):
		var want := bool(c.get("is", true))
		return bool(ctx.get(str(c["flag"]), false)) == want
	var val := _value_of(c, ctx)
	if c.has("gte"):
		return val >= float(c["gte"])
	if c.has("gt"):
		return val > float(c["gt"])
	if c.has("lte"):
		return val <= float(c["lte"])
	if c.has("lt"):
		return val < float(c["lt"])
	if c.has("eq"):
		return is_equal_approx(val, float(c["eq"]))
	return false


## 取值：axis / series 是「查表」键，其余从 ctx 平取。
static func _value_of(c: Dictionary, ctx: Dictionary) -> float:
	if c.has("axis"):
		var table: Dictionary = ctx.get("cleared_axis", {})
		return float(table.get(str(c["axis"]), 0))
	if c.has("series"):
		var tbl: Dictionary = ctx.get("illusion_series_cleared", {})
		return float(tbl.get(str(c["series"]), 0))
	return float(ctx.get(str(c.get("metric", "")), 0))
