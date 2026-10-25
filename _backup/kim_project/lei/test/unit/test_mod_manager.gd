# test_mod_manager.gd —— mod 依赖管理测试（文档第二篇 §2.3 / §2.5）
extends GutTest


func test_resolve_topological_order() -> void:
	var manager := ModManager.new()
	var mods := [
		{"name": "A", "depends": [], "conflicts": [], "loadAfter": []},
		{"name": "B", "depends": ["A"], "conflicts": [], "loadAfter": []},
		{"name": "C", "depends": ["B"], "conflicts": [], "loadAfter": []},
	]
	var r: Dictionary = manager.resolve(mods)
	assert_true(r["ok"], "应成功排序：%s" % r.get("reason", ""))
	var order: Array = r["order"]
	assert_lt(order.find("A"), order.find("B"), "A 应在 B 前")
	assert_lt(order.find("B"), order.find("C"), "B 应在 C 前")


func test_resolve_cycle_detection() -> void:
	var manager := ModManager.new()
	var mods := [
		{"name": "A", "depends": ["B"], "conflicts": [], "loadAfter": []},
		{"name": "B", "depends": ["A"], "conflicts": [], "loadAfter": []},
	]
	var r: Dictionary = manager.resolve(mods)
	assert_false(r["ok"], "循环依赖应被检测")
	assert_true(str(r["reason"]).contains("循环"), "原因应提及循环依赖")


func test_resolve_conflict_detection() -> void:
	var manager := ModManager.new()
	var mods := [
		{"name": "A", "depends": [], "conflicts": ["B"], "loadAfter": []},
		{"name": "B", "depends": [], "conflicts": [], "loadAfter": []},
	]
	var r: Dictionary = manager.resolve(mods)
	assert_false(r["ok"], "冲突应被检测")
	assert_true(str(r["reason"]).contains("冲突"), "原因应提及冲突")


func test_apply_patch() -> void:
	var manager := ModManager.new()
	manager.engine.register_clue_def("MyClock", {"type": "clue", "window": DefEngine.WINDOW_RING8, "aggregate": DefEngine.AGG_FIRST_INDEX, "max": 8, "min_clue": 0})
	var patch := {"op": "patch", "target": "MyClock", "patch": [{"path": "max", "value": 6}]}
	var r: Dictionary = manager.apply_patch(patch)
	assert_true(r["ok"], "patch 应成功：%s" % r.get("reason", ""))
	assert_eq(manager.engine.clue_defs["MyClock"]["max"], 6, "max 应被修改为 6")
