# clue_engine.gd —— 线索函数引擎（文档附 A.3 的 7 个线索型 + 经典）
# 线索值统一用 Variant：int（单值）、Array[A, B]（HV 双值）、String "inf"（FR 无雷哨兵）。
# 坐标约定：内部 Vector2i(col, row) = Vector2i(c, r)，即 x=列、y=行。
# mine_set 用 Dictionary（Vector2i -> true）便于 O(1) 查询。
class_name ClueEngine
extends RefCounted

enum Variant {
	CLASSIC,    # 经典 8 邻求和，0~8
	N4,         # C1 四邻（正交），0~4
	CLOCK,      # C2 钟点（8 邻顺时针首个雷方位），0~8
	HV,         # C3 纵横分计（正交|对角），双值 [A, B]
	FR,         # C4 首雷（向右射线），number | "inf"
	LOOP_RUNS,  # C5 环游程（8 邻环序连续雷段数），0~4
	DIST_SUM,   # C6 曼哈顿和（正交×1 + 对角×2），0~12
	SAME_COLOR, # C7 同色（对角邻居），0~4
}


## 方位序（文档 §A.3 C2/C5）：从正上开始顺时针 1~8。
## 返回数组顺序固定为 [上, 右上, 右, 右下, 下, 左下, 左, 左上]（对应 Clock 编号 1~8、LoopRuns 环序）。
static func ring_dirs() -> Array[Vector2i]:
	return [
		Vector2i(0, -1),   # 1 上
		Vector2i(1, -1),   # 2 右上
		Vector2i(1, 0),    # 3 右
		Vector2i(1, 1),    # 4 右下
		Vector2i(0, 1),    # 5 下
		Vector2i(-1, 1),   # 6 左下
		Vector2i(-1, 0),   # 7 左
		Vector2i(-1, -1),  # 8 左上
	]


## 正交四邻（上下左右）。
static func orthogonal_dirs() -> Array[Vector2i]:
	return [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]


## 对角四邻（左上、右上、左下、右下）。
static func diagonal_dirs() -> Array[Vector2i]:
	return [Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]


## DistSum 加权方向：正交（权重 1）+ 对角（权重 2）。返回 [dirs, weights]。
static func dist_sum_dirs_weights() -> Array:
	return [
		orthogonal_dirs() + diagonal_dirs(),
		[1, 1, 1, 1, 2, 2, 2, 2],
	]


## 计算线索值。返回 Variant（int / Array / String）。
static func compute(variant: int, mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
	match variant:
		Variant.N4:
			return _count_dirs(mine_set, pos, grid_size, orthogonal_dirs())
		Variant.CLOCK:
			return _clock_value(mine_set, pos, grid_size)
		Variant.HV:
			return [_count_dirs(mine_set, pos, grid_size, orthogonal_dirs()), _count_dirs(mine_set, pos, grid_size, diagonal_dirs())]
		Variant.FR:
			return _fr_value(mine_set, pos, grid_size)
		Variant.LOOP_RUNS:
			return _loop_runs_value(mine_set, pos, grid_size)
		Variant.DIST_SUM:
			return _count_dirs(mine_set, pos, grid_size, orthogonal_dirs()) + 2 * _count_dirs(mine_set, pos, grid_size, diagonal_dirs())
		Variant.SAME_COLOR:
			return _same_color_value(mine_set, pos, grid_size)
		_:
			return _count_dirs(mine_set, pos, grid_size, ring_dirs())


static func _count_dirs(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i, dirs: Array) -> int:
	var n := 0
	for d in dirs:
		var p: Vector2i = pos + (d as Vector2i)
		if _in_board(p, grid_size) and mine_set.has(p):
			n += 1
	return n


## Clock：8 邻按顺时针从正上编号，返回第一颗雷的方位编号（1~8），无雷=0。
## 边界处理：跳过不存在的格子继续顺时针编号（文档 §A.3 C2）。
static func _clock_value(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> int:
	for i in ring_dirs().size():
		var p := pos + ring_dirs()[i]
		if not _in_board(p, grid_size):
			continue
		if mine_set.has(p):
			return i + 1
	return 0


## 变体「0 值 ⟹ 邻域全安全」的**权威定义（单点，v2.9.3）**。
##
## 为什么必须单点：这条语义散落过 4 处（board 扩散 / hint 零值特判 / 规则
## zero_safe_neighbors / clue_engine 各自实现），新增变体时极易漏改一处 → 漂移。
## 规则关卡走 RulePlugin.zero_safe_neighbors（每个规则自己声明，同一契约）；
## 本函数是**内置变体**路径的对应单点，二者语义一致。
##
## 返回该变体在本格线索值下「保证安全」的方向集合；空数组 = 永不扩散。
## 调用方负责：过滤已翻开/?格、按盘面边界裁剪、去重。
static func zero_safe_dirs(variant: int, value: Variant) -> Array[Vector2i]:
	# 注意：必须逐分支构造**带类型的** Array[Vector2i]。ring_dirs()/orthogonal_dirs()/
	# diagonal_dirs() 返回的是无类型 Array，直接 return 会破坏 Array[Vector2i] 契约，
	# 调用方（board._append_flood_dirs）会报 "does not have the same element type"。
	var out: Array[Vector2i] = []
	match variant:
		Variant.FR:
			# 0 = 「右邻必雷」，语义与雷数无关，故永不扩散
			return out
		Variant.N4:
			if _is_zero_value(value):
				out.append_array(orthogonal_dirs())
			return out
		Variant.SAME_COLOR:
			if _is_zero_value(value):
				out.append_array(diagonal_dirs())
			return out
		Variant.HV:
			# 双分量：任一分量 0 就扩散对应的那一组（两个都 0 时并集即 8 邻）
			if value is Array and (value as Array).size() >= 2:
				if int(value[0]) == 0:
					out.append_array(orthogonal_dirs())
				if int(value[1]) == 0:
					out.append_array(diagonal_dirs())
			return out
		_:
			# CLASSIC / CLOCK / LOOP_RUNS / DIST_SUM：值 0 ⟹ 8 邻无雷
			if _is_zero_value(value):
				out.append_array(ring_dirs())
			return out


## 线索值是否为「零」（仅 int 型；HV 的 Array 与 FR 的 "inf" 不在此列）。
static func _is_zero_value(value: Variant) -> bool:
	return value is int and int(value) == 0


## FR：向右逐格扫描，返回到第一颗雷之间的安全格数；无雷返回 "inf"。
static func _fr_value(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
	var c := pos.x
	while c + 1 < grid_size.x:
		c += 1
		var p := Vector2i(c, pos.y)
		if mine_set.has(p):
			return c - pos.x - 1
	return "inf"


## LoopRuns：8 邻环序（首尾相接）的连续雷段数。
static func _loop_runs_value(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> int:
	# 收集环上实际存在的格子的雷状态（按环序，跳过越界格）
	var seq: Array[int] = []
	for d in ring_dirs():
		var p := pos + d
		if _in_board(p, grid_size):
			seq.append(1 if mine_set.has(p) else 0)
	if seq.is_empty():
		return 0
	# 环形：首尾相接，统计"0->1 上升沿"数量，即连续雷段数
	var runs := 0
	for i in seq.size():
		var prev: int = seq[(i - 1 + seq.size()) % seq.size()]
		var cur: int = seq[i]
		if prev == 0 and cur == 1:
			runs += 1
	return runs


## SC 同色：8 邻中与本格同色（对角）的雷数。同色 = (r+c) mod 2 相同。
static func _same_color_value(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> int:
	return _count_dirs(mine_set, pos, grid_size, diagonal_dirs())


static func _in_board(pos: Vector2i, grid_size: Vector2i) -> bool:
	return pos.x >= 0 and pos.x < grid_size.x and pos.y >= 0 and pos.y < grid_size.y


## 变体值域上界（文档 §3.3 值域导出规则）。
static func value_upper_bound(variant: int, grid_size: Vector2i) -> int:
	match variant:
		Variant.N4, Variant.LOOP_RUNS, Variant.SAME_COLOR:
			return 4
		Variant.CLOCK, Variant.CLASSIC:
			return 8
		Variant.DIST_SUM:
			return 12
		Variant.FR:
			return grid_size.x - 1  # 保守上界 C-1
		Variant.HV:
			return 4  # 双值各自 0~4
		_:
			return 8
