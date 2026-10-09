# illusion_series.gd —— 官方策展：异形 / 错觉关卡系列目录（纯数据，无 I/O，无 class_name）
#
# 为什么独立成一个 core 模块：三处需要同一份「系列归属」事实——
#   ① 选关页异形弹窗（系列导览卡 + 一句话看点）；
#   ② 成就系统（错觉收藏组的进度与解锁）；
#   ③ 掌握度雷达（错觉关算不算「观测/结构/守恒」之外的第四类）。
# 三处各写一份前缀表必然漂移，表现是「同一关在这个界面属于错觉系列、在那个界面不算」——
# 玩家看不出来，只有截图偶然发现。所以前缀与文案只此一份。
#
# ⚠️ 刻意不写 class_name：headless 下新全局类不在 .godot 缓存里会报 Identifier not found
#（坑表 #26）。调用方写 const Series := preload("res://core/illusion_series.gd")。
#
# 归属判定按**文件名前缀**（不看内容）：levels/ 下的文件名就是策展编号（iso_01.json …），
# 前缀是稳定契约；而内容里的 topology/style 字段是渲染层口径，两者不该互相依赖。
extends RefCounted


const LEVELS_DIR := "res://levels"

## 系列表。字段：
##   id        稳定标识（成就/存档用它，改名会丢进度）
##   name      界面显示名
##   hook      一句话看点（卡片副标题）
##   prefixes  文件名前缀（多个时按最长优先匹配）
##   illusion  是否属于「看见什么 ≠ 是什么」错觉策展（成就与导览据此分组）
##   text      系列导览正文（玩家点「这是什么」时读的一段话）
##
## 顺序即选关页的展示顺序：先错觉、后造型，先老牌（iso）后新增（ani）。
const SERIES := [
	{
		"id": "iso", "name": "错觉立方体", "illusion": true,
		"prefixes": ["iso_"],
		"hook": "看着是立体的，其实是一张平面",
		"text": "等轴视角的菱面拼在一起，眼睛会自动把它们读成一个个立方体。\n"
			+ "但引擎里只有一张平面网格：每格没有高度、没有遮挡，只有相邻关系。\n"
			+ "「看见什么 ≠ 是什么」——先数清格子，再把眼睛关掉。",
	},
	{
		"id": "ani", "name": "动态错觉", "illusion": true,
		"prefixes": ["ani_"],
		"hook": "静止的图案，看着却在动",
		"text": "高对比的重复纹理在余光里会自己抖动——这是错觉，不是动画。\n"
			+ "唯一会真的动的是你的光标与推理：盯着看会累，按规则推不会。",
	},
	{
		"id": "holed", "name": "穿孔棋盘", "illusion": true,
		"prefixes": ["holed_"],
		"hook": "中间的空洞是缺口，不是背景",
		"text": "挖掉的格子不属于棋盘：不在格子上的数字不成立，绕不过去的路就是没有路。\n"
			+ "空洞边界是最容易被忽略的线索来源。",
	},
	{
		"id": "ring", "name": "环形回路", "illusion": true,
		"prefixes": ["ring_"],
		"hook": "走到尽头，会接回起点",
		"text": "左右两条边其实是同一条边，上下也是。\n"
			+ "一条线索的作用范围因此可以「绕一圈」回来——这是拓扑，不是视觉。",
	},
	{
		"id": "fold", "name": "折叠盘面", "illusion": true,
		"prefixes": ["fold_"],
		"hook": "折痕两侧，其实是同一张纸上贴着的两格",
		"text": "折痕把盘面粘起来：穿过折痕的一步，平面距离是零。\n"
			+ "先用眼睛找折痕，再用脑子把它们当成不存在的边界。",
	},
	{
		"id": "wormhole", "name": "虫洞", "illusion": true,
		"prefixes": ["wormhole_"],
		"hook": "不相邻的两格，可能共享同一条线索",
		"text": "虫洞把棋盘的远处拉近：它不改变格子的位置，只改变「谁和谁相邻」。\n"
			+ "看到线穿过棋盘时，先问一句「这条线是从哪个洞出来的」。",
	},
	{
		"id": "hex", "name": "蜂窝棱面", "illusion": false,
		"prefixes": ["hex_"],
		"hook": "六边形棋盘：每格有六个邻居",
		"text": "邻居数从 8 变成 6，所有「边角最少邻居」的直觉都要重算一遍。\n"
			+ "六格围一圈的环，是最常见的结构线索。",
	},
	{
		"id": "tri", "name": "三角镶嵌", "illusion": false,
		"prefixes": ["tri_", "t31212_"],
		"hook": "三角形只朝三个方向延伸",
		"text": "三角格里「一条线」的含义随朝向变化，方向被压缩成三类。\n"
			+ "三个方向的分界处，往往藏着只能靠计数才能发现的结论。",
	},
	{
		"id": "girih", "name": "吉里赫花纹", "illusion": false,
		"prefixes": ["girih_"],
		"hook": "花纹是对称的，线索也常常对称",
		"text": "纹样的周期对称意味着线索分布有规律：先找对称轴，再找被对称放大的结论。",
	},
	{
		"id": "sty", "name": "造型变体", "illusion": false,
		"prefixes": ["sty_var_"],
		"hook": "同一个规则，换一副骨架",
		"text": "规则没变，只是棋盘的形状被重新描了一遍。\n"
			+ "这是检验「你到底会不会这个规则」最快的方式：换皮之后你还认得出它吗。",
	},
	{
		"id": "art", "name": "图形关卡", "illusion": false,
		"prefixes": ["art_"],
		"hook": "把盘面摆成一个能认出来的形状",
		"text": "盘面形状本身就是提示：规则还在，只是它先向你打了个招呼。",
	},
]


## 全部系列（含非错觉）。返回的是**副本**，调用方不得改到本表。
static func all() -> Array:
	var out: Array = []
	for s in SERIES:
		out.append((s as Dictionary).duplicate(true))
	return out


static func ids() -> Array[String]:
	var out: Array[String] = []
	for s in SERIES:
		out.append(str((s as Dictionary)["id"]))
	return out


static func by_id(id: String) -> Dictionary:
	for s in SERIES:
		if str((s as Dictionary)["id"]) == id:
			return (s as Dictionary).duplicate(true)
	return {}


## 只有错觉策展里的系列。
static func illusion_series() -> Array:
	var out: Array = []
	for s in SERIES:
		if bool((s as Dictionary).get("illusion", false)):
			out.append((s as Dictionary).duplicate(true))
	return out


## 文件名 / 路径 → 系列 id；不属于任何系列返回 ""。
## 前缀按长度降序匹配：`t31212_01` 与 `tri_01` 都归 tri，但若将来加入 `tri_long_` 这类更长前缀，
## 短的不会先把长的吃掉。
static func series_of(path: String) -> String:
	var base := path.get_file().get_basename()
	if base == "":
		base = path
	var best := ""
	var best_len := -1
	for s in SERIES:
		for p in (s as Dictionary)["prefixes"]:
			var pre := str(p)
			if base.begins_with(pre) and pre.length() > best_len:
				best_len = pre.length()
				best = str((s as Dictionary)["id"])
	return best


## 该关卡是否属于「看见什么 ≠ 是什么」错觉策展。
static func is_illusion(path: String) -> bool:
	var sid := series_of(path)
	if sid == "":
		return false
	return bool(by_id(sid).get("illusion", false))


## 属于错觉策展的系列 id 列表（成就统计用）。
static func illusion_ids() -> Array[String]:
	var out: Array[String] = []
	for s in illusion_series():
		out.append(str((s as Dictionary)["id"]))
	return out


## 人话：关卡路径 → 「系列名 · 一句话看点」；不属于任何系列返回 ""。
static func label_for(path: String) -> String:
	var sid := series_of(path)
	if sid == "":
		return ""
	var s := by_id(sid)
	return str(s.get("name", "")) + " · " + str(s.get("hook", ""))


## 导览正文（玩家点「这是什么」时展示）；无归属返回 ""。
static func text_for(path: String) -> String:
	var sid := series_of(path)
	if sid == "":
		return ""
	return str(by_id(sid).get("text", ""))
