# mod_manager.gd —— mod 依赖管理与 PatchOperation（文档第二篇 §2.3 / §2.5）
# 依赖图构建 + 拓扑排序 + 环检测 + 冲突检测 + def 级 patch。
class_name ModManager
extends RefCounted

var engine := DefEngine.new()


## 解析 mod 依赖关系，返回加载顺序（拓扑排序）。
## mods: Array[Dictionary]，每个含 name / depends / conflicts / loadAfter。
## 返回 { ok, order, reason }。
func resolve(mods: Array) -> Dictionary:
	var names: Dictionary = {}
	for m in mods:
		names[m.get("name", "")] = true

	# 冲突检测：同时启用的 mod 若有互斥即报错
	for m in mods:
		var mname: String = m.get("name", "")
		for c in m.get("conflicts", []):
			if names.has(c):
				return {"ok": false, "order": [], "reason": "%s 与 %s 冲突" % [mname, c]}

	# 入度计算：depends 与 loadAfter 都构成「前置 → 本 mod」的边
	var indegree: Dictionary = {}
	for n in names:
		indegree[n] = 0
	for m in mods:
		var mname: String = m.get("name", "")
		for d in m.get("depends", []):
			if names.has(d):
				indegree[mname] = int(indegree[mname]) + 1
		for d in m.get("loadAfter", []):
			if names.has(d):
				indegree[mname] = int(indegree[mname]) + 1

	# Kahn 拓扑排序
	var queue: Array = []
	for n in names:
		if int(indegree[n]) == 0:
			queue.append(n)
	var order: Array = []
	while not queue.is_empty():
		var n: String = queue.pop_front()
		order.append(n)
		for m in mods:
			var mname: String = m.get("name", "")
			if mname == n:
				continue
			if n in m.get("depends", []) or n in m.get("loadAfter", []):
				indegree[mname] = int(indegree[mname]) - 1
				if int(indegree[mname]) == 0:
					queue.append(mname)

	if order.size() != names.size():
		return {"ok": false, "order": order, "reason": "存在循环依赖"}
	return {"ok": true, "order": order, "reason": ""}


## 应用 PatchOperation（def 级 patch）。
## patch: { op: "patch", target: "def_name" 或 "mod.def_name", patch: [{ path, value }] }。
## 返回 { ok, reason }。
func apply_patch(patch: Dictionary) -> Dictionary:
	if patch.get("op", "") != "patch":
		return {"ok": false, "reason": "不支持的 patch op: %s" % patch.get("op", "")}
	var target: String = patch.get("target", "")
	var def_name: String = target.split(".")[-1] if target.contains(".") else target
	var def: Dictionary
	if engine.clue_defs.has(def_name):
		def = engine.clue_defs[def_name]
	elif engine.constraint_defs.has(def_name):
		def = engine.constraint_defs[def_name]
	else:
		return {"ok": false, "reason": "patch target 不存在: %s" % def_name}
	for p in patch.get("patch", []):
		def[p.get("path", "")] = p.get("value")
	return {"ok": true, "reason": ""}
