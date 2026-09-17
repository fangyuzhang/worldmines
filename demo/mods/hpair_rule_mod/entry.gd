# entry.gd —— 试验性 Mod 规则：「水平配对」（hpair）
#
# 规则：每个雷的左侧或右侧必须有一个相邻的雷（雷水平成对出现）。
# 等价形式：mine(r,c) → mine(r,c-1) ∨ mine(r,c+1)。
# 玩家可读表述：一个雷的左边或右边一定有另一个雷；
#   反过来说，八邻全翻开且都不是雷的格子必然不是雷（规则给出的排除推理）。
#
# 数学观察（生成前预判，待 is_feasible 实测）：
#   · 每行的雷数必须为偶数——行内雷要两两水平相邻成段，段长 ≥2；
#   · R07 固定雷数（10/14/20/26/32）全为偶数 → 5 个尺寸均数学可行；
#   · 单列盘（cols=1）无水平邻 → 全盘禁雷 → 与 total_mines≥1 矛盾（UNSAT，天然正确）。
#
# 本 Mod 仅作「Mod 端到端接入生成器」试验，不接入正式版本。
extends RefCounted


class HorizontalPairRule:
	extends RulePlugin

	func get_rule_id() -> StringName:
		return &"hpair"

	func get_kind() -> String:
		return KIND_GLOBAL

	func describe() -> Dictionary:
		return {"name": "水平配对", "rule_text": "每个雷的左侧或右侧必须有一个相邻的雷（试验 Mod）"}

	func build_global_constraints(b: RuleBuilder) -> void:
		for r in b.rows:
			for c in b.cols:
				# ¬mine(r,c) ∨ mine(r,c-1) ∨ mine(r,c+1)
				# 越界格 cell_var 自动为 const 0（false 字面量）——边界无需特判。
				# 注：IR 的 implication 右端只支持单字面量（cell/aux/not），
				# 「mine → (l ∨ r)」须用德摩根展开为等价或门（mod 作者需知的表达力边界）。
				b.add_bool_or([
					b.not_lit(b.cell_var(r, c)),
					b.cell_var(r, c - 1),
					b.cell_var(r, c + 1),
				])


func on_load() -> bool:
	# 与内置规则同一张表、同一套 API（ModAPI 会 diff 记录归属，卸载时自动清理）。
	RuleRegistry.default().register(HorizontalPairRule.new())

	return true