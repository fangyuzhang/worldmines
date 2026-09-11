# achievement_registry.gd —— Mod 成就注册（文档 23 号 §14.11 / §3.3 ⑲）
# Mod 注册成就定义 + 触发条件；check 返回本次新解锁的成就。
class_name AchievementRegistry
extends RefCounted


# id(String) -> { definition: Dictionary, trigger: Callable }
var _defs: Dictionary = {}
# id(String) -> bool（已解锁）
var _unlocked: Dictionary = {}


## 注册成就。definition 含 {name, description}；trigger 接收上下文返回 bool（是否达成）。
func register(id: String, definition: Dictionary, trigger: Callable) -> bool:
	if id == "" or not trigger.is_valid() or _defs.has(id):
		return false
	_defs[id] = {"definition": definition, "trigger": trigger}
	_unlocked[id] = false
	return true


## 检查全部成就，返回本次新解锁的成就 id 列表。
func check(ctx: Variant = null) -> Array[String]:
	var newly: Array[String] = []
	for id in _defs:
		if _unlocked[id]:
			continue
		if bool(_defs[id]["trigger"].call(ctx)):
			_unlocked[id] = true
			newly.append(id)
	return newly


## 是否已解锁。
func is_unlocked(id: String) -> bool:
	return _unlocked.get(id, false)


## 列出全部成就（含解锁状态）。
func list() -> Array:
	var out: Array = []
	for id in _defs:
		var entry: Dictionary = _defs[id]["definition"].duplicate(true)
		entry["id"] = id
		entry["unlocked"] = _unlocked[id]
		out.append(entry)
	return out


## 清空全部。
func clear() -> void:
	_defs.clear()
	_unlocked.clear()
