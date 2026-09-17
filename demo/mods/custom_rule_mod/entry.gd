# entry.gd —— 第三方规则 mod 示例（自举式平台接入演示）
# 「双倍对角」：线索值 = 2 × 对角 4 格雷数。
# 展示创作者用 ~25 行 + 一个 wsum 原语接入完整平台：
#   生成（CP-SAT 唯一解）/ 验证（黑盒 oracle）/ 图鉴（describe 自动收录）。
# 注意：这条规则在旧 Def IR（固定窗口×聚合原子）中无法表达——加权语义不存在。
extends RefCounted


class DoubleDiagRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"x2diag"

	func get_kind() -> String:
		return KIND_CLUE

	func describe() -> Dictionary:
		return {"name": "双倍对角", "rule_text": "数字 = 对角 4 格雷数 × 2（mod 自定义规则）"}

	func compute_clue(mine_set: Dictionary, pos: Vector2i, grid_size: Vector2i) -> Variant:
		return 2 * RulePlugin.count_dirs(mine_set, pos, grid_size, ClueEngine.diagonal_dirs())

	func build_clue_constraints(b: RuleBuilder, pos: Vector2i, value: Variant) -> void:
		var nbs := b.neighbors(pos, ClueEngine.diagonal_dirs())
		b.add_eq(b.wsum([2, 2, 2, 2], b.cell_vars(nbs)), int(value))


## 钩子契约（v3.1）：必须 return true 表示完成——ModAPI._call_hook 以返回值判定成败
##（GDScript 无 try/catch，钩子内运行时错误只能靠「没返回 true」探测）。
func on_load() -> bool:
	# 直接注册进全局规则注册表（与内置规则同一张表、同一套 API）
	RuleRegistry.default().register(DoubleDiagRule.new())
	return true
