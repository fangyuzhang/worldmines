# solver_variable.gd —— 求解器变量域注册（文档 23 号 §15.3）
# 引擎级原语之一：声明一类新的推理变量。现有求解器只有"格子=雷/安全"一种变量；
# 2E 引入 π（置换）、别的玩法可能引入"温度/能量/步数/方向/序列号"等新变量。
# 与其一个个预判，不如把"变量种类"本身开放。
class_name SolverVariablePlugin
extends RefCounted


## 变量域类型。
const DOMAIN_BOOLEAN := 0      # 二值
const DOMAIN_ENUM := 1         # 枚举（domain_size 个取值）
const DOMAIN_INT_RANGE := 2    # 整数区间 [a,b]


## 变量 id（唯一）。子类实现。
func get_var_id() -> StringName:
	return &""


## PluginManager 统一注册句柄（映射到变量 id）。
func get_id() -> StringName:
	return get_var_id()


## 域类型。子类实现。
func domain_kind() -> int:
	return DOMAIN_BOOLEAN


## ENUM 时取值个数。子类按需覆盖。
func domain_size() -> int:
	return 2


## INT_RANGE 时值域 [a,b]。子类按需覆盖。
func int_range() -> Vector2i:
	return Vector2i(0, 1)


## 该变量的传播规则（候选收缩）。子类实现。
## assignments: 当前赋值快照；state: 求解状态。返回是否有收缩（false = 无变化）。
func propagate(_assignments: Dictionary, _state: Variant = null) -> bool:
	return false


## z3 编码（可选）。提供则可进官方验证（z3 序贯可行性链这一半）；不提供则黑盒，只能工坊 🧩。
func z3_encode(_encoder: Variant, _vars: Variant) -> void:
	pass


## 变量说明（进规则图鉴/提示）。子类可覆盖。
func describe() -> Dictionary:
	return {"name": get_var_id(), "rule_text": ""}
