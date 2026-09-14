# rule_plugin.gd —— 规则插件基类（自举式规则平台的创作者契约）
# 与 CluePlugin（黑盒纯函数）/ ConstraintPlugin（黑盒判定）并存且互通：
#   - 新创作者：实现 build_*_constraints，用 RuleBuilder 原语直接写结构化约束
#     → 可翻译到 CP-SAT（快），支持 enforce 开关 / 说谎者等任意组合。
#   - 兼容性：RuleOracle 用 IR 黑盒求值实现 check，可直接接入
#     BruteForceOracle / SolverPerfectPlayer 的既有验证管线。
#
# 线索规则（KIND_CLUE）契约：
#   compute_clue(mine_set, pos, grid_size) -> Variant        正向：雷分布 → 线索值（展示/建盘）
#   build_clue_constraints(builder, pos, value)              逆向：给定值 → 结构化约束
# 全局规则（KIND_GLOBAL）契约：
#   build_global_constraints(builder)                        棋盘级约束（镜像/禁形/总数…）
# 可选：
#   applies_to(pos, grid_size)     哪些格携带本线索（默认全部）
#   place_mines(rng, cols, rows, count)  构造式布雷（默认空 = 生成器随机）
class_name RulePlugin
extends RefCounted


const KIND_CLUE := "clue"
const KIND_GLOBAL := "global"


## 规则 id（唯一）。子类必须实现。
func get_rule_id() -> StringName:
	return &""


## PluginManager 统一注册句柄（勿覆盖；映射到规则 id）。
func get_id() -> StringName:
	return get_rule_id()


## 规则类别：KIND_CLUE（格子级线索）/ KIND_GLOBAL（棋盘级约束）。
func get_kind() -> String:
	return KIND_CLUE


## 规则说明（自动进规则图鉴）。子类可选覆盖。
func describe() -> Dictionary:
	return {"name": String(get_rule_id()), "rule_text": ""}


# ==== 线索规则契约 ====

## 该格是否携带本线索（默认全部非雷格）。
func applies_to(_pos: Vector2i, _grid_size: Vector2i) -> bool:
	return true


## 正向计算线索值。mine_set: Dictionary（Vector2i -> true）。
func compute_clue(_mine_set: Dictionary, _pos: Vector2i, _grid_size: Vector2i) -> Variant:
	return 0


## 逆向：给定线索值，向模型写结构化约束（value 即 compute_clue 的返回值）。
func build_clue_constraints(_b: RuleBuilder, _pos: Vector2i, _value: Variant) -> void:
	pass


## v3.0 扩展：线索规则的「棋盘级」约束（可选覆写）——
## 需要「全盘配额」的算子（如变径 O4 的 ∑_p w_p = k）在生成 spec 时被调用一次。
## 语义：b 是独立于逐格 builder 的「全局 builder」，其 constraints 并入 spec["globals"]
## （与全局规则 IR 同锅翻译）；aux 编号空间由 build_spec 统一管理（先于逐格分配）。
## 注意：逐格 builder 与全局 builder 不共享 aux 变量。跨格共享量的正确写法：
## 把「共享量的语义」用「全盘统一的『按格编码』」表达（如 w_p 在逐格 builder 按格重建、k 配额在
## 全局 builder 用「相同构造」重建——两边用确定性规则生成『内容一致』的变量集，
## CP-SAT 层面各自独立、语义由约束保证；O4 采用此模式）。
func build_global_clue_constraints(_b: RuleBuilder) -> void:
	pass


## 该规则是否支持遮蔽（问号格）。计数型（classic/4n/sc/distsum）返回 true；
## 非计数型（clock/fr/loopruns/hv）遮蔽语义不成立，返回 false。
func supports_mask() -> bool:
	return false


## 遮蔽（问号）格约束：线索值域落在 [lo, hi]。仅 supports_mask() 为 true 时实现。
## 计数型默认语义：sum(窗口) ∈ [lo, hi]（即 lo ≤ sum ≤ hi）。
func build_interval_constraints(_b: RuleBuilder, _pos: Vector2i, _lo: int, _hi: int) -> void:
	pass


## 值域上限（遮蔽 interval 的 hi）。计数型覆盖；默认 8（classic/4n/sc 自然 ≤8，冗余无害）。
func value_upper_bound(_grid_size: Vector2i) -> int:
	return 8


## 「线索值语义为 0（或分量含 0）」时保证安全的邻格（连锁扩散用，plan1.9 §7.2 变体感知）。
## value 为当前格线索值（int 或 Array），规则自行判断扩散条件。
## 默认空数组 = 不扩散（最安全默认，如 FR 射线规则）。
## 平台不硬编码扩散语义——窗口由规则自己声明（8邻/4邻/骑士步/自定义……）。
func zero_safe_neighbors(_pos: Vector2i, _grid_size: Vector2i, _value: Variant = null) -> Array[Vector2i]:
	return []


# ==== 全局规则契约 ====

## 棋盘级约束（可读 b.rows / b.cols / b.total_mines）。
func build_global_constraints(_b: RuleBuilder) -> void:
	pass


## 构造式布雷（镜像/骨牌等结构性布局）。返回空数组 = 交给生成器随机。
func place_mines(_rng: RandomNumberGenerator, _cols: int, _rows: int, _count: int) -> Array[Vector2i]:
	return []


# ==== 共享工具 ====

## 数 mine_set 中 dirs 邻域的雷数（内置计数规则共用）。
## 单点化：委托给 ClueEngine._count_dirs，避免与内置变体路径（ClueEngine）各写一份计数逻辑。
static func count_dirs(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i, dirs: Array) -> int:
	return ClueEngine._count_dirs(mine_set, pos, grid_size, dirs)


## dirs 偏移 → 板内邻格列表（zero_safe_neighbors 共用的便捷实现）。
static func dirs_to_neighbors(pos: Vector2i, grid_size: Vector2i, dirs: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in dirs:
		var p: Vector2i = pos + d
		if p.x >= 0 and p.x < grid_size.x and p.y >= 0 and p.y < grid_size.y:
			out.append(p)
	return out
