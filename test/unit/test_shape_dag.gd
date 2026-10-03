# test_shape_dag.gd —— 形状依赖图（ShapeDag）自证。
#
# 钉住的不变量（坏一条，形状链就有"删了中间形状整条链悬空"或"有环却算不出来"的风险）：
#   ① 拓扑序：A→C、A,B→C 都必须在依赖之后；同入度按插入顺序（可复现）；
#   ② 环：加边成环必须**拒绝**且报出环上节点，被拒的边不得留在图里；
#   ③ detect_cycle 对无环图返回空数组；
#   ④ 删中间节点能列出会被悬空的子孙与受影响的链（安全删除拒绝 / 级联删除两种策略）；
#   ⑤ 序列化往返逐字段一致（含 1/65536 量化）；version 更大 → 拒绝，缺失（老数据）→ 可读；
#   ⑥ eval_plan 两次调用逐项相同，且每个节点的输入都排在它前面。
#
# 用 preload 而非全局类名：非编辑器运行读的是 .godot 里的全局类缓存，新增类名可能还没进缓存，
# 直接写 `ShapeDag.new()` 会解析失败（ci_check 的 collected 守卫正是为这种坑加的）。
extends GutTest

const ShapeDagScript := preload("res://core/shape_dag.gd")
const QUANT_STEP := 1.0 / 65536.0


func test_chain_topo_order() -> void:
	var g = ShapeDagScript.new()
	assert_true(g.add_primitive("a", "rect", {"w": 3, "h": 2})["ok"])
	assert_true(g.add_primitive("c", "circle", {"r": 1.5})["ok"])
	assert_true(g.add_edge("a", "c")["ok"], "A → C 应可加")
	assert_eq(g.topo_order(), ["a", "c"], "拓扑序：先 A 后 C")
	assert_eq(g.dependencies_of("c"), ["a"], "C 的直接输入 = A")
	assert_eq(g.dependents_of("a"), ["c"], "A 的依赖方 = C")


func test_fan_in_topo_order_and_inputs() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	assert_true(g.add_boolean("c", "union", {})["ok"])
	assert_true(g.add_edge("a", "c")["ok"])
	assert_true(g.add_edge("b", "c")["ok"])
	assert_eq(g.topo_order(), ["a", "b", "c"], "并集 C 必须在 A、B 之后")
	var plan = g.eval_plan()
	assert_eq(plan.size(), 3, "三个节点 → 三步")
	assert_eq(plan[2]["id"], "c", "最后一步是 C")
	assert_eq(plan[2]["inputs"], ["a", "b"], "输入按加边顺序（差集等有序运算依赖它）")


func test_cycle_rejected_and_reports_nodes() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	g.add_boolean("c", "union", {})
	assert_true(g.add_edge("a", "b")["ok"])
	assert_true(g.add_edge("b", "c")["ok"])
	var r = g.add_edge("c", "a")
	assert_false(r["ok"], "c → a 会成环，必须拒绝")
	assert_true(r["error"].contains("a") and r["error"].contains("b") and r["error"].contains("c"),
			"拒绝原因要报出环上节点：%s" % r["error"])
	assert_eq(g.detect_cycle(), [], "被拒的边不得留在图里（图仍无环）")
	assert_eq(g.topo_order(), ["a", "b", "c"], "拒绝后拓扑序不受影响")


func test_detect_cycle_empty_for_dag() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	g.add_boolean("c", "xor", {})
	g.add_edge("a", "c")
	g.add_edge("b", "c")
	assert_eq(g.detect_cycle(), [], "无环图 detect_cycle 必须返回空数组")


func test_self_loop_rejected() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	var r = g.add_edge("a", "a")
	assert_false(r["ok"], "自依赖必须拒绝")
	assert_eq(g.detect_cycle(), [], "拒绝自依赖后仍是 DAG")


func test_dependents_of_lists_orphans() -> void:
	var g = ShapeDagScript.new()
	for id in ["a", "b", "c", "d"]:
		g.add_primitive(id, "rect", {})
	g.add_edge("a", "b")
	g.add_edge("b", "c")
	g.add_edge("c", "d")
	assert_eq(g.dependents_of("a"), ["b", "c", "d"], "删 A 会悬空整条链")
	assert_eq(g.dependents_of("c"), ["d"], "删 C 只悬空 D")
	assert_eq(g.dependents_of("d"), [], "叶子没有子孙")


func test_remove_node_safe_refuses_with_chains() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	g.add_primitive("c", "star", {})
	g.add_edge("a", "b")
	g.add_edge("b", "c")
	var r = g.remove_node_safe("a")
	assert_false(r["ok"], "有子孙时安全删除必须拒绝")
	assert_eq(r["dependents"], ["b", "c"], "要列出会被悬空的子孙")
	assert_eq(r["chains"], [["a", "b", "c"]], "还要列出一条条受影响的链")
	assert_true(g.has_node("a"), "拒绝 = 一个都没删")
	# 叶子没有子孙 → 可安全删除
	assert_true(g.remove_node_safe("c")["ok"])
	assert_eq(g.node_ids(), ["a", "b"])


func test_remove_node_cascade_keeps_upstream() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	g.add_boolean("c", "union", {})
	g.add_boolean("d", "difference", {})
	g.add_edge("a", "c")
	g.add_edge("b", "c")
	g.add_edge("c", "d")
	var r = g.remove_node_cascade("a")
	assert_true(r["ok"], "级联删除应成功")
	assert_eq(r["removed"], ["a", "c", "d"], "级联删除 = 自己 + 全部子孙")
	assert_eq(g.node_ids(), ["b"], "上游 B 不是 A 的子孙，应保留")
	assert_eq(g.detect_cycle(), [], "删完仍是 DAG")


func test_serialize_roundtrip_identical() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("rect1", "rect", {"w": 4, "h": 2.5})
	g.add_primitive("circle1", "circle", {"r": 1.0 / 3.0, "cx": -2.25})
	g.add_boolean("bool1", "union", {"feather": 0.1})
	g.add_edge("rect1", "bool1")
	g.add_edge("circle1", "bool1")
	var d = g.to_dict()
	assert_eq(int(d["version"]), ShapeDagScript.VERSION, "必须带 version 字段")
	assert_eq(d["nodes"].size(), 3)
	assert_eq(d["edges"].size(), 2)
	var g2 = ShapeDagScript.new()
	var r = g2.from_dict(d)
	assert_true(r["ok"], "载入应成功：%s" % r.get("error", ""))
	assert_eq(g2.to_dict(), d, "序列化往返必须逐字段一致（含量化）")
	assert_eq(g2.topo_order(), g.topo_order(), "往返后拓扑序一致")
	assert_eq(g2.eval_plan(), g.eval_plan(), "往返后求值计划一致")
	assert_eq(g2.node("circle1"), g.node("circle1"))


func test_quantization_is_one_over_65536() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "circle", {"r": 1.0 / 3.0, "k": 7, "flag": true, "label": "x"})
	var p = g.node("a")["params"]
	var q = float(p["r"])
	assert_ne(q, 1.0 / 3.0, "非 2^-16 栅格上的值必须被量化")
	assert_eq(q, snappedf(1.0 / 3.0, QUANT_STEP), "量化口径必须正好是 1/65536 栅格")
	assert_true(absf(q * 65536.0 - roundf(q * 65536.0)) < 0.000001, "量化后落在 1/65536 整数栅格上")
	assert_eq(int(p["k"]), 7, "整数不动")
	assert_eq(p["flag"], true, "布尔不动")
	assert_eq(p["label"], "x", "字符串不动")
	assert_eq(g.to_dict(), g.to_dict(), "两次 to_dict 必须一致")


func test_quantization_recurses_into_arrays_and_dicts() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "freehand", {"pts": [{"x": 1.0 / 3.0, "y": 2.0}], "z": 5})
	var p = g.node("a")["params"]
	var pt = (p["pts"] as Array)[0]
	assert_eq(float(pt["x"]), snappedf(1.0 / 3.0, QUANT_STEP), "数组/字典里的数值也要量化")
	assert_eq(float(pt["y"]), 2.0, "已在栅格上的值不变")
	assert_eq(int(p["z"]), 5)


func test_version_guard_and_legacy_read() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {"w": 1})
	var future = g.to_dict()
	future["version"] = ShapeDagScript.VERSION + 1
	var g2 = ShapeDagScript.new()
	var r = g2.from_dict(future)
	assert_false(r["ok"], "更高版本必须拒绝而不是猜")
	assert_true(r["error"].contains("版本"), "原因要说清版本问题：%s" % r["error"])
	assert_eq(g2.node_ids(), [], "拒绝时不得留下半成品")
	# 旧数据（无 version 字段）必须可读
	var legacy = g.to_dict()
	legacy.erase("version")
	var g3 = ShapeDagScript.new()
	assert_true(g3.from_dict(legacy)["ok"], "无 version 的老数据应可读")
	assert_eq(g3.to_dict()["version"], ShapeDagScript.VERSION, "读入后按当前版本写出")
	assert_eq(g3.topo_order(), ["a"])


func test_from_dict_rejects_cycle_and_bad_edges() -> void:
	var bad = {
		"version": 1,
		"nodes": [
			{"id": "a", "kind": "primitive", "shape": "rect", "params": {}},
			{"id": "b", "kind": "primitive", "shape": "circle", "params": {}},
		],
		"edges": [{"from": "a", "to": "b"}, {"from": "b", "to": "a"}],
	}
	var g = ShapeDagScript.new()
	var r = g.from_dict(bad)
	assert_false(r["ok"], "数据里的环必须拒绝")
	assert_true(r["error"].contains("循环") or r["error"].contains("a"), "要报出环：%s" % r["error"])
	assert_eq(g.node_ids(), [], "拒绝时不得留半成品")
	var dangling = {
		"version": 1,
		"nodes": [{"id": "a", "kind": "primitive", "shape": "rect", "params": {}}],
		"edges": [{"from": "a", "to": "zzz"}],
	}
	assert_false(g.from_dict(dangling)["ok"], "悬挂边必须拒绝")
	assert_eq(g.node_ids(), [], "仍然不得留半成品")


func test_eval_plan_is_stable_and_topo() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	g.add_primitive("c", "star", {})
	g.add_boolean("d", "union", {})
	g.add_boolean("e", "difference", {})
	g.add_edge("a", "d")
	g.add_edge("b", "d")
	g.add_edge("d", "e")
	g.add_edge("c", "e")
	var p1 = g.eval_plan()
	var p2 = g.eval_plan()
	assert_eq(p1, p2, "同一图两次 eval_plan 必须逐项相同")
	assert_eq(p1.size(), g.node_count(), "每个节点一步")
	var seen := {}
	for i in p1.size():
		assert_eq(int(p1[i]["step"]), i + 1, "步骤号必须从 1 连续")
		for inp in p1[i]["inputs"]:
			assert_true(seen.has(str(inp)), "节点 %s 的输入 %s 必须先算" % [p1[i]["id"], str(inp)])
		seen[p1[i]["id"]] = true
	assert_eq(p1[3]["id"], "d", "D 在 E 之前")
	assert_eq(p1[4]["inputs"], ["d", "c"], "输入顺序 = 加边顺序（模块不擅自重排）")


func test_topo_ties_follow_insertion_order() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	g.add_primitive("c", "star", {})
	g.add_boolean("d", "union", {})
	g.add_edge("b", "d")
	assert_eq(g.topo_order(), ["a", "b", "c", "d"], "同入度按插入顺序；D 就绪后仍排在 C 之后")


func test_remove_edge_restores_state() -> void:
	var g = ShapeDagScript.new()
	g.add_primitive("a", "rect", {})
	g.add_primitive("b", "circle", {})
	assert_true(g.add_edge("a", "b")["ok"])
	assert_true(g.remove_edge("a", "b")["ok"])
	assert_eq(g.dependencies_of("b"), [], "B 的输入清空")
	assert_eq(g.dependents_of("a"), [])
	assert_false(g.remove_edge("a", "b")["ok"], "已删的边再删要报错")
	assert_eq(g.topo_order(), ["a", "b"], "无依赖后按插入顺序")


func test_add_rejects_duplicate_and_unknown() -> void:
	var g = ShapeDagScript.new()
	assert_true(g.add_primitive("a", "rect", {})["ok"])
	assert_false(g.add_primitive("a", "circle", {})["ok"], "重复 id 拒绝")
	assert_false(g.add_primitive("b", "polygon", {})["ok"], "未注册的原子形状拒绝")
	assert_true(g.add_boolean("c", "intersect", {})["ok"], "交运算名 = intersect（对齐 shape_boolean.OP_INTERSECT）")
	assert_false(g.add_boolean("d", "intersection", {})["ok"], "非规范名（intersection）必须拒绝，防两套叫法漂移")
	assert_false(g.add_boolean("e", "blend", {})["ok"], "未注册的布尔运算拒绝")
	assert_false(g.add_primitive("", "rect", {})["ok"], "空 id 拒绝")
	assert_false(g.add_edge("a", "zzz")["ok"], "未知节点拒绝")
	assert_eq(g.node_ids(), ["a", "c"], "被拒的节点不得进图，合法的 c 才进")
	assert_eq(g.edges(), [], "拒绝的边不得进图")
