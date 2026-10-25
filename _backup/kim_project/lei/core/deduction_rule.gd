# deduction_rule.gd —— 推理规则插件基类（文档 23 号 §14.8 / 21 号 R31）
# 不想重写整个求解器，只想贡献一种推理技巧？注册一条规则即可。
# 引擎把内置规则与 Mod 规则一视同仁地跑，结论同样过 SolverValidator；
# 详细提示面板会显示「本步由规则 XXX（来自 Mod YYY）推出」→ 作者被看见。
class_name DeductionRulePlugin
extends RefCounted


## 规则 id（唯一）。子类实现。
func get_rule_id() -> StringName:
	return &""


## PluginManager 统一注册句柄（映射到规则 id）。
func get_id() -> StringName:
	return get_rule_id()


## 挂在哪一层：1=L1（单格直推）/ 2=L2（邻域枚举）/ 3=L3（归谬）。
func layer() -> int:
	return 1


## 规则名（进提示面板/规则图鉴）。子类可覆盖。
func rule_name() -> String:
	return str(get_rule_id())


## 应用规则，返回必然结论数组。子类实现。
## 输入 PlayerView（Mod 只能访问玩家视角，R30）；输出 Array[Dictionary]，每项：
##   { "pos": Vector2i, "state": "safe"|"mine", "proof": String, "sources": Array[Vector2i] }
## 结论必须 sound（在所有相容布局中成立）；否则 SolverValidator 会拒绝，不得显示。
func apply(_view: PlayerView) -> Array:
	return []
