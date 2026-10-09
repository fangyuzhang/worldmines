# coloring_preview.gd —— 变体专用辅助工具的两块纯逻辑（文档 §5）
#   ① 四象 / 染色预览：把盘内格按**四象**分为 4 个象限 + 中轴，给出每格的预览色号；
#   ② 行容量侧栏：按行统计"这一行有多少格 / 已放几颗雷 / 能不能达到目标"，并给出不可行原因。
#
# 【单一事实来源：四象划分绝不再实现一遍】
#   象限划分调用 `core/constraint_engine.gd` 的 `quadrant_of(r, c, rows, cols)` —— 那是校验器
#   （ConstraintEngine._check_qd）、规则平台（QdRule）、生成器共用的同一枚原语
#   （constraint_engine.gd:109 明令"禁止各自手写划分"；历史上三处各自实现曾出现偶数盘语义冲突）。
#   本模块只做"把象限变成色号"的呈现映射，不重复几何判断。
#
# 【网格门禁：直接消费 VariantGridMatrix，不自己猜】
#   四象 / 行容量都长在**矩形行列**语义上：六边形 / 三角形 / Voronoi 上"象限""行"没有几何对应。
#   本模块用 `VariantGridMatrix.status(variant_id, grid_kind)` 判可不可用（唯一事实源），
#   被禁的组合一律 ok=false + 矩阵给的可读原因 —— 与 `EditorVerify.variant_grid_issues()` 同口径。
#
# 【纯逻辑】不引用 UI / 引擎绘制 / autoload；颜色只是数据（UI 自己决定怎么涂）。
class_name ColoringPreview
extends RefCounted

const CE := preload("res://core/constraint_engine.gd")
const MATRIX := preload("res://core/variant_grid_matrix.gd")
const VERIFY := preload("res://core/editor_verify.gd")

## 四象的变体 id（与 VariantRegistry / hint_solver 的 "qd" 同源）。
const V_QUADRANT := "qd"
## 行语义的变体 id：纵横分计（hv）本来就要求"按行 / 按列"分计 ⇒ 它可用即可用。
const V_ROW := "hv"

## 中轴格（`quadrant_of` 返回 -1：奇数盘的正中行 / 正中列）的色号。
const AXIS_LEVEL := 4
## 象限数（左上 / 右上 / 左下 / 右下）。
const QUADRANT_COUNT := 4

## 预览色（**硬编码**：主题里没有"每象限一色"的槽位，与 ui/level_editor.gd 的 ISSUE_LEVEL_UI 同理）。
## 透明度刻意压低（≤0.42）⇒ 底下的格型 / 数字仍然看得见 —— 预览层不许盖住编辑内容。
const QUADRANT_COLORS: Array[Color] = [
	Color(0.91, 0.30, 0.24, 0.32),   # 左上：红
	Color(0.97, 0.74, 0.16, 0.32),   # 右上：琥珀
	Color(0.22, 0.60, 0.88, 0.32),   # 左下：蓝
	Color(0.28, 0.72, 0.42, 0.32),   # 右下：绿
	Color(0.66, 0.45, 0.92, 0.42),   # 中轴（不动点）：紫
]


## 色号 → 预览色（给 UI / 叠加层用；越界色号 ⇒ 全透明，绝不假装知道）。
static func color_of(level: int) -> Color:
	if level < 0 or level >= QUADRANT_COLORS.size():
		return Color(0, 0, 0, 0)
	return QUADRANT_COLORS[level]


## 色号 → 叠加层用的颜色表 `{level: Color}`（画布叠加 API 的 `opts.colors` 直接吃）。
static func color_table() -> Dictionary:
	var out: Dictionary = {}
	for i in QUADRANT_COLORS.size():
		out[i] = QUADRANT_COLORS[i]
	return out


## 四象染色预览。
##
## 参数：
##   grid      —— 判界网格（盘内/盘外一律问它，禁止包围盒）；
##   positions —— 要上色的格（通常是 `grid.all_positions()`；不在盘上的格会被**忽略并计数**）；
##   grid_kind —— 当前网格族（`EditorVerify.grid_kind_of(doc)` 的口径）。
## 返回：
##   {ok, cells: {Vector2i -> {level:int, axis:bool}}, counts: Array[int]（4 象限 + 中轴）,
##    off_board: Array[Vector2i]（被忽略的盘外格）, grid_kind: String, reason: String}
##   · ok=true  ⇒ cells 里每一格都满足 grid.in_board()，且 level ∈ 0..AXIS_LEVEL；
##   · ok=false ⇒ cells 为空，reason 来自矩阵（网格族上四象语义未定义）。
static func quadrant_preview(grid: GridInterface, positions: Array, grid_kind: String) -> Dictionary:
	if grid == null:
		return _fail("网格为空：判界必须走 grid.in_board()（不得按包围盒猜盘内格）")
	var st := MATRIX.status(V_QUADRANT, grid_kind)
	if st != MATRIX.OK:
		var why := MATRIX.reason(V_QUADRANT, grid_kind).strip_edges()
		if why == "":
			why = "矩阵未给出理由（状态 %s）" % st
		return _fail("网格族「%s」上四象语义未定义（见变体×网格兼容矩阵）：%s" % [grid_kind, why])

	var size: Vector2i = grid.size()
	var rows := size.y
	var cols := size.x
	if rows <= 0 or cols <= 0:
		return _fail("网格尺寸异常（%d×%d）：四象需要行列轴才谈得上" % [rows, cols])

	var cells: Dictionary = {}
	var counts: Array = [0, 0, 0, 0, 0]
	var off_board: Array[Vector2i] = []
	for raw in positions:
		if not (raw is Vector2i):
			continue
		var p: Vector2i = raw
		if not grid.in_board(p):
			off_board.append(p)
			continue
		var qi := int(CE.quadrant_of(p.y, p.x, rows, cols))
		var level := AXIS_LEVEL if qi < 0 else qi
		cells[p] = {"level": level, "axis": qi < 0, "quadrant": qi}
		counts[level] = int(counts[level]) + 1
	return {
		"ok": true, "cells": cells, "counts": counts, "off_board": off_board,
		"grid_kind": grid_kind, "reason": "",
	}


## 一句话说明（UI 直接显示；确定性字符串）。
static func describe_quadrants(rep: Dictionary) -> String:
	if not bool(rep.get("ok", false)):
		return "四象预览不可用：%s" % str(rep.get("reason", ""))
	var c: Array = rep.get("counts", [])
	var parts: Array[String] = []
	var names := ["左上", "右上", "左下", "右下"]
	for i in QUADRANT_COUNT:
		parts.append("%s %d 格" % [names[i], int(c[i]) if i < c.size() else 0])
	var axis := int(c[AXIS_LEVEL]) if c.size() > AXIS_LEVEL else 0
	var ax := "、中轴 %d 格" % axis if axis > 0 else "、无中轴（偶数盘）"
	var extra := ""
	if not (rep.get("off_board", []) as Array).is_empty():
		extra = "；已忽略 %d 个盘外格" % (rep["off_board"] as Array).size()
	return "四象染色：%s%s%s" % ["、".join(parts), ax, extra]


## 行容量报告（§5「行容量侧边栏：每行目标雷数 + 可行性预检」）。
##
## 参数：
##   grid    —— 判界网格；
##   target  —— 每行目标雷数（UI 用一个 SpinBox 给同一个目标；负数非法）；
##   mines   —— 当前雷位（盘外的会被忽略并计数）；
##   grid_kind —— 当前网格族（行语义未定义的格子族一律拒绝）。
## 返回：
##   {ok, rows: [{y, capacity, mines, remaining, target, feasible, reason}], infeasible: Array[int],
##    total_capacity, total_mines, total_target, ignored_mines, grid_kind, reason}
##   · 行按 y 升序；`capacity` = 该行的**盘内**格数（洞格不算容量）；
##   · feasible 判据（三条，全部给可读原因）：
##       ① target < 0                       ⇒ 目标非法；
##       ② target > capacity                ⇒ 这一行格数不够；
##       ③ 已放雷数 > target                ⇒ 已经超出目标。
static func row_report(grid: GridInterface, target: int, mines: Array, grid_kind: String) -> Dictionary:
	if grid == null:
		return _fail("网格为空：判界必须走 grid.in_board()（不得按包围盒猜盘内格）")
	var st := MATRIX.status(V_ROW, grid_kind)
	if st != MATRIX.OK:
		var why := MATRIX.reason(V_ROW, grid_kind).strip_edges()
		if why == "":
			why = "矩阵未给出理由（状态 %s）" % st
		return _fail("网格族「%s」上没有「行」这个几何量（见变体×网格兼容矩阵）：%s" % [grid_kind, why])

	var cap: Dictionary = {}
	for p: Vector2i in grid.all_positions():
		cap[p.y] = int(cap.get(p.y, 0)) + 1
	var placed: Dictionary = {}
	var ignored := 0
	for raw in mines:
		if not (raw is Vector2i):
			continue
		var m: Vector2i = raw
		if not grid.in_board(m):
			ignored += 1
			continue
		placed[m.y] = int(placed.get(m.y, 0)) + 1

	var ys: Array = cap.keys()
	ys.sort()
	var rows: Array = []
	var infeasible: Array = []
	var total_target := 0
	var total_mines := 0
	for y: int in ys:
		var capacity := int(cap[y])
		var got := int(placed.get(y, 0))
		var feasible := true
		var row_reason := ""
		if target < 0:
			feasible = false
			row_reason = "目标雷数不能是负数（收到 %d）" % target
		elif target > capacity:
			feasible = false
			row_reason = "这一行只有 %d 个盘内格，放不下 %d 颗雷" % [capacity, target]
		elif got > target:
			feasible = false
			row_reason = "这一行已经放了 %d 颗雷，超过目标 %d" % [got, target]
		if not feasible:
			infeasible.append(y)
		rows.append({
			"y": y, "capacity": capacity, "mines": got, "remaining": maxi(0, capacity - got),
			"target": target, "feasible": feasible, "reason": row_reason,
		})
		total_target += target
		total_mines += got
	return {
		"ok": true, "rows": rows, "infeasible": infeasible,
		"total_capacity": grid.cell_count(), "total_mines": total_mines,
		"total_target": total_target, "ignored_mines": ignored,
		"grid_kind": grid_kind, "reason": "",
	}


## 一句话摘要（UI 侧边栏用）。
static func describe_rows(rep: Dictionary) -> String:
	if not bool(rep.get("ok", false)):
		return "行容量不可用：%s" % str(rep.get("reason", ""))
	var rows: Array = rep.get("rows", [])
	var bad: Array = rep.get("infeasible", [])
	var head := "行容量：%d 行，每行目标 %d 颗；当前已放 %d 颗" % [
		rows.size(),
		int((rows[0] as Dictionary).get("target", 0)) if not rows.is_empty() else 0,
		int(rep.get("total_mines", 0)),
	]
	if bad.is_empty():
		return head + " ⇒ 每行都放得下（可用格数足够）"
	var ys: Array[String] = []
	for y in bad:
		ys.append(str(y))
	return head + " ⇒ %d 行不可行（第 %s 行）" % [bad.size(), "、".join(ys)]


static func _fail(reason: String) -> Dictionary:
	return {
		"ok": false, "cells": {}, "counts": [], "off_board": [], "rows": [], "infeasible": [],
		"grid_kind": "", "reason": reason,
	}
