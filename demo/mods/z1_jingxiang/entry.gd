# entry.gd —— Z1「镜像」（v3.0 GDD §4.2 Z1 / §4.5）
#
# 规则（KIND_GLOBAL）：棋盘的左半部分与右半部分逐格对称——第 j 列与倒数第 j 列的雷分布完全相同：
#     K = { B : B_{i,j} = B_{i,C−1−j}, ∀ i, j }
#
# 作用域：拓扑（列对称）。推理手感（GDD §4.5 原文）：严格说本算子会**降低**推理量（确定左半即可
# 推出右半），但其教学价值与视觉辨识度不可替代——玩家一眼即可识别对称结构，**规则零学习成本**。
# 评分 C3 F2 L5 G4 D2。
#
# 一个必须记住的蕴含（GDD）：镜像严格蕴含「列雷数对称」，因此与任何基于列雷数序列的算子叠加
# 都会退化；与行列同序（Z4）叠加时会强制行雷数序列呈**回文结构**（见 C03）。
#
# 本插件与内置 `mx`（镜像）等价——独立成 `z1` 是为总表「镜像（底座：经典）」集合提供稳定 id
# （自举式规则平台：平台能做到的创作者也能做到）。
#
# 构造式布雷（R03 红线）：**左半区采样 + 镜像**；列数为奇数时**中轴列单独处理**
#（中轴格不参与镜像配对，其雷数计入总雷数）。
extends RefCounted


class MirrorRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"z1"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {
			"name": "镜像",
			"rule_text": "雷的分布左右完全对称",
		}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows:
			for c in int(b.cols / 2):
				b.add_eq(b.cell_var(r, c), b.cell_var(r, b.cols - 1 - c))

	## 构造式布雷：左半 k 颗 + 镜像（共 2k）+ 中轴 j 颗（奇数列时），2k + j = count。
	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		if count <= 0 or count > cols * rows:
			return []
		var has_axis := (cols % 2 == 1)
		var left: Array[Vector2i] = []
		var axis: Array[Vector2i] = []
		for r in rows:
			for c in int(cols / 2):
				left.append(Vector2i(c, r))
			if has_axis:
				axis.append(Vector2i(cols / 2, r))
		# 收集全部合法 (k, j)：2k + j = count
		var options: Array = []
		for j in range(axis.size() + 1):
			if j > count:
				break
			var rem := count - j
			if rem % 2 != 0:
				continue
			var k := rem / 2
			if k > left.size():
				continue
			options.append([k, j])
		if options.is_empty():
			return []
		var pick: Array = options[rng.randi_range(0, options.size() - 1)]
		var mines := {}
		for m in _sample(rng, left, int(pick[0])):
			mines[m] = true
			mines[Vector2i(cols - 1 - m.x, m.y)] = true
		for m in _sample(rng, axis, int(pick[1])):
			mines[m] = true
		var out: Array[Vector2i] = []
		for m in mines:
			out.append(m)
		return out

	static func _sample(rng: RandomNumberGenerator, cells: Array, k: int) -> Array:
		if k <= 0:
			return []
		var pool := cells.duplicate()
		for i in range(pool.size() - 1, 0, -1):
			var j := rng.randi_range(0, i)
			var t = pool[i]
			pool[i] = pool[j]
			pool[j] = t
		var out: Array = []
		for i in mini(k, pool.size()):
			out.append(pool[i])
		return out

	## 全盘复核：左右逐格对称（独立于生成过程的终检）。
	static func _ok(mines: Array[Vector2i], cols: int, rows: int) -> bool:
		var ms := {}
		for m in mines:
			ms[m] = true
		for r in rows:
			for c in int(cols / 2):
				if ms.has(Vector2i(c, r)) != ms.has(Vector2i(cols - 1 - c, r)):
					return false
		return true


func on_load() -> void:
	RuleRegistry.default().register(MirrorRule.new())
