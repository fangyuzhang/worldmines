# ripple_rings.gd —— 「开格波浪」按图距离分环（纯逻辑：无渲染、无节点、无全局状态）
#
# 为什么存在（移植一份动效规范时的核心修正）：
# 涟漪必须按**图距离**分环，不能按泛洪（flood fill）的出队序号。泛洪的出队序号在 8 邻
# 棋盘上会沿固定扫描顺序斜着推进，视觉上波纹变成一条**螺旋**而不是一圈扩散的波。
# 所以这里显式做 BFS，把每一层新发现的格子收集成一环；环内元素顺序不影响观感
# （同一环内的延迟相同）。
#
# 时间模型（刻意设计，勿"顺手修正"成 delay(d)=d*WS）：
#   delay(d) = 0                d <= 1
#   delay(d) = (d - 1) * WS     d >= 2
# 即第 0 环（起点自身）与第 1 环（紧邻一圈）**同时开始**：起点的弹跳与邻格的平移本
# 就是一个整体动作；只有从第 2 环起才按每环 WS 秒逐环级联。
#
# 拓扑无关：邻接关系由调用方以 Callable 传入（矩形 8 邻 / 六边形 / 异形邻接表皆可），
# 本模块只负责 BFS，并自行校验越界与去重（调用方的邻接表不保证干净）。
class_name RippleRings
extends RefCounted


## 按图距离分环。返回环数组：
##   rings[0] = [start]（起点自身，单元素）
##   rings[1] = 第一环；rings[2] = 第二环；…
##
## 参数：
##   start     —— 起点
##   size      —— 棋盘尺寸（x = 列数，y = 行数）
##   neighbors —— 邻接关系，形如 func(pos: Vector2i) -> Array[Vector2i]；
##                调用方可能不过滤越界/重复，故本模块会再校验一遍
##   max_rings —— 安全上限（默认 64），防止环形/异常拓扑下无限扩散；
##                结果最多 max_rings + 1 个环
##
## 起点越界或 size 非正时返回空数组。
static func build(start: Vector2i, size: Vector2i, neighbors: Callable,
		max_rings: int = 64) -> Array:
	var rings: Array = []
	if size.x <= 0 or size.y <= 0:
		return rings
	if not _in_board(start, size):
		return rings

	rings.append([start])
	var visited: Dictionary = {start: true}    # 键 = Vector2i
	var frontier: Array = [start]
	for d in range(1, max_rings + 1):
		var next: Array = []
		for p in frontier:
			var nbs: Variant = neighbors.call(p)
			if nbs == null:
				continue
			for raw in nbs:
				if not (raw is Vector2i):
					continue
				var q: Vector2i = raw
				if visited.has(q) or not _in_board(q, size):
					continue
				visited[q] = true
				next.append(q)
		if next.is_empty():
			break          # 已覆盖到边界，扩散结束
		rings.append(next)
		frontier = next
	return rings


## 本动效的时间模型：环 d 相对起点的开始延迟（秒）。
##   delay(0) = delay(1) = 0 —— 起点与第一环同时开始（刻意设计，见文件头）
##   delay(d) = (d - 1) * ws （d >= 2）
static func delay_of(ring: int, ws: float) -> float:
	if ring <= 1:
		return 0.0
	return float(ring - 1) * ws


## 环总数（rings[0] 计作一环）。小工具，避免调用处到处写 rings.size()。
static func total_rings(rings: Array) -> int:
	return rings.size()


static func _in_board(pos: Vector2i, size: Vector2i) -> bool:
	return pos.x >= 0 and pos.x < size.x and pos.y >= 0 and pos.y < size.y
