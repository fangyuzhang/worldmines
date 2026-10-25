class_name VariantClue
extends RefCounted
## 一条线索。一个 B 类变体对某格返回一个或多个 VariantClue。
## 含显示文本与触发洪水填充的标记，UI 直接渲染 text。

var text: String = ""
var is_flood: bool = false
## 该线索对应的"雷数约束"（用于唯一解求解器）。-1 表示不参与精确数字推理
## （如 Clock/HaloDiff 这类无法给出单一雷数的变体）。classic=8邻雷数，4N=4邻雷数。

var solver_count: int = -1

func _init(p_text: String = "", p_flood: bool = false, p_solver_count: int = -1) -> void:
	text = p_text
	is_flood = p_flood
	solver_count = p_solver_count

func _to_string() -> String:
	return "VariantClue(%s, flood=%s, count=%d)" % [text, is_flood, solver_count]
