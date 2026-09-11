# symbol_mapping.gd —— 符号映射约束（文档 23 号 §15.2）
# 引擎级原语之一：覆盖"加密线索"整类玩法（2E 字母加密、颜色加密、凯撒位移、摩斯码…）。
# 数学结构统一为：线索值 = π(看到的符号)，π 是未知全局映射。
# 继承 ConstraintPlugin（coupling_kind 返回 SYMBOL_MAPPING），按 22 号 K14 走独立符号候选域传播。
class_name SymbolMappingConstraint
extends ConstraintPlugin


## 映射类型。
const MAPPING_BIJECTION := 0    # 双射（每符号恰 1 值 + 每值恰 1 符号，2E 的"一一映射"）
const MAPPING_INJECTION := 1    # 单射（不同符号不同值）
const MAPPING_SURJECTION := 2   # 满射
const MAPPING_ARBITRARY := 3    # 任意


## 映射 id（唯一）。子类实现。
func get_mapping_id() -> StringName:
	return &""


## 覆写 ConstraintPlugin 的 get_constraint_id，避免双 id 冲突。
func get_constraint_id() -> StringName:
	return get_mapping_id()


## PluginManager 统一注册句柄（映射到映射 id）。
func get_id() -> StringName:
	return get_mapping_id()


## 耦合类型：符号映射走独立候选域传播，不得并入 L2 连通分量（K14）。
func coupling_kind() -> int:
	return COUPLING_SYMBOL_MAPPING


## 符号集合（如 [A..I]）。子类实现。
func symbols() -> Array[StringName]:
	return []


## 语义值域（如 [0,8]）。子类实现。
func value_domain() -> Vector2i:
	return Vector2i(0, 8)


## 映射类型。子类实现。
func mapping_kind() -> int:
	return MAPPING_BIJECTION


## 数独式候选消除：根据已翻线索，收缩每个符号的候选值集。子类实现。
## 返回是否有收缩。
func propagate(_state: Variant = null) -> bool:
	return false


## L2 局部投影（叠加到枚举过滤）。子类按需覆盖。
func project_local(_cells: Array, _state: Variant = null) -> Dictionary:
	return {}


## z3 编码（BIJECTION = perfect matching：all-different / cardinality）。子类按需覆盖。
func z3_encode(_encoder: Variant) -> void:
	pass


## 规则说明（进规则图鉴）。
func describe() -> Dictionary:
	return {"name": get_mapping_id(), "rule_text": ""}
