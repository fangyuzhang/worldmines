# shape_boolean.gd —— 形状布尔运算：并/交/差/异或（文档「三」布尔运算，2026-10-03）。
#
# 【为什么是「格集布尔」而不是「多边形裁剪」】
#   文档警告的是「两形状顶点两两求交，中间结果 O(N×M)；两个 2000 点手绘轮廓求交 = 400 万次判定」。
#   本仓的关卡本体就是**格坐标集合**（`EditorDoc.mines / obstacles / revealed`、`GridInterface.all_positions()`）。
#   对格集做布尔只有字典增删查：O(n+m)、无中间顶点、无浮点误差、结果天然可复现。
#   多边形裁剪（Sutherland–Hodgman / Weiler–Atherton 之类）会引入顶点拓扑、退化共线、自交等一堆
#   在本项目里**没有消费者**的复杂度（关卡是格不是矢量图形）⇒ 属于过度工程，故不采用。
#   空间哈希/顶点上限在这里也不需要：上限只用来兜住「有人把超大集合喂进来」这一种病。
#
# 纯函数：static + RefCounted，不引用场景树、不碰 UI/autoload、不做随机。
#
# 【输入口径】格集接受两种容器，二选一：
#   · `Array`：元素为 `Vector2i(c, r)` 或 `{"x": int, "y": int}`（JSON 口径）；
#   · `Dictionary`：键为 `Vector2i(c, r)`，值忽略（只取键集）。
#   同一格重复出现视为一次；`null` 非法（空集请给 `[]` 或 `{}`）。
#
# 【输出口径】四种运算返回同一个结构（Dictionary）：
#   `{ok: bool, cells: Array[Vector2i], count: int, reason: String}`
#   · `cells` 恒按 (y, x) 升序排序 ⇒ 两次调用逐项相同、可复现（字典遍历顺序不作数）；
#   · `reason` 失败时为可读原因，成功时为 ""；
#   · `ok == false` 时 `cells` 为空、`count == 0`（调用方据此不执行下游操作）。
#   `apply_to_grid()` 额外带 `discarded: Array[Vector2i]`（同样排序，见下）。
class_name ShapeBoolean
extends RefCounted

## 单次运算允许的**输入**格数上限。复用 `EditorDoc.MAX_CELL_BUDGET` 口径（只读不改，
## 避免这里再长出一个会与编辑器漂移的魔数）——文档「事前估算、超限硬阻」。
## 注意门槛落在**每个输入集合**上，而不是结果：两个 5000 格集合求并（结果可达 10000）
## 是允许的，因为格集布尔的结果不会退化爆炸（O(n+m) 字典运算），这正是它相对多边形裁剪的优势。
const MAX_CELL_BUDGET := EditorDoc.MAX_CELL_BUDGET

const OP_UNION := "union"
const OP_INTERSECT := "intersect"
const OP_DIFFERENCE := "difference"
const OP_XOR := "xor"


## 并集：a ∪ b。
static func union(a: Variant, b: Variant) -> Dictionary:
	return _binary(a, b, OP_UNION)


## 交集：a ∩ b。
static func intersect(a: Variant, b: Variant) -> Dictionary:
	return _binary(a, b, OP_INTERSECT)


## 差集：a − b（在 a 中而不在 b 中）。注意**非交换**。
static func difference(a: Variant, b: Variant) -> Dictionary:
	return _binary(a, b, OP_DIFFERENCE)


## 对称差（异或）：恰好属于 a、b 之一。
static func xor(a: Variant, b: Variant) -> Dictionary:
	return _binary(a, b, OP_XOR)


## 把格集与真实网格求交：**只保留盘内格**，返回被丢弃的盘外格清单。
##
## 判定严格走 `grid.in_board()`（`GridInterface` 契约：矩形 = 坐标范围，异形/邻接表 = 稀疏成员集），
## **禁止用包围盒**——异形盘（挖洞/蜂窝）的 bbox 里有大量不存在的格，用 bbox 会放行幽灵格。
## `in_board()` 与 `all_positions()` 同源（都是"盘上真实存在的格"），两者口径一致。
##
## 返回在四运算结构上追加 `discarded: Array[Vector2i]`（盘外被丢弃的格，排序）。
## 全部格都在盘内时 `discarded` 为空、`reason == ""`；输入非法/超限时 `ok=false`，
## 此时 `cells` 为空、`discarded` = 全部输入格（都没落地），`reason` 说明原因。
static func apply_to_grid(cells: Variant, grid: Variant) -> Dictionary:
	if grid == null or not grid.has_method("in_board"):
		return _fail("apply_to_grid: grid 为空或没有 in_board()（需 GridInterface 口径）")
	var norm := _normalize(cells)
	var all_in: Array[Vector2i] = _sorted_positions(norm["keys"])
	if not bool(norm["ok"]):
		return {
			"ok": false, "cells": [] as Array[Vector2i], "discarded": all_in,
			"count": 0, "reason": str(norm["reason"]),
		}
	var kept := {}
	var dropped := {}
	for pos in norm["keys"]:
		if grid.in_board(pos):
			kept[pos] = true
		else:
			dropped[pos] = true
	var kept_arr := _sorted_positions(kept)
	var dropped_arr := _sorted_positions(dropped)
	var reason := ""
	if dropped_arr.size() > 0:
		reason = "%d 格不在盘内已丢弃（%s）" % [dropped_arr.size(), _grid_desc(grid)]
	return {
		"ok": true, "cells": kept_arr, "discarded": dropped_arr,
		"count": kept_arr.size(), "reason": reason,
	}


## 公开的「格集归一化 + 上限硬阻」入口（内部实现是 `_normalize`）：给同族的形状模块复用**同一套**
## 容器口径与 `MAX_CELL_BUDGET`，免得每个模块各写一份、日久彼此漂移（本仓老病；`ShapeFill` 已在用）。
## 返回 `{ok, keys: Dictionary[Vector2i -> true], reason}`。
static func normalize(cells: Variant) -> Dictionary:
	return _normalize(cells)


# ==================== 内部实现 ====================

## 二元运算主流程：先各自归一化（含上限硬阻），再按运算类型做字典运算。
static func _binary(a: Variant, b: Variant, op: String) -> Dictionary:
	var na := _normalize(a)
	if not bool(na["ok"]):
		return _fail(str(na["reason"]))
	var nb := _normalize(b)
	if not bool(nb["ok"]):
		return _fail(str(nb["reason"]))
	var ka: Dictionary = na["keys"]
	var kb: Dictionary = nb["keys"]
	var out := {}
	match op:
		OP_UNION:
			for k in ka:
				out[k] = true
			for k in kb:
				out[k] = true
		OP_INTERSECT:
			for k in ka:
				if kb.has(k):
					out[k] = true
		OP_DIFFERENCE:
			for k in ka:
				if not kb.has(k):
					out[k] = true
		OP_XOR:
			for k in ka:
				if not kb.has(k):
					out[k] = true
			for k in kb:
				if not ka.has(k):
					out[k] = true
		_:
			return _fail("未知布尔运算：%s" % op)
	var arr := _sorted_positions(out)
	return {"ok": true, "cells": arr, "count": arr.size(), "reason": ""}


## 归一化成 `{ok, keys: Dictionary[Vector2i -> true], reason}`。
## 非法元素 / 不支持的类型 / 超过 MAX_CELL_BUDGET → ok=false + 可读原因（不静默吞）。
static func _normalize(cells: Variant) -> Dictionary:
	var keys := {}
	if cells == null:
		return {"ok": false, "keys": keys, "reason": "格集为 null（空集请传 [] 或 {}）"}
	if cells is Dictionary:
		for k in cells:
			var pk: Variant = _to_pos(k)
			if pk == null:
				return {"ok": false, "keys": keys,
					"reason": "格集含无法解析的键：%s（需 Vector2i 或 {x,y}）" % str(k)}
			keys[pk] = true
	elif cells is Array:
		for e in cells:
			var pe: Variant = _to_pos(e)
			if pe == null:
				return {"ok": false, "keys": keys,
					"reason": "格集含无法解析的元素：%s（需 Vector2i 或 {x,y}）" % str(e)}
			keys[pe] = true
	else:
		return {"ok": false, "keys": keys,
			"reason": "格集类型不支持：%s（需 Array 或 Dictionary）" % type_string(typeof(cells))}
	if keys.size() > MAX_CELL_BUDGET:
		return {"ok": false, "keys": keys,
			"reason": "输入 %d 格，超过最高上限 %d（拒绝执行；请降精度/合并格子）" % [keys.size(), MAX_CELL_BUDGET]}
	return {"ok": true, "keys": keys, "reason": ""}


## 单格解析：Vector2i 原样；{"x": int, "y": int} 按 JSON 口径转换；其余 → null。
static func _to_pos(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Dictionary and v.has("x") and v.has("y"):
		return Vector2i(int(v["x"]), int(v["y"]))
	return null


## 键集 → 排序后的 Array[Vector2i]，(y, x) 升序。稳定排序是"可复现"的口径本身。
static func _sorted_positions(keys: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in keys:
		out.append(k)
	out.sort_custom(_pos_less)
	return out


static func _pos_less(p: Vector2i, q: Vector2i) -> bool:
	if p.y != q.y:
		return p.y < q.y
	return p.x < q.x


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "cells": [] as Array[Vector2i], "count": 0, "reason": reason}


## 盘的可读描述（只作提示文案；size() 缺失时退回 cell_count()）。
static func _grid_desc(grid: Variant) -> String:
	if grid.has_method("size"):
		var s: Variant = grid.size()
		if s is Vector2i and (s.x > 0 or s.y > 0):
			return "盘 %d×%d" % [s.x, s.y]
	if grid.has_method("cell_count"):
		return "盘 %d 格" % int(grid.cell_count())
	return "盘外"
