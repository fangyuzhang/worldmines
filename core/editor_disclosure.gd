# editor_disclosure.gd —— 编辑器「简单 / 专家」渐进披露 + 变体配色锁定（纯数据规则；缺口 #16 第二、三块）
#
# 两块都是**纯数据规则**，不含任何 UI / 引擎调用：UI 侧只调用这里的函数拿结果去 set_visible()。
#
# ============ 一、渐进披露（visible_controls）============
# 目标：新手只看得到「一条能做完一关的最短路径」，高级功能藏在专家模式，规则集中在一张表里。
#
# 【单一事实来源】就是下面这张 TIER_OF 表：控件 id → 档位。要改可见性，只改这张表，
#   绝不在 UI 里散落 `if mode == ...` 判断（散落判断必然互相矛盾 —— 这正是本模块要治的病）。
#
# 【未知控件 id 的策略：默认按"简单模式可见"处理（fail-visible）】
#   理由（三选一的取舍，明确落定）：
#     ① 未知 = 我们的表对某个控件**过时**了，而不是那个控件"危险"。表中没有它时，
#        保守做法是**别把用户已有的功能藏起来**（藏错 = 静默的功能丢失，最难查）；
#        多显示一个 = 可恢复、可见、用户能自己忽略。
#     ② 本函数的输入 all_control_ids 由调用方（UI/Mod）给出：Mod 新注入的控件不该因为
#        没登记就消失；「要藏」必须是**显式**写在表里（专家档）的动作，绝不靠"默认藏"。
#     ③ 该默认天然满足下面的不变量：未知在两种模式都可见 ⇒ 简单集 ⊆ 专家集恒成立。
#   一句话：**显式才隐藏，未知即显示**。
#
# 【不变量：专家模式可见集 ⊇ 简单模式可见集】
#   实现上专家模式返回全部（去重后）控件、简单模式只在其中筛掉专家档，故恒成立；
#   check_superset() 把它写成断言，防止哪天有人改表/改筛选把两条规则改成互相矛盾。
class_name EditorDisclosure
extends RefCounted

## 配色口径只读复用既有模块（**不改它**）：本文件用它把色码/数组解析成真颜色。
const PaletteColorLib := preload("res://core/palette_color.gd")

const SIMPLE := "simple"
const EXPERT := "expert"
const MODES: Array[String] = [SIMPLE, EXPERT]

## ==== 唯一事实来源：控件 id → 档位 ====
## 键用**编辑器动作 id / 面板 id**（与 ui/level_editor.gd、core/editor_bindings.gd 的口径一致），
## 便于 UI 直接拿自己的 id 来查。未列出的 id 一律按 SIMPLE（见文件头未知策略）。
##
## 简单档：一关做完的必经路径 —— 画、擦、撤销、试玩、保存、看说明、平移视图、网格线。
## 专家档：高级页 / 调试 / 批量 / 分析类 —— 不是做一关的必需步骤。
const TIER_OF := {
	# —— 简单模式可见（新手四步：画 → 试玩 → 保存）——
	"pan_mode": SIMPLE,
	"grid_toggle": SIMPLE,
	"brush": SIMPLE,
	"eraser": SIMPLE,
	"fill": SIMPLE,
	"clear": SIMPLE,
	"size": SIMPLE,
	"undo": SIMPLE,
	"redo": SIMPLE,
	"playtest_toggle": SIMPLE,
	"save": SIMPLE,
	"help": SIMPLE,
	# —— 仅专家模式可见 ——
	"cheat_toggle": EXPERT,     # 编辑态显雷/线索：调试用
	"hotmap": EXPERT,           # 猜点热力图：分析用
	"rule_text": EXPERT,        # 直接看/改规则原文（高级页）
	"globals": EXPERT,          # 全局约束列表：高级
	"verify": EXPERT,           # 校验 / 推理链回放：高级
	"replay": EXPERT,
	"batch": EXPERT,            # 批量生成
	"shape_compose": EXPERT,    # 异形拼装
	"template": EXPERT,         # 模板库
}


## 给定模式与全部控件 id，返回**应可见**的 id（保持输入顺序、去重）。
## 未知模式一律回退到 SIMPLE（最保守：只显示最少的东西，绝不因模式拼错而暴露全部高级项）。
static func visible_controls(mode: String, all_control_ids: Array) -> Array:
	var m := mode.to_lower()
	if not MODES.has(m):
		m = SIMPLE
	var out: Array = []
	for raw in all_control_ids:
		var id := str(raw)
		if id == "" or out.has(id):
			continue
		# 专家模式 = 全可见；简单模式 = 只保留非专家档（未知默认 SIMPLE ⇒ 可见）。
		if m == EXPERT or str(TIER_OF.get(id, SIMPLE)) != EXPERT:
			out.append(id)
	return out


## 该控件是否"仅专家模式可见"（未知 id ⇒ false，与未知策略一致）。
static func is_expert_only(id: String) -> bool:
	return str(TIER_OF.get(id, SIMPLE)) == EXPERT


## 供 UI tooltip / 帮助文案用的一句话解释。
static func explain(id: String) -> String:
	if is_expert_only(id):
		return "高级功能：仅专家模式显示"
	return "基础功能：两种模式都显示"


## 不变量自检（断言，防规则互相矛盾）：简单集必须是专家集的子集。
## 返回 true；一旦被违反，assert 直接暴露（测试会调用它）。
static func check_superset(all_control_ids: Array) -> bool:
	var simple := visible_controls(SIMPLE, all_control_ids)
	var expert := visible_controls(EXPERT, all_control_ids)
	for c in simple:
		assert(expert.has(c), "披露规则自相矛盾：'%s' 简单模式可见，却在专家模式不可见" % str(c))
	return true


# ============ 二、变体配色锁定（lock_report）============
#
# 目标：多个变体不能共用同一个颜色，否则玩家分不清"这个色 = 哪条规则"。
# 颜色口径**只读** PaletteColor：接受 Color / 色码字符串（"RED" / "PINK_DARK" / Mod 自定义名）/
# RGB 数组（[r,g,b]），统一解析成真颜色后按精确值分组；同色组 ≥2 个**不同**变体即冲突。
# 未知色码走 PaletteColor 的稳定散列 —— 两个不同未知码若散列撞到同一色，**同样会被报为冲突**
#（这正是本功能的价值：把"看起来同色"提前抓出来）。
#
# 输入两种形式都收：
#   · Array： [{id, color}, ...]  或  [[id, color], ...]
#   · Dictionary： { id: color, ... }
# 返回 { ok, conflicts, reason }：
#   ok        : bool，True = 无冲突（颜色各自唯一）
#   conflicts : Array[{ color: "#RRGGBB", variants: [id...] }]，**指名哪几个变体、哪个颜色**
#   reason    : String，"" / 冲突摘要 / 被忽略条目说明
static func lock_report(variants_with_colors: Variant) -> Dictionary:
	var entries: Array = []
	if variants_with_colors is Array:
		entries = variants_with_colors
	elif variants_with_colors is Dictionary:
		for k in (variants_with_colors as Dictionary).keys():
			entries.append({"id": str(k), "color": (variants_with_colors as Dictionary)[k]})
	else:
		return {"ok": false, "conflicts": [], "reason": "输入不是数组或字典，无法判定配色冲突"}
	if entries.is_empty():
		return {"ok": true, "conflicts": [], "reason": "没有变体，无需锁定"}

	var by_color := {}   # "#rrggbb" -> Array[String]（变体 id，去重）
	var bad := 0
	for e in entries:
		var id := ""
		var col := PaletteColorLib.TRANSPARENT
		if e is Dictionary:
			id = str((e as Dictionary).get("id", ""))
			col = _to_color((e as Dictionary).get("color", null))
		elif e is Array and (e as Array).size() >= 2:
			id = str((e as Array)[0])
			col = _to_color((e as Array)[1])
		else:
			bad += 1
			continue
		# 无效条目（缺 id / 颜色解析失败）跳过并计数，绝不臆造颜色。
		if id == "" or col == PaletteColorLib.TRANSPARENT:
			bad += 1
			continue
		var hex := "#" + col.to_html(false)
		if not by_color.has(hex):
			by_color[hex] = []
		var ids: Array = by_color[hex]
		if not ids.has(id):
			ids.append(id)

	var conflicts: Array = []
	for hex in by_color.keys():
		var ids: Array = by_color[hex]
		if ids.size() >= 2:
			conflicts.append({"color": str(hex).to_upper(), "variants": ids})
	# 按颜色排序，保证输出确定性（不受字典遍历顺序影响）。
	conflicts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["color"]) < str(b["color"]))

	var reasons: Array[String] = []
	if not conflicts.is_empty():
		reasons.append("%d 种颜色被多个变体占用" % conflicts.size())
	if bad > 0:
		reasons.append("有 %d 个条目缺 id 或颜色无法解析（已忽略）" % bad)
	return {"ok": conflicts.is_empty(), "conflicts": conflicts, "reason": "；".join(reasons)}


# ---- 内部 ----

## 颜色口径：Color 直接用；字符串 / 数组交给 PaletteColor.parse（只读复用）；其余 → 透明（判为无效）。
static func _to_color(v: Variant) -> Color:
	if v is Color:
		return v
	if v is String or v is Array:
		return PaletteColorLib.parse(v)
	return PaletteColorLib.TRANSPARENT
