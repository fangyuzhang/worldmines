# test_editor_doc_mega_domino_fields.gd —— EditorDoc 承载「复合格 / 骨牌划分」两个**关卡字段**
#
# 背景：`MegaCell` / `DominoModel` 两个模块已交付，但文档里没有位置放它们。本套件钉住：
#   ① 两个独立字段（mega_cells / dominoes）进 `to_level_json()`→`load_from()` 往返一致；
#   ② `snapshot()`→`restore()` 往返一致（撤销不能把这两个关卡内容丢掉）；
#   ③ 老 JSON（没有这两个键）仍能载入、不报错、也不凭空写出键；
#   ④ 坐标桥：生成器/Board 的 `[[{c,r},…]]` 形态 ↔ 模型 `[[x,y]]`（**c=x, r=y**）往返形态不变；
#   ⑤ 既有语义不受影响（雷位/未知字段往返、载入清空会话形状选择）。
extends GutTest


func _doc(p_rows := 5, p_cols := 5, p_mines: Array = [Vector2i(0, 0)]) -> EditorDoc:
	var d := EditorDoc.new(p_rows, p_cols)
	for m in p_mines:
		d.mines.append(m)
	return d


# ==================== ① to_level_json → load_from ====================

func test_level_json_round_trip_keeps_mega_and_dominoes() -> void:
	var d := _doc()
	var mg := d.mega_cells.merge([Vector2i(0, 3), Vector2i(0, 4), Vector2i(1, 4)])
	assert_true(bool(mg["ok"]), "合并复合格应成功：%s" % str(mg))
	var mg_id := int(mg["id"])
	var p1 := d.dominoes.place(Vector2i(2, 2), Vector2i(3, 2), {"grid": d.grid()})
	assert_true(bool(p1["ok"]), "放置骨牌应成功：%s" % str(p1))
	var p2 := d.dominoes.place(Vector2i(2, 3), Vector2i(3, 3), {"grid": d.grid()})
	assert_true(bool(p2["ok"]), "放置骨牌应成功：%s" % str(p2))

	var js := d.to_level_json()
	assert_true(js.has("dominoes"), "有关卡内容时 dominoes 必须落到关卡顶层")
	var cust: Variant = js.get("custom", {})
	assert_true(cust is Dictionary and (cust as Dictionary).has("mega_cells"),
		"复合格必须落到 custom.mega_cells：%s" % str(cust))

	var back := EditorDoc.new()
	var r := back.load_from(js)
	assert_true(bool(r["ok"]), "载入应成功：%s" % str(r["reason"]))
	assert_eq(back.mega_cells.count(), 1, "复合格数量往返")
	assert_eq(back.mega_cells.internal_cells(mg_id), d.mega_cells.internal_cells(mg_id),
		"复合格内部格集合往返（下钻内容一致）")
	assert_eq(back.dominoes.count(), 2, "骨牌数量往返")
	assert_eq(back.dominoes.owner_of(Vector2i(2, 2)), d.dominoes.owner_of(Vector2i(2, 2)),
		"骨牌归属往返")
	assert_eq(back.dominoes.owner_of(Vector2i(3, 3)), d.dominoes.owner_of(Vector2i(3, 3)),
		"骨牌归属往返")

	# 二次导出：与首次逐键一致（双射，不是"越导越变"）
	assert_eq(back.to_level_json().get("dominoes"), js.get("dominoes"), "dominoes 二次导出必须一致")
	var cust2: Variant = back.to_level_json().get("custom", {})
	assert_eq((cust2 as Dictionary).get("mega_cells"), (cust as Dictionary).get("mega_cells"),
		"mega_cells 二次导出必须一致")


# ==================== ② snapshot → restore ====================

func test_snapshot_restore_round_trip_keeps_fields() -> void:
	var d := _doc()
	var mg := d.mega_cells.merge([Vector2i(1, 1), Vector2i(2, 1)])
	assert_true(bool(mg["ok"]), "合并复合格应成功：%s" % str(mg))
	var mg_id := int(mg["id"])
	var p := d.dominoes.place(Vector2i(3, 3), Vector2i(4, 3), {"grid": d.grid()})
	assert_true(bool(p["ok"]), "放置骨牌应成功：%s" % str(p))

	var snap := d.snapshot()
	# 破坏当前态（模拟继续编辑后按撤销）
	assert_true(bool(d.mega_cells.split(mg_id)["ok"]), "构造前提：拆掉复合格")
	d.dominoes.clear_all()
	assert_eq(d.mega_cells.count(), 0, "构造前提：复合格已清空")
	assert_eq(d.dominoes.count(), 0, "构造前提：骨牌已清空")

	assert_true(d.restore(snap), "恢复应成功")
	assert_eq(d.mega_cells.count(), 1, "撤销必须恢复复合格（关卡内容不能被当会话选择丢掉）")
	var icells := d.mega_cells.internal_cells(mg_id)
	assert_eq(icells.size(), 2, "复合格内部格集合大小恢复")
	assert_true(icells.has(Vector2i(1, 1)) and icells.has(Vector2i(2, 1)), "复合格内部格集合内容恢复：%s" % str(icells))
	assert_eq(d.dominoes.count(), 1, "撤销必须恢复骨牌划分")
	assert_eq(d.dominoes.owner_of(Vector2i(4, 3)), int(p["id"]), "骨牌归属恢复")


# ==================== ③ 老 JSON（没有这两个键）====================

func test_old_json_without_fields_loads_without_error() -> void:
	var level := {
		"name": "老关卡",
		"size": {"rows": 4, "cols": 4},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
	}
	var d := EditorDoc.new()
	var r := d.load_from(level)
	assert_true(bool(r["ok"]), "老 JSON 必须能载入：%s" % str(r["reason"]))
	assert_eq(d.dominoes.count(), 0, "无 dominoes 键 ⇒ 按「无」处理")
	assert_eq(d.mega_cells.count(), 0, "无 mega_cells 键 ⇒ 按「无」处理")

	var js := d.to_level_json()
	assert_false(js.has("dominoes"), "空模型不该凭空写出 dominoes 键（老数据输出不变）")
	var cust: Variant = js.get("custom", {})
	assert_false(cust is Dictionary and (cust as Dictionary).has("mega_cells"),
		"空模型不该凭空写出 custom.mega_cells")
	# 也不该漏进 passthrough（否则会重复/污染）
	assert_false(d.passthrough.has("dominoes"), "dominoes 是已识别字段，不该进 passthrough")


# ==================== ④ 坐标桥 c/r ↔ x/y ====================

func test_coordinate_bridge_cr_form_round_trip() -> void:
	# 生成器落盘形态：`[[{c,r},{c,r}], …]`。刻意用 c≠r 的坐标 —— 把 c/r 当 [r,c] 用错会在这里翻车。
	var raw: Array = [
		[{"c": 0, "r": 4}, {"c": 1, "r": 4}],
		[{"c": 3, "r": 1}, {"c": 3, "r": 2}],
	]
	var m := EditorDoc.dominoes_from_level(raw)
	assert_eq(m.count(), 2, "两张骨牌都应读进来")
	# c=x, r=y ⇒ (0,4)-(1,4) 一组、(3,1)-(3,2) 一组
	assert_ne(m.owner_of(Vector2i(0, 4)), 0, "(0,4) 应被占用")
	assert_eq(m.owner_of(Vector2i(0, 4)), m.owner_of(Vector2i(1, 4)), "c=x,r=y：这两格应同属一张骨牌")
	assert_eq(m.owner_of(Vector2i(3, 1)), m.owner_of(Vector2i(3, 2)), "c=x,r=y：这两格应同属一张骨牌")
	# 方向反了（按 [r,c] 读）会占用 (1,3)/(2,3) —— 必须为空，钉死换算方向
	assert_eq(m.owner_of(Vector2i(1, 3)), 0, "换算方向错误会把 (1,3) 误占用")
	assert_eq(m.owner_of(Vector2i(2, 3)), 0, "换算方向错误会把 (2,3) 误占用")

	# 写回**形态不变**：仍是 [[{c,r},…]]，键不能变成 x/y
	var back := EditorDoc.dominoes_to_level(m)
	assert_eq(back, raw, "写回必须与生成器形态逐键一致（c/r 口径 + 顺序一致）")
	for entry: Variant in back:
		for p: Variant in (entry as Array):
			var pd: Dictionary = p
			assert_true(pd.has("c") and pd.has("r"), "写回键必须是 c/r：%s" % str(pd))
			assert_false(pd.has("x") or pd.has("y"), "写回不能混入 x/y 键：%s" % str(pd))

	# 端到端接线：Board._parse_dominoes 只认 c/r ⇒ 我们导出的关卡 JSON 必须被 Board 读成同样的坐标
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(4, 4)])
	d.dominoes = EditorDoc.dominoes_from_level(raw)
	var b := Board.new()
	b.load_level(d.to_level_json())
	assert_eq(b.dominoes.size(), 2, "Board 应读到 2 张骨牌（接线不能丢）")
	var found := {}
	for pair: Variant in b.dominoes:
		assert_eq((pair as Array).size(), 2, "每张骨牌应为 2 格")
		for p: Variant in (pair as Array):
			found[p] = true
	assert_true(found.has(Vector2i(0, 4)) and found.has(Vector2i(1, 4)),
		"Board 读到的坐标必须是 c=x,r=y 口径：%s" % str(found.keys()))
	assert_true(found.has(Vector2i(3, 1)) and found.has(Vector2i(3, 2)),
		"Board 读到的坐标必须是 c=x,r=y 口径（非对称坐标）：%s" % str(found.keys()))


# ==================== ⑤ 既有语义冒烟对照 ====================

func test_existing_doc_behavior_unaffected_smoke() -> void:
	# 既有语义①：载入关卡会**清空会话编辑选择**（形状族），雷位则作为关卡内容保留。
	var d := _doc(5, 5, [Vector2i(1, 1)])
	d.shape_kind = "hex"
	d.shape_params = {"size": 3}
	var js := d.to_level_json()
	var back := EditorDoc.new()
	back.shape_kind = "hex"
	assert_true(bool(back.load_from(js)["ok"]), "载入应成功")
	assert_eq(back.shape_kind, "", "载入关卡必须清空会话形状选择（既有语义不变）")
	assert_eq(back.shape_params, {}, "形状参数同样清空（既有语义不变）")
	assert_true(back.mines.has(Vector2i(1, 1)), "雷位是关卡内容，不被清（既有语义不变）")

	# 既有语义②：不认识的字段原样带回（无损）
	var lvl := {
		"name": "外来关卡",
		"size": {"rows": 3, "cols": 3},
		"total_mines": 1,
		"mines": [{"r": 0, "c": 0}],
		"my_future_field": {"y": 2},
	}
	var d2 := EditorDoc.new()
	assert_true(bool(d2.load_from(lvl)["ok"]), "载入应成功")
	assert_eq(d2.to_level_json().get("my_future_field", {}), {"y": 2}, "未知字段无损往返（既有语义不变）")
