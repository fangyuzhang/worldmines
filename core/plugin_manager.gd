# plugin_manager.gd —— 插件注册表（文档 23 号 §三 / §14.2 / 21 号 R33）
# 职责（纯注册表，不含任何判负/雷位逻辑）：
#   - 扩展点（point）注册：内置点与 Mod 自举点共用 declare_point（R33：平台不得垄断定义扩展点的权力）
#   - 实现注册：register，按 priority 降序，契约（鸭子类型）校验
#   - 取用：get（最高优先级）/ all / next（自动回退）
class_name PluginManager
extends RefCounted

# point(StringName) -> Array[Dictionary]（{impl, id, priority}，按 priority 降序）
var _registry: Dictionary = {}
# point(StringName) -> Array[String]（必需方法名，契约）
var _contracts: Dictionary = {}


## 声明扩展点契约。内置点与 Mod 自举点共用（R33）。
## required_methods：实现必须拥有的方法名（鸭子类型契约）。
## 已存在的契约拒绝覆盖（防 Mod 弱化内置扩展点的契约）。
func declare_point(point: StringName, required_methods: Array) -> void:
	if _contracts.has(point):
		return
	var methods: Array[String] = []
	for m in required_methods:
		methods.append(str(m))
	_contracts[point] = methods


## 注册实现。返回是否成功（失败：契约不满足 / 缺 get_id / impl 为 null）。
func register(point: StringName, impl: Object, priority: int = 100) -> bool:
	if impl == null:
		return false
	# 未声明契约的点：最低要求实现 get_id
	if not _contracts.has(point):
		_contracts[point] = ["get_id"]
	# 契约校验（鸭子类型）：缺任一必需方法即拒绝
	for m in _contracts[point]:
		if not impl.has_method(m):
			return false
	if not impl.has_method("get_id"):
		return false
	var id := StringName(str(impl.call("get_id")))
	_unregister(point, id)
	if not _registry.has(point):
		_registry[point] = []
	var list: Array = _registry[point]
	var entry := {"impl": impl, "id": id, "priority": priority}
	# 插入保持 priority 降序；同 priority 后注册排后（稳定）
	var idx := 0
	while idx < list.size() and int(list[idx]["priority"]) >= priority:
		idx += 1
	list.insert(idx, entry)
	return true


## 注销指定 point 下的指定 id。返回是否找到并移除。
func unregister(point: StringName, id: StringName) -> bool:
	return _unregister(point, id)


## 取最高优先级实现（无则 null）。命名 first 以免覆盖 Object.get()。
func first(point: StringName) -> Object:
	var list: Array = _registry.get(point, [])
	if list.is_empty():
		return null
	return list[0]["impl"]


## 取全部实现（priority 降序）。
func all(point: StringName) -> Array:
	var list: Array = _registry.get(point, [])
	var impls: Array = []
	for e in list:
		impls.append(e["impl"])
	return impls


## 当前实现失效时回退到下一个（无下一个返回 null）。
func next(point: StringName, current: Object) -> Object:
	var list: Array = _registry.get(point, [])
	for i in list.size():
		if list[i]["impl"] == current:
			if i + 1 < list.size():
				return list[i + 1]["impl"]
			return null
	return null


## 列出所有已声明/已注册 point。
func list_points() -> Array[StringName]:
	var points: Array[StringName] = []
	for p in _contracts:
		if not points.has(p):
			points.append(p)
	for p in _registry:
		if not points.has(p):
			points.append(p)
	return points


## 查询某 point 的契约（必需方法名）。
func contract_of(point: StringName) -> Array[String]:
	return _contracts.get(point, [])


## 清空全部注册与契约。
func clear() -> void:
	_registry.clear()
	_contracts.clear()


## 内部：按 id 移除。返回是否移除。
func _unregister(point: StringName, id: StringName) -> bool:
	var list: Array = _registry.get(point, [])
	for i in list.size():
		if list[i]["id"] == id:
			list.remove_at(i)
			return true
	return false
