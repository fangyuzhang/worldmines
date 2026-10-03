# test_editor_issue_levels.gd —— 校验问题三级化（W3）自证
#
# 钉住的不变量：
#   1) `validate()` 统一产出 ❌error / ⚠️warn / 💡info 三级，每条带 code/text/pos/level；
#   2) **出问题的格**能定位：error（雷位越界）、warn（邻接过多）、info（孤立格）各有一条带真实坐标；
#   3) 向后兼容：老读取方仍拿得到 `errors`（=error）与 `warnings`（= warn ∪ info）；`ok == errors.is_empty()`；
#   4) `highlight_cells()` 连 info 的格也收（可跳到点上）。
extends GutTest


func _doc(p_rows: int, p_cols: int, mine_list: Array) -> EditorDoc:
	var d := EditorDoc.new(p_rows, p_cols)
	for m in mine_list:
		d.mines.append(m)
	return d


func _find(list: Array, code: String) -> Dictionary:
	for it in list:
		if str((it as Dictionary)["code"]) == code:
			return it
	return {}


# ==================== 1. 三级 + 每条都带 level / pos 字段 ====================

func test_every_issue_carries_level_and_pos() -> void:
	var d := _doc(5, 5, [Vector2i(1, 1), Vector2i(1, 1), Vector2i(7, 7)])
	var rep := d.validate()
	assert_true(rep.has("issues"), "应给出三级统一列表 issues")
	assert_true(rep.has("infos"), "应给出 infos 桶")
	for bucket in ["errors", "warnings", "infos", "issues"]:
		for it in rep[bucket]:
			var e: Dictionary = it
			assert_true(e.has("code") and e.has("text") and e.has("pos") and e.has("level"),
				"每条问题都必须带 code/text/pos/level：%s" % str(e))
			assert_true([EditorDoc.ISSUE_ERROR, EditorDoc.ISSUE_WARN, EditorDoc.ISSUE_INFO].has(str(e["level"])),
				"level 只能是三级之一：%s" % str(e["level"]))


# ==================== 2. ❌error 带坐标 ====================

func test_error_level_and_cell() -> void:
	var d := _doc(5, 5, [Vector2i(1, 1), Vector2i(1, 1), Vector2i(7, 7)])
	var rep := d.validate()
	var oob := _find(rep["errors"], "mine_oob")
	assert_false(oob.is_empty(), "越界雷位应报 mine_oob：%s" % str(rep["errors"]))
	assert_eq(str(oob["level"]), EditorDoc.ISSUE_ERROR, "mine_oob 必须是 error 级")
	assert_eq(oob["pos"], Vector2i(7, 7), "mine_oob 必须带越界格坐标 (7,7)")
	# errors 桶里只应有 error 级
	for it in rep["errors"]:
		assert_eq(str((it as Dictionary)["level"]), EditorDoc.ISSUE_ERROR)


# ==================== 3. ⚠️warn 带坐标 ====================

func test_warn_level_and_cell() -> void:
	var d := _doc(9, 9, [Vector2i(4, 4)])
	var dirs: Array[Vector2i] = []
	for y in range(-3, 3):
		for x in range(-3, 3):
			if x != 0 or y != 0:
				dirs.append(Vector2i(x, y))
	d.dirs = dirs
	var rep := d.validate()
	var many := _find(rep["warnings"], "neighbor_many")
	assert_false(many.is_empty(), "35 个邻居应报 neighbor_many：%s" % str(rep["warnings"]))
	assert_eq(str(many["level"]), EditorDoc.ISSUE_WARN, "邻接过多是 warn 级（放行、只提醒）")
	var pos: Vector2i = many["pos"]
	assert_true(pos.x >= 0 and pos.y >= 0, "邻接过多必须指出「是哪一格」：%s" % str(pos))


# ==================== 4. 💡info 带坐标（且向后兼容仍在 warnings 里） ====================

func test_info_level_with_cell_and_backward_compat() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0)])
	d.dirs = [Vector2i(9, 9)]     # 偏移永远够不到 ⇒ 每格都没有邻居
	var rep := d.validate()
	var iso := _find(rep["infos"], "isolated_cell")
	assert_false(iso.is_empty(), "孤立格应进 infos：%s" % str(rep["infos"]))
	assert_eq(str(iso["level"]), EditorDoc.ISSUE_INFO, "孤立格是纯提示（💡info）")
	var pos: Vector2i = iso["pos"]
	assert_true(pos.x >= 0 and pos.y >= 0, "孤立格提示必须带格坐标：%s" % str(pos))
	# 兼容桶：老的读取方只认 warnings，也必须仍能看到这条
	var codes: Array[String] = []
	for w in rep["warnings"]:
		codes.append(str((w as Dictionary)["code"]))
	assert_true(codes.has("isolated_cell"), "warnings 必须保持「非阻塞项」超集（含 info）：%s" % str(codes))
	# info 也参与高亮
	assert_true(d.highlight_cells(rep).has(pos), "highlight_cells 应把 info 的格也收进来")


# ==================== 5. ok 语义与三级计数 ====================

func test_ok_semantics_and_issue_partition() -> void:
	var good := _doc(5, 5, [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)])
	var rg := good.validate()
	assert_true(bool(rg["ok"]), "合法文档应 ok：%s" % str(rg["errors"]))
	assert_eq((rg["errors"] as Array).size(), 0, "ok 时不应有 error")
	# issues = errors + warnings（warnings = warn ∪ info），三级不重不漏
	assert_eq((rg["issues"] as Array).size(), (rg["errors"] as Array).size() + (rg["warnings"] as Array).size(),
		"issues 应等于 errors + warnings")
	var bad := _doc(5, 5, [])
	var rb := bad.validate()
	assert_false(bool(rb["ok"]), "没放雷应不 ok")
	assert_true((rb["errors"] as Array).size() > 0, "没放雷应至少一条 error")
