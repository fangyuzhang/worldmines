class_name VariantClue
extends RefCounted
## 一条线索。一个 B 类变体对某格返回一个或多个 VariantClue。
## 含显示文本与触发洪水填充的标记，UI 直接渲染 text。

var text: String = ""
var is_flood: bool = false

func _init(p_text: String = "", p_flood: bool = false) -> void:
	text = p_text
	is_flood = p_flood

func _to_string() -> String:
	return "VariantClue(%s, flood=%s)" % [text, is_flood]
