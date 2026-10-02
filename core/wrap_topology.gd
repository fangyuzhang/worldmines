class_name WrapTopology
extends RefCounted

## 环绕边界（wrap / toroidal）与自定义邻域偏移 → 邻接表（topology dict）。
##
## 【为什么要走"邻接表"这条路线，而不是改 RectGrid 的边界检查（2026-10-01 编辑器批次）】
## 本仓的**异形盘全链路**早已打通：关卡 JSON 一旦带 `topology`，`core/board.gd:164` 就用
## `AdjacencyGrid`，此后生成器 / CP-SAT 判据 / 提示求解 / 渲染高亮**全部按 `GridInterface`
## 抽象工作**（`core/grid_interface.gd` 明写"遍历必须用 all_positions()，禁止假设坐标连续"）。
## 所以"环绕边界"和"自定义邻域"只要产出一张**折返后的邻居表**，就等于同时接进了这条链路，
## RectGrid / Board / 求解器 / 渲染**一行都不用改**。
## 反例（为什么不改 `core/rect_grid.gd:32` 的 `if in_board(n): out.append(n)`）：
## 那一处的边界语义同时被「线索计算 / 0 值扩散 / 生成期邻域 / 提示求解 / 渲染高亮」五处依赖，
## 改它等于在这五处同时引入"何时折返、何时截断"的分歧——编辑器不该付这个代价。
##
## 【与其他模块的分工】
##   * 形状族（六边形 / 三角 / 截角 / 环 / ASCII 轮廓 …）**不在这里**，直接调
##     `ShapeGenerator.to_adjacency_grid(kind, params)`（9 族现成，编辑器"形状下拉"用）。
##     本文件只管**方形坐标下的邻域规则**：默认 8 邻 / 自定义偏移 / 是否含自身 / 是否环绕。
##   * 邻接表 ↔ JSON 的读写由 `core/adjacency_grid.gd:27 setup_from_topo` 负责（本文件输出
##     其中"形式 2" `{"positions":[{x,y}], "neighbors":{"x,y":[...]}}`——它是优先分支且保序）。

## 棋盘格数上限：与 `ui/level_loader.gd:152 MAX_CELLS` 同口径。
## 编辑器绝不该产出加载器会拒收的盘，否则"能编辑、不能玩"。
const MAX_CELLS := 64 * 64

## 单个格的邻居数上限：与 `core/spec_schema.gd:43 TOPO_REF_MAX` 同口径
##（声明式规格的 `ref i` 最大索引是 63 ⇒ 邻居数超过 64 就没有任何 refs 能表达）。
const MAX_DEGREE := 64

## 4 正交邻域（上下左右）。UI 的"邻域预设"用。
const DIRS_ORTHO4: Array[Vector2i] = [
	Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1),
]

## 骑士步（国际象棋马，8 个偏移）。UI 的"邻域预设"用——本仓已有 knight 类规则的先例。
const DIRS_KNIGHT8: Array[Vector2i] = [
	Vector2i(-1, -2), Vector2i(1, -2), Vector2i(-2, -1), Vector2i(2, -1),
	Vector2i(-2, 1), Vector2i(2, 1), Vector2i(-1, 2), Vector2i(1, 2),
]


## 结果信封：`{"ok": bool, "reason": String, "topology": Dictionary}`。
## `ok == true` 且 `topology.is_empty()` ⇒ **这是一个默认矩形盘，不需要 topology**
##（调用方不要往关卡 JSON 里写 `topology` 字段，让它继续走 `RectGrid`，
##  这样"默认扫雷"的产物与今天逐位一致——这是本仓反复强调的兼容纪律）。
## `force = true`：即使邻域是默认的也**强制产出**邻接表。
## 为什么需要：**障碍格（洞）只能用邻接表表达**——"某坐标不存在"在 RectGrid 里没有表示法，
## 而 `AdjacencyGrid` 的 positions 缺谁就等于谁不在盘上。所以"默认 8 邻 + 有障碍"的盘也必须
## 走 topology 路线（编辑器文档模型据此调用）。
static func build(rows: int, cols: int, dirs: Array[Vector2i] = [],
		include_self: bool = false, wrap: bool = false, force: bool = false) -> Dictionary:
	var use_dirs: Array[Vector2i] = []
	# 空 = 用默认 Moore 8 邻（同时方便 JSON 回读：`dirs` 字段缺失时不必填 8 个偏移）。
	# 用 assign() 而不是 `= ShapeGenerator.MOORE8`：那是个**只读常量数组**（const 数组在 Godot 4
	# 是只读的），直接引用后若下游手滑 sort()/append() 会报错；assign 是拷贝。
	use_dirs.assign(dirs if not dirs.is_empty() else ShapeGenerator.MOORE8)

	if rows < 1 or cols < 1:
		return _err("棋盘尺寸必须 ≥ 1（当前 %dx%d）" % [rows, cols])
	if rows * cols > MAX_CELLS:
		return _err("格数 %d 超过上限 %d（%dx%d）：加载器会拒收（%s）" % [
			rows * cols, MAX_CELLS, rows, cols, "ui/level_loader.gd MAX_CELLS"])
	if use_dirs.size() > MAX_DEGREE:
		return _err("邻域偏移 %d 个，超过上限 %d" % [use_dirs.size(), MAX_DEGREE])
	if wrap and (rows < 2 or cols < 2):
		# 环绕要求"两个方向折返后仍是不同的格"。1 行列时 ±1 会折回自身，
		# 结果是一张"自己是自己邻居"的表——语义上不再是环绕，是错误数据，宁可直接拒绝。
		return _err("环绕边界要求行、列都 ≥ 2（当前 %dx%d）；%s" % [rows, cols, "单行/单列的环绕无意义"])

	if not force and is_default(use_dirs, include_self, wrap):
		return {"ok": true, "reason": "默认矩形盘（Moore 8 邻、不含自身、不环绕）", "topology": {}}

	var positions: Array = []
	for y in rows:
		for x in cols:
			positions.append({"x": x, "y": y})

	var neighbors: Dictionary = {}
	for y in rows:
		for x in cols:
			var nbs: Array[Vector2i] = []
			for d in use_dirs:
				var nx := x + d.x
				var ny := y + d.y
				if wrap:
					nx = _fold(nx, cols)
					ny = _fold(ny, rows)
				elif nx < 0 or ny < 0 or nx >= cols or ny >= rows:
					continue
				nbs.append(Vector2i(nx, ny))
			if include_self:
				nbs.append(Vector2i(x, y))
			neighbors["%d,%d" % [x, y]] = _keys(_sorted_unique(nbs))

	var topology := {
		"positions": positions,
		"neighbors": neighbors,
		"style": "custom",   # 单位方格渲染（不是 hex）；style 是渲染判据，不是拓扑语义
		# 编辑器回读用。刻意**不写进 params**：params 会被 `setup_from_topo` 原样搬进
		# `AdjacencyGrid.style_params` 交给渲染层解释，塞编辑器元数据进去有污染渲染的风险。
		"editor": {
			"wrap": wrap,
			"include_self": include_self,
			"dirs": dirs_to_json(use_dirs),
		},
	}
	return {"ok": true, "reason": "", "topology": topology}


## 默认矩形盘判据：Moore 8 邻 + 不含自身 + 不环绕 ⇒ 与 `RectGrid.get_neighbors` 完全同义，
## 此时**不该**生成 topology（生成器/求解器走矩形路径，产物与今天逐位一致）。
static func is_default(dirs: Array[Vector2i], include_self: bool, wrap: bool) -> bool:
	if wrap or include_self:
		return false
	var use_dirs: Array[Vector2i] = []
	use_dirs.assign(dirs if not dirs.is_empty() else ShapeGenerator.MOORE8)
	if use_dirs.size() != ShapeGenerator.MOORE8.size():
		return false
	for d in use_dirs:
		if not ShapeGenerator.MOORE8.has(d):
			return false
	return true


## 从 topology dict 回读编辑器元数据（`WrapTopology.build` 写进 `editor` 的那一份）。
## 返回 `{"wrap": bool, "include_self": bool, "dirs": Array[Vector2i]}`；缺失字段取默认值，
## 于是"手工写的/旧版本的 topology"也能被编辑器打开（不崩、按默认解释）。
static func read_editor_meta(topo: Dictionary) -> Dictionary:
	var meta: Variant = topo.get("editor", {})
	var m: Dictionary = meta if meta is Dictionary else {}
	var dirs: Array[Vector2i] = []
	var raw: Variant = m.get("dirs", [])
	if raw is Array:
		for d in raw:
			if d is Dictionary:
				dirs.append(Vector2i(int(d.get("x", 0)), int(d.get("y", 0))))
	if dirs.is_empty():
		dirs.assign(ShapeGenerator.MOORE8)
	return {
		"wrap": bool(m.get("wrap", false)),
		"include_self": bool(m.get("include_self", false)),
		"dirs": dirs,
	}


## 邻域偏移 → JSON 友好数组（`[{x,y}]`）。与 `read_editor_meta` 成对，保证 JSON 往返可还原。
static func dirs_to_json(dirs: Array[Vector2i]) -> Array:
	var out: Array = []
	for d in dirs:
		out.append({"x": d.x, "y": d.y})
	return out


## 环绕用的模运算。**必须显式补正**：GDScript 的 `%` 对负数返回负数
##（`-1 % 5 == -1`，不是 4），直接拿去做下标/坐标会得到越界负数——
## 这是本文件最容易被后人改错的一行。
static func _fold(v: int, n: int) -> int:
	return ((v % n) + n) % n


## 邻居按 (y, x) 升序去重。**为什么固定排序**：本仓声明式规格的 `refs:"topo"` 已把
## `ref i` 定义为"本格邻居按 (y,x) 升序的第 i 个"（`core/spec_rule_plugin.gd:_sorted_neighbors`），
## 编辑器生成的邻接表用同一序 ⇒ 两处一致，不会出现"生成期验证过、载入后索引漂移"的静默不可解。
static func _sorted_unique(nbs: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.assign(nbs)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	var dedup: Array[Vector2i] = []
	for p in out:
		if dedup.is_empty() or dedup[dedup.size() - 1] != p:
			dedup.append(p)
	return dedup


static func _keys(nbs: Array[Vector2i]) -> Array:
	var out: Array = []
	for p in nbs:
		out.append("%d,%d" % [p.x, p.y])
	return out


static func _err(reason: String) -> Dictionary:
	push_warning("WrapTopology: " + reason)
	return {"ok": false, "reason": reason, "topology": {}}
