# adjacency_grid.gd —— 邻接表网格（异形/六边形/自定义拓扑，GridInterface 实现）
# 格子用稀疏 Vector2i 坐标标识；邻域由邻接表显式给出，不依赖矩形行列连续。
# 线索语义 = 拓扑邻域计数（等价 classic「周围格」）；方向型变体（4n/sc/clock）不适用。
# 这是 GridInterface 注释里预留的「CustomGrid（邻接表来自 grid_def 数据）」。
class_name AdjacencyGrid
extends GridInterface

var _cells: Dictionary = {}    # Vector2i -> Cell
var _adj: Dictionary = {}      # Vector2i -> Array[Vector2i]

## 几何风格（T4）：渲染层据此决定「按包围盒方阵画」还是「按六边形几何排布」。
##   "custom"     —— 无风格信息（旧拓扑 / 手写拓扑）= 按包围盒方阵渲染（向后兼容，行为零变化）
##   "hex"        —— 蜂窝：格心/六边形顶点按六边形几何计算（ui/board_view.gd 的 _hex_layout()）
##   "holed_grid" / "t488" —— 形状族标记，当前渲染仍走方阵（保留字符串供后续渲染扩展）
## 只影响**展示**，绝不影响邻接语义（线索仍是拓扑邻域计数）。
var style: String = "custom"
## 风格的附随参数（如 hex / t488 的 {"size": N}）。同样是展示/几何提示，不参与邻接语义。
var style_params: Dictionary = {}


## 从关卡拓扑描述构建。
## topo 两种等价形式（均只读、可种子化）：
##   1) {"positions":[{"x":..,"y":..},...], "adjacency":[{"a":{"x":..,"y":..},"b":{"x":..,"y":..}}, ...]}
##   2) {"positions":[...], "neighbors":{"x,y":["x,y",...], ...}}
## 可选字段：style（缺省 "custom"）、params（缺省 {}）——**旧拓扑无这两个字段 ⇒ 方阵渲染**，
## 故本函数对既有数据是纯向后兼容的扩展。
func setup_from_topo(topo: Dictionary) -> void:
	_cells.clear()
	_adj.clear()
	style = String(topo.get("style", "custom"))
	var sp: Variant = topo.get("params", {})
	style_params = sp if sp is Dictionary else {}
	var positions: Array = topo.get("positions", [])
	for p in positions:
		var d: Dictionary = p
		var pos := Vector2i(int(d["x"]), int(d["y"]))
		_cells[pos] = Cell.new()
		_adj[pos] = []

	# 形式 2：显式邻接表（优先）
	if topo.has("neighbors"):
		var nb: Dictionary = topo["neighbors"]
		for key in nb:
			var pos := _parse_key(String(key))
			if not _cells.has(pos):
				continue
			var lst: Array = nb[key]
			for nk in lst:
				var npos := _parse_key(String(nk))
				if _cells.has(npos):
					var cur: Array = _adj[pos]
					if not cur.has(npos):
						cur.append(npos)
		return

	# 形式 1：边列表
	var adj: Array = topo.get("adjacency", [])
	for e in adj:
		var edge: Dictionary = e
		var a_d: Dictionary = edge["a"]
		var b_d: Dictionary = edge["b"]
		var a := Vector2i(int(a_d["x"]), int(a_d["y"]))
		var b := Vector2i(int(b_d["x"]), int(b_d["y"]))
		if _cells.has(a) and _cells.has(b):
			var la: Array = _adj[a]
			var lb: Array = _adj[b]
			if not la.has(b):
				la.append(b)
			if not lb.has(a):
				lb.append(a)


## 是否按蜂窝六边形几何排布（渲染层唯一判据）。只读辅助，不改任何拓扑语义。
func has_hex_layout() -> bool:
	return style == "hex"


static func _parse_key(s: String) -> Vector2i:
	var parts := s.split(",")
	if parts.size() != 2:
		return Vector2i(0, 0)
	return Vector2i(int(parts[0]), int(parts[1]))


## 归一化坐标到非负（P0-A）：邻接表坐标可以是任意的（含负值，如六边形以中心为原点），
## 而 CP-SAT 的 cell 索引是 [0,rows)×[0,cols)，负坐标会越界。
## 返回归一化后的新实例（原实例不变）。坐标已非负时返回原实例（零拷贝）。
static func normalized(topo: GridInterface) -> AdjacencyGrid:
	var min_c := 1 << 30
	var min_r := 1 << 30
	for p in topo.all_positions():
		min_c = mini(min_c, p.x)
		min_r = mini(min_r, p.y)
	if min_c == 0 and min_r == 0:
		return topo as AdjacencyGrid
	var positions: Array = []
	for p in topo.all_positions():
		positions.append({"x": p.x - min_c, "y": p.y - min_r})
	var adjacency: Array = []
	var seen := {}
	# L1 交叉说明（2026-09-21）：本处的去重键按遍历序 (p, nb)，与 core/shape_generator.gd 的
	# `_add_edge`（字典序 lo/hi）输出定向不同、集合语义相同——不要断言两处 adjacency 逐字节一致。
	for p in topo.all_positions():
		for nb in topo.get_neighbors(p):
			var rkey := "%d,%d|%d,%d" % [nb.x, nb.y, p.x, p.y]
			if seen.has(rkey):
				continue
			seen["%d,%d|%d,%d" % [p.x, p.y, nb.x, nb.y]] = true
			adjacency.append({
				"a": {"x": p.x - min_c, "y": p.y - min_r},
				"b": {"x": nb.x - min_c, "y": nb.y - min_r},
			})
	# 几何风格随坐标一起搬过去：平移不改形状，但若把 style 丢了，蜂窝盘会被静默降级成方阵渲染。
	var moved := {"positions": positions, "adjacency": adjacency}
	if topo is AdjacencyGrid:
		var src := topo as AdjacencyGrid
		if src.style != "custom":
			moved["style"] = src.style
			if not src.style_params.is_empty():
				moved["params"] = src.style_params
	var out := AdjacencyGrid.new()
	out.setup_from_topo(moved)
	return out


func get_cell(pos: Vector2i) -> Cell:
	return _cells.get(pos) as Cell


func get_neighbors(pos: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var n: Variant = _adj.get(pos, [])
	if n is Array:
		for v in n:
			out.append(v)
	return out


func in_board(pos: Vector2i) -> bool:
	return _cells.has(pos)


func all_positions() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for k in _cells:
		out.append(k)
	return out


func cell_count() -> int:
	return _cells.size()


## 包围盒尺寸（渲染布局用）。遍历请用 all_positions()，不要假设坐标连续。
func size() -> Vector2i:
	var positions := all_positions()
	if positions.is_empty():
		return Vector2i.ZERO
	var min_x := 1 << 30
	var max_x := -(1 << 30)
	var min_y := 1 << 30
	var max_y := -(1 << 30)
	for p in positions:
		min_x = mini(min_x, p.x)
		max_x = maxi(max_x, p.x)
		min_y = mini(min_y, p.y)
		max_y = maxi(max_y, p.y)
	return Vector2i(max_x - min_x + 1, max_y - min_y + 1)
