# core/stroke_limits.gd —— 手绘笔迹 / 轮廓的几何常量与 Douglas-Peucker 抽稀（纯函数，**唯一事实来源**）。
#
# 为什么单独成模块（分层纪律，2026-10-04）：
#   这些常量原本长在 ui/drawing_layer.gd（UI 层），但 core/text_to_shape.gd（纯逻辑层）也要用同一套
#   抽稀容差 / 量化步长。若 core 直接 preload ui/**，就是**分层倒置**（纯逻辑上下文被拖进 UI 代码）。
#   故把「值 + 推导注释」整体上移到 core 作为唯一事实来源；ui 侧只做**别名常量**
#   （见 ui/drawing_layer.gd 常量段：`const SIMPLIFY_EPSILON := StrokeLimitsScript.EPSILON`），
#   于是所有既有调用点一字不改、口径也不可能漂移（值只在这里定义一次）。
#
# 手绘落盘口径（原注释**原样保留**，搬移不改语义）：
#   · 抽稀容差（单位 = 棋盘坐标）。棋盘坐标口径见 board_view._unit_px() 与文件头：
#     **1 棋盘单位 = 1 格**（矩形/蜂窝/自定义盘同构），不新造概念。
#     取格宽的 5%（= 0.05 格）：小于此幅度的抖动在单格内视觉不可辨、可抹掉，
#     又不至于把一格内的转折形状改走样（对应"格宽的 5% 左右"）。
#   · 落盘坐标量化步长。原落盘坐标精度约定 1e-4：按步长取整后最大误差 = 步长/2 = 5e-5 ≤ 1e-4，
#     与原精度兼容；落盘存整数格点而非浮点 ⇒ 同一笔画跨机器/跨次加载结果逐位一致。
#
# DP 两份实现的**等价性依据**（对拍测试：test/unit/test_text_to_shape.gd 的
# test_stroke_limits_match_drawing_layer_bit_for_bit）：
#   本模块的 simplify_stroke / _point_segment_distance 与 ui/drawing_layer.gd:480 起的同名函数是
#   **逐行同源**的两份拷贝：同样的显式栈（不用递归，避免数千点爆栈）、同样的 `max_d > epsilon`
#   严格判据、同样的点到**线段**距离（t 夹在 [0,1]，端点附近不放大误差）、同样保留首尾、
#   同样在 `n <= 2 or epsilon <= 0` 时原样返回副本 ⇒ 输出逐位相同（对拍钉住）。
#   两份并存的原因：ui 侧要保留既有公开 API / 全部调用点不动；core 侧要能在不依赖 UI 的前提下
#   独立使用。**值只由本模块提供**，故两实现不会因常量漂移而分叉。
class_name StrokeLimits
extends RefCounted

## 棋盘坐标与格的换算：1 棋盘单位 = 1 格。
const BOARD_UNIT_PER_CELL := 1.0
## 抽稀容差 = 格宽的 5%（推导见文件头；与手绘落盘同一枚值）。
const EPSILON := BOARD_UNIT_PER_CELL * 0.05
## 落盘坐标量化步长 = 1e-4（推导见文件头）。
const QUANT_STEP := 1e-4


## Douglas-Peucker 抽稀（纯函数）：保留「首尾 + 偏离超容差的拐点」。
## epsilon <= 0 或点数 ≤ 2 时原样返回副本（不被调用方改动串味）。
static func simplify_stroke(points: PackedVector2Array, epsilon: float) -> PackedVector2Array:
	var n := points.size()
	if n <= 2 or epsilon <= 0.0:
		return points.duplicate()
	var keep := PackedByteArray()
	keep.resize(n)  # resize 后默认全 0
	keep[0] = 1
	keep[n - 1] = 1
	# 显式栈代替递归：单笔可达数千点，递归深度最坏 = 点数，会爆栈。
	var stack: Array = [[0, n - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var i: int = seg[0]
		var j: int = seg[1]
		if j <= i + 1:
			continue
		var max_d := -1.0
		var max_i := -1
		for k in range(i + 1, j):
			var d := _point_segment_distance(points[k], points[i], points[j])
			if d > max_d:
				max_d = d
				max_i = k
		if max_d > epsilon and max_i > i:
			keep[max_i] = 1
			stack.append([i, max_i])
			stack.append([max_i, j])
	var out := PackedVector2Array()
	for i in n:
		if keep[i] == 1:
			out.append(points[i])
	return out


## 点到**线段**的最短距离（DP 的偏离度量）。比"到无限直线"稳：端点附近不会放大误差。
static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 <= 0.000000000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 坐标量化（落盘用）：棋盘坐标 → 步长 QUANT_STEP 的整数格点（四舍五入）。
static func quantize_point(p: Vector2) -> Vector2i:
	return Vector2i(roundi(p.x / QUANT_STEP), roundi(p.y / QUANT_STEP))


## 反量化：整数格点 → 棋盘坐标。与 quantize_point 的往返误差 ≤ QUANT_STEP/2。
static func dequantize_point(q: Vector2i) -> Vector2:
	return Vector2(float(q.x) * QUANT_STEP, float(q.y) * QUANT_STEP)
