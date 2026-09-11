# constraint_plugin.gd —— 全局约束插件基类（文档 23 号 §3.1 ② / 21 号 R22）
# 约束本质 = 判定函数：给定雷分布(mine_set)，是否满足约束。
# 契约（子类必须实现）：get_constraint_id / check / coupling_kind
# 可选：project_local / propagate / get_affected_cells / describe / z3_encode
class_name ConstraintPlugin
extends RefCounted

# coupling_kind 常量（23 号 §3.1 ② / 21 号 R22 / 22 号 K14）
const COUPLING_NONE := 0            # 不参与 L2 分量
const COUPLING_EQUALITY := 1        # 等式耦合：变量融合后并入分量
const COUPLING_CAPACITY := 2        # 容量类：计数约束传播（GCC），不并入分量
const COUPLING_SYMBOL_MAPPING := 3  # 符号映射：独立符号候选域传播（23 号 §15.2）


## 约束 id（唯一）。子类实现。
func get_constraint_id() -> StringName:
	return &""


## PluginManager 统一注册句柄（勿覆盖；映射到约束 id）。
func get_id() -> StringName:
	return get_constraint_id()


## 判定雷分布是否满足约束。子类实现。
## mine_set: Dictionary（Vector2i -> true）；extra: 附加数据（如 DT 骨牌划分）。
func check(_mine_set: Dictionary, _grid_size: Vector2i, _extra: Dictionary = {}) -> bool:
	return true


## 耦合类型（决定 L2 分量怎么处理，K14）。默认 NONE。
func coupling_kind() -> int:
	return COUPLING_NONE


## 规则说明（自动进规则图鉴）。子类可选覆盖。
func describe() -> Dictionary:
	return {"name": get_constraint_id(), "rule_text": ""}
