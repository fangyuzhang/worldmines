# test_editor_fold_wiring.gd —— 折痕作者入口（面板 + 画布几何 + 撤销/往返）
#
# 缺的不是模型：FoldModel 早已单测。这里只守“用户在编辑器里能不能真的做出一张折叠关”：
#   A. 加一折真的写进文档并改变拓扑邻接；非法第二折只报错、不改数据；
#   B. 删除一折后撤销能完整退回；多折序列能落盘再读回；
#   C. 画布给每条折痕一条可验证的屏幕线段。
extends GutTest


func _make_editor() -> Object:
	var scene: PackedScene = load("res://ui/level_editor.tscn")
	assert_not_null(scene, "编辑器场景应能加载")
	var ed: Object = scene.instantiate()
	add_child_autofree(ed as Node)
	return ed


func _bind(ed: Object, d: EditorDoc) -> void:
	ed.doc = d
	ed.call("_doc_to_ui")
	ed.call("_refresh_all")


func _canvas_of(ed: Object) -> EditorCanvas:
	var n := ed as Node
	var found := n.find_children("*", "EditorCanvas", true, false)
	if found.is_empty():
		return null
	return found[0] as EditorCanvas


func _add_fold(ed: Object, axis_index: int, at: int) -> void:
	var axis := ed.get("_fold_axis_opt") as OptionButton
	var spin := ed.get("_fold_at_spin") as SpinBox
	assert_not_null(axis, "应有折痕轴下拉")
	assert_not_null(spin, "应有折痕位置输入")
	if axis == null or spin == null:
		return
	axis.selected = axis_index
	spin.max_value = 64.0
	spin.value = at
	ed.call("_on_fold_added")


func test_fold_panel_adds_a_fold_and_writes_the_overlap_edge() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(4, 4)
	_bind(ed, d)
	assert_not_null(ed.get("_fold_axis_opt"), "属性页应有折痕轴下拉")
	assert_not_null(ed.get("_fold_at_spin"), "属性页应有折痕位置输入")
	assert_not_null(ed.get("_fold_list_box"), "属性页应有折痕列表")
	var note := ed.get("_fold_note") as Label
	assert_not_null(note, "属性页应有折痕状态行")
	_add_fold(ed, 0, 2)
	var seq := FoldModel.fold_list(d.fold)
	assert_eq(seq.size(), 1, "加一折后文档里应恰好有一条折痕")
	assert_eq(seq[0], {"axis": "x", "at": 2}, "左右折 at=2 应原样写回")
	var g := d.grid()
	assert_true(g.get_neighbors(Vector2i(1, 1)).has(Vector2i(2, 1)), "折过去的两格应互为邻居")
	assert_true(g.get_neighbors(Vector2i(2, 1)).has(Vector2i(1, 1)), "叠合边必须双向")
	if note != null:
		assert_true(note.text.contains("最厚 2 层"), "状态行应报出折完的层数：%s" % note.text)


func test_invalid_second_fold_is_rejected_without_mutating_document() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(4, 4)
	_bind(ed, d)
	_add_fold(ed, 0, 2)
	var before := d.fold.duplicate(true)
	_add_fold(ed, 0, 2)
	assert_eq(d.fold, before, "非法折痕不得静默改写文档")
	var note := ed.get("_fold_note") as Label
	if note != null:
		assert_true(note.text.contains("没有比同轴上一折"), "状态行应说明同轴折痕必须更靠内：%s" % note.text)


func test_delete_fold_can_be_undone_and_sequence_round_trips() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(6, 6)
	_bind(ed, d)
	_add_fold(ed, 0, 4)
	_add_fold(ed, 1, 2)
	assert_eq(FoldModel.fold_list(d.fold).size(), 2, "应先做出两折")
	ed.call("_on_fold_delete", 1)
	assert_eq(FoldModel.fold_list(d.fold).size(), 1, "删除后应只剩第一折")
	ed.call("_undo_once")
	assert_eq(FoldModel.fold_list(d.fold).size(), 2, "撤销应把删掉的那一折退回")
	var back := EditorDoc.new(6, 6)
	back.load_from(d.to_level_json())
	assert_eq(FoldModel.fold_list(back.fold), FoldModel.fold_list(d.fold), "多折序列应落盘再读回一字不差")


func test_editor_canvas_returns_one_crease_segment_per_fold() -> void:
	var ed := _make_editor()
	var d := EditorDoc.new(4, 4)
	d.fold = {"folds": [{"axis": "x", "at": 2}, {"axis": "y", "at": 1}]}
	_bind(ed, d)
	var canvas := _canvas_of(ed)
	assert_not_null(canvas, "编辑器应有画布")
	if canvas == null:
		return
	canvas.size = Vector2(400, 400)
	var segs := canvas.fold_crease_segments()
	assert_eq(segs.size(), 2, "两条折痕应产生两条线段")
	if segs.size() != 2:
		return
	var first: Dictionary = segs[0]
	var second: Dictionary = segs[1]
	assert_eq(str(first["axis"]), "x", "第一条应是左右折")
	assert_eq(float(first["a"].x), float(first["b"].x), "竖折痕两端 x 应相同")
	assert_eq(str(second["axis"]), "y", "第二条应是上下折")
	assert_eq(float(second["a"].y), float(second["b"].y), "横折痕两端 y 应相同")
