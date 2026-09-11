# stats_registry.gd —— Mod 统计维度注册（文档 23 号 §14.11）
# Mod 注册统计维度 → 统计面板多一列，自动累计。
class_name StatsRegistry
extends RefCounted


# id(String) -> { agg: String, value: Variant }
var _dims: Dictionary = {}


## 注册一个统计维度。agg 描述聚合方式（如 "sum"/"max"/"count"，供面板展示）。
func register_dimension(id: String, agg: String) -> bool:
	if id == "" or _dims.has(id):
		return false
	_dims[id] = {"agg": agg, "value": 0}
	return true


## 累计该维度的值（默认 +1，也可传具体增量）。
func add(id: String, amount: Variant = 1) -> void:
	if not _dims.has(id):
		return
	var cur: Variant = _dims[id]["value"]
	if cur is int and amount is int:
		_dims[id]["value"] = int(cur) + int(amount)
	elif cur is float or amount is float:
		_dims[id]["value"] = float(cur) + float(amount)
	else:
		_dims[id]["value"] = amount


## 读维度当前值（未注册返回 null）。
func get_value(id: String) -> Variant:
	if not _dims.has(id):
		return null
	return _dims[id]["value"]


## 列出全部维度。
func list() -> Array:
	var out: Array = []
	for id in _dims:
		var dim: Dictionary = _dims[id].duplicate(true)
		dim["id"] = id
		out.append(dim)
	return out


## 清空全部。
func clear() -> void:
	_dims.clear()
