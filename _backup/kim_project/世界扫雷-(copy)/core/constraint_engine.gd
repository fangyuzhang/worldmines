# constraint_engine.gd —— 全局约束引擎（文档附 A.2 的 7 个全局约束）
# 每个约束提供：check(mine_set, grid_size, extra) -> bool 判定雷分布是否满足约束。
# 坐标：Vector2i(col, row)。mine_set 为 Dictionary（Vector2i -> true）。
class_name ConstraintEngine
extends RefCounted

enum Variant {
	MX,         # G1 镜像：左右对称
	RL,         # G2 相邻行锁：相邻行雷数差 = 1
	PF,         # G3 局部禁形：2×2 窗口雷数 ≤ 2
	QD,         # G4 四象：四象限雷数相等
	DT,         # G5 骨牌边界：每骨牌恰 1 雷
	EP,         # G6 端点平衡：最左列雷数 = 最右列雷数
	FOUR_COLOR, # G7 四向守恒：黑格雷数 = 白格雷数
}


## 判定雷分布是否满足约束。extra 用于 DT 骨牌划分等附加数据。
static func check(variant: int, mine_set: Dictionary, grid_size: Vector2i, extra: Dictionary = {}) -> bool:
	match variant:
		Variant.MX:
			return _check_mx(mine_set, grid_size)
		Variant.RL:
			return _check_rl(mine_set, grid_size)
		Variant.PF:
			return _check_pf(mine_set, grid_size)
		Variant.QD:
			return _check_qd(mine_set, grid_size)
		Variant.DT:
			return _check_dt(mine_set, grid_size, extra)
		Variant.EP:
			return _check_ep(mine_set, grid_size)
		Variant.FOUR_COLOR:
			return _check_4c(mine_set, grid_size)
		_:
			return true


## 统计某列（x=col）的雷数。
static func _col_mines(mine_set: Dictionary, grid_size: Vector2i, col: int) -> int:
	var n := 0
	for y in grid_size.y:
		if mine_set.has(Vector2i(col, y)):
			n += 1
	return n


## 统计某行（y=row）的雷数。
static func _row_mines(mine_set: Dictionary, grid_size: Vector2i, row: int) -> int:
	var n := 0
	for x in grid_size.x:
		if mine_set.has(Vector2i(x, row)):
			n += 1
	return n


## G1 镜像：左右对称。对所有 c < (C-1)/2，状态(c) = 状态(C-1-c)。
static func _check_mx(mine_set: Dictionary, grid_size: Vector2i) -> bool:
	var cols := grid_size.x
	for y in grid_size.y:
		for x in cols:
			var mirror_x := cols - 1 - x
			if x >= mirror_x:
				break
			if mine_set.has(Vector2i(x, y)) != mine_set.has(Vector2i(mirror_x, y)):
				return false
	return true


## G2 相邻行锁：|M(r) - M(r+1)| = 1。
static func _check_rl(mine_set: Dictionary, grid_size: Vector2i) -> bool:
	for r in grid_size.y - 1:
		var diff: int = absi(_row_mines(mine_set, grid_size, r) - _row_mines(mine_set, grid_size, r + 1))
		if diff != 1:
			return false
	return true


## G3 局部禁形：任意 2×2 窗口雷数 ≤ 2。
static func _check_pf(mine_set: Dictionary, grid_size: Vector2i) -> bool:
	for r in grid_size.y - 1:
		for c in grid_size.x - 1:
			var n := 0
			for dy: int in [0, 1]:
				for dx: int in [0, 1]:
					if mine_set.has(Vector2i(c + dx, r + dy)):
						n += 1
			if n > 2:
				return false
	return true


## G4 四象：去掉中央行/列后四象限雷数相等。
static func _check_qd(mine_set: Dictionary, grid_size: Vector2i) -> bool:
	var mid_r := grid_size.y / 2
	var mid_c := grid_size.x / 2
	var q := [-1, -1, -1, -1]  # Q1 左上, Q2 右上, Q3 左下, Q4 右下
	for y in grid_size.y:
		for x in grid_size.x:
			if y == mid_r or x == mid_c:
				continue  # 中央行/列不参与
			if not mine_set.has(Vector2i(x, y)):
				continue
			if y < mid_r and x < mid_c:
				q[0] += 1
			elif y < mid_r and x > mid_c:
				q[1] += 1
			elif y > mid_r and x < mid_c:
				q[2] += 1
			else:
				q[3] += 1
	return q[0] == q[1] and q[1] == q[2] and q[2] == q[3]


## G5 骨牌边界：每骨牌恰 1 雷。extra.dominoes 为 Array[Array[Vector2i]]（每骨牌 2 格）。
static func _check_dt(mine_set: Dictionary, grid_size: Vector2i, extra: Dictionary) -> bool:
	var dominoes: Array = extra.get("dominoes", [])
	if dominoes.is_empty():
		return true
	for d in dominoes:
		var n := 0
		for p in d:
			if mine_set.has(p):
				n += 1
		if n != 1:
			return false
	return true


## G6 端点平衡：最左列雷数 = 最右列雷数。
static func _check_ep(mine_set: Dictionary, grid_size: Vector2i) -> bool:
	if grid_size.x <= 1:
		return true
	return _col_mines(mine_set, grid_size, 0) == _col_mines(mine_set, grid_size, grid_size.x - 1)


## G7 四向守恒：黑格（(r+c)偶）雷数 = 白格（(r+c)奇）雷数。
static func _check_4c(mine_set: Dictionary, grid_size: Vector2i) -> bool:
	var black := 0
	var white := 0
	for y in grid_size.y:
		for x in grid_size.x:
			if mine_set.has(Vector2i(x, y)):
				if (x + y) % 2 == 0:
					black += 1
				else:
					white += 1
	return black == white
