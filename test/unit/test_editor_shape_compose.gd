# test_editor_shape_compose.gd —— 形状布尔 + 形状依赖图**接进编辑器界面**的自证（2026-10-03）。
#
# 背景：审计核实 `core/shape_boolean.gd` / `core/shape_dag.gd` 早有实现与单测，但 `ui/` 零引用
# ⇒ 用户根本用不到。本文件钉住"真的接上了"这件事：按**界面上的按钮**（不是直接调 core），
# 并断言副作用（doc 变了 / 撤销步数变了 / 文案非空）。
#
# 类型纪律同 `test_level_editor_smoke`：编辑器脚本没有 class_name，变量声明成 `Object` 并用 `.call()`。
extends GutTest

const ShapeBoolean = preload("res://core/shape_boolean.gd")


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	return ed


func _canvas_of(ed: Object) -> EditorCanvas:
	var found := (ed as Node).find_children("*", "EditorCanvas", true, false)
	return found[0] as EditorCanvas if not found.is_empty() else null


func _doc(rows: int, cols: int, mines: Array = []) -> EditorDoc:
	var d := EditorDoc.new(rows, cols)
	for m in mines:
		d.mines.append(m)
	return d


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


## 真实入口：在真实控件树里找按钮并**按下**（不是直接调回调）。
func _press(ed: Object, prefix: String) -> bool:
	for c in (ed as Node).find_children("*", "Button", true, false):
		var b := c as Button
		if b != null and b.text.begins_with(prefix):
			b.pressed.emit()
			return true
	return false


func _select_key(ed: Object, var_name: String, key: String) -> bool:
	var opt := ed.get(var_name) as OptionButton
	if opt == null:
		return false
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == key:
			opt.selected = i
			return true
	return false


func _note(ed: Object) -> String:
	return (ed.get("_dag_note") as Label).text


# ==================== 1. 布尔运算作用于选中形状并写回 doc ====================

func test_boolean_difference_paints_back_into_the_doc_and_is_one_undo_step() -> void:
	var ed := _make_editor()
	# 5×5、雷 (0,0)(1,1)(2,2)：差集挖掉的框里有两颗雷 ⇒ 顺带验证"落在盘外的雷被清掉"
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	canvas.size = Vector2(600, 600)
	canvas.set_selection(Rect2i(Vector2i(1, 1), Vector2i(1, 1)))   # 框选 (1,1)-(2,2) 共 4 格
	# A = 整盘形状（默认第 0 项）、B = 框选区域（第 1 项）
	assert_true(_select_key(ed, "_dag_a_opt", "__board__"), "A 下拉应有「整盘形状」")
	assert_true(_select_key(ed, "_dag_b_opt", "__selection__"), "B 下拉应有「框选区域」")
	var undo_before: int = (ed.get("_undo") as Array).size()

	assert_true(_press(ed, "差集"), "形状面板应有「差集」按钮")

	assert_eq(d.obstacles.size(), 4, "差集后：框选那 4 格应被记为「不存在」")
	assert_eq(d.cell_count(), 21, "5×5 去掉 4 格 = 21 格")
	assert_eq(d.mine_count(), 1, "被挖掉的两格里的雷必须一起清掉（否则试玩/打包被永久挡住）")
	assert_eq((ed.get("_undo") as Array).size(), undo_before + 1, "一次写回只算一步撤销")
	assert_true(_note(ed).length() > 0, "必须给出可读结果文案（不许静默）")

	ed.call("_undo_once")
	assert_eq(d.obstacles.size(), 0, "撤销一步应把障碍还原")
	assert_eq(d.cell_count(), 25, "撤销一步应把盘还原")
	assert_eq(d.mine_count(), 3, "撤销一步应把雷还原")


func test_boolean_union_without_selection_gives_readable_reason() -> void:
	var ed := _make_editor()
	_bind(ed, _doc(4, 4, [Vector2i(0, 0)]))
	var before := JSON.stringify(ed.doc.snapshot())
	assert_true(_select_key(ed, "_dag_b_opt", "__selection__"))
	# 没框选就做布尔：必须给可读原因，且**不许改动文档**（不许静默、也不许写坏盘）
	assert_true(_press(ed, "并集"), "应有「并集」按钮")
	assert_true(_note(ed).length() > 0, "失败必须留下可读文案")
	assert_true(_note(ed).find("框选") != -1, "原因要点明是「还没框选」：%s" % _note(ed))
	assert_eq(JSON.stringify(ed.doc.snapshot()), before, "失败的操作不得改动文档")


# ==================== 2. 依赖图：表达「子依赖父」 + 环检测的拒绝理由 ====================

func test_dag_links_shapes_and_shows_the_cycle_path_when_rejected() -> void:
	var ed := _make_editor()
	_bind(ed, _doc(5, 5, [Vector2i(4, 4)]))
	# 建三个形状节点（界面上的「加形状」）
	for i in 3:
		assert_true(_press(ed, "加形状"), "应有「加形状」按钮（第 %d 次）" % (i + 1))
	var dag: Object = ed.get("_dag")
	assert_eq(dag.call("node_count"), 3, "应有 3 个形状节点")
	var ids: Array = dag.call("node_ids")
	# s1 → s2、s2 → s3：这就是「子形状依赖父形状」的表达
	assert_true(_select_key(ed, "_dag_a_opt", str(ids[0])))
	assert_true(_select_key(ed, "_dag_b_opt", str(ids[1])))
	assert_true(_press(ed, "加依赖"), "应有「加依赖」按钮")
	assert_true(_select_key(ed, "_dag_a_opt", str(ids[1])))
	assert_true(_select_key(ed, "_dag_b_opt", str(ids[2])))
	assert_true(_press(ed, "加依赖"))
	assert_eq((dag.call("edges") as Array).size(), 2, "两条依赖应加进去")

	# s3 → s1 会成环：必须**拒绝**，并把环路径显示出来（不能只说"失败"）
	assert_true(_select_key(ed, "_dag_a_opt", str(ids[2])))
	assert_true(_select_key(ed, "_dag_b_opt", str(ids[0])))
	assert_true(_press(ed, "加依赖"))
	assert_eq((dag.call("edges") as Array).size(), 2, "成环的边不许进图（拒绝时图保持原样）")
	var note := _note(ed)
	assert_true(note.find("循环") != -1, "拒绝理由必须点明是循环依赖：%s" % note)
	assert_true(note.find(str(ids[0])) != -1 and note.find(str(ids[2])) != -1,
		"理由里必须带上环上的节点（不是只说失败）：%s" % note)
	assert_true(_press(ed, "检查有没有环"), "应有「检查有没有环」按钮")


# ==================== 3. 依赖图求值：形状 → 格集 → 写回棋盘 ====================

func test_dag_boolean_node_evaluates_and_rewrites_the_board() -> void:
	var ed := _make_editor()
	var d := _doc(9, 9, [Vector2i(0, 0)])
	_bind(ed, d)
	(ed.get("_dag_shape_size") as SpinBox).value = 3
	# s1 = 圆（半径 3）、s2 = 扇形（半径 3，0°~90°）
	assert_true(_press(ed, "加形状"))
	(ed.get("_dag_shape_opt") as OptionButton).selected = 2      # 扇形
	assert_true(_press(ed, "加形状"))
	var dag: Object = ed.get("_dag")
	var ids: Array = dag.call("node_ids")
	assert_eq(ids.size(), 2, "应有两个形状节点")

	# 用界面上的「差集」把 s1 − s2 合成
	assert_true(_select_key(ed, "_dag_a_opt", str(ids[0])))
	assert_true(_select_key(ed, "_dag_b_opt", str(ids[1])))
	var undo_before: int = (ed.get("_undo") as Array).size()
	assert_true(_press(ed, "差集"))

	# 期望结果独立算一遍（同一 core 模块；这里要验证的是**写回**是否精确）
	var circle := ShapeGenerator.to_adjacency_grid("circle", {"radius": 3, "precision": 24})
	var sector := ShapeGenerator.to_adjacency_grid("sector",
		{"radius": 3, "start_deg": 0.0, "end_deg": 90.0})
	var exp: Dictionary = ShapeBoolean.difference(circle.all_positions(), sector.all_positions())
	assert_true(bool(exp["ok"]), "前提：布尔运算应成功：%s" % str(exp["reason"]))
	var exp_set := {}
	for p in exp["cells"]:
		exp_set[p] = true
	assert_gt(exp_set.size(), 0, "前提：结果非空")
	assert_lt(exp_set.size(), 81, "前提：结果不该是整个盘（否则'没改动'）")

	var bad := 0
	for y in 9:
		for x in 9:
			var p := Vector2i(x, y)
			if d.grid().in_board(p) != exp_set.has(p):
				bad += 1
	assert_eq(bad, 0, "写回后盘上「在/不在」应恰好等于布尔结果（逐格核对）")
	assert_eq(d.cell_count(), exp_set.size(), "格数应等于结果格数")
	assert_eq((ed.get("_undo") as Array).size(), undo_before + 1, "写回只算一步撤销")

	# 这次布尔运算必须登记成依赖图里的节点（谁由谁算出来，图上可查）
	assert_eq(dag.call("node_count"), 3, "应多出一个布尔节点")
	assert_eq((dag.call("edges") as Array).size(), 2, "布尔节点应依赖两个输入")
	var bool_id: String = str((dag.call("node_ids") as Array)[2])
	assert_true(bool_id.begins_with("b"), "布尔节点 id 应为 bN：%s" % bool_id)
	assert_eq((dag.call("dependencies_of", bool_id) as Array).size(), 2, "布尔节点应有两个上游")

	# 无环（加边时已拒绝成环）⇒ 诊断按钮应说"无环"
	assert_true(_press(ed, "检查有没有环"))
	assert_true(_note(ed).find("无环") != -1, "无环时应给出拓扑序说明：%s" % _note(ed))
