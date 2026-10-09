# tutorial_catalog.gd —— 教学树：按算子轴分章（纯数据 + 纯判定，无 I/O，无 class_name）
#
# 用户口径（2026-10-09）：「已有 8 个手工教学关，扩成按算子轴分章的教学树」。
# 实测 res://levels/tutorial 下有 42 页（含 o1~o10 / s1~s7 / z1~z5 全轴席位 + 复合与特殊），
# 所以「扩」在这里的具体含义是：**给它们加一层章 / 顺序 / 软解锁**，而不是再造 42 页内容。
#
# 设计取舍：
#   · 章的成员由**实际存在的文件**推导（Tutorial.pages_for），不写死页数 —— 新增一页自动进树；
#   · 解锁是**软门**：进入下一章只要求上一章看过 ≥1 页，不要求全读完
#     （硬门槛会把人挡在门外，而教学的价值是「随时能看」）；
#   · 本章没有文件时整章不出现（不显示空章）。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Tree := preload("res://core/tutorial_catalog.gd")。
extends RefCounted


const TutorialData := preload("res://core/tutorial.gd")

## 章定义。combos = 该章包含的规则组合（Tutorial.pages_for 的前缀键）。
## 顺序即解锁顺序；名称里的「第N章」刻意写在 name 里，避免 UI 再拼一次。
const CHAPTERS := [
	{"id": "basics", "name": "第 1 章 · 先会玩", "desc": "左键翻格、右键插旗、数字怎么读。",
		"combos": ["basics"]},
	{"id": "classic", "name": "第 2 章 · 经典扫雷", "desc": "没有变体的原始规则：内外边界与死局。",
		"combos": ["classic"]},
	{"id": "observe", "name": "第 3 章 · 观测轴 O1~O10", "desc": "每格一个数字的十种读法。",
		"combos": ["o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10"]},
	{"id": "structure", "name": "第 4 章 · 结构轴 S1~S7", "desc": "棋盘级的形状与拓扑约束。",
		"combos": ["s1", "s2", "s3", "s4", "s5", "s6", "s7"]},
	{"id": "conserve", "name": "第 5 章 · 守恒轴 Z1~Z5", "desc": "棋盘级的计数平衡约束。",
		"combos": ["z1", "z2", "z3", "z4", "z5"]},
	{"id": "advanced", "name": "第 6 章 · 复合与特殊", "desc": "混合档与历史特殊算子：一个盘面同时用两种能力。",
		"combos": ["combo", "4c", "4n", "clock", "distsum", "dt", "ep", "fr", "hv",
			"knight", "loopruns", "mx", "pf", "qd", "rl", "sc"]},
]


static func chapter_ids() -> Array[String]:
	var out: Array[String] = []
	for c in CHAPTERS:
		out.append(str((c as Dictionary)["id"]))
	return out


## 章 → 页 id 列表（只含**实际存在**的页）。
static func pages_of_chapter(chapter_id: String) -> Array[String]:
	var out: Array[String] = []
	for c in CHAPTERS:
		if str((c as Dictionary)["id"]) != chapter_id:
			continue
		for combo in (c["combos"] as Array):
			for id in TutorialData.pages_for(str(combo)):
				if not out.has(id):
					out.append(id)
		break
	return out


## 全部章（空洞章已剔除）。每项 = {id, name, desc, pages: Array[String], index: int}。
static func chapters() -> Array:
	var out: Array = []
	var idx := 0
	for c in CHAPTERS:
		var pages := pages_of_chapter(str((c as Dictionary)["id"]))
		if pages.is_empty():
			continue
		idx += 1
		out.append({
			"id": str((c as Dictionary)["id"]),
			"name": str((c as Dictionary)["name"]),
			"desc": str((c as Dictionary)["desc"]),
			"pages": pages,
			"index": idx,
		})
	return out


## 全树的页顺序（章内按 pages_of_chapter 的顺序）。
static func flatten() -> Array[String]:
	var out: Array[String] = []
	for c in chapters():
		for id in (c["pages"] as Array):
			out.append(str(id))
	return out


## 页 → 章 id；不在树里返回 ""。
static func chapter_of(page_id: String) -> String:
	for c in CHAPTERS:
		if pages_of_chapter(str((c as Dictionary)["id"])).has(page_id):
			return str((c as Dictionary)["id"])
	return ""


## 章是否已解锁：首章永远解锁；其余要求**上一章**至少看过 1 页（软门）。
static func is_chapter_unlocked(chapter_id: String, seen: Dictionary) -> bool:
	var list := chapters()
	for i in list.size():
		var c: Dictionary = list[i]
		if str(c["id"]) != chapter_id:
			continue
		if i == 0:
			return true
		var prev: Dictionary = list[i - 1]
		for pid in (prev["pages"] as Array):
			if bool(seen.get(str(pid), false)):
				return true
		return false
	return false


## 该章看过几页。
static func chapter_progress(chapter_id: String, seen: Dictionary) -> Dictionary:
	var pages := pages_of_chapter(chapter_id)
	var n := 0
	for pid in pages:
		if bool(seen.get(str(pid), false)):
			n += 1
	return {"seen": n, "total": pages.size()}


## 整树进度。
static func progress(seen: Dictionary) -> Dictionary:
	var total := 0
	var got := 0
	var per: Array = []
	for c in chapters():
		var p := chapter_progress(str(c["id"]), seen)
		total += int(p["total"])
		got += int(p["seen"])
		per.append({"id": str(c["id"]), "seen": int(p["seen"]), "total": int(p["total"])})
	return {"seen": got, "total": total, "chapters": per}


## 下一课：全树顺序里第一个没看过的页；全部看过返回 ""。
static func next_page(seen: Dictionary) -> String:
	for pid in flatten():
		if not bool(seen.get(pid, false)):
			return pid
	return ""


## 页的人类可读副标题：取该页 `?` 之后正文的第一行（教学文件天然带一句说明）。
## 读取失败 / 空页返回 ""，UI 退回只显示 id。
static func subtitle_of(page_id: String) -> String:
	var page := TutorialData.load_page(page_id)
	if str(page.get("error", "")) != "":
		return ""
	var text := str(page.get("text", "")).strip_edges()
	if text == "":
		return ""
	var first := text.split("\n")[0].strip_edges()
	if first.length() > 60:
		first = first.substr(0, 58) + "…"
	return first
