# shape_fill.gd —— 形状间空隙的「填充」（功能清单 §3「填充系统」，2026-10-09）。
#
# 【文档要什么】「形状间空隙自动填充（实心/环形/图案），图案单元可以是任意形状（"用五角星铺满圆环"）。」
# 外加一条硬约束：「填充是参数化生成，但用户手工改过的地方要标记"已脱离生成"，下次填充不得覆盖。」
#
# 【为什么空隙不由本模块算】「哪两块形状之间的空隙」是**选区 / 布尔**的语义，本仓已有 `ShapeBoolean`
# （并 / 交 / 差 / 异或）负责。把 A − B 的结果（一串格）交给这里，填充样式就与「空隙怎么来的」彻底解耦
# —— 多岛、护城河、任意挖洞都复用同一条填充路径，不必各写一份。
#
# 【纯函数】static + RefCounted；不引用场景树、不碰 UI/autoload、不做随机。
# 格集口径**全套复用 `ShapeBoolean.normalize`**（Array[Vector2i | {x,y}] 或 Dictionary 键集，含
# MAX_CELL_BUDGET 事前硬阻）—— 不在这里另写一份归一化，否则两处口径迟早漂移（本仓的老病）。
#
# 【三种样式】
#   · solid   —— 空隙本体全填（一格不落）；
#   · ring    —— 只填"边缘一圈"：4 邻域里**至少有一个**不在空隙里的格（内芯留空，保证还走得通）；
#   · pattern —— 拿一个**单元格集**（任意形状）周期平铺，只保留落在空隙里的格；
#                单元自身左上角会被归零；平铺原点默认 = 空隙包围盒左上角（可用 anchor 覆盖）。
#
# 【手工格保护（硬约束）】`opts.hand_edited` 里的格**绝不进结果**，并原样列进 `protected`。
# `protected` 非空 ⇒ `reason` 非空（"跳过 N 格手工修改"）—— 调用方据此提示用户，不许静默忽略。
#
# 【输出】`{ok, cells: Array[Vector2i], count, protected: Array[Vector2i], reason}`
#   · cells / protected 恒按 (y, x) 升序 ⇒ 两次调用逐项相同、可复现（字典遍历顺序不作数）；
#   · ok == false 时 cells / protected 为空、count == 0，reason 是可读原因。
class_name ShapeFill
extends RefCounted

const MODE_SOLID := "solid"
const MODE_RING := "ring"
const MODE_PATTERN := "pattern"
## 样式白名单：未知样式**可读拒绝**，绝不静默按 solid 处理（那会让用户以为填对了）。
const MODES := [MODE_SOLID, MODE_RING, MODE_PATTERN]

## 输入上限只读复用 `EditorDoc.MAX_CELL_BUDGET` 的硬阻口径（实际判据走 `ShapeBoolean.normalize`），
## 这里不再另立魔数 —— 同 `ShapeBoolean.MAX_CELL_BUDGET` 的理由。
const MAX_CELL_BUDGET := EditorDoc.MAX_CELL_BUDGET


## 把空隙 `region` 按 `opts` 填成结果格集。语义见文件头「三种样式」「手工格保护」。
##
## opts（全部可省）：
##   · mode        : "solid"（默认）| "ring" | "pattern"；
##   · unit        : 图案单元格集（仅 mode == "pattern" 需要；空单元被拒绝）；
##   · anchor      : Vector2i 平铺原点（默认空隙包围盒左上角；仅 pattern 生效）；
##   · hand_edited : 手工改过的格（这些格**一定不进结果**）。
static func fill(region: Variant, opts: Dictionary = {}) -> Dictionary:
	var nr: Dictionary = ShapeBoolean.normalize(region)
	if not bool(nr["ok"]):
		return _fail(str(nr["reason"]))
	var holes: Dictionary = nr["keys"]
	var mode := str(opts.get("mode", MODE_SOLID))
	if not MODES.has(mode):
		return _fail("未知填充样式「%s」（可用：%s）" % [mode, ", ".join(MODES)])
	var filled := {}
	match mode:
		MODE_PATTERN:
			if not opts.has("unit"):
				return _fail("图案样式需要指定 unit（图案单元格集）")
			var unit: Dictionary = ShapeBoolean.normalize(opts["unit"])
			if not bool(unit["ok"]):
				return _fail("图案单元不能用：%s" % str(unit["reason"]))
			if (unit["keys"] as Dictionary).is_empty():
				return _fail("图案单元是空的：至少要有一个格（空单元铺不出任何东西）")
			filled = _tile(holes, unit["keys"], opts.get("anchor", null))
		MODE_RING:
			for p in holes:
				var hp: Vector2i = p
				if _on_edge(holes, hp):
					filled[hp] = true
		_:
			for p in holes:
				filled[p] = true
	# 手工格保护：先收集、再统一剔除（边遍历边改容器是一类隐蔽 bug，刻意分两步）。
	var hand: Dictionary = ShapeBoolean.normalize(opts.get("hand_edited", []))
	if not bool(hand["ok"]):
		return _fail("手工格集合不能用：%s" % str(hand["reason"]))
	var hand_keys: Dictionary = hand["keys"]
	var protected := {}
	for p in filled:
		if hand_keys.has(p):
			protected[p] = true
	for p in protected:
		filled.erase(p)
	var cells := _sorted_positions(filled)
	var prot := _sorted_positions(protected)
	var reason := ""
	if not prot.is_empty():
		reason = "跳过 %d 格手工修改：填充不覆盖「已脱离生成」的格。" % prot.size()
	return {"ok": true, "cells": cells, "count": cells.size(),
		"protected": prot, "reason": reason}


## UI 一行文案（纯格式化，不读全局状态）。
static func describe(result: Dictionary) -> String:
	if not bool(result.get("ok", false)):
		return "填充失败：%s" % str(result.get("reason", ""))
	var n := int(result.get("count", 0))
	var prot: Array = result.get("protected", [])
	if n == 0 and prot.is_empty():
		return "空隙是空的：没有可填的格。"
	var text := "填了 %d 格" % n
	if not prot.is_empty():
		text += "，跳过 %d 格手工修改" % prot.size()
	return text + "。"


# ==================== 内部实现 ====================

## 边缘判定：4 邻域里至少有一个不在空隙里。
## 对角不算 —— 与「通道宽度 ≥ 2 格」的口径一致（对角连通会让 1 格宽的斜缝看起来通、实际走不通）。
static func _on_edge(holes: Dictionary, pos: Vector2i) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if not holes.has(pos + d):
			return true
	return false


## 周期平铺：单元先归零到自身左上角，再按「(格 − 原点) mod 单元包围盒」取模落位。
static func _tile(holes: Dictionary, unit: Dictionary, anchor: Variant) -> Dictionary:
	var out := {}
	if holes.is_empty() or unit.is_empty():
		return out
	var ub := _bbox(unit)
	var w := maxi(ub.size.x, 1)
	var h := maxi(ub.size.y, 1)
	var norm := {}
	for p in unit:
		var up: Vector2i = p
		norm[Vector2i(up.x - ub.position.x, up.y - ub.position.y)] = true
	var origin := _bbox(holes).position
	if anchor is Vector2i:
		origin = anchor
	for p in holes:
		var hp: Vector2i = p
		var dx := posmod(hp.x - origin.x, w)
		var dy := posmod(hp.y - origin.y, h)
		if norm.has(Vector2i(dx, dy)):
			out[hp] = true
	return out


## 格集的整数包围盒 —— **只**用于平铺原点与单元归零，**不参与**盘内/盘外判定
##（判界一律问网格 `in_board()`，见 core/shape_boolean.gd:61 的同条纪律）。
static func _bbox(keys: Dictionary) -> Rect2i:
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for p in keys:
		var k: Vector2i = p
		min_x = mini(min_x, k.x)
		min_y = mini(min_y, k.y)
		max_x = maxi(max_x, k.x)
		max_y = maxi(max_y, k.y)
	if min_x > max_x:
		return Rect2i(0, 0, 0, 0)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


## 键集 → 排序后的 Array[Vector2i]（(y, x) 升序是"可复现"的口径本身）。
static func _sorted_positions(keys: Dictionary) -> Array[Vector2i]:
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
	return {"ok": false, "cells": [] as Array[Vector2i], "count": 0,
		"protected": [] as Array[Vector2i], "reason": reason}
