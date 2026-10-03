# shape_reflow.gd —— 形状参数改变后的「重栅格化 + 保留手工格」（纯函数，无副作用）。
#
# 缺口（本轮补齐）：既有换形状路径（ui/level_editor.gd 的 _on_shape_selected → _drop_off_board）
# 只做「把盘外格直接丢掉」——不管是自动生成的还是用户手工摆的雷/障碍，一视同仁地删。
# 结果：用户辛苦手工改过的格，换了形状参数（或换形状）后会**静默消失**，且没有任何报告。
#
# 本模块把这一步的语义收进一个**可单测的纯函数**：
#   · 未手工改过的格 —— 完全交给新形状（旧的消失、新的出现）；
#   · 手工改过的格   —— 盘内 ⇒ 保留（**即使新形状不含它**）；盘外 ⇒ 丢弃，但**必须报告**
#                       （进 dropped_hand + 非空 reason），绝不允许静默丢。
#
# 硬约束（与仓库里其它「形状 × 网格」纯函数同一口径，见 core/shape_generator.gd:895 的腐蚀/膨胀）：
#   · 不建真实网格、不碰场景树、不 preload 任何 ui/*；除返回值外无副作用。
#   · 判界**一律问网格** `grid.in_board()`（形状盘 / 挖洞盘的洞格没有 Cell，不在盘上）。
#     **禁止**用 new_cells 的 cols/rows 包围盒：环形的洞在包围盒内，按包围盒判界会把格写进洞里。
#   · 顺序可复现：kept_hand / dropped_hand 一律按 (y, x) 排序后再返回，不依赖哈希遍历顺序。
#
# 数据形态：old_cells / new_cells / hand_edited 均为 Dictionary（键 = Vector2i，值 = 任意负载）。
#   只有**键**参与「格集」判定；值用于填充返回的 cells 负载 ——
#   **手工格取其旧值（手改负载）优先**（不被 new_cells 的新形状默认值覆盖），其余格取 new_cells 值。
# UI 接线口径：grid 传「新形状盘对象」（EditorDoc.grid()），in_board 与「新栅格」同源。
class_name ShapeReflow
extends RefCounted


## 重栅格化：新形状的格集 + 盘内手工格 = 结果格集。
##
## 入参：
##   · grid        —— **目标盘**（GridInterface 子类，须有 in_board()）。它定义「盘内 / 盘外」。
##                     UI 接线一律传「新形状盘对象」（与 _drop_off_board / EditorDoc.grid() 同源）。
##   · old_cells   —— 旧格集（含用户手工改后的状态）：给手工格提供负载（手改负载优先）。
##   · new_cells   —— 新形状栅格化后的格集（Dictionary，键 = Vector2i）。
##   · hand_edited —— 被用户手工改过的格（Dictionary，键 = Vector2i）。
##
## 负载规则（值如何取）：手工格的负载 = old_cells[pos]（手改后的旧状态）；old_cells 无此格时退用
##   hand_edited[pos]。**手工格的手改负载优先于 new_cells 的新形状默认值**——即便该格在新形状里，
##   也不许被新形状默认值覆盖（「重栅格化不覆盖我的手工修改」是本模块对用户的真实价值）。
##   其余（未手工改过的）格一律取 new_cells[pos]。
##
## 返回：{
##   "cells":        Dictionary，结果格集（键 = Vector2i，值 = 负载）；
##   "kept_hand":    Array[Vector2i]，被保留的手工格（按 (y,x) 排序）；
##   "dropped_hand": Array[Vector2i]，被丢弃的手工格（盘外，按 (y,x) 排序）；
##   "reason":       String，丢弃发生时的可读原因（未丢弃时为空串）。
## }
static func reflow(grid, old_cells: Dictionary, new_cells: Dictionary, hand_edited: Dictionary) -> Dictionary:
	var cells: Dictionary = {}
	# ① 未手工改过的格：按 new_cells 走（旧的有、新的没有 ⇒ 消失；新的有 ⇒ 出现）。
	for p in new_cells.keys():
		cells[p] = new_cells[p]

	# ② 手工格：盘内保留（新形状不含它也要留），盘外丢弃并报告。
	#    **手改负载优先**：即便该格也在 new_cells 里，也用旧状态覆盖新形状默认值。
	var kept_hand: Array = []
	var dropped_hand: Array = []
	for p in hand_edited.keys():
		if _on_board(grid, p):
			cells[p] = _payload_for(old_cells, hand_edited, p)
			kept_hand.append(p)
		else:
			cells.erase(p)          # 该格不在盘上 ⇒ 任何来源都不能留在结果里
			dropped_hand.append(p)

	kept_hand = _sorted_positions(kept_hand)
	dropped_hand = _sorted_positions(dropped_hand)

	var reason := ""
	if not dropped_hand.is_empty():
		reason = "有 %d 格手工修改落在新盘之外：盘上没有对应的格，无法保留，已丢弃并报告。" % dropped_hand.size()
	return {
		"cells": cells,
		"kept_hand": kept_hand,
		"dropped_hand": dropped_hand,
		"reason": reason,
	}


## UI 一行文案：这轮换形状保住了几格手工修改、丢了几格。纯格式化，不读全局状态。
static func describe_reflow(result: Dictionary) -> String:
	var kept: Array = result.get("kept_hand", [])
	var dropped: Array = result.get("dropped_hand", [])
	if kept.is_empty() and dropped.is_empty():
		return "换形状：没有手工修改的格需要保留。"
	var parts: Array[String] = []
	if not kept.is_empty():
		parts.append("保留了 %d 格手工修改" % kept.size())
	if not dropped.is_empty():
		parts.append("丢弃了 %d 格盘外手工修改" % dropped.size())
	var text := "换形状：" + "、".join(parts) + "。"
	if not dropped.is_empty():
		text += "（盘外格在新盘上没有对应位置，无法保留。）"
	return text


# ============================== 内部实现 ==============================

## 盘内判定：唯一权威是网格的 in_board()。数组 / 字典（格集）作为无网格场景的显式兜底，
## 仍然是「集合判界」，**不是** cols/rows 包围盒。grid 为 null / 不提供判据时显式报错并判盘外
## （宁可丢弃并报告，也不静默用包围盒猜）。
static func _on_board(grid, pos: Vector2i) -> bool:
	if grid == null:
		push_error("ShapeReflow._on_board: grid 为空，无法判定「盘内/盘外」——拒绝用包围盒猜测。")
		return false
	if grid is Dictionary:
		return (grid as Dictionary).has(pos)
	if grid is Array:
		return (grid as Array).has(pos)
	if grid.has_method("in_board"):
		return bool(grid.call("in_board", pos))
	push_error("ShapeReflow._on_board: grid 未提供 in_board()（收到 %s）——拒绝用包围盒猜测。" % str(grid))
	return false


## 保留的手工格若不在新形状里，用它的历史负载补回：旧格集优先，其次手工记录本身。
static func _payload_for(old_cells: Dictionary, hand_edited: Dictionary, pos: Vector2i) -> Variant:
	if old_cells.has(pos):
		return old_cells[pos]
	return hand_edited[pos]


## 稳定排序（按 (y, x)）：两次同输入必得逐项相同的数组，不受字典哈希遍历顺序影响。
static func _sorted_positions(arr: Array) -> Array:
	var out: Array = arr.duplicate()
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return out
