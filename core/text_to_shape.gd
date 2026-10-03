# core/text_to_shape.gd —— 文字 / 手绘轮廓 → 格集（缺口 #2 的构建器）。
#
# 背景（缺口原文）：core/shape_dag.gd 的词汇表 PRIMITIVE_SHAPES 早已登记 "text" / "freehand"
#   （shape_dag.gd:59-61），`primitive_to_builder()` 也如实报「本仓无 text/freehand 构建器」，
#   但全仓**没有**「文字 / 笔迹 → 格集」这一层：UI 画得出，落盘落不下。
#   本模块补的就是这一层：纯数据进（点阵 / 点列）、纯数据出（格集 / DAG 参数表）。
#
# 硬约束（与 core/shape_generator.gd 的 (o) 节同口径）：
#   · 纯函数：static + RefCounted，无状态、无副作用、无随机；同输入两次调用输出**逐位相同**。
#   · **不读任何字体文件 / 不吃 UI 状态**：字形点阵由调用方作为纯数据传入（见 _glyph_rows）。
#   · 判界**一律问网格** grid.in_board()（洞格 / 盘外格都由网格回答），**绝不用 cols×rows 包围盒**
#     —— 环形 annulus / 挖洞盘的洞格不在盘上，按包围盒补洞会把格写进洞里（渲染找不到 Cell、
#     CP-SAT 索引错位），这是 shape_generator.gd:895-897 已经踩过的坑。
#   · 产物 cells = Dictionary[Vector2i -> true]（与 ShapeGenerator.dilate_cells / erode_cells
#     的格集同型，可直接串进形态学）。
#   · 失败一律 {ok:false, cells:{}, reason:<可读原因>}，**绝不**静默返回空格集冒充成功。
#
# 一处**刻意的策略不对称**（各有理由，测试逐条钉住）：
#   · text_to_cells：**任一格越界即整体拒绝**（不裁剪）。文字是一次完整「摆放」，裁掉半边字会让
#     落盘形状与所见不符——正是 shape_dag.gd:268 明令禁止的「静默降级出错几何 / 空几何」。
#     拒绝 + 可读原因（含越界格样例）把决定权交回调用方：挪 origin 或调小 scale。
#   · outline_to_cells：**裁剪**为「闭合多边形 ∩ 盘面」。手绘轮廓天然会画出盘边几格，
#     「区域与盘面求交」是它的自然语义；裁剪量不隐藏，写进结果 `clipped` 计数（可审计）。
#
# 与手绘落盘的口径一致（**分层纪律：本模块不依赖任何 UI 层脚本 / 场景**）：
#   唯一事实来源 = core/stroke_limits.gd（常量与 DP 纯函数）。手绘落盘侧 ui/drawing_layer.gd
#   的 SIMPLIFY_EPSILON / QUANT_STEP 只是它的**别名常量**，故两边口径不可能漂移
#   （两实现输出逐位相同由 test/unit/test_text_to_shape.gd 的对拍用例钉住）。
#   · 抽稀 = StrokeLimits.simplify_stroke（Douglas-Peucker），容差单位 = 棋盘单位（1 单位 = 1 格）；
#     tolerance ≤ 0 ⇒ 取 StrokeLimits.EPSILON（= 格宽的 5%），与手绘落盘同一枚常量。
#   · freehand DAG 参数表的坐标按 StrokeLimits.quantize_point 量化（quant = StrokeLimits.QUANT_STEP），
#     与 DrawingLayer.get_save_data() 的整数格点落盘格式同构。
class_name TextToShape
extends RefCounted

const SG := preload("res://core/shape_generator.gd")
const SL := preload("res://core/stroke_limits.gd")

## 字形点阵的字母表：**复用** ShapeGenerator.build_from_mask 的 mask 口径（单一真源，不另立字母表）。
##   有格 = SG.MASK_FILLED（"#X1"）；空 = SG.MASK_EMPTY（".0 "）。其余字符 = 数据错误 ⇒ 拒绝。
## 字形点阵形态（font_mask 的值）：Array[String]，每行等长；行索引 = 字形局部 y（向下），
##   列索引 = 字形局部 x（向右）。为什么只收点阵、不收整型位掩码：点阵的宽度由行长**唯一确定**，
##   而位掩码要额外约定「宽度从哪来 / 高位还是低位是第 0 列」，多一个约定就多一处跨模块漂移。
## 字符间距：每个字形后推进 GLYPH_GAP_CELLS 个「逻辑列」（再乘 scale），跨 scale 视觉一致。
const GLYPH_GAP_CELLS := 1


# ============================== ① 文字 → 格集 ==============================

## 文字点阵 → 盘内格集。
##
## 参数：
##   text      —— 要摆放的文字（可多字符；空串 ⇒ 拒绝）。
##   font_mask —— 纯数据「字符 → 点阵」：{字符: Array[String]}（见文件头字母表）。
##   scale     —— 每个点阵像素放大的格数（≥ 1）。
##   grid      —— 判界网格（GridInterface）；in_board() 是唯一的盘内判据。
##   origin    —— 摆放原点（可选，默认 (0,0) = 盘坐标左上）。文字从 origin 向右/下生长；
##                加它是为了让 UI 能把文字放到任意位置（4 参调用不受影响）。
## 返回 {ok, cells, reason}：
##   · ok=true  ⇒ cells 非空，且**每一格都满足 grid.in_board()**；
##   · ok=false ⇒ cells = {}（不留半成品），reason 可读（空串 / 未知字符 / 非法点阵 / 越界 / scale 非法）。
static func text_to_cells(text: String, font_mask: Dictionary, scale: int,
		grid: GridInterface, origin: Vector2i = Vector2i.ZERO) -> Dictionary:
	if grid == null:
		return _fail("网格为空：判界必须走 grid.in_board()（不得按包围盒猜盘内格）")
	if text.is_empty():
		return _fail("文字为空：空串不成形状（没有可栅格化的字符）")
	if scale < 1:
		return _fail("scale 必须 ≥ 1（收到 %d）：scale 是每个点阵像素放大的格数" % scale)
	# 先把**全部**字形校验完再栅格化：任一不合法 ⇒ 整体拒绝，不留半成品。
	var glyphs: Array = []
	for ch in text:
		var g: Dictionary = _glyph_rows(ch, font_mask)
		if not bool(g["ok"]):
			return _fail(str(g["reason"]))
		glyphs.append(g)
	# 逐字符摆放：pen_x 从左到右推进；越界格既不写入也不丢弃，而是**记账后整体拒绝**。
	var cells := {}
	var pen_x := 0
	var out_count := 0
	var samples: Array = []
	for gi in glyphs.size():
		var rows: Array = glyphs[gi]["rows"]
		var gw: int = int(glyphs[gi]["width"])
		for gy in rows.size():
			var row: String = rows[gy]
			for gx in gw:
				if not SG.MASK_FILLED.contains(row[gx]):
					continue
				for dy in scale:
					for dx in scale:
						var p := Vector2i(origin.x + pen_x + gx * scale + dx,
								origin.y + gy * scale + dy)
						if not grid.in_board(p):
							out_count += 1
							if samples.size() < 8:
								samples.append(p)
							continue
						cells[p] = true
		pen_x += gw * scale + GLYPH_GAP_CELLS * scale
	if out_count > 0:
		return _fail("文字越界：%d 格不在盘内（样例 %s）——文字是一次完整摆放，裁剪会让落盘与所见不符，故整体拒绝；请挪动 origin 或调小 scale" % [out_count, _fmt_positions(samples)])
	if cells.is_empty():
		return _fail("文字未产出任何格（点阵全空或全部越界）")
	return {"ok": true, "cells": cells, "reason": ""}


# ============================== ② 手绘轮廓 → 格集 ==============================

## 手绘点列 → 闭合多边形 → 栅格化格集（= 多边形 ∩ 盘面；裁剪量见 clipped）。
##
## 参数：
##   points    —— 笔画点列（棋盘坐标，1 单位 = 1 格）；首尾不必重复（闭合是隐含的）。
##   grid      —— 判界网格。产物每格都满足 grid.in_board()。
##   tolerance —— 抽稀容差（≥ 0，棋盘单位）；≤ 0 ⇒ 取 StrokeLimits.EPSILON（与手绘落盘同口径）。
## 返回 {ok, cells, reason, clipped, epsilon, simplified}：
##   · ok=true  ⇒ cells 非空（多边形在盘内的部分），clipped = 落在多边形内但不在盘上的格数；
##   · ok=false ⇒ cells = {}，reason 可读（点太少 / 自交 / 退化 / 盘内无格 / 网格为空）。
static func outline_to_cells(points: PackedVector2Array, grid: GridInterface,
		tolerance: float) -> Dictionary:
	if grid == null:
		return _fail("网格为空：判界必须走 grid.in_board()（不得按包围盒猜盘内格）")
	if points.size() < 3:
		return _fail("手绘轮廓至少需要 3 个点（收到 %d）：不足 3 点不成闭合多边形" % points.size())
	var dedup := _dedup_consecutive(points)
	if dedup.size() < 3:
		return _fail("去重后不足 3 个不同点（原始 %d 点，去重后 %d 点）：轮廓退化为点 / 线段" % [points.size(), dedup.size()])
	# 抽稀口径与手绘落盘一致：用 StrokeLimits.simplify_stroke（唯一事实来源），容差单位同为棋盘单位。
	# 容差 ≤ 0 表示「用缺省」，缺省值就是手绘落盘的那枚常量（StrokeLimits.EPSILON）。
	var eps := tolerance if tolerance > 0.0 else float(SL.EPSILON)
	var simplified: PackedVector2Array = SL.simplify_stroke(dedup, eps)
	if simplified.size() < 3:
		return _fail("按容差 %.6f 抽稀后不足 3 个点（原始 %d 点）：轮廓退化为线段" % [eps, points.size()])
	# 先判自交再判面积：蝴蝶结（bowtie）的有向面积为 0，但它的真因是自交，原因文字不能张冠李戴。
	var why := _find_self_intersection(simplified)
	if why != "":
		return _fail("轮廓自交：%s（自交多边形没有唯一内部，栅格化结果不可复现）" % why)
	if absf(_signed_area(simplified)) <= 1e-9:
		return _fail("轮廓面积为 0（顶点共线）：退化线段不可栅格化")
	# 栅格化：扫描窗用多边形包围盒（只是扫描范围），**是否成格**由「奇偶判据 ∧ grid.in_board()」决定。
	var cells := {}
	var clipped := 0
	var box := _poly_bbox(simplified)
	for y in range(box.position.y, box.end.y):
		for x in range(box.position.x, box.end.x):
			if not _poly_contains(simplified, Vector2(float(x), float(y))):
				continue
			var p := Vector2i(x, y)
			if not grid.in_board(p):
				clipped += 1
				continue
			cells[p] = true
	if cells.is_empty():
		return _fail("轮廓在盘内没有覆盖任何格（多边形可能整个落在盘外或洞上）")
	return {
		"ok": true, "cells": cells, "reason": "",
		"clipped": clipped, "epsilon": eps, "simplified": simplified,
	}


# ============================== ③ 给 ShapeDag 的纯数据参数表 ==============================
#
# 形状名逐字落在 shape_dag.gd 的 PRIMITIVE_SHAPES 内（"text" / "freehand"），**不改它**；
# params 只用 JSON 可存类型（String / int / float / bool / Array / Dictionary），
# 能原样过 ShapeDag.quantize_value 并往返落盘（test 里直接喂 add_primitive → to_dict → from_dict 验证）。
#
# 注意（不越界声明）：shape_dag.gd 的 primitive_to_builder("text"/"freehand") 目前仍返回 ok=false
# ——本模块提供的是「参数表 + 格集」，**不是** ShapeGenerator 的几何构建器；那条缺口不在本轮范围。

## 文字节点的纯数据参数表（配 ShapeDag.add_primitive(id, "text", params)）。
static func text_dag_params(text: String, scale: int, origin: Vector2i = Vector2i.ZERO) -> Dictionary:
	return {
		"kind": "text",
		"text": text,
		"scale": scale,
		"origin": {"x": origin.x, "y": origin.y},
	}


## 手绘节点的纯数据参数表（配 ShapeDag.add_primitive(id, "freehand", params)）。
## 坐标按 StrokeLimits 的落盘口径量化为整数格点（quant = StrokeLimits.QUANT_STEP），
## 与 DrawingLayer.get_save_data() 的笔画格式同构 ⇒「手绘落盘 → DAG 参数 → 落盘」全链路口径一致。
static func freehand_dag_params(points: PackedVector2Array, tolerance: float = -1.0) -> Dictionary:
	var eps := tolerance if tolerance > 0.0 else float(SL.EPSILON)
	var simplified: PackedVector2Array = SL.simplify_stroke(points, eps)
	var out_pts: Array = []
	for p in simplified:
		var q := SL.quantize_point(p)
		out_pts.append([q.x, q.y])
	return {
		"kind": "freehand",
		"points": out_pts,
		"quant": float(SL.QUANT_STEP),
		"tolerance": eps,
		"closed": true,
	}


# ============================== 内部实现 ==============================

## 取一个字符的点阵并校验（行长一致 / 只含字母表 / 至少一个填充格）。
## 返回 {ok, rows, width, reason}。不合法一律 ok=false + 可读原因（不静默跳过字符）。
static func _glyph_rows(ch: String, font_mask: Dictionary) -> Dictionary:
	if not font_mask.has(ch):
		return _bad("未知字符「%s」：font_mask 未提供其点阵（点阵须为 Array[String]，有格 = \"%s\"，空 = \"%s\"）" % [ch, SG.MASK_FILLED, SG.MASK_EMPTY])
	var v: Variant = font_mask[ch]
	if not (v is Array):
		return _bad("字形「%s」不是点阵数组（收到 %s）" % [ch, type_string(typeof(v))])
	var rows_v: Array = v
	if rows_v.is_empty():
		return _bad("字形「%s」的点阵为空（至少一行）" % ch)
	var width := -1
	for i in rows_v.size():
		if not (rows_v[i] is String):
			return _bad("字形「%s」第 %d 行不是字符串（收到 %s）" % [ch, i, type_string(typeof(rows_v[i]))])
		var row: String = rows_v[i]
		if width < 0:
			width = row.length()
		elif row.length() != width:
			return _bad("字形「%s」行长不一致（第 %d 行 %d 列，首行 %d 列）" % [ch, i, row.length(), width])
	if width == 0:
		return _bad("字形「%s」行长必须 ≥ 1（收到 0 列）" % ch)
	var filled := 0
	for i in rows_v.size():
		var row: String = rows_v[i]
		for c in width:
			var g := row[c]
			if SG.MASK_FILLED.contains(g):
				filled += 1
			elif not SG.MASK_EMPTY.contains(g):
				return _bad("字形「%s」第 %d 行第 %d 列含非法字符「%s」（有格 = \"%s\"，空 = \"%s\"）" % [ch, i, c, g, SG.MASK_FILLED, SG.MASK_EMPTY])
	if filled == 0:
		return _bad("字形「%s」没有任何填充格（全空点阵）⇒ 不成形状" % ch)
	return {"ok": true, "rows": rows_v, "width": width, "reason": ""}


## 去掉相邻重复点 + 首尾重复（显式闭合环写法）：采样抖动 / 手写闭合不该被当成几何。
static func _dedup_consecutive(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if out.size() > 0 and out[out.size() - 1].distance_squared_to(p) <= 1e-12:
			continue
		out.append(p)
	while out.size() >= 2 and out[0].distance_squared_to(out[out.size() - 1]) <= 1e-12:
		out.remove_at(out.size() - 1)
	return out


## 找第一条与后续非相邻段相交的段。无自交返回 ""；否则返回可读原因。
## 相邻段共享端点（同一条折线的前后段）天然共点，跳过；首段与末段的「闭合相邻」也跳过。
static func _find_self_intersection(poly: PackedVector2Array) -> String:
	var n := poly.size()
	for i in n:
		var a1: Vector2 = poly[i]
		var a2: Vector2 = poly[(i + 1) % n]
		for j in range(i + 1, n):
			if j == i + 1 or (i == 0 and j == n - 1):
				continue
			var b1: Vector2 = poly[j]
			var b2: Vector2 = poly[(j + 1) % n]
			if _segments_intersect(a1, a2, b1, b2):
				return "第 %d 段 %s→%s 与第 %d 段 %s→%s 相交" % [
					i, _fmt_vec(a1), _fmt_vec(a2), j, _fmt_vec(b1), _fmt_vec(b2)]
	return ""


## 线段相交（含端点落在另一段上的共线接触）：非相邻段的任何接触都算自交 / 退化。
static func _segments_intersect(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> bool:
	var d1 := _cross(b2 - b1, a1 - b1)
	var d2 := _cross(b2 - b1, a2 - b1)
	var d3 := _cross(a2 - a1, b1 - a1)
	var d4 := _cross(a2 - a1, b2 - a1)
	if ((d1 > 0.0 and d2 < 0.0) or (d1 < 0.0 and d2 > 0.0)) \
			and ((d3 > 0.0 and d4 < 0.0) or (d3 < 0.0 and d4 > 0.0)):
		return true
	if is_zero_approx(d1) and _on_segment(b1, b2, a1):
		return true
	if is_zero_approx(d2) and _on_segment(b1, b2, a2):
		return true
	if is_zero_approx(d3) and _on_segment(a1, a2, b1):
		return true
	if is_zero_approx(d4) and _on_segment(a1, a2, b2):
		return true
	return false


static func _cross(u: Vector2, v: Vector2) -> float:
	return u.x * v.y - u.y * v.x


## 已知 p 与线段 ab 共线时的「落在线段内」判定（包围盒口径，整数坐标下无浮点误差放大）。
static func _on_segment(a: Vector2, b: Vector2, p: Vector2) -> bool:
	return p.x >= minf(a.x, b.x) and p.x <= maxf(a.x, b.x) \
			and p.y >= minf(a.y, b.y) and p.y <= maxf(a.y, b.y)


## 闭合多边形的有向面积 ×2（鞋带公式）。>0 逆时针、<0 顺时针、≈0 退化。
static func _signed_area(poly: PackedVector2Array) -> float:
	var s := 0.0
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		s += pj.x * pi.y - pi.x * pj.y
		j = i
	return s


## 点是否在多边形内（射线法 / 奇偶规则，凹凸皆可）。
## 与 ShapeGenerator._poly_contains 同一判据、同一口径；本模块自持一份是因为 shape_generator.gd
## 只读、其 `_rasterize_polygon` / `_poly_contains` 是私有实现（跨模块调私有方法会造成隐藏耦合）。
static func _poly_contains(poly: PackedVector2Array, p: Vector2) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var den := pj.y - pi.y
			if is_zero_approx(den):
				den = 1e-9
			if p.x < (pj.x - pi.x) * (p.y - pi.y) / den + pi.x:
				inside = not inside
		j = i
	return inside


## 多边形顶点包围盒的整数扫描窗（floor/ceil，无 margin——判据只看格心，不做弧线凸出补偿）。
static func _poly_bbox(poly: PackedVector2Array) -> Rect2i:
	var min_x := 1 << 30
	var min_y := 1 << 30
	var max_x := -(1 << 30)
	var max_y := -(1 << 30)
	for v: Vector2 in poly:
		min_x = mini(min_x, floori(v.x))
		min_y = mini(min_y, floori(v.y))
		max_x = maxi(max_x, ceili(v.x))
		max_y = maxi(max_y, ceili(v.y))
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


static func _fail(reason: String) -> Dictionary:
	return {"ok": false, "cells": {}, "reason": reason}


static func _bad(reason: String) -> Dictionary:
	return {"ok": false, "rows": [], "width": 0, "reason": reason}


static func _fmt_positions(ps: Array) -> String:
	var parts := PackedStringArray()
	for p: Vector2i in ps:
		parts.append("(%d,%d)" % [p.x, p.y])
	return "[" + ", ".join(parts) + "]"


static func _fmt_vec(v: Vector2) -> String:
	return "(%.1f,%.1f)" % [v.x, v.y]
