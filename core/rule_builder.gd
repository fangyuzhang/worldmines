# rule_builder.gd —— 规则构建器（自举式规则平台给创作者的公共 API）
# 规则作者在 build_clue_constraints / build_global_constraints 中拿到本对象，
# 用可组合原语直接「写约束」（对齐社区 create_constraints 的表达力）：
#
#   func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
#       var nbs := b.neighbors(pos, ClueEngine.ring_dirs())
#       b.add_eq(b.sum(b.cell_vars(nbs)), int(value))
#
# 说谎者示例（无需平台新增任何接口）：
#   var lie := b.bool_var()
#   b.add_eq(b.sum(b.cell_vars(nbs)), value, [b.not_lit(lie)])  # 开关关闭时线索失效
#   b.add_eq(b.sum([lies...]), k)                                # 恰 k 条失效
class_name RuleBuilder
extends RefCounted

var rows: int
var cols: int
## 总雷数（供 total_mines 等全局规则读取；-1 = 未知）。
var total_mines: int
## 已声明的 aux 变量（[{"i":int,"kind":"bool"} | {...,"kind":"int","lo","hi"}]）。
var aux_vars: Array = []
## 已添加的约束 IR 节点列表。
var constraints: Array = []
## 拓扑（方案 A2）：非空时邻域/边界走拓扑邻接表（异形/六边形），否则走矩形 dirs 偏移。
## 默认 null = 矩形，完全向后兼容。
var topology: GridInterface = null

var _aux_base: int
var _aux_count: int


func _init(p_rows: int, p_cols: int, p_total_mines: int = -1, p_aux_base: int = 0) -> void:
	rows = p_rows
	cols = p_cols
	total_mines = p_total_mines
	_aux_base = p_aux_base


## 下一个 aux 编号（多线索 IR 合并进同一 spec 时保证编号全局唯一）。
func next_aux_index() -> int:
	return _aux_base + _aux_count


## 设置拓扑（异形棋盘）。设置后 in_board/neighbors 走拓扑邻接表，忽略 dirs 偏移。
func set_topology(t: GridInterface) -> void:
	topology = t


func in_board(r: int, c: int) -> bool:
	if topology != null:
		return topology.in_board(Vector2i(c, r))
	return r >= 0 and r < rows and c >= 0 and c < cols


## 格布尔变量（r=行, c=列）。越界 → const 0（方便写射线/环序等开窗口规则）。
func cell_var(r: int, c: int) -> Dictionary:
	if not in_board(r, c):
		return CPIR.const_expr(0)
	return CPIR.cell_var(r, c)


## pos.x=列, pos.y=行。
func cell_var_pos(pos: Vector2i) -> Dictionary:
	return cell_var(pos.y, pos.x)


## 批量取格变量（越界格自动为 const 0，被 sum 忽略）。
func cell_vars(positions: Array) -> Array:
	var out: Array = []
	for p in positions:
		out.append(cell_var(int(p.y), int(p.x)))
	return out


## 邻域（板内过滤）。dirs: Vector2i 偏移数组（任意形状：8邻/4邻/骑士/射线……）。
## 拓扑非空（异形）时忽略 dirs，直接走拓扑邻接表（邻域由拓扑定义，无「方向」语义）。
func neighbors(pos: Vector2i, dirs: Array) -> Array[Vector2i]:
	if topology != null:
		return topology.get_neighbors(pos)
	var out: Array[Vector2i] = []
	for d in dirs:
		var p: Vector2i = pos + d
		if in_board(p.y, p.x):
			out.append(p)
	return out


## 新建布尔 aux 变量（开关 / 说谎标记 / 可选窗口选择……）。
func bool_var() -> Dictionary:
	var i := next_aux_index()
	_aux_count += 1
	aux_vars.append({"i": i, "kind": "bool"})
	return CPIR.aux_var(i)


## 新建整数 aux 变量（注意：GDScript 黑盒求值不支持，仅 C# 后端可用）。
func int_var(lo: int, hi: int) -> Dictionary:
	var i := next_aux_index()
	_aux_count += 1
	aux_vars.append({"i": i, "kind": "int", "lo": lo, "hi": hi})
	return CPIR.aux_var(i)


## 按格缓存的整数变量（v3.0 性能基建）：同一格的共享量（如邻序的经典雷数 v）
## 会被「本格约束」与「所有邻居的约束」反复引用，必须复用同一变量——
## 否则各调用点各建一份，约束量随度数平方级膨胀且语义要靠等值约束硬拉回。
## 缓存以 (列,行) 为键；builder 生命周期 = 单次 spec 构建 → 天然 per-spec 安全。
var _cell_int_cache: Dictionary = {}

func cell_int_var(r: int, c: int, lo: int, hi: int) -> Dictionary:
	var key := Vector2i(c, r)
	if _cell_int_cache.has(key):
		return _cell_int_cache[key]
	var v := int_var(lo, hi)
	_cell_int_cache[key] = v
	return v


## 规则作者的 per-spec 临时存储（builder 生命周期内有效，不同 spec 互不影响）。
## 用途：规则需要跨「逐格调用」维护状态时（如「某格的共享变量是否已初始化」），
## 平台不内置具体语义，由规则自行约定键。
var scratch: Dictionary = {}


## 按格标记（配合 scratch）：首次返回 true，其后 false。便于「初始化一次」类逻辑。
func mark_once(key: Variant) -> bool:
	if scratch.has(key):
		return false
	scratch[key] = true
	return true


func not_lit(lit: Dictionary) -> Dictionary:
	return CPIR.not_lit(lit)


func sum(xs: Array) -> Dictionary:
	return CPIR.sum(xs)


## 加权和（xs 须为变量引用或 const）。
func wsum(ws: Array, xs: Array) -> Dictionary:
	return CPIR.wsum(ws, xs)


## 仿射线性表达式：Σ ws[i]·xs[i] + c（任意线性约束的通用表达，如相邻行差==1）。
func lin(ws: Array, xs: Array, c: int = 0) -> Dictionary:
	return CPIR.lin(ws, xs, c)


func const_expr(v: int) -> Dictionary:
	return CPIR.const_expr(v)


# ==== 添加约束（enforce 非空 → OnlyEnforceIf 语义：开关全开才生效）====
# 表达式参数可传 int（自动包装为常量）：b.add_eq(b.sum(xs), 3) 等价于 …== const 3。

func add_eq(a: Variant, b: Variant, enforce: Array = []) -> void:
	_add(CPIR.c_eq(_wrap(a), _wrap(b)), enforce)


func add_le(a: Variant, b: Variant, enforce: Array = []) -> void:
	_add(CPIR.c_le(_wrap(a), _wrap(b)), enforce)


func add_lt(a: Variant, b: Variant, enforce: Array = []) -> void:
	_add(CPIR.c_lt(_wrap(a), _wrap(b)), enforce)


func add_bool_or(lits: Array, enforce: Array = []) -> void:
	_add(CPIR.c_bool_or(lits), enforce)


func add_bool_and(lits: Array, enforce: Array = []) -> void:
	_add(CPIR.c_bool_and(lits), enforce)


func add_imp(a: Dictionary, b: Dictionary, enforce: Array = []) -> void:
	_add(CPIR.c_imp(a, b), enforce)


func add_iff(a: Dictionary, b: Dictionary, enforce: Array = []) -> void:
	_add(CPIR.c_iff(a, b), enforce)


func add_all_diff(xs: Array, enforce: Array = []) -> void:
	_add(CPIR.c_all_diff(xs), enforce)


## 直接添加 CPIR 工厂产出的约束节点。
func add(constraint: Dictionary, enforce: Array = []) -> void:
	_add(constraint, enforce)


func _add(c: Dictionary, enforce: Array) -> void:
	if enforce.is_empty():
		constraints.append(c)
	else:
		constraints.append(CPIR.c_enforce(enforce, c))


## int → 常量表达式；Dictionary（IR 节点）原样通过。
static func _wrap(v: Variant) -> Dictionary:
	if v is Dictionary:
		return v
	return CPIR.const_expr(int(v))
