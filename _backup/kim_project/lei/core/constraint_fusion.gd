# constraint_fusion.gd —— 变量融合 + 加权枚举（文档 22 号 K14 / 21 号 R22 的求解器消费层）
# 两套互补机制：
#   ① 变量组融合（MX/DT）：格子对关系 → 1 个变量，雷数贡献 0/2（MX）或 1/1（DT）
#   ② 容量行（4C/EP/QD/PF/RL）：集合雷数的线性关系 → 带权重的行 + 区间约束
# 容量约束天然跨连通分量（如 4C 黑/白格散落全盘），故由调用方把相关分量合并后传入。
# 只做「同分量内」融合（跨分量配对保持原样，少推但不错 = sound）。
# 本模块纯函数式，不依赖 Board，可独立单元测试。
class_name ConstraintFusion
extends RefCounted


# 枚举节点预算（超出即放弃，返回 budget_exceeded）
var _node_count := 0
var _budget_exceeded := false


## 融合分量内的格成变量组。
## cells: Array[Vector2i]（分量内的 frontier 格）
## grid_size: 棋盘尺寸（取 cols 用于 MX 镜像）
## dominoes: Array[Array[Vector2i]]（DT 骨牌划分）
## 返回 Array[Dictionary]，每项 { cells, choices, mine_count }：
##   cells      组内所有格
##   choices    每种取值的雷位集合（Dictionary: pos->true）
##   mine_count 每种取值贡献的雷数
static func fuse_groups(cells: Array[Vector2i], grid_size: Vector2i, dominoes: Array, use_mx: bool = true, use_dt: bool = true) -> Array:
	var groups: Array = []
	var grouped := {}  # pos -> true

	# 1) DT 骨牌对（互补：每骨牌恰 1 雷，两种排布）—— 仅当关卡真正启用 DT 约束
	if use_dt:
		for d in dominoes:
			if d.size() < 2:
				continue
			var a: Vector2i = d[0]
			var b: Vector2i = d[1]
			if cells.has(a) and cells.has(b) and not grouped.has(a) and not grouped.has(b):
				grouped[a] = true
				grouped[b] = true
				groups.append({
					"cells": [a, b],
					"choices": [{a: true}, {b: true}],   # 排布1: a雷；排布2: b雷
					"mine_count": [1, 1],                 # 恒贡献 1 雷
				})

	# 2) MX 镜像对（相等：两格同状态）—— 仅当关卡真正启用 MX 约束
	if use_mx:
		var cols: int = grid_size.x
		for p in cells:
			if grouped.has(p):
				continue
			var mirror := Vector2i(cols - 1 - p.x, p.y)
			if mirror.x <= p.x:
				continue  # 奇数宽中央列（mirror==p）自由；或已是右半区
			if cells.has(mirror) and not grouped.has(mirror):
				grouped[p] = true
				grouped[mirror] = true
				groups.append({
					"cells": [p, mirror],
					"choices": [{}, {p: true, mirror: true}],  # 同安全 或 同雷
					"mine_count": [0, 2],                        # 贡献 0 或 2 雷
				})

	# 3) 剩余普通格
	for p in cells:
		if not grouped.has(p):
			grouped[p] = true
			groups.append({
				"cells": [p],
				"choices": [{}, {p: true}],
				"mine_count": [0, 1],
			})

	return groups


# ============================================================
# 容量约束 → 线性加权行
# ============================================================

## 把全局容量约束转成线性行（加权 + 区间），供枚举使用。
## 与「变量组融合」互补：容量约束不是格子对关系，而是集合雷数的线性关系。
## frontier: 当前未知格；known_mines: 已确认的雷（pos -> true）
## 返回 Array[Dictionary]，每项 { cells, weights, lo, hi }：
##   cells/weights 平行数组（未知格及其权重）；lo/hi 为剩余未知格需满足的区间
##   已确定的雷的贡献计入 base，故 lo/hi = 目标 - base
## 按全局约束构造原始行（cells 含全部未知格 = frontier + interior）。
static func _build_raw(global_constraints: Array, grid_size: Vector2i, unknown_all: Array[Vector2i], known_mines: Dictionary, rl_sign: int = 0) -> Array:
	var raw: Array = []
	for gc in global_constraints:
		match gc.get("type", ""):
			"4c":
				raw.append_array(_rows_4c(grid_size, unknown_all, known_mines))
			"ep":
				raw.append_array(_rows_ep(grid_size, unknown_all, known_mines))
			"qd":
				raw.append_array(_rows_qd(grid_size, unknown_all, known_mines))
			"pf":
				raw.append_array(_rows_pf(grid_size, unknown_all, known_mines))
			"rl":
				raw.append_array(_rows_rl(grid_size, unknown_all, known_mines, rl_sign))
			"mx":
				raw.append_array(_rows_mx(grid_size, unknown_all, known_mines))
			"dt":
				raw.append_array(_rows_dt(gc.get("dominoes", []), unknown_all, known_mines))
	return raw


## 容量约束涉及的「枚举范围外未知格」（interior），供调用方判断是否纳入枚举。
## 纳入后容量约束不再被区间放宽稀释，推导力显著增强（代价是枚举变量变多）。
static func capacity_outside(global_constraints: Array, grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary, interior: Array[Vector2i]) -> Array[Vector2i]:
	var unknown_all: Array[Vector2i] = []
	unknown_all.append_array(frontier)
	unknown_all.append_array(interior)
	var raw: Array = _build_raw(global_constraints, grid_size, unknown_all, known_mines)
	var fset := {}
	for p in frontier:
		fset[p] = true
	var out: Array[Vector2i] = []
	var seen := {}
	for r in raw:
		for p in (r["cells"] as Array):
			if not fset.has(p) and not seen.has(p):
				seen[p] = true
				out.append(p)
	return out


static func capacity_rows(global_constraints: Array, grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary, interior: Array[Vector2i] = [], include_interior: bool = false, rl_sign: int = 0) -> Array:
	# 未知格 = 枚举范围内（frontier）+ 枚举范围外（interior）
	var unknown_all: Array[Vector2i] = []
	unknown_all.append_array(frontier)
	unknown_all.append_array(interior)
	var raw: Array = _build_raw(global_constraints, grid_size, unknown_all, known_mines, rl_sign)
	# 分离：只保留 frontier 格；interior 格贡献不确定，按其权重符号放宽区间（只放宽 = sound）
	var fset := {}
	for p in frontier:
		fset[p] = true
	var out: Array = []
	for r in raw:
		var cells: Array[Vector2i] = []
		var weights: Array = []
		var imin := 0
		var imax := 0
		var rc: Array = r["cells"]
		var rw: Array = r["weights"]
		for j in rc.size():
			var p = rc[j]
			var w: int = int(rw[j])
			# include_interior：interior 格也纳入枚举变量，约束不再被区间放宽稀释
			if fset.has(p) or include_interior:
				cells.append(p)
				weights.append(w)
			elif w > 0:
				imax += w
			else:
				imin += w
		if cells.is_empty():
			continue  # 不含枚举变量，跳过
		var entry := {
			"cells": cells, "weights": weights,
			"lo": int(r["lo"]) - imax, "hi": int(r["hi"]) - imin,
		}
		if r.get("rl", false):
			# 保留 RL 拆分的元信息（base + interior 调整量）
			entry["rl"] = true
			entry["base"] = int(r["base"])
			entry["imax"] = imax
			entry["imin"] = imin
		out.append(entry)
	return out


## G7 四向守恒：黑格（(x+y) 偶）雷数 = 白格雷数 → sum(w * is_mine) = 0
static func _rows_4c(grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary) -> Array:
	var cells: Array[Vector2i] = []
	var weights: Array = []
	var base := 0
	for y in grid_size.y:
		for x in grid_size.x:
			var p := Vector2i(x, y)
			var w := 1 if (x + y) % 2 == 0 else -1
			if known_mines.has(p):
				base += w
			elif frontier.has(p):
				cells.append(p)
				weights.append(w)
	if cells.is_empty():
		return []
	return [{"cells": cells, "weights": weights, "lo": -base, "hi": -base}]


## G6 端点平衡：最左列雷数 = 最右列雷数
static func _rows_ep(grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary) -> Array:
	if grid_size.x <= 1:
		return []
	var cells: Array[Vector2i] = []
	var weights: Array = []
	var base := 0
	var last_x: int = grid_size.x - 1
	for y in grid_size.y:
		for x in [0, last_x]:
			var p := Vector2i(x, y)
			var w := 1 if x == 0 else -1
			if known_mines.has(p):
				base += w
			elif frontier.has(p):
				cells.append(p)
				weights.append(w)
	if cells.is_empty():
		return []
	return [{"cells": cells, "weights": weights, "lo": -base, "hi": -base}]


## G4 四象：去中央行/列后四象限雷数相等 → Q1-Q2=0, Q2-Q3=0, Q3-Q4=0（3 行）
static func _rows_qd(grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary) -> Array:
	var mid_r: int = grid_size.y / 2
	var mid_c: int = grid_size.x / 2
	var qcells: Array = [[], [], [], []]
	var qbase: Array = [0, 0, 0, 0]
	for y in grid_size.y:
		for x in grid_size.x:
			var p := Vector2i(x, y)
			if y == mid_r or x == mid_c:
				continue  # 中央行/列不参与
			var q := 0
			if y < mid_r and x < mid_c:
				q = 0
			elif y < mid_r and x > mid_c:
				q = 1
			elif y > mid_r and x < mid_c:
				q = 2
			else:
				q = 3
			if known_mines.has(p):
				qbase[q] += 1
			elif frontier.has(p):
				(qcells[q] as Array).append(p)
	var rows: Array = []
	for k in 3:
		var cells: Array[Vector2i] = []
		var weights: Array = []
		for p in (qcells[k] as Array):
			cells.append(p)
			weights.append(1)
		for p in (qcells[k + 1] as Array):
			cells.append(p)
			weights.append(-1)
		if cells.is_empty():
			continue
		var base: int = int(qbase[k]) - int(qbase[k + 1])
		rows.append({"cells": cells, "weights": weights, "lo": -base, "hi": -base})
	return rows


## G3 局部禁形：每个 2×2 窗口雷数 ≤ 2（区间 [0, 2]）
static func _rows_pf(grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary) -> Array:
	var rows: Array = []
	for r in grid_size.y - 1:
		for c in grid_size.x - 1:
			var cells: Array[Vector2i] = []
			var weights: Array = []
			var base := 0
			for dy in 2:
				for dx in 2:
					var p := Vector2i(c + dx, r + dy)
					if known_mines.has(p):
						base += 1
					elif frontier.has(p):
						cells.append(p)
						weights.append(1)
			if cells.is_empty():
				continue  # 该窗口全确定，无需约束
			rows.append({"cells": cells, "weights": weights, "lo": -base, "hi": 2 - base})
	return rows


## G2 相邻行锁：|M(r) - M(r+1)| = 1。
## sign=0：松弛为区间 [-1,1]（sound，推导弱）；sign=±1：精确 diff（调用方枚举两次取并集）。
static func _rows_rl(grid_size: Vector2i, unknown_all: Array[Vector2i], known_mines: Dictionary, sign: int = 0) -> Array:
	var rows: Array = []
	for r in grid_size.y - 1:
		var cells: Array[Vector2i] = []
		var weights: Array = []
		var base := 0
		for x in grid_size.x:
			var p0 := Vector2i(x, r)
			var p1 := Vector2i(x, r + 1)
			if known_mines.has(p0):
				base += 1
			elif unknown_all.has(p0):
				cells.append(p0)
				weights.append(1)
			if known_mines.has(p1):
				base -= 1
			elif unknown_all.has(p1):
				cells.append(p1)
				weights.append(-1)
		if cells.is_empty():
			continue
		if sign == 0:
			# 松弛版带 rl/base 标记，供枚举器拆成 ±1 两种精确情况取并集
			rows.append({"cells": cells, "weights": weights, "lo": -1 - base, "hi": 1 - base, "rl": true, "base": base})
		else:
			rows.append({"cells": cells, "weights": weights, "lo": sign - base, "hi": sign - base})
	return rows


## G1 镜像（跨分量兜底）：每对 (c, mirror) 状态相等 → w=+1/-1，和为 0
static func _rows_mx(grid_size: Vector2i, frontier: Array[Vector2i], known_mines: Dictionary) -> Array:
	var rows: Array = []
	var cols: int = grid_size.x
	for y in grid_size.y:
		for x in cols:
			var mx_x: int = cols - 1 - x
			if x >= mx_x:
				break
			var p := Vector2i(x, y)
			var q := Vector2i(mx_x, y)
			var cells: Array[Vector2i] = []
			var weights: Array = []
			var base := 0
			if known_mines.has(p):
				base += 1
			elif frontier.has(p):
				cells.append(p)
				weights.append(1)
			if known_mines.has(q):
				base -= 1
			elif frontier.has(q):
				cells.append(q)
				weights.append(-1)
			if cells.is_empty():
				continue
			rows.append({"cells": cells, "weights": weights, "lo": -base, "hi": -base})
	return rows


## G5 骨牌（跨分量兜底）：每骨牌恰 1 雷 → 两格 w=+1，和为 1
static func _rows_dt(dominoes: Array, frontier: Array[Vector2i], known_mines: Dictionary) -> Array:
	var rows: Array = []
	for d in dominoes:
		if d.size() < 2:
			continue
		var cells: Array[Vector2i] = []
		var weights: Array = []
		var base := 0
		for i in 2:
			var p: Vector2i = d[i]
			if known_mines.has(p):
				base += 1
			elif frontier.has(p):
				cells.append(p)
				weights.append(1)
		if cells.is_empty():
			continue
		rows.append({"cells": cells, "weights": weights, "lo": 1 - base, "hi": 1 - base})
	return rows


# ============================================================
# 加权枚举（线索行 + 容量行）
# ============================================================

## 组枚举：返回 { sols: Array[Dictionary], budget_exceeded: bool }。
## 每个 sol 是 pos -> bool（雷=true），供调用方判断公共格。
## cell_hits: Dictionary(pos -> Array[线索 idx])，线索行权重恒为 1
## need: Array（每条线索还需的雷数）
## extra_rows: Array[{cells, weights, lo, hi}]（容量约束的加权行）
## lo/hi: 本分量雷数的松弛投影下/上界
## max_solutions / max_nodes: 预算
func enumerate_groups(
	groups: Array, cell_hits: Dictionary, need: Array,
	lo: int, hi: int, max_solutions: int, max_nodes: int,
	extra_rows: Array = []
) -> Dictionary:
	# RL 约束（|diff|=1）：单行时拆 ±1 严格；多行符号组合是 2^k 种，全 ±1 会漏混合符号解（UNSOUND），
	# 故多行退回松弛区间 [-1,1]（extra_rows 里的 rl 行本就是松弛版），保 sound。
	var rl_count := 0
	for r in extra_rows:
		if r.get("rl", false):
			rl_count += 1
	if rl_count <= 1:
		if rl_count == 0:
			return _enumerate_impl(groups, cell_hits, need, lo, hi, max_solutions, max_nodes, extra_rows)
		# 单行 RL：2 种符号组合 = 全 ±1，完备
		var r1 := _enumerate_impl(groups, cell_hits, need, lo, hi, max_solutions, max_nodes, _rl_signed(extra_rows, 1))
		if r1["budget_exceeded"]:
			return r1
		var r2 := _enumerate_impl(groups, cell_hits, need, lo, hi, max_solutions, max_nodes, _rl_signed(extra_rows, -1))
		if r2["budget_exceeded"]:
			return r2
		return _merge_sols(r1, r2)
	return _enumerate_impl(groups, cell_hits, need, lo, hi, max_solutions, max_nodes, extra_rows)


## RL 行改为精确 sign（±1），其余行原样。
static func _rl_signed(rows: Array, sign: int) -> Array:
	var out: Array = []
	for r in rows:
		if r.get("rl", false):
			var b: int = int(r["base"])
			var imx: int = int(r.get("imax", 0))
			var imn: int = int(r.get("imin", 0))
			out.append({
				"cells": r["cells"], "weights": r["weights"],
				"lo": sign - b - imx, "hi": sign - b - imn,
			})
		else:
			out.append(r)
	return out


## 合并两组解（按雷位集合去重）。
static func _merge_sols(r1: Dictionary, r2: Dictionary) -> Dictionary:
	var seen := {}
	var sols: Array = []
	for s in (r1["sols"] as Array):
		var key: Array = (s as Dictionary).keys()
		key.sort()
		seen[str(key)] = true
		sols.append(s)
	for s in (r2["sols"] as Array):
		var key: Array = (s as Dictionary).keys()
		key.sort()
		if not seen.has(str(key)):
			seen[str(key)] = true
			sols.append(s)
	return {"sols": sols, "budget_exceeded": false}


## 单次枚举实现（行 0..nclue-1 = 线索行，其后为容量行）。
func _enumerate_impl(
	groups: Array, cell_hits: Dictionary, need: Array,
	lo: int, hi: int, max_solutions: int, max_nodes: int,
	extra_rows: Array
) -> Dictionary:
	var nclue: int = need.size()
	var nrow: int = nclue + extra_rows.size()
	var row_lo: Array = []
	var row_hi: Array = []
	row_lo.resize(nrow)
	row_hi.resize(nrow)
	for i in nclue:
		row_lo[i] = need[i]
		row_hi[i] = need[i]
	for k in extra_rows.size():
		row_lo[nclue + k] = int(extra_rows[k]["lo"])
		row_hi[nclue + k] = int(extra_rows[k]["hi"])

	# point_rows: pos -> Array[[row_idx, weight]]
	# cell_hits[p] 元素可为 int（旧格式，权重 1）或 [idx, weight]（加权线索）
	var point_rows: Dictionary = {}
	for p in cell_hits:
		var arr: Array = []
		for entry in (cell_hits[p] as Array):
			if entry is Array:
				arr.append([int(entry[0]), int(entry[1])])
			else:
				arr.append([int(entry), 1])
		point_rows[p] = arr
	for k in extra_rows.size():
		var er: Dictionary = extra_rows[k]
		var ecells: Array = er["cells"]
		var eweights: Array = er["weights"]
		var ri: int = nclue + k
		for j in ecells.size():
			var ep = ecells[j]
			var w: int = int(eweights[j])
			if not point_rows.has(ep):
				point_rows[ep] = []
			(point_rows[ep] as Array).append([ri, w])

	# counts = 当前加权和；rem_pos/rem_neg = 未确定格的贡献上下界
	var counts: Array = []
	var rem_pos: Array = []
	var rem_neg: Array = []
	counts.resize(nrow)
	rem_pos.resize(nrow)
	rem_neg.resize(nrow)
	for i in nrow:
		counts[i] = 0
		rem_pos[i] = 0
		rem_neg[i] = 0
	for p in point_rows:
		for pr in (point_rows[p] as Array):
			var ri: int = int(pr[0])
			var w: int = int(pr[1])
			if w > 0:
				rem_pos[ri] += w
			else:
				rem_neg[ri] += w

	# 每组最大雷数贡献（用于全局 lo/hi 下界剪枝）
	var max_mine: Array = []
	for g in groups:
		var mx := 0
		for mc in (g["mine_count"] as Array):
			if int(mc) > mx:
				mx = int(mc)
		max_mine.append(mx)
	var suffix: Array = []
	suffix.resize(groups.size() + 1)
	suffix[groups.size()] = 0
	for gi in range(groups.size() - 1, -1, -1):
		suffix[gi] = suffix[gi + 1] + max_mine[gi]

	var assign: Array = []
	assign.resize(groups.size())
	for i in groups.size():
		assign[i] = 0

	_node_count = 0
	_budget_exceeded = false
	var sols: Array = []
	_bt(groups, point_rows, row_lo, row_hi, 0, counts, rem_pos, rem_neg,
		lo, hi, 0, assign, suffix, max_solutions, max_nodes, sols)
	return {"sols": sols, "budget_exceeded": _budget_exceeded}


## 回溯：每个组遍历其 choices，维护加权行和 + 剩余贡献界。
func _bt(
	groups: Array, point_rows: Dictionary, row_lo: Array, row_hi: Array, gidx: int,
	counts: Array, rem_pos: Array, rem_neg: Array,
	lo: int, hi: int, mine_count: int,
	assign: Array, suffix: Array, max_solutions: int, max_nodes: int, sols: Array
) -> void:
	if sols.size() >= max_solutions:
		_budget_exceeded = true  # 解集被截断即不完整，置超限让调用方放弃该分量（保 sound）
		return
	_node_count += 1
	if _node_count > max_nodes:
		_budget_exceeded = true
		return
	var ng: int = groups.size()

	# 雷数剪枝（加权）：已超上界 / 剩余最大雷数达不到下界
	if mine_count > hi:
		return
	if mine_count + suffix[gidx] < lo:
		return

	if gidx == ng:
		# 叶子：所有行（线索 + 容量）均满足区间
		for i in row_lo.size():
			if counts[i] < row_lo[i] or counts[i] > row_hi[i]:
				return
		var sol := {}
		for gi in groups.size():
			var choice: Dictionary = groups[gi]["choices"][assign[gi]]
			for p in choice:
				sol[p] = true
		sols.append(sol)
		return

	var group: Dictionary = groups[gidx]
	var cells: Array = group["cells"]
	var choices: Array = group["choices"]
	var mcs: Array = group["mine_count"]

	for k in choices.size():
		assign[gidx] = k
		var choice: Dictionary = choices[k]
		var ok := true
		# ① 雷格贡献 +w（超上界即失败）；所有确定格从剩余界中移除
		for p in cells:
			if not point_rows.has(p):
				continue
			var is_mine: bool = choice.has(p)
			for pr in (point_rows[p] as Array):
				var ri: int = int(pr[0])
				var w: int = int(pr[1])
				# 注意：不可在此做「counts > row_hi 即失败」的即时判断——
				# 含负权重的行（如 MX 的 +1/-1）中途会先越界、后续负权重再拉回，
				# 提前剪枝会删掉合法解 ⇒ 解集不完整 ⇒ 推出错误结论（UNSOUND）。
				# 区间可行性一律交给下方基于 rem_pos/rem_neg 的界判断。
				if is_mine:
					counts[ri] += w
				if w > 0:
					rem_pos[ri] -= w
				else:
					rem_neg[ri] -= w
		# ② 区间可行性：剩余最大贡献达不到下界 / 剩余最小贡献已超上界
		if ok:
			for i in row_lo.size():
				if counts[i] + rem_pos[i] < row_lo[i]:
					ok = false
					break
				if counts[i] + rem_neg[i] > row_hi[i]:
					ok = false
					break

		if ok:
			_bt(groups, point_rows, row_lo, row_hi, gidx + 1, counts, rem_pos, rem_neg,
				lo, hi, mine_count + int(mcs[k]), assign, suffix, max_solutions, max_nodes, sols)

		# 回滚（逆序）
		for p in cells:
			if not point_rows.has(p):
				continue
			var is_mine: bool = choice.has(p)
			for pr in (point_rows[p] as Array):
				var ri: int = int(pr[0])
				var w: int = int(pr[1])
				if is_mine:
					counts[ri] -= w
				if w > 0:
					rem_pos[ri] += w
				else:
					rem_neg[ri] += w
