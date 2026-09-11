# wasm_level_generator.gd —— wasm Mod 黑盒生成路径（P0-T7 二期）
# wasm 模块只提供黑盒正向（call_clue 线索值 / call_global_check 全局约束），
# 没有 build_clue_constraints（约束 IR），故无法走 CP-SAT 规则平台。
# 本生成器走黑盒路径：随机布雷 → 正向算线索 → BruteForceOracle 完备穷举验证唯一解。
#
# 能力边界（黑盒穷举的固有局限）：
#   · 线索语义固定为 8 邻求和（等价 classic），Board 加载走 classic 重算一致。
#   · 组合数受 BruteForceOracle.MAX_COMBOS 保护（200 万），实际仅小盘（≤6×6 少量雷）可行。
class_name WasmLevelGenerator
extends RefCounted

const TIMEOUT_MS := 15_000

var _rng := RandomNumberGenerator.new()


## 线索型 wasm 生成：sandbox.call_clue 正向算线索 + 完备穷举验证唯一解。
## 输出标准关卡格式（clue_rule=classic，因为 wasm clue 语义 = 8 邻求和，Board 加载后重算一致）。
func generate_clue(sandbox: WasmSandbox, size: Vector2i, mine_count: int, seed: int, attempts: int = 50) -> Dictionary:
	if sandbox == null:
		return {}
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	_rng.seed = seed

	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MS

	for _attempt in attempts:
		if Time.get_ticks_msec() > deadline:
			push_warning("WasmLevelGenerator: 线索生成超时")
			return {}
		# 1. 随机布雷
		var mines: Array[Vector2i] = _place_random(cols, rows, mine_count)
		if mines.is_empty():
			continue
		var mine_set := {}
		for m in mines:
			mine_set[m] = true
		# 2. 正向算线索（sandbox.call_clue，8 邻）
		var values := {}
		var clue_cells: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				var pos := Vector2i(c, r)
				if mine_set.has(pos):
					continue
				var v := sandbox.call_clue(_neighborhood(mine_set, pos, cols, rows))
				if v < 0:
					continue  # 模块未导出 clue → 不可用
				values[pos] = v
				if int(v) == 0:
					continue  # 0 值格不进初始翻开集（同规则平台口径）
				clue_cells.append(pos)
		if clue_cells.is_empty():
			continue
		# 3. 黑盒完备穷举验证唯一解（check 闭包用 wasm clue 对拍）
		var revealed := {}
		for pos in clue_cells:
			revealed[pos] = int(values[pos])
		var oracle := BruteForceOracle.new()
		var check := func(ms: Array[Vector2i], rev: Dictionary, gs: Vector2i) -> bool:
			var ms2 := {}
			for p in ms:
				ms2[p] = true
			for pos in rev:
				if sandbox.call_clue(_neighborhood(ms2, pos, int(gs.x), int(gs.y))) != int(rev[pos]):
					return false
			return true
		if oracle.count_solutions_variant(size, revealed, mine_count, check, [], 2) != 1:
			continue  # 非唯一解（多解或无解）
		# 4. 输出关卡
		return _build_level(rows, cols, mines, clue_cells, values, seed)
	return {}


## 全局约束型 wasm 生成：classic 线索 + wasm globalCheck 作为自定义全局约束。
## 布雷需满足 globalCheck；验证用 classic 剪枝 + wasm globalCheck 叶子检查。
func generate_global(sandbox: WasmSandbox, size: Vector2i, mine_count: int, seed: int, attempts: int = 50) -> Dictionary:
	if sandbox == null:
		return {}
	var cols := size.x
	var rows := size.y
	var n := cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	_rng.seed = seed

	var deadline: int = Time.get_ticks_msec() + TIMEOUT_MS

	for _attempt in attempts:
		if Time.get_ticks_msec() > deadline:
			push_warning("WasmLevelGenerator: 约束生成超时")
			return {}
		# 1. 布雷并满足 globalCheck
		var mines: Array[Vector2i] = []
		for _try in 20:
			var cand: Array[Vector2i] = _place_random(cols, rows, mine_count)
			if cand.is_empty():
				continue
			var st := {}
			for m in cand:
				st[m] = "mine"
			if sandbox.call_global_check(st):
				mines = cand
				break
		if mines.is_empty():
			continue
		var mine_set := {}
		for m in mines:
			mine_set[m] = true
		# 2. classic 线索（8 邻求和，Board 加载一致）
		var values := {}
		var clue_cells: Array[Vector2i] = []
		for r in rows:
			for c in cols:
				var pos := Vector2i(c, r)
				if mine_set.has(pos):
					continue
				var v := 0
				for nb in _neighborhood_positions(pos, cols, rows):
					if mine_set.has(nb):
						v += 1
				values[pos] = v
				if v == 0:
					continue
				clue_cells.append(pos)
		if clue_cells.is_empty():
			continue
		# 3. 验证唯一解：classic 线索约束（8 邻求和）+ wasm globalCheck 叶子检查。
		# 注意：count_solutions_classic 只支持内置 constraint，不接受自定义 check，
		# 故用 count_solutions_variant（通用 check 回调）——wasm globalCheck 在此真正参与。
		var revealed := {}
		for pos in clue_cells:
			revealed[pos] = int(values[pos])
		var oracle := BruteForceOracle.new()
		var check := func(ms: Array[Vector2i], rev: Dictionary, gs: Vector2i) -> bool:
			var ms2 := {}
			for p in ms:
				ms2[p] = true
			# classic 线索约束
			for pos in rev:
				var actual := 0
				for nb in _neighborhood_positions(pos, int(gs.x), int(gs.y)):
					if ms2.has(nb):
						actual += 1
				if actual != int(rev[pos]):
					return false
			# wasm globalCheck 全局约束
			var st := {}
			for p in ms:
				st[p] = "mine"
			return sandbox.call_global_check(st)
		if oracle.count_solutions_variant(size, revealed, mine_count, check, [], 2) != 1:
			continue
		# 4. 输出
		return _build_level(rows, cols, mines, clue_cells, values, seed)
	return {}


## 8 邻雷状态数组（与 WasmSandbox.clue 契约一致：ClueEngine.ring_dirs 顺序，界外补 0）。
static func _neighborhood(mine_set: Dictionary, pos: Vector2i, cols: int, rows: int) -> Array:
	var out: Array = []
	for d in ClueEngine.ring_dirs():
		var p := pos + d
		if p.x >= 0 and p.x < cols and p.y >= 0 and p.y < rows:
			out.append(1 if mine_set.has(p) else 0)
		else:
			out.append(0)
	return out


## 8 邻界内格子坐标（classic 线索计数用）。
static func _neighborhood_positions(pos: Vector2i, cols: int, rows: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in ClueEngine.ring_dirs():
		var p := pos + d
		if p.x >= 0 and p.x < cols and p.y >= 0 and p.y < rows:
			out.append(p)
	return out


func _place_random(cols: int, rows: int, count: int) -> Array[Vector2i]:
	var positions: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			positions.append(Vector2i(c, r))
	if positions.size() <= count:
		return positions.duplicate()
	var shuffled: Array = positions.duplicate()
	for i in range(shuffled.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = t
	var out: Array[Vector2i] = []
	for i in count:
		out.append(shuffled[i])
	return out


func _build_level(rows: int, cols: int, mines: Array[Vector2i], clue_cells: Array[Vector2i], values: Dictionary, seed: int) -> Dictionary:
	var mines_arr: Array = []
	for m in mines:
		mines_arr.append({"r": m.y, "c": m.x})
	var revealed_arr: Array = []
	for pos in clue_cells:
		# value 仅作注释（Board 加载走 classic 重算，语义等价）；写 value 便于工坊展示与复验。
		revealed_arr.append({"r": pos.y, "c": pos.x, "value": int(values[pos])})
	return {
		"rule_level": true,
		"wasm_level": true,
		"clue_rule": "classic",  # wasm clue = 8 邻求和 ≡ classic，Board 加载重算一致
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": mines_arr,
		"revealed": revealed_arr,
		"seed": seed,
	}
