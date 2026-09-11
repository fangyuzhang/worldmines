# action_plugin.gd —— 动作域（文档 23 号 §15.7）
# 引擎级原语之一：声明一种新的玩家动作（第三类动作，如 2E 的"右盘插旗/排除"）。
# 约束：动作只改玩家视角约束集（R03 单调性不变量），不得改雷位、不得触发判负。
class_name ActionPlugin
extends RefCounted


## 动作 id（唯一）。子类实现。
func get_action_id() -> StringName:
	return &""


## PluginManager 统一注册句柄（映射到动作 id）。
func get_id() -> StringName:
	return get_action_id()


## 当前盘面该动作是否可用。子类实现。
func is_applicable(_view: PlayerView, _ctx: Variant = null) -> bool:
	return false


## 施加动作 → 新玩家视角（只改约束，不改雷位）。子类实现。
func apply_to_player_view(view: PlayerView, _ctx: Variant = null) -> PlayerView:
	return view


## 撤销（供撤销栈/回放）。子类实现。
func inverse(view: PlayerView, _ctx: Variant = null) -> PlayerView:
	return view


## 动作对约束的影响可符号化（可选；提供则可进官方验证）。
func z3_encode_effect(_encoder: Variant, _ctx: Variant = null) -> void:
	pass


## 动作说明（进规则图鉴/提示）。
func describe() -> Dictionary:
	return {"name": get_action_id(), "rule_text": ""}
