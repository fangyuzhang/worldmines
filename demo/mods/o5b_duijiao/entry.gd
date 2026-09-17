# entry.gd —— O5b「对角」（O5 变体实验：隐藏「看哪组对角块」+ 全盘配额）
#
# 状态（2026-09-16「原三角 mod 处置」）：**实验否决**——真盘口径复测全尺寸零产（5 尺寸 × 3 盘全 0/3；
# 见 HANDOFF「预检修复」段），与「计数型隐藏维度死路」定性一致；本目录**保留为设计档案**（默认保留，不删除）。
#
# 背景（2026-09-14）：O5 原版「4 块满块计数」为信息型简单（难度 0.03~0.10，遮蔽实验无效）。
# 本变体按「换变体以达标」思路设计——引入「不确定性维度」（对齐 O4 变径的成功机制）：
#   · 每格 4 个 2×2 块（同 O5）切分为两组对角：
#       组 A（主对角） = {块0（p 左上块）, 块3（p 右下块）}
#       组 B（副对角） = {块1（p 右上块）, 块2（p 左下块）}
#   · 每格隐藏「看哪组」的朝向 dir_p ∈ {0,1}；数字 = 所看组「满块（另外三格全雷）」数（0–2）。
#     含混杂：块 0/3 距 p 的切比雪夫距离均为 +1 对角方向——主对角组；块 1/2 为副对角组。
#   · 全盘 dir=1 的格数固定为 k（公开；k = 格数/4）。
# 编码（平台 O4 验证过的机制）：dir 共享池（bool_var_at 显式索引）+ 4 项乘积线性化
#   （(1−dir)·t 与 dir·t 各 3 条约束）+ Σdir=k 全局配额（build_global_clue_constraints）。
# 线索覆盖：本版仅内圈（四块全有效；边缘格块越界导致组有效数不均，先不铺，预检说话）。
# 实验性变体（o5b）——预检 + 探针数据决定是否转正；不转正则保留为设计档案。
extends RefCounted


class DiagGroupRule:
	extends RulePlugin

	const BLOCK_TRIPLES := [
		[Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],      # 块0：p 左上块（位于 p 右下方向）
		[Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)],    # 块1：p 右上块（位于 p 左下方向）
		[Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0)],    # 块2：p 左下块（位于 p 右上方向）
		[Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, -1)],  # 块3：p 右下块（位于 p 左上方向）
	]

	## dir=1（看副对角组）的格集合（place_mines 时决定）。
	var _dir1: Dictionary = {}

	func get_rule_id() -> StringName:
		return &"o5b"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {
			"name": "对角",
			"rule_text": "每个数字看两组对角小方块（各两块）——看哪组不显示；数字 = 所看组里『另外三格全是雷』的块数（全盘看副对角组的格数固定为 k）",
		}

	func applies_to(pos: Vector2i, grid_size: Vector2i) -> bool:
		# 仅内圈（四块全有效）
		return pos.x >= 1 and pos.x <= grid_size.x - 2 \
			and pos.y >= 1 and pos.y <= grid_size.y - 2

	func _block_full_flags(mine_set: Dictionary, pos: Vector2i) -> Array:
		var out: Array = [0, 0, 0, 0]
		for i in 4:
			var all_mine := true
			for d in BLOCK_TRIPLES[i]:
				if not mine_set.has(pos + d):
					all_mine = false
					break
			out[i] = 1 if all_mine else 0
		return out

	func compute_clue(mine_set: Dictionary, pos: Vector2i, _grid_size: Vector2i) -> Variant:
		var t := _block_full_flags(mine_set, pos)
		if _dir1.has(pos):
			return t[1] + t[2]   # 副对角组
		return t[0] + t[3]       # 主对角组

	func value_upper_bound(_grid_size: Vector2i) -> int:
		return 2

	func zero_safe_neighbors(_pos: Vector2i, _grid_size: Vector2i, _value: Variant = null) -> Array[Vector2i]:
		return []   # 不可扩散（「组非全满」不保证任何格安全）

	func supports_mask() -> bool:
		return false  # 实验版暂不启用遮蔽

	# ==== 逆向编码 ====

	static func _did(c: int, r: int) -> int:
		return 1_000_000 + r * 64 + c

	func build_global_clue_constraints(b: RuleBuilder) -> void:
		# dir 共享池（全部格）+ 全盘配额 Σdir = k
		var ds: Array = []
		for rr in b.rows:
			for cc in b.cols:
				ds.append(b.bool_var_at(_did(cc, rr)))
		var k := maxi(1, (b.rows * b.cols) / 4)
		b.add_eq(b.sum(ds), k)

	func _flags(b: RuleBuilder, pos: Vector2i) -> Array:
		var ts: Array = []
		for triple in BLOCK_TRIPLES:
			var bs: Array = []
			for d in triple:
				bs.append(b.cell_var((pos + d).y, (pos + d).x))
			var t := b.bool_var()
			for bq in bs:
				b.add_imp(t, bq)
			b.add_le(b.sum(bs), b.lin([1], [t], 2))
			ts.append(t)
		return ts

	## u = (1−dir)·t：u ≤ 1−dir；u ≤ t；u ≥ t−dir。
	func _prod_not_dir(b: RuleBuilder, dir: Dictionary, t: Dictionary) -> Dictionary:
		var u := b.int_var(0, 1)
		b.add_le(b.sum([u, dir]), 1)
		b.add_le(u, t)
		b.add_le(b.sum([t]), b.sum([u, dir]))
		return u

	## u = dir·t：u ≤ dir；u ≤ t；u ≥ dir+t−1。
	func _prod_dir(b: RuleBuilder, dir: Dictionary, t: Dictionary) -> Dictionary:
		var u := b.int_var(0, 1)
		b.add_le(u, dir)
		b.add_le(u, t)
		b.add_le(b.sum([dir, t]), b.lin([1], [u], 1))
		return u

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var dir := b.bool_var_at(_did(pos.x, pos.y))
		var ts := _flags(b, pos)
		# 组 A = {t0, t3}（dir=0 生效）；组 B = {t1, t2}（dir=1 生效）
		var u0 := _prod_not_dir(b, dir, ts[0])
		var u3 := _prod_not_dir(b, dir, ts[3])
		var u1 := _prod_dir(b, dir, ts[1])
		var u2 := _prod_dir(b, dir, ts[2])
		b.add_eq(b.lin([1, 1, 1, 1], [u0, u3, u1, u2]), int(value))

	# ==== 构造式布雷 + dir 配额分配 ====

	func place_mines(rng: RandomNumberGenerator, cols: int, rows: int, count: int) -> Array[Vector2i]:
		# dir=1 配额：全盘随机选 k 个
		_dir1.clear()
		var all_cells: Array = []
		for r in rows:
			for c in cols:
				all_cells.append(Vector2i(c, r))
		var k := (cols * rows) / 4
		if k < 1:
			k = 1
		for _i in range(mini(k, all_cells.size())):
			var pi := rng.randi_range(0, all_cells.size() - 1)
			_dir1[all_cells[pi]] = true
			all_cells.remove_at(pi)
		# 效率布雷（同 O1/O5 方案：低聚类 + 偏边缘加权序列采样）
		var weights: Dictionary = {}
		for r in rows:
			for c in cols:
				var edge := c == 0 or r == 0 or c == cols - 1 or r == rows - 1
				weights[Vector2i(c, r)] = 1.25 if edge else 1.0
		var out: Array[Vector2i] = []
		for _i in count:
			var total := 0.0
			for p in weights:
				total += float(weights[p])
			if total <= 0.0:
				break
			var pick := rng.randf() * total
			var acc := 0.0
			var chosen := Vector2i(-1, -1)
			for p in weights:
				acc += float(weights[p])
				if acc >= pick:
					chosen = p
					break
			if chosen.x < 0:
				break
			out.append(chosen)
			weights.erase(chosen)
			for d in BLOCK_TRIPLES[0]:
				var q: Vector2i = chosen + d
				if weights.has(q):
					weights[q] = maxf(0.05, float(weights[q]) * 0.35)
			for d in BLOCK_TRIPLES[3]:
				var q3: Vector2i = chosen + d
				if weights.has(q3):
					weights[q3] = maxf(0.05, float(weights[q3]) * 0.35)
		return out


func on_load() -> bool:
	RuleRegistry.default().register(DiagGroupRule.new())

	return true