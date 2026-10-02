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


# ==== 棋盘几何声明（v4.x：把「异形盘 × 变体」的门控从平台硬编码改为规则自述）====
#
# 为什么需要：生成期原先把「异形拓扑 + 非 classic 线索」一律强制 classic
#（core/puzzle_generator.gd:431），方向型线索在邻接表上语义矛盾没错，但「只依赖邻域」的
# 计数型变体被**一并**降级——这正是用户点名的「异形盘可用、变体可用、组合却被误判不可行」。
# 改为规则显式声明几何依赖，平台据 supports_topology() 决定是否原样使用。
#
# 兼容铁律：默认值必须 = 今天的行为（未声明的规则一律保守判「仅矩形」）。
const GEO_ADJ_GENERIC := 0   # 只依赖邻域/邻接表 ⇒ 任意棋盘可用
const GEO_RECT_ONLY := 1     # 依赖行列/方向/中轴/象限/对称/骨牌划分 ⇒ 仅矩形盘


## 规则声明的棋盘几何种类。默认 GEO_RECT_ONLY = 今天的行为（第三方 mod 不声明时零变化）。
func geometry_kind() -> int:
	return GEO_RECT_ONLY


## 是否支持任意拓扑棋盘（异形/邻接表）。生成期门控唯一判据。
func supports_topology() -> bool:
	return geometry_kind() == GEO_ADJ_GENERIC


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


## 拓扑盘（邻接表）上的「0 值安全邻格」（v4.x，可选覆写）。
##
## 【为什么必须有这条契约（2026-10-02 补齐"值接了、扩散没接"）】
## `zero_safe_neighbors` 吃的是**矩形 grid_size + 规则自己的偏移**，在异形盘上要么数不到
##（偏移越界）要么数错（矩形对角在蜂窝上根本不是邻居）；于是 `core/board.gd:_flood_neighbors`
## 原先只能在拓扑分支**硬编码**"0 值 ⇒ 全部拓扑邻格"。对计数型规则（classic）那是对的，
## 对加权/压缩型的声明式规格则是"把不在线索保证范围内的格免费翻开"——
## 难度低于生成画像、与提示结论不一致（本项目反复出现的同一类分叉）。
##
## 默认实现 = 把那段硬编码**搬进契约**（计数语义逐位不变）；声明拓扑能力的规则应当按自己的
## 0 值语义覆写：加权型应返回空（不扩散），只覆盖部分邻居的应返回空。
## 非整数线索值（双值/射线型）一律不扩散——与 `zero_safe_neighbors` 的口径一致。
func zero_safe_neighbors_topo(pos: Vector2i, topo: GridInterface, value: Variant = null) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if topo == null or not (value is int):
		return out
	if int(value) == 0:
		out.assign(topo.get_neighbors(pos))
	return out


# ==== 全局规则契约 ====

## 棋盘级约束（可读 b.rows / b.cols / b.total_mines）。
func build_global_constraints(_b: RuleBuilder) -> void:
	pass


## 构造式布雷（镜像/骨牌等结构性布局）。返回空数组 = 交给生成器随机。
func place_mines(_rng: RandomNumberGenerator, _cols: int, _rows: int, _count: int) -> Array[Vector2i]:
	return []


## 拓扑构造式布雷（异形/邻接表棋盘，v4.x）。默认空数组 = 「本规则不提供构造式」，
## 交回生成器既有路径（CP-SAT / 随机）——**默认返回空 ⇒ 今天的行为逐位不变**。
## 语义纪律：空 = 不提供，**不是**「再试一次」；本接口禁暴力重试（与 place_mines 同纪律）。
## 契约：返回非空时必须恰为 count 颗、且全部落在 topo 的存活格内（生成器会硬校验雷数）。
func place_mines_topo(_rng: RandomNumberGenerator, _topo: GridInterface, _count: int) -> Array[Vector2i]:
	return []


## 异形/邻接表棋盘上的线索值（v4.x，可选覆写）。
##
## 为什么必须有这个契约：生成期在异形盘上**不调用** compute_clue（它按矩形 grid_size 与 dirs 偏移
## 求值），历史上直接硬编码「拓扑邻域雷数」（core/puzzle_generator.gd:505-506）。若只放开
## supports_topology() 门控而不改这里，加权/压缩/奇偶型规则会拿到「无权重计数」的值，而其
## build_clue_constraints 按自己的语义建约束 ⇒ 值与模型自相矛盾（用户点名的「组合出问题」）。
##
## 默认实现 = 数 topo.get_neighbors(pos) 中的雷格数 —— 与今天异形盘的硬编码口径**逐位同义**，
## 故 classic（不覆写）零变化。声明 supports_topology() == true 的规则**应当**覆写本方法；
## 若不覆写，其线索值就必须恰为邻域雷数（生成期不再替它猜语义）。
func compute_clue_topo(mine_set: Dictionary, pos: Vector2i, topo: GridInterface, _grid_size: Vector2i) -> Variant:
	if topo == null:
		return 0
	var n := 0
	for p in topo.get_neighbors(pos):
		if mine_set.has(p):
			n += 1
	return n


## 隐藏态初始化（P0，2026-09-27）：**只**为「当前盘面」采样本规则的隐藏态，不产出雷。
##
## 为什么必须有这个入口：隐藏态原本**只在 place_mines 内部**采样（o4 抽 r=2 格、o5x 抽 s=1 格）。
## 而生成器在以下路径上**不会调用线索规则的 place_mines**：
##   · 带全局规则的复合档（`_place_mines_rules_raw`：多 G 走 find_solution / 单 G 走 G.place_mines）；
##   · 上述构造式失败的 CP-SAT 兜底；· 最终随机兜底。
## 于是复合档的隐藏态**从未被采样**：全新会话下为空 ⇒ `compute_clue` 退化成「只算八邻」
##（o5x 退化成「只走主斜线」，隐藏选择消失），而线索数字与求解器读的是同一份状态，
## 故 R01 验证仍通过（`verify_fail=0`）⇒ **坏关静默过关**（2026-09-27 实测确认）。
## 更隐蔽的是规则为**注册表单例**：残留上一盘状态时 `export_hidden_state()` 非空，
## 落盘后玩家侧也能复现 ⇒ 表面自洽，但该状态不属于本盘（跨尺寸时连 k 配额都对不上，
## 实测 7×7 盘落盘 16 个 s=1 格而 `_k_of(7,7)=12`）。
##
## 契约（实现者须遵守）：
##   1. **幂等**：先清空自己的状态再采样（不得叠加）。
##   2. **与 place_mines 内的采样逐 rng 调用一致**——推荐 place_mines 直接调用本方法作为首步，
##      这样「单线索档」的产物**逐字节不变**（黄金网约束），复合档才走独立初始化。
##   3. 只依赖 (rng, cols, rows, k 旋钮)，**不得依赖雷布局**（否则无法在外部布雷后复现）。
##
## 默认空实现 = 无隐藏态（未实现本方法的规则零影响）。能力键：hidden_state（declares()）。
func init_hidden_state(_rng: RandomNumberGenerator, _cols: int, _rows: int, _count: int) -> void:
	pass


# ==== 隐藏态导出 / 导入（载盘复现，2026-09-16）====

## 导出「生成时决定的隐藏态」——有隐藏状态的规则覆写（如 o4 半径集合 r2 / o5x 斜向集合 s1）。
## 契约：生成落盘时调用本方法，返回非空字典 → 写入 level["hidden_state"][rule_id]；
##       Board.load_level 读取后对同一规则实例调用 import_hidden_state 恢复。
## 返回空字典（默认）= 无隐藏态（载盘无损）。
## 背景：此前隐藏态不落盘 → 载盘后 compute_clue 用空/残留状态 → 线索数字全错
##      （HANDOFF 已知坑 #18，2026-09-15 侦破）。新增隐藏态规则务必实现本对方法。
func export_hidden_state() -> Dictionary:
	return {}


## 导入隐藏态（与 export_hidden_state 严格配对：import(export()) == 原状态）。
func import_hidden_state(_state: Dictionary) -> void:
	pass


# ==== 能力声明（2026-09-16，复盘评审 C2/C3 整改）====

## 规则**显式声明自身能力**，供生成器/工具做能力校验——取代 `has_method` 鸭子探测（隐式契约）。
## 返回形如 {"k_knob": true, "hidden_state": true} 的字典；**默认 {} = 未声明**。
## 兼容策略：调用方应「**优先查 declares()、未声明时回退 has_method**」——旧规则零改动可用，
## 新规则建议显式声明（新增能力时同步声明，避免「实现了但工具不知道 / 工具探测了但规则没实现」）。
## 已知能力键：k_knob（set_k_public/set_k_ratio/is_k_public）、hidden_state（export/import_hidden_state）、
##            mask（supports_mask/build_interval_constraints）、place_mines（构造式布雷）。
func declares() -> Dictionary:
	return {}


## 隐藏态坐标数组排序比较器（先 r 后 c，保证导出确定序；mod 可用 sort_custom 引用）。
static func state_pos_less(a: Dictionary, b: Dictionary) -> bool:
	return int(a["r"]) * 1000 + int(a["c"]) < int(b["r"]) * 1000 + int(b["c"])


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
