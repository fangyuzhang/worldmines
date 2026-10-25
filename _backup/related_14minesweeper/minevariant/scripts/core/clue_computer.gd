class_name ClueComputer
extends RefCounted
## B 类数字规则层管线：聚合所有 B 类变体为每个格子计算线索。
##
## 叠加规则（GDD §4.1.1）：多个 B 类变体同时生效时，各自独立计算线索，
## 格子上显示全部线索。无 B 类时退回经典 8 邻。

var num_variants: Array = []  # Array[VariantBase]，仅含 B 类

func _init(variants: Array = []) -> void:
	num_variants = variants.filter(func(v): return v.category == VariantBase.Category.NUMBER_RULE)
	if num_variants.is_empty():
		# 兜底：没有 B 类变体时使用经典规则（若 classic 未注册则保持空，调用方需保证至少 1 个 B 类）
		var fallback = VariantRegistry.get_variant("classic")
		if fallback:
			num_variants = [fallback]

static func from_ids(ids: Array) -> ClueComputer:
	var vars: Array = []
	for id_str in ids:
		var v = VariantRegistry.get_variant(id_str)
		if v:
			vars.append(v)
	return ClueComputer.new(vars)

## 某格的全部线索（按变体顺序）。未被揭开的格子返回空数组。
func clues_for(board: Board, r: int, c: int) -> Array[VariantClue]:
	var out: Array[VariantClue] = []
	for v in num_variants:
		var clues := v.compute_clues(board, r, c)
		if not clues.is_empty():
			out.append_array(clues)
	return out

## 某格是否触发洪水填充（任一 B 类变体标记为 flood 种子，或全部都是安全展开）。
## 经典规则：数字为 0 时展开。这里取"该格所有线索都 is_flood" 为展开条件。
func is_flood_seed(board: Board, r: int, c: int) -> bool:
	if board.is_mine(r, c):
		return false
	var clues := clues_for(board, r, c)
	if clues.is_empty():
		return false
	for clue in clues:
		if not clue.is_flood:
			return false
	return true

## 某格已揭开后的显示文本。有 B 类变体时按变体各自 display；否则经典数字。
func display_text(board: Board, r: int, c: int) -> String:
	var parts: Array[String] = []
	for v in num_variants:
		var t := v.cell_display(board, r, c)
		if not t.is_empty():
			parts.append(t)
	return " / ".join(parts)
