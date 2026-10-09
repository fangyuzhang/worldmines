# test_glyph_font.gd —— 「文字 → 字形点阵」接线层的钉子（编辑器「文字转形状」入口的下游）
#
# 钉四件事（全部**可复核**，不是自证）：
#   ① 真字体真出字：ASCII 与**中文**都能栅格化出非空点阵（用仓库自带字体，不依赖系统字体）；
#   ② 点阵形状合规：行长一致、只含 #/.、至少一个填充格 —— 也就是 `TextToShape._glyph_rows` 的同款判据；
#   ③ 确定性：同输入两次逐位相同（跨机器可复现的前提）；
#   ④ 能拒绝：空串 / 多行 / 像素高度越界 / 只有空格 / 超字符数 / 字体缺字 ⇒ ok=false + reason 非空；
#   ⑤ 自动适配：`text_cells_fit` 在放不下时逐档缩小，产出格**全部**在盘内（判界一律问网格）。
extends GutTest

const GF := preload("res://core/glyph_font.gd")
const SG := preload("res://core/shape_generator.gd")
const TTS := preload("res://core/text_to_shape.gd")


# ==================== ① 真字体真出字 ====================

func test_ascii_glyph_rasterizes_to_nonempty_mask() -> void:
	var m: Dictionary = GF.mask_for("A", 20)
	assert_true(bool(m["ok"]), "ASCII 单字应能栅格化：%s" % str(m["reason"]))
	var mask: Dictionary = m["font_mask"]
	assert_true(mask.has("A"), "点阵表里应有 'A'")
	var rows: Array = mask["A"]
	assert_gt(rows.size(), 0, "点阵至少一行")
	var ink := _ink_count(rows)
	assert_gt(ink, 0, "字形必须要有笔画（%d 个填充像素）" % ink)


func test_cjk_glyph_rasterizes_to_nonempty_mask() -> void:
	# 中文是这套编辑器的第一输入语言；这里用随包字体验证**真的**能出字（不是"只支持 ASCII"）。
	for ch in ["中", "国", "变"]:
		var m: Dictionary = GF.mask_for(ch, 24)
		assert_true(bool(m["ok"]), "中文字「%s」应能栅格化：%s" % [ch, str(m["reason"])])
		var rows: Array = (m["font_mask"] as Dictionary)[ch]
		assert_gt(_ink_count(rows), 0, "中文字「%s」必须要有笔画" % ch)


func test_mask_charset_matches_text_to_shape_contract() -> void:
	# 与 ShapeGenerator.MASK_FILLED / MASK_EMPTY 的字母表同源（本模块不另立字母表）。
	var m: Dictionary = GF.mask_for("AB1", 18)
	assert_true(bool(m["ok"]), "三字应成功：%s" % str(m["reason"]))
	var width := -1
	for ch in ["A", "B", "1"]:
		var rows: Array = (m["font_mask"] as Dictionary)[ch]
		for i in rows.size():
			var row: String = rows[i]
			if width < 0:
				width = row.length()
			assert_eq(row.length(), (rows[0] as String).length(),
					"「%s」行长必须一致（第 %d 行）" % [ch, i])
			for c in row.length():
				var g := row[c]
				assert_true(SG.MASK_FILLED.contains(g) or SG.MASK_EMPTY.contains(g),
						"「%s」第 %d 行第 %d 列的字符 %s 不在点阵字母表里" % [ch, i, c, g])
	assert_gt(width, 0, "点阵宽度应 > 0")


# ==================== ③ 确定性 ====================

func test_same_input_produces_bitwise_identical_mask() -> void:
	var a: Dictionary = GF.mask_for("AI中", 16)
	var b: Dictionary = GF.mask_for("AI中", 16)
	assert_true(bool(a["ok"]) and bool(b["ok"]), "两次都应成功")
	assert_eq(a["font_mask"], b["font_mask"], "同文本 + 同像素高度 ⇒ 点阵必须逐位相同（跨机器可复现）")
	assert_eq(a["glyph_px"], b["glyph_px"], "字形像素尺寸也应相同")


# ==================== ④ 能拒绝 ====================

func test_rejects_with_readable_reason() -> void:
	var cases := [
		[GF.mask_for("", 16), "空串"],
		[GF.mask_for("A\nB", 16), "多行"],
		[GF.mask_for("A\tB", 16), "制表符"],
		[GF.mask_for("A", 2), "像素高度低于下限"],
		[GF.mask_for("A", 97), "像素高度高于上限"],
		[GF.mask_for("   ", 16), "只有空格"],
		[GF.mask_for("ABCDEFGHIJKLMNOPQ", 16), "字符数超限"],
		[GF.mask_for("\uE000", 16), "字体缺字（私有区码点）"],
	]
	for c: Variant in cases:
		var r: Dictionary = c[0]
		var why := str(c[1])
		assert_false(bool(r["ok"]), "%s ⇒ 必须拒绝" % why)
		assert_eq((r["font_mask"] as Dictionary).size(), 0, "%s ⇒ 不得留下半成品点阵" % why)
		assert_ne(str(r["reason"]).strip_edges(), "", "%s ⇒ 必须给可读原因" % why)


func test_spaces_are_dropped_and_counted() -> void:
	var m: Dictionary = GF.mask_for("A B", 18)
	assert_true(bool(m["ok"]), "带空格的文字应成功（空格被剔除并记账）：%s" % str(m["reason"]))
	assert_eq(int(m["ignored_spaces"]), 1, "必须如实记账：1 个空格被忽略")
	assert_false((m["font_mask"] as Dictionary).has(" "), "空格不得作为字形写进点阵表（全空点阵不成形状）")


# ==================== ⑤ 自动适配 ====================

func test_text_cells_fit_shrinks_until_it_fits() -> void:
	var grid = _rect(12, 12)
	var r: Dictionary = GF.text_cells_fit("A", grid, Vector2i.ZERO, 40)
	assert_true(bool(r["ok"]), "12×12 盘上放 'A' 应能自动适配：%s" % str(r["reason"]))
	assert_true(bool(r["shrunk"]), "40 像素高的 A 放不进 12×12 ⇒ 应报告缩小过（不许静默缩）")
	assert_lt(int(r["used_px"]), 40, "used_px 应小于起始值")
	_assert_all_in_board(r["cells"], grid)


func test_text_cells_fit_reports_when_nothing_fits() -> void:
	var grid = _rect(2, 2)
	var r: Dictionary = GF.text_cells_fit("ABC", grid, Vector2i.ZERO, 20)
	assert_false(bool(r["ok"]), "2×2 盘上放 3 个字不可能成功")
	assert_eq((r["cells"] as Dictionary).size(), 0, "失败不得留半成品格")
	assert_ne(str(r["reason"]).strip_edges(), "", "失败必须给可读原因")
	assert_gt(int(r["attempts"]), 0, "应真的试过若干档（不是直接放弃）")


func test_text_cells_fit_propagates_font_level_errors() -> void:
	# 栅格化层面的错与尺寸无关 ⇒ 不该把每档都空试一遍，应立刻带原因返回。
	var grid = _rect(12, 12)
	var r: Dictionary = GF.text_cells_fit("A\nB", grid, Vector2i.ZERO, 20)
	assert_false(bool(r["ok"]), "多行必须失败")
	assert_eq(int(r["attempts"]), 1, "与尺寸无关的错应一次返回（实测 %d 次）" % int(r["attempts"]))
	assert_ne(str(r["reason"]).strip_edges(), "", "必须给可读原因")


# ==================== helpers ====================

func _rect(rows: int, cols: int):
	return SG.to_adjacency_grid("holed_grid", {"rows": rows, "cols": cols})


func _ink_count(rows: Array) -> int:
	var n := 0
	for row: String in rows:
		for c in row.length():
			if row[c] == GF.FILLED:
				n += 1
	return n


func _assert_all_in_board(cells: Dictionary, grid) -> void:
	assert_gt(cells.size(), 0, "前提：要有格可查")
	for p: Vector2i in cells.keys():
		assert_true(grid.in_board(p), "%s 必须被网格判为盘内（判界一律问网格）" % str(p))

