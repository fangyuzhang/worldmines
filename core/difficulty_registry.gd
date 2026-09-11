# difficulty_registry.gd —— Mod 难度维度注册（文档 23 号 §14.11）
# 难度指纹不止 D/G/C：Mod 可加自己的难度维度，显示在体检卡片上。
class_name DifficultyRegistry
extends RefCounted


# id(String) -> compute(Callable)
var _metrics: Dictionary = {}


## 注册一个难度维度。compute 接收关卡上下文，返回数值。
func register_metric(id: String, compute: Callable) -> bool:
	if id == "" or not compute.is_valid() or _metrics.has(id):
		return false
	_metrics[id] = compute
	return true


## 计算某维度（未注册返回 null）。
func compute(id: String, ctx: Variant = null) -> Variant:
	if not _metrics.has(id):
		return null
	return _metrics[id].call(ctx)


## 计算全部维度 → {id: value}。
func compute_all(ctx: Variant = null) -> Dictionary:
	var out: Dictionary = {}
	for id in _metrics:
		out[id] = _metrics[id].call(ctx)
	return out


## 列出全部维度 id。
func list_metrics() -> Array[String]:
	var out: Array[String] = []
	for id in _metrics:
		out.append(id)
	return out


## 清空全部。
func clear() -> void:
	_metrics.clear()
