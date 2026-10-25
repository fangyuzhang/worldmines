# def_engine.gd —— Def/Comp 组件化引擎（文档第二篇 §2）
# 规则 = 声明式 Def。mod 可注册新 Def，求解器统一读 Def。
# 内置 8 线索 + 7 约束在此注册；ClueEngine/ConstraintEngine 作为底层 IR 原子被复用。
class_name DefEngine
extends RefCounted

# ==== IR 原子：线索窗口 ====
const WINDOW_N8 := "n8"                # 8 邻
const WINDOW_N4 := "n4"                # 4 邻（正交）
const WINDOW_DIAG := "diag"            # 对角 4 邻
const WINDOW_RING8 := "ring8"          # 8 邻环序（顺时针）
const WINDOW_RAY_RIGHT := "ray_right"  # 向右射线
const WINDOW_SPLIT := "split"          # 正交|对角 双值

# ==== IR 原子：线索聚合 ====
const AGG_SUM := "sum"                 # 求和（雷数）
const AGG_WEIGHTED_SUM := "weighted_sum"  # 加权和（曼哈顿距离）
const AGG_FIRST_INDEX := "first_index"    # 首个雷方位/距离
const AGG_RUN_COUNT := "run_count"        # 连续段数

# ==== IR 原子：全局约束 op ====
const OP_SYMMETRY_AXIS := "symmetry_axis"       # 镜像
const OP_SEQUENCE_DIFF := "sequence_diff"       # 相邻行差 1
const OP_PATTERN_FORBIDDEN := "pattern_forbidden"  # 2×2 至多 2 雷
const OP_QUADRANT_EQUAL := "quadrant_equal"     # 四象限雷数相等
const OP_ENDPOINT_EQUAL := "endpoint_equal"     # 端点列雷数相等
const OP_COLOR_EQUAL := "color_equal"           # 黑白雷数相等
const OP_PARTITION_PAIRING := "partition_pairing"  # 骨牌每块恰 1 雷

# Def 注册表：线索 def_name -> def；约束 def_name -> def
var clue_defs: Dictionary = {}
var constraint_defs: Dictionary = {}


func _init() -> void:
	_register_builtin()


## 内置 Def 注册（8 线索 + 7 约束）。
func _register_builtin() -> void:
	clue_defs["classic"] = {"type": "clue", "window": WINDOW_N8, "aggregate": AGG_SUM, "max": 8, "min_clue": 0}
	clue_defs["4n"] = {"type": "clue", "window": WINDOW_N4, "aggregate": AGG_SUM, "max": 4, "min_clue": 0}
	clue_defs["sc"] = {"type": "clue", "window": WINDOW_DIAG, "aggregate": AGG_SUM, "max": 4, "min_clue": 0}
	clue_defs["clock"] = {"type": "clue", "window": WINDOW_RING8, "aggregate": AGG_FIRST_INDEX, "max": 8, "min_clue": 0}
	clue_defs["fr"] = {"type": "clue", "window": WINDOW_RAY_RIGHT, "aggregate": AGG_FIRST_INDEX, "max": -1, "min_clue": -1}
	clue_defs["loopruns"] = {"type": "clue", "window": WINDOW_RING8, "aggregate": AGG_RUN_COUNT, "max": 4, "min_clue": 0}
	clue_defs["distsum"] = {"type": "clue", "window": WINDOW_N8, "aggregate": AGG_WEIGHTED_SUM, "max": 12, "min_clue": 0}
	clue_defs["hv"] = {"type": "clue", "window": WINDOW_SPLIT, "aggregate": AGG_SUM, "max": 4, "min_clue": 0}

	constraint_defs["mx"] = {"type": "constraint", "op": OP_SYMMETRY_AXIS}
	constraint_defs["rl"] = {"type": "constraint", "op": OP_SEQUENCE_DIFF}
	constraint_defs["pf"] = {"type": "constraint", "op": OP_PATTERN_FORBIDDEN}
	constraint_defs["qd"] = {"type": "constraint", "op": OP_QUADRANT_EQUAL}
	constraint_defs["ep"] = {"type": "constraint", "op": OP_ENDPOINT_EQUAL}
	constraint_defs["4c"] = {"type": "constraint", "op": OP_COLOR_EQUAL}
	constraint_defs["dt"] = {"type": "constraint", "op": OP_PARTITION_PAIRING}


## 线索计算：def_name -> 线索值（Variant：int / Array / "inf"）。
func compute_clue(def_name: String, mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
	var def: Dictionary = clue_defs[def_name]
	var window: String = def["window"]
	var aggregate: String = def["aggregate"]
	match window:
		WINDOW_N8:
			if aggregate == AGG_WEIGHTED_SUM:
				return _weighted_sum(mine_set, pos, grid_size)
			return ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.ring_dirs())
		WINDOW_N4:
			return ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.orthogonal_dirs())
		WINDOW_DIAG:
			return ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.diagonal_dirs())
		WINDOW_RING8:
			if aggregate == AGG_RUN_COUNT:
				return ClueEngine._loop_runs_value(mine_set, pos, grid_size)
			return ClueEngine._clock_value(mine_set, pos, grid_size)
		WINDOW_RAY_RIGHT:
			return ClueEngine._fr_value(mine_set, pos, grid_size)
		WINDOW_SPLIT:
			return [
				ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.orthogonal_dirs()),
				ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.diagonal_dirs()),
			]
	return 0


## 约束检查：def_name -> bool。
func check_constraint(def_name: String, mine_set: Dictionary, grid_size: Vector2i, extra: Dictionary = {}) -> bool:
	var def: Dictionary = constraint_defs[def_name]
	match def["op"]:
		OP_SYMMETRY_AXIS:
			return ConstraintEngine._check_mx(mine_set, grid_size)
		OP_SEQUENCE_DIFF:
			return ConstraintEngine._check_rl(mine_set, grid_size)
		OP_PATTERN_FORBIDDEN:
			return ConstraintEngine._check_pf(mine_set, grid_size)
		OP_QUADRANT_EQUAL:
			return ConstraintEngine._check_qd(mine_set, grid_size)
		OP_ENDPOINT_EQUAL:
			return ConstraintEngine._check_ep(mine_set, grid_size)
		OP_COLOR_EQUAL:
			return ConstraintEngine._check_4c(mine_set, grid_size)
		OP_PARTITION_PAIRING:
			return ConstraintEngine._check_dt(mine_set, grid_size, extra)
	return true


## 注册自定义线索 Def（mod 调用）。返回是否成功。
func register_clue_def(def_name: String, def: Dictionary) -> bool:
	if not def.has("window") or not def.has("aggregate"):
		return false
	clue_defs[def_name] = def
	return true


## 注册自定义约束 Def（mod 调用）。返回是否成功。
func register_constraint_def(def_name: String, def: Dictionary) -> bool:
	if not def.has("op"):
		return false
	constraint_defs[def_name] = def
	return true


## 曼哈顿和：正交×1 + 对角×2。
func _weighted_sum(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> int:
	return ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.orthogonal_dirs()) \
		+ 2 * ClueEngine._count_dirs(mine_set, pos, grid_size, ClueEngine.diagonal_dirs())
