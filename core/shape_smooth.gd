# shape_smooth.gd —— 边缘平滑（腐蚀 / 膨胀）的「连通性硬校验」闸门（功能清单 §3，2026-10-09）。
#
# 【文档要什么】「平滑可能把 1 格宽的缝隙填死（两个洞意外连通）或把细梁弄断 —— 视觉上没问题，
#   逻辑上整个迷宫已经变了。执行前后必须校验『连通区域数量不变』，变了就**拒绝操作**并**高亮出
#   问题的位置**。这条是硬约束。」
#
# 【本模块负责什么，不负责什么】形态学**不在这里重写**：腐蚀 / 膨胀沿用 `ShapeGenerator.erode_cells` /
#   `dilate_cells`（唯一事实来源）。这里只做文档点名的那一件事 —— 执行前后校验 + 拒绝 + 指出问题格。
#   于是"怎么变形"与"变形是否合法"彻底解耦：将来加开运算 / 闭运算，接同一道闸门即可，不必各写一遍校验。
#
# 【为什么要查两类连通性】文档点了两个失败模式，各自对应一类分量，只查一类必然漏另一类：
#   · 「把细梁弄断」     ⇒ **格集自身**的连通分量变多（一个岛裂成两个）；
#   · 「两个洞意外连通」 ⇒ **格集之外**（同一张盘上的补集）的连通分量变少（两块空隙并成一块）。
#
# 【判界】一律走传进来的 `grid`。编辑器侧要传 `EditorDoc.space_grid()`（**未挖洞**的盘空间）：
#   洞格必须"存在于盘上"，否则膨胀永远长不进洞里，操作变成空转（理由见 core/editor_doc.gd:_build_topology_raw）。
#
# 【手工格保护】与 `ShapeFill` 同一条硬约束（文档 §3）：`opts.hand_edited` 里的格**一律保持原状**
#   （本来是格就仍是格、本来不是就不是），并原样列进 `protected`；非空 ⇒ `reason` 要说出跳过了几格。
#   保护在**过闸门之前**应用 —— 闸门判的是"实际会落盘的结果"，不是"算法想做的结果"。
#
# 【输出】`{ok, mode, cells, count, added, removed, protected, reason, problem, problem_kind, before, after}`
#   · cells / added / removed / protected / problem 恒按 (y, x) 升序 ⇒ 两次调用逐项相同、可复现；
#   · ok == false 时 cells 为空、`problem` 是"出问题的格"（供 UI 高亮），reason 是可读原因。
class_name ShapeSmooth
extends RefCounted

const MODE_DILATE := "dilate"
const MODE_ERODE := "erode"
## 模式白名单：未知模式**可读拒绝**，绝不静默按其中一种处理（那会让用户以为平滑过了）。
const MODES := [MODE_DILATE, MODE_ERODE]

## 输入上限只读复用 `EditorDoc.MAX_CELL_BUDGET` 的硬阻口径（实际判据走 `ShapeBoolean.normalize`），
## 这里不另立魔数 —— 同 `ShapeFill.MAX_CELL_BUDGET` 的理由。
const MAX_CELL_BUDGET := EditorDoc.MAX_CELL_BUDGET

## 问题分类（UI 据此给不同话术；测试钉住这三个字符串）。
const KIND_BEAM_CUT := "beam_cut"          # 细梁被弄断：格集分量变多
const KIND_VOID_MERGED := "void_merged"    # 缝隙被填死：盘上空隙的分量变少
const KIND_OTHER := "components_changed"   # 两个模式都不是（或两类同时变）：只报"连通区域数量变了"


## 对 `cells` 做一次腐蚀 / 膨胀，并在结果**实际落盘之前**校验连通区域数量不变。
##
## opts（可省）：
##   · hand_edited : 手工改过的格（这些格**保持原状**，不参与变形）。
##
## grid 必须是**未挖洞**的盘空间（`EditorDoc.space_grid()`），理由见文件头。
static func apply(cells: Variant, grid, mode: String = MODE_ERODE, opts: Dictionary = {}) -> Dictionary:
	if grid == null:
		return _fail("盘为空（判界必须走网格 in_board()/get_neighbors()，不得按包围盒）")
	if not MODES.has(mode):
		return _fail("未知平滑模式「%s」（可用：%s）" % [mode, ", ".join(MODES)])
	var nr: Dictionary = ShapeBoolean.normalize(cells)
	if not bool(nr["ok"]):
		return _fail(str(nr["reason"]))
	var base: Dictionary = _clip(nr["keys"], grid)
	var out: Dictionary = (ShapeGenerator.dilate_cells(base, grid) if mode == MODE_DILATE
		else ShapeGenerator.erode_cells(base, grid))
	# 手工格保护：把受保护的格**还原成原状**（在本集合里就补回去、不在就删掉），再进闸门。
	var hand: Dictionary = ShapeBoolean.normalize(opts.get("hand_edited", []))
	if not bool(hand["ok"]):
		return _fail("手工格集合不能用：%s" % str(hand["reason"]))
	var protected := {}
	for p in hand["keys"]:
		var pp: Vector2i = p
		if not grid.in_board(pp):
			continue                      # 盘外的手工标记与本次操作无关（不虚报"跳过"）
		var was_in := base.has(pp)
		if was_in == out.has(pp):
			continue                      # 本来就没被改到 ⇒ 不算"跳过"
		protected[pp] = true
		if was_in:
			out[pp] = true
		else:
			out.erase(pp)
	var added: Array[Vector2i] = _diff(out, base)
	var removed: Array[Vector2i] = _diff(base, out)
	var before: Dictionary = _stats(base, grid)
	var after: Dictionary = _stats(out, grid)
	var kind := _problem_kind(before, after)
	if kind != "":
		var res := _fail(_problem_text(mode, kind, before, after))
		res["mode"] = mode
		res["problem"] = _problem_cells(added, removed)
		res["problem_kind"] = kind
		res["added"] = added
		res["removed"] = removed
		res["protected"] = _sorted(protected)
		res["before"] = before
		res["after"] = after
		return res
	var out_cells: Array[Vector2i] = _sorted(out)
	var reason := ""
	if not protected.is_empty():
		reason = "跳过 %d 格手工修改：平滑不覆盖「已脱离生成」的格。" % protected.size()
	return {
		"ok": true, "mode": mode, "cells": out_cells, "count": out_cells.size(),
		"added": added, "removed": removed, "protected": _sorted(protected),
		"reason": reason, "problem": [] as Array[Vector2i], "problem_kind": "",
		"before": before, "after": after,
	}


## UI 一行文案（纯格式化，不读全局状态）。
static func describe(result: Dictionary) -> String:
	var mode := str(result.get("mode", ""))
	var verb := "膨胀" if mode == MODE_DILATE else "腐蚀"
	if not bool(result.get("ok", false)):
		return "未执行：%s" % str(result.get("reason", ""))
	var text := "%s完成：补 %d 格、挖 %d 格" % [
		verb, (result.get("added", []) as Array).size(), (result.get("removed", []) as Array).size()]
	var prot: Array = result.get("protected", [])
	if not prot.is_empty():
		text += "，跳过 %d 格手工修改" % prot.size()
	return text + "。"


# ==================== 内部实现 ====================

## 只保留**盘上**的格（盘外条目丢弃：它们既不是数据错误，也没有形态学意义）。
static func _clip(keys: Dictionary, grid) -> Dictionary:
	var out := {}
	for p in keys:
		var pp: Vector2i = p
		if grid.in_board(pp):
			out[pp] = true
	return out


## 连通性快照：`{cells, regions, voids, void_regions}`。
##   · regions      = 集合自身的连通分量数（「细梁弄断」会让它变大）；
##   · voids        = 集合外、盘内的格数；
##   · void_regions = 这些格的分量数（「缝隙填死」会让它变小）。
static func _stats(set_cells: Dictionary, grid) -> Dictionary:
	var complement := {}
	for p in grid.all_positions():
		if not set_cells.has(p):
			complement[p] = true
	return {
		"cells": set_cells.size(),
		"regions": _regions(set_cells, grid),
		"voids": complement.size(),
		"void_regions": _regions(complement, grid),
	}


## 连通分量数（BFS，只走 `grid.get_neighbors()`，**绝不**按 cols/rows 包围盒判界）。
static func _regions(set_cells: Dictionary, grid) -> int:
	if set_cells.is_empty():
		return 0
	var seen := {}
	var n := 0
	for p in set_cells:
		var start: Vector2i = p
		if seen.has(start):
			continue
		n += 1
		seen[start] = true
		var stack: Array[Vector2i] = [start]
		while not stack.is_empty():
			var cur: Vector2i = stack.pop_back()
			for nb in grid.get_neighbors(cur):
				if set_cells.has(nb) and not seen.has(nb):
					seen[nb] = true
					stack.append(nb)
	return n


## 连通性是否被破坏；被破坏则返回问题分类，正常返回 ""。
## 文档点名的两个失败模式各给一条**更贴切**的分类（只在另一个维度没同时变时才归它们）。
static func _problem_kind(before: Dictionary, after: Dictionary) -> String:
	var regions_changed := int(after["regions"]) != int(before["regions"])
	var voids_changed := int(after["void_regions"]) != int(before["void_regions"])
	if not regions_changed and not voids_changed:
		return ""
	if int(after["regions"]) > int(before["regions"]) and not voids_changed:
		return KIND_BEAM_CUT
	if int(after["void_regions"]) < int(before["void_regions"]) and not regions_changed:
		return KIND_VOID_MERGED
	return KIND_OTHER


## 出问题的格（供 UI 高亮）："变化发生在哪就报哪"。
##
## 【为什么不能只取一边】同一类问题两个方向都会出：**腐蚀**吃掉两洞之间的薄墙 ⇒ 两洞连通（问题格在 removed）；
## **膨胀**塞住一格宽的缝隙 ⇒ 同样是补集变化（问题格在 added）。只取 added 会在腐蚀时报一个空集，
## 那就等于"拒绝了却不告诉用户哪里出事"——文档明写要"高亮出问题的位置"。
static func _problem_cells(added: Array[Vector2i], removed: Array[Vector2i]) -> Array[Vector2i]:
	if removed.is_empty():
		return added.duplicate()
	if added.is_empty():
		return removed.duplicate()
	var both: Array[Vector2i] = added.duplicate()
	both.append_array(removed)
	both.sort_custom(_pos_less)
	return both


static func _problem_text(mode: String, kind: String, before: Dictionary, after: Dictionary) -> String:
	var verb := "膨胀" if mode == MODE_DILATE else "腐蚀"
	match kind:
		KIND_BEAM_CUT:
			return "拒绝%s：会把细梁弄断 —— 连通区域从 %d 个变成 %d 个（视觉上没问题，逻辑上迷宫已经变了）。" % [
				verb, int(before["regions"]), int(after["regions"])]
		KIND_VOID_MERGED:
			return "拒绝%s：会把 1 格宽的缝隙填死 —— 盘上的空隙从 %d 块并成 %d 块（两个洞意外连通）。" % [
				verb, int(before["void_regions"]), int(after["void_regions"])]
		_:
			return "拒绝%s：连通区域数量变了（格集 %d→%d 块、空隙 %d→%d 块）。" % [
				verb, int(before["regions"]), int(after["regions"]),
				int(before["void_regions"]), int(after["void_regions"])]


## a 有、b 没有的格（(y, x) 升序）。
static func _diff(a: Dictionary, b: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in a:
		if not b.has(p):
			var pp: Vector2i = p
			out.append(pp)
	out.sort_custom(_pos_less)
	return out


## 键集 → 排序后的 Array[Vector2i]（(y, x) 升序就是"可复现"的口径本身）。
static func _sorted(keys: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in keys:
		var kk: Vector2i = k
		out.append(kk)
	out.sort_custom(_pos_less)
	return out


static func _pos_less(p: Vector2i, q: Vector2i) -> bool:
	if p.y != q.y:
		return p.y < q.y
	return p.x < q.x


static func _fail(reason: String) -> Dictionary:
	return {
		"ok": false, "mode": "", "cells": [] as Array[Vector2i], "count": 0,
		"added": [] as Array[Vector2i], "removed": [] as Array[Vector2i],
		"protected": [] as Array[Vector2i], "reason": reason,
		"problem": [] as Array[Vector2i], "problem_kind": "",
		"before": {}, "after": {},
	}
