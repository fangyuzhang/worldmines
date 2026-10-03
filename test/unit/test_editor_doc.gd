# test_editor_doc.gd —— 编辑器文档模型（EditorDoc）自证
#
# 钉住的不变量（坏一条，编辑器就会产出"存了读不回"或"显示与玩不一致"的关卡）：
#   1) JSON 双射：默认盘 / 环绕盘 / 障碍 / 自定义邻域 全部往返还原；
#   2) **预览 == 玩家看到的**：`preview_clues()` 逐格对上 `Board` 载入后的 Cell.value
#      （矩形盘、环绕盘、以及 spec 规则盘三种）——这是本文件最重要的一条；
#   3) 规则数据驱动：spec 原文随关卡走（custom.spec），注册后可真的建出 Board；
#   4) 校验能定位：错误带坐标，`highlight_cells()` 能取出来；
#   5) 无损往返：不认识的字段与带 interval 的 revealed 原样保留；
#   6) 环绕盘能被生成管线真的产出关卡（编辑器画完就能玩）。
extends GutTest


func test_snapshot_keeps_shape_params() -> void:
	# 【W1 前置修复 2026-10-03】`load_from()` 会把 `shape_kind/shape_params` 清零，而快照原来没带它们
	# ⇒ "换形状后按撤销"会**悄悄退回方阵**（用户手工改的格子与形状定义一起丢）。
	var d := EditorDoc.new(9, 9)
	d.mines.append(Vector2i(4, 4))
	d.shape_kind = "ring"
	d.shape_params = {"outer": 3, "inner": 1}
	var snap := d.snapshot()
	d.shape_kind = ""
	d.shape_params = {}
	assert_true(d.restore(snap), "恢复应成功")
	assert_eq(d.shape_kind, "ring", "撤销必须恢复到原形状类型")
	assert_eq(int(d.shape_params.get("inner", -1)), 1, "形状参数也要一起恢复：%s" % str(d.shape_params))
	assert_true(d.mines.has(Vector2i(4, 4)), "盘面本身也要照旧恢复")


func test_neighbor_degree_limits_warn_and_block() -> void:
	# 【清单·数据爆炸 B】单格邻居 >30 警告、>80 阻止。形状盘最容易中招：作者写一张大偏移表时
	# 不会意识到自己在造一个"读不出数字"的格子。
	var d := EditorDoc.new(9, 9)
	d.mines.append(Vector2i(4, 4))
	# ① 6×6 邻域 = 35 个偏移 ⇒ 应警告、不阻止
	var w: Array[Vector2i] = []
	for y in range(-3, 3):
		for x in range(-3, 3):
			if x != 0 or y != 0:
				w.append(Vector2i(x, y))
	d.dirs = w
	var rep_w := d.validate()
	assert_true(_has_neighbor_issue(rep_w["warnings"]), "35 个邻居应出「邻接偏多」警告：%s" % str(rep_w["warnings"]))
	assert_false(_has_neighbor_issue(rep_w["errors"]), "35 个邻居不该被阻止")
	# ② 边界：9×9 邻域**正好 80** ⇒ 门槛是 `>80` 才阻止 ⇒ 这一档**只警告不阻止**（把边界写死，防后人改错）
	var edge: Array[Vector2i] = []
	for y in range(-4, 5):
		for x in range(-4, 5):
			if x != 0 or y != 0:
				edge.append(Vector2i(x, y))
	assert_eq(edge.size(), 80, "9×9 邻域应正好 80 个偏移（不含自身）")
	d.dirs = edge
	var rep_e := d.validate()
	assert_false(_has_neighbor_issue(rep_e["errors"]), "正好 80 不该被阻止（门槛是 >80）")
	assert_true(_has_neighbor_issue(rep_e["warnings"]), "正好 80 应出警告")
	# ③ 11×11 邻域 = 120 个偏移 ⇒ 超过上限，必须阻止
	var b: Array[Vector2i] = []
	for y in range(-5, 6):
		for x in range(-5, 6):
			if x != 0 or y != 0:
				b.append(Vector2i(x, y))
	d.dirs = b
	var rep_b := d.validate()
	assert_true(_has_neighbor_issue(rep_b["errors"]), "120 个邻居必须被阻止：%s" % str(rep_b["errors"]))
	# ③ 默认邻域不许误报（闸门不能把正常关卡挡下）
	var ok := EditorDoc.new(9, 9)
	ok.mines.append(Vector2i(4, 4))
	assert_false(_has_neighbor_issue(ok.validate()["warnings"]), "默认邻域不该触发邻接警告")


func _has_neighbor_issue(list: Array) -> bool:
	# 只认**本门禁自己的消息**（"单格邻接 …"）。用宽串"邻接"会误命中 `WrapTopology` 自己的报错
	#（实测：35 个偏移会让拓扑构建器先报一条同样含"邻接"的错误）⇒ 那会把"某处报错"当成"我的门禁触发"。
	for it in list:
		if str((it as Dictionary).values()).find("单格邻接") != -1:
			return true
	return false

## 本文件注册进全局表的 spec id（after_each 全部注销——注册表是进程级单例，不清理会污染别的套件）
var _registered: Array[String] = []


func after_each() -> void:
	for rid in _registered:
		RuleRegistry.default().unregister(StringName(rid))
	_registered.clear()


func _doc(p_rows: int, p_cols: int, mine_list: Array) -> EditorDoc:
	var d := EditorDoc.new(p_rows, p_cols)
	for m in mine_list:
		d.mines.append(m)
	return d


## 复刻内置 classic 的 spec（refs 顺序 == ClueEngine.ring_dirs()，expr = Σ ref）。
func _classic_spec(id: String) -> Dictionary:
	var refs: Array = []
	for d in ClueEngine.ring_dirs():
		refs.append({"dx": d.x, "dy": d.y})
	var xs: Array = []
	for i in refs.size():
		xs.append({"t": "ref", "i": i})
	return {
		"spec_version": 1,
		"id": id,
		"title": "编辑器测试用经典8邻",
		"geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}},
	}


func _board_values(doc: EditorDoc) -> Dictionary:
	var b := doc.build_board()
	assert_not_null(b, "build_board 应成功（规则注册 + 关卡可加载）")
	var out := {}
	if b == null:
		return out
	for p in b.grid.all_positions():
		var c: Cell = b.grid.get_cell(p)
		if c == null or c.is_mine:
			continue
		out[p] = c.value
	return out


func _assert_preview_matches_board(doc: EditorDoc, tag: String) -> void:
	var pv := doc.preview_clues()
	assert_true(bool(pv["ok"]), "%s：预览应成功（%s）" % [tag, str(pv["reason"])])
	var preview: Dictionary = pv["values"]
	var board_vals := _board_values(doc)
	assert_eq(board_vals.size(), preview.size(), "%s：非雷格数量应一致" % tag)
	var mismatch := 0
	var example := ""
	for p in preview:
		if not board_vals.has(p) or board_vals[p] != preview[p]:
			mismatch += 1
			if example == "":
				example = "格 %s：预览 %s vs Board %s" % [str(p), str(preview[p]), str(board_vals.get(p))]
	assert_eq(mismatch, 0, "%s：编辑器显示必须与玩家看到的一致（%s）" % [tag, example])


# ==================== 1. 基础校验与派生量 ====================

func test_fresh_doc_is_invalid_until_it_has_mines() -> void:
	var d := EditorDoc.new(5, 5)
	var bad := d.validate()
	assert_false(bool(bad["ok"]), "没放雷的文档不该通过校验")
	var codes := []
	for it in bad["errors"]:
		codes.append(str((it as Dictionary)["code"]))
	assert_true(codes.has("no_mines"), "应给出 no_mines：%s" % str(codes))

	d.mines.append(Vector2i(0, 0))
	d.mines.append(Vector2i(4, 4))
	d.mines.append(Vector2i(2, 2))
	var good := d.validate()
	assert_true(bool(good["ok"]), "放雷后应通过校验：%s" % str(good["errors"]))


func test_counts_and_density_exclude_obstacles() -> void:
	var d := _doc(4, 4, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	assert_eq(d.cell_count(), 16, "无障碍时格数 = 行*列")
	assert_eq(d.mine_count(), 3, "雷数取真源")
	assert_almost_eq(d.density(), 3.0 / 16.0, 0.0001, "密度 = 雷数/可用格数")
	d.obstacles.append(Vector2i(3, 3))
	assert_eq(d.cell_count(), 15, "障碍应从可用格数里扣除")


# ==================== 2. JSON 形状与往返 ====================

func test_json_shape_is_loadable_and_sorted() -> void:
	var d := _doc(5, 5, [Vector2i(3, 2), Vector2i(0, 0), Vector2i(1, 1)])
	d.revealed[Vector2i(4, 4)] = null
	var js := d.to_level_json()
	assert_eq(int((js["size"] as Dictionary)["rows"]), 5, "size.rows")
	assert_eq(int(js["total_mines"]), 3, "total_mines = 实际雷位")
	assert_eq((js["mines"] as Array).size(), 3, "mines 条目数")
	var first: Dictionary = (js["mines"] as Array)[0]
	assert_eq(int(first["r"]), 0, "落盘按 r 升序（diff 友好）")
	assert_eq(int(first["c"]), 0, "同 r 内按 c 升序")
	assert_false(js.has("rule_level"), "只放雷、不写规则时不该有 rule_level")


func test_round_trip_default_board() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(2, 3), Vector2i(4, 4)])
	d.title = "往返用例"
	d.revealed[Vector2i(1, 1)] = null
	d.revealed[Vector2i(3, 0)] = null
	var js := d.to_level_json()
	var back := EditorDoc.new()
	var r := back.load_from(js)
	assert_true(bool(r["ok"]), "载入应成功：%s" % str(r["reason"]))
	assert_eq(back.title, "往返用例", "标题往返")
	assert_eq(back.rows, 5, "行往返")
	assert_eq(back.cols, 5, "列往返")
	assert_eq(back.mines.size(), 3, "雷位数量往返")
	assert_true(back.mines.has(Vector2i(2, 3)), "雷位内容往返")
	assert_eq(back.revealed.size(), 2, "初始翻开集合往返")
	assert_true(back.revealed.has(Vector2i(3, 0)), "初始翻开内容往返")
	assert_true(back.topology().is_empty(), "默认盘不产出 topology（继续走 RectGrid）")


func test_round_trip_wrap_custom_dirs_and_obstacles() -> void:
	var d := _doc(6, 6, [Vector2i(0, 0), Vector2i(2, 3)])
	d.wrap = true
	d.dirs.assign(WrapTopology.DIRS_ORTHO4)
	d.include_self = true
	d.obstacles.append(Vector2i(5, 5))
	var js := d.to_level_json()
	assert_true(js.has("topology"), "非默认邻域必须落 topology")
	var back := EditorDoc.new()
	assert_true(bool(back.load_from(js)["ok"]), "载入应成功")
	assert_true(back.wrap, "wrap 往返")
	assert_true(back.include_self, "include_self 往返")
	assert_eq(back.dirs.size(), 4, "dirs 往返")
	assert_true(back.dirs.has(Vector2i(0, 1)), "dirs 内容往返")
	assert_eq(back.obstacles.size(), 1, "障碍由 topology.positions 反推回来")
	assert_true(back.obstacles.has(Vector2i(5, 5)), "障碍坐标往返")


func test_passthrough_keeps_unknown_fields_and_warns() -> void:
	var level := {
		"name": "外来关卡",
		"size": {"rows": 5, "cols": 5},
		"total_mines": 2,
		"mines": [{"r": 0, "c": 0}, {"r": 4, "c": 4}],
		"revealed": [{"r": 2, "c": 2}, {"r": 3, "c": 3, "interval": [0, 1]}],
		"variant": "C1",           # 内置线索变体：编辑器不编辑，但要如实提醒
		"my_future_field": {"x": 1},  # 未来字段：必须原样带回
	}
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(level)["ok"]), "载入应成功")
	assert_false(d.revealed.has(Vector2i(3, 3)), "带 interval 的条目不进编辑集合")
	var js := d.to_level_json()
	assert_eq(js.get("my_future_field", {}), {"x": 1}, "不认识的字段必须原样带回（无损）")
	var kept := false
	for e in js["revealed"]:
		if (e as Dictionary).has("interval"):
			kept = true
	assert_true(kept, "带 interval 的 revealed 条目必须原样写回（不静默丢数据）")
	var warns := []
	for w in d.validate()["warnings"]:
		warns.append(str((w as Dictionary)["code"]))
	assert_true(warns.has("foreign_variant"), "应提醒「该关卡用内置线索变体」：%s" % str(warns))
	assert_true(warns.has("revealed_extras"), "应提醒「遮蔽区间不编辑、但会保留」：%s" % str(warns))


# ==================== 3. 预览 == 玩家看到（核心不变量） ====================

func test_preview_matches_board_on_default_board() -> void:
	var d := _doc(6, 6, [Vector2i(0, 0), Vector2i(3, 3), Vector2i(5, 5), Vector2i(1, 4)])
	_assert_preview_matches_board(d, "矩形盘")


func test_preview_cells_matches_full_preview() -> void:
	# 增量预览（编辑器改一格只重算"该格+邻居"）必须与全量预览**逐值一致**，
	# 否则会出现"改了雷但数字没跟着变"或"数字变了但算错"这类静默问题。
	var d := _doc(7, 7, [Vector2i(0, 0), Vector2i(3, 3), Vector2i(6, 6), Vector2i(1, 5)])
	d.wrap = true
	var full: Dictionary = d.preview_clues()["values"]
	var all_cells: Array[Vector2i] = []
	for y in 7:
		for x in 7:
			all_cells.append(Vector2i(x, y))
	var inc := d.preview_cells(all_cells)
	assert_eq(inc.size(), full.size(), "全盘取样时增量结果数量应与全量一致")
	var mismatch := 0
	for p in full:
		if inc.get(p) != full[p]:
			mismatch += 1
	assert_eq(mismatch, 0, "增量与全量必须逐值一致")

	# 真实调用方式是"只问几格"（改一格 ⇒ 该格 + 邻居）
	var few: Array[Vector2i] = [Vector2i(2, 2), Vector2i(3, 3), Vector2i(0, 0)]
	var inc2 := d.preview_cells(few)
	assert_false(inc2.has(Vector2i(3, 3)), "雷格不携带线索值（应被剔除）")
	assert_eq(inc2.get(Vector2i(2, 2)), full.get(Vector2i(2, 2)), "子集值应与全量一致")
	assert_eq(inc2.get(Vector2i(0, 0)), full.get(Vector2i(0, 0)), "角落格同理")


func test_caches_invalidate_when_structure_changes() -> void:
	# 缓存按"结构签名"失效：改了边界/障碍/邻域就必须重建，否则会拿旧盘算新盘
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	assert_true(d.topology().is_empty(), "默认盘无 topology（构造前提）")
	var sig0 := d.struct_signature()
	d.wrap = true
	assert_ne(d.struct_signature(), sig0, "改边界后结构签名必须变")
	var topo := d.topology()
	assert_false(topo.is_empty(), "改成环绕后必须真的重建出邻接表（缓存失效）")
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(topo)
	assert_eq(ag.get_neighbors(Vector2i(0, 0)).size(), 8, "环绕 5x5 角格应有 8 邻")

	# 障碍变化也要失效，且新障碍必须真的从盘上消失
	d.obstacles.append(Vector2i(0, 0))
	var present := {}
	for p in d.topology()["positions"]:
		var pd: Dictionary = p
		present[Vector2i(int(pd["x"]), int(pd["y"]))] = true
	assert_false(present.has(Vector2i(0, 0)), "新加的障碍必须从盘上消失（缓存必须失效）")

	# 审计结论也要随结构失效：把偏移改成够不到的 ⇒ 应重新审计出孤立格
	d.dirs = [Vector2i(9, 9)]
	var codes: Array[String] = []
	for w in d.validate()["warnings"]:
		codes.append(str((w as Dictionary)["code"]))
	assert_true(codes.has("isolated_cell"),
		"偏移全错时应重新审计并报孤立格（审计缓存必须失效）：%s" % str(codes))


func test_preview_matches_board_on_wrap_board() -> void:
	var d := _doc(6, 6, [Vector2i(0, 0), Vector2i(3, 3), Vector2i(5, 5), Vector2i(1, 4)])
	d.wrap = true
	_assert_preview_matches_board(d, "环绕盘")


func test_preview_matches_board_with_spec_rule() -> void:
	# 规则数据驱动：spec 原文随关卡走，注册后 Board 与预览必须同口径
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)])
	var sid := "spec_edit_%d" % randi()
	d.rule_spec = _classic_spec(sid)
	var reg := d.register_rule()
	assert_true(bool(reg["ok"]), "spec 规则应注册成功：%s" % str(reg["reason"]))
	_registered.append(sid)
	assert_not_null(RuleRegistry.default().resolve(StringName(sid)), "注册后应能解析")
	_assert_preview_matches_board(d, "spec 规则盘")


func test_json_carries_the_spec_so_it_can_be_shared() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	var sid := "spec_edit_share_%d" % randi()
	d.rule_spec = _classic_spec(sid)
	var js := d.to_level_json()
	assert_true(bool(js.get("rule_level", false)), "用规则时必须写 rule_level=true（否则 Board 不解析 clue_rule）")
	assert_eq(str(js.get("clue_rule", "")), sid, "clue_rule = spec id")
	var spec := EditorDoc.spec_of_level(js)
	assert_eq(str(spec.get("id", "")), sid, "规格原文随关卡携带（分享闭环的接收端据此注册）")
	# 接收端：未注册 → 注册 → 可玩
	var r := EditorDoc.register_spec_from_level(js)
	assert_true(bool(r["ok"]), "接收端应能注册关卡自带的规格：%s" % str(r["reason"]))
	_registered.append(sid)
	assert_not_null(RuleRegistry.default().resolve(StringName(sid)), "注册后规则可用")


# ==================== 4. 校验与定位 ====================

func test_validate_locates_cells_and_highlight_works() -> void:
	var d := _doc(5, 5, [Vector2i(1, 1), Vector2i(1, 1), Vector2i(7, 7)])
	var rep := d.validate()
	assert_false(bool(rep["ok"]), "重复/越界雷位必须报错")
	var codes := []
	var has_pos := false
	for it in rep["errors"]:
		var e: Dictionary = it
		codes.append(str(e["code"]))
		if str(e["code"]) == "mine_oob" and (e["pos"] as Vector2i) == Vector2i(7, 7):
			has_pos = true
	assert_true(codes.has("mine_oob"), "应报越界：%s" % str(codes))
	assert_true(codes.has("mine_dup"), "应报重复：%s" % str(codes))
	assert_true(has_pos, "越界错误必须带坐标（UI 才能高亮）")
	assert_true(d.highlight_cells(rep).has(Vector2i(7, 7)), "highlight_cells 应能取到待高亮的格")


func test_validate_flags_rect_only_rule_on_topology_board() -> void:
	# 「规则看起来生效其实没生效」是本仓的经典坑：拓扑盘上 RECT_ONLY 规则会被生成器回退 classic
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	d.wrap = true
	d.clue_rule_id = "clock"
	var rep := d.validate()
	var codes := []
	for it in rep["errors"]:
		codes.append(str((it as Dictionary)["code"]))
	assert_true(codes.has("geom_conflict"), "拓扑盘 + RECT_ONLY 规则必须报 geom_conflict：%s" % str(codes))

	# 换成声明"任意拓扑可用"的 classic ⇒ 冲突消失
	d.clue_rule_id = "classic"
	var rep2 := d.validate()
	var codes2 := []
	for it in rep2["errors"]:
		codes2.append(str((it as Dictionary)["code"]))
	assert_false(codes2.has("geom_conflict"), "classic 声明支持任意拓扑，不该冲突")


func test_validate_warns_on_dead_and_identity_offsets() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	d.dirs = [Vector2i(9, 9)]   # 非环绕：永远够不到
	var w1 := []
	for w in d.validate()["warnings"]:
		w1.append(str((w as Dictionary)["code"]))
	assert_true(w1.has("offset_dead"), "非环绕下的死偏移应告警：%s" % str(w1))

	var e := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	e.wrap = true
	e.dirs = [Vector2i(0, 5)]   # 环绕下 y+5 正好返回自身列
	var w2 := []
	for w in e.validate()["warnings"]:
		w2.append(str((w as Dictionary)["code"]))
	assert_true(w2.has("offset_identity"), "环绕下的整圈偏移应告警：%s" % str(w2))


func test_foreign_form1_topology_survives_load_and_save() -> void:
	# 【2026-10-02 由真实关卡（levels/ani_butterfly.json）抓到的 bug 的回归测试】
	# 拓扑有两种等价形式：形式 1 = positions + adjacency（ShapeGenerator 产出、mod 的
	# board.json 约定），形式 2 = positions + neighbors。挖洞逻辑最初只处理形式 2 ⇒
	# 形式 1 的盘被处理后会输出**空的 neighbors**，而 setup_from_topo 优先读 neighbors
	# ⇒ 整盘邻接全丢（实测 158 个格全变孤立格），且这份坏拓扑还会被导出写回文件。
	var topo := {
		"positions": [{"x": 0, "y": 0}, {"x": 1, "y": 0}, {"x": 0, "y": 1}, {"x": 1, "y": 1}],
		"adjacency": [
			{"a": {"x": 0, "y": 0}, "b": {"x": 1, "y": 0}},
			{"a": {"x": 0, "y": 0}, "b": {"x": 0, "y": 1}},
			{"a": {"x": 1, "y": 0}, "b": {"x": 1, "y": 1}},
			{"a": {"x": 0, "y": 1}, "b": {"x": 1, "y": 1}},
		],
		"style": "custom",
	}
	# 刻意把 size 报成 3x3（大于 positions 包围盒）：于是"包围盒内但不在盘上"的 5 个格
	# 会成为障碍 ⇒ 载入后 obstacles 非空 ⇒ 正好走"挖洞"那条路径（bug 的触发条件）。
	var lvl := {
		"name": "外部拓扑回归", "size": {"rows": 3, "cols": 3}, "total_mines": 1,
		"mines": [{"r": 0, "c": 0}], "revealed": [], "topology": topo,
	}
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(lvl)["ok"]), "应能载入外部拓扑关卡")
	assert_false(d.foreign_topology.is_empty(), "应识别为外部拓扑")
	assert_eq(d.obstacles.size(), 5, "包围盒内的 5 个空格应被识别为障碍")

	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(d.topology())
	assert_eq(ag.cell_count(), 4, "格数应保持 4")
	var isolated := 0
	var maxdeg := 0
	for p in ag.all_positions():
		var deg := ag.get_neighbors(p).size()
		if deg == 0:
			isolated += 1
		maxdeg = maxi(maxdeg, deg)
	assert_eq(isolated, 0, "外部拓扑里不该出现孤立格（邻接丢了才会这样）")
	assert_eq(maxdeg, 2, "2x2 环上每格应恰有 2 个邻居")
	assert_true(bool(AdjacencyBuilder.audit(ag)["ok"]), "载入后的表应过审计")

	# 再导出一次：邻接必须还在（防"保存就把盘写坏"）
	var t2: Dictionary = d.to_level_json()["topology"]
	assert_true(t2.has("adjacency"), "导出必须保留形式 1 的邻接：%s" % str(t2.keys()))
	var ag2 := AdjacencyGrid.new()
	ag2.setup_from_topo(t2)
	var isolated2 := 0
	for p in ag2.all_positions():
		if ag2.get_neighbors(p).is_empty():
			isolated2 += 1
	assert_eq(isolated2, 0, "导出后再载入仍不该出现孤立格（否则保存会损坏盘面）")


func test_validate_aggregates_topology_audit_and_locates_isolated_cells() -> void:
	# 偏移全写错 ⇒ 每格都没有邻居：审计器该报（或逐格告警），且**必须带坐标**供高亮
	var d := _doc(3, 3, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	d.dirs = [Vector2i(5, 5)]   # 非环绕 ⇒ 3x3 盘上永远取不到邻居
	var rep := d.validate()
	var isolated: Array[Vector2i] = []
	for w in rep["warnings"]:
		var it: Dictionary = w
		if str(it["code"]) == "isolated_cell":
			isolated.append(it["pos"])
	assert_true(isolated.size() >= 9, "9 个格全都孤立，应逐格给出坐标（收到 %d 条）" % isolated.size())
	assert_true(d.highlight_cells(rep).size() >= 9, "highlight_cells 应能取到这些格")


func test_validate_passes_topology_audit_on_a_correct_wrap_board() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	d.wrap = true
	var rep := d.validate()
	var codes: Array[String] = []
	for it in rep["errors"]:
		codes.append(str((it as Dictionary)["code"]))
	for w in rep["warnings"]:
		codes.append(str((w as Dictionary)["code"]))
	# 注意：断言必须**无条件**执行。第一版写成"遍历 errors/warnings 逐个 assert_ne"，
	# 在正确盘上两个数组都是空的 ⇒ 一个断言都没跑 ⇒ GUT 判 `Risky: did not assert`
	#（不会失败的测试等于没有保护；这条被门禁新增的 [Risky] 检查当场抓住）。
	assert_false(codes.has("topology"), "正确的环绕盘不该被审计器判错：%s" % str(codes))
	assert_false(codes.has("isolated_cell"), "环绕盘不该有孤立格：%s" % str(codes))
	assert_true(bool(rep["ok"]), "正确的环绕盘文档应通过校验：%s" % str(rep["errors"]))
	# 正面证据：环绕盘确实产出拓扑，且角格在环绕下也是 8 邻（审计通过的直接体现）
	var topo := d.topology()
	assert_false(topo.is_empty(), "环绕盘应产出 topology")
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(topo)
	assert_eq(ag.get_neighbors(Vector2i(0, 0)).size(), 8, "环绕盘角格也应是 8 邻")


func test_declared_mine_mismatch_is_reported_not_silently_fixed() -> void:
	var level := {
		"name": "声明不符",
		"size": {"rows": 5, "cols": 5},
		"total_mines": 5,
		"mines": [{"r": 0, "c": 0}, {"r": 4, "c": 4}],
		"revealed": [],
	}
	var d := EditorDoc.new()
	assert_true(bool(d.load_from(level)["ok"]), "载入应成功")
	assert_eq(d.declared_total_mines, 5, "声明的雷数必须保留")
	assert_eq(d.total_mines_for_solving(), 5, "求解用声明值（矛盾就在声明 vs 实际之间）")
	var codes := []
	for it in d.validate()["errors"]:
		codes.append(str((it as Dictionary)["code"]))
	assert_true(codes.has("declared_mismatch"), "应报声明不符：%s" % str(codes))
	assert_eq(int(d.to_level_json()["total_mines"]), 5, "导出按声明值写（不静默修正）")


func test_register_rule_is_idempotent_and_leaves_no_trace_on_failure() -> void:
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 1), Vector2i(2, 2)])
	var sid := "spec_edit_bad_%d" % randi()
	var bad := _classic_spec(sid)
	bad.erase("title")   # 非法规格：缺 title
	d.rule_spec = bad
	var r := d.register_rule()
	assert_false(bool(r["ok"]), "非法规格注册必须失败")
	assert_null(RuleRegistry.default().resolve(StringName(sid)), "失败不得在全局表留痕")

	d.rule_spec = _classic_spec(sid)
	var ok1 := d.register_rule()
	assert_true(bool(ok1["ok"]), "合法规格应注册成功：%s" % str(ok1["reason"]))
	_registered.append(sid)
	var ok2 := d.register_rule()
	assert_true(bool(ok2["ok"]), "重复注册应幂等成功（不报错、不覆盖）")


# ==================== 5. 建议开局 + 端到端（画完就能玩） ====================

func test_suggest_reveal_never_includes_mines() -> void:
	var d := _doc(6, 6, [Vector2i(5, 5), Vector2i(0, 3)])
	var sug := d.suggest_reveal()
	assert_true(sug.size() > 0, "有 0 值格时应给出开局建议")
	for p in sug:
		assert_false(d.mines.has(p), "建议开局里不能有雷：%s" % str(p))


func test_snapshot_carries_edit_state_without_derived_topology() -> void:
	# 撤销快照必须"只存编辑状态"：若存 topology，64x64 环绕盘的快照可达数 MB，
	# 50 步撤销就是上百 MB 内存（2026-10-02 复查发现的隐患）。
	var d := _doc(12, 12, [Vector2i(0, 0), Vector2i(5, 5), Vector2i(11, 11)])
	d.wrap = true
	d.obstacles.append(Vector2i(6, 6))
	d.title = "快照用例"
	var full := d.to_level_json()
	assert_true(full.has("topology"), "导出关卡当然要带 topology（构造前提）")

	var snap := d.snapshot()
	assert_false((snap["level"] as Dictionary).has("topology"), "快照不得包含派生的 topology")
	var full_len := JSON.stringify(full).length()
	var snap_len := JSON.stringify(snap["level"]).length()
	assert_true(snap_len * 2 < full_len,
		"快照应显著小于完整关卡（实测 %d vs %d）" % [snap_len, full_len])

	# 还原必须完整：结构字段 + 雷 + 障碍 + 标题，且线索值逐格一致
	var before_values: Dictionary = d.preview_clues()["values"]
	d.mines.append(Vector2i(3, 3))
	d.wrap = false
	d.obstacles.clear()
	d.title = "被改了"
	assert_true(d.restore(snap), "restore 应成功")
	assert_eq(d.title, "快照用例", "标题还原")
	assert_true(d.wrap, "环绕标志还原（结构字段在快照里，topology 由它重算）")
	assert_eq(d.mines.size(), 3, "雷位还原")
	assert_eq(d.obstacles.size(), 1, "障碍还原")
	var after: Dictionary = d.preview_clues()["values"]
	var mismatch := 0
	for p in before_values:
		if after.get(p) != before_values[p]:
			mismatch += 1
	assert_eq(mismatch, 0, "还原后逐格线索值必须与快照时完全一致")


func test_shape_board_can_be_authored_from_scratch() -> void:
	# 需求里的"架构上要能扩展到六边形/三角"：这里把它变成"真的能从零画"。
	var d := EditorDoc.new(9, 9)
	d.shape_kind = "hex"
	d.shape_params = {"size": 3}
	d.sync_size_to_shape()
	assert_true(d.rows >= 3 and d.cols >= 3, "大小应同步成六边形包围盒：%dx%d" % [d.rows, d.cols])

	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(d.topology())
	assert_true(ag.cell_count() > 0, "应产出六边形格")
	var deg: int = ag.get_neighbors(ag.all_positions()[0]).size()
	assert_true(deg >= 1 and deg <= 6, "六边形的度数应在 1..6（不该出现矩形 8 邻）：%d" % deg)
	assert_true(bool(AdjacencyBuilder.audit(ag)["ok"]),
		"形状盘应过审计：%s" % str(AdjacencyBuilder.audit(ag)["problems"]))

	var warns: Array[String] = []
	for w in d.validate()["warnings"]:
		warns.append(str((w as Dictionary)["code"]))
	assert_true(warns.has("shape_active"), "应提醒当前是形状盘（邻域/边界不适用）：%s" % str(warns))

	# 盘外雷位必须被报出来（否则它会静默消失：盘上没那个格，而包围盒校验查不出）
	var on_board := {}
	for p in ag.all_positions():
		on_board[p] = true
	var outside := Vector2i(-1, -1)
	for y in d.rows:
		for x in d.cols:
			if not on_board.has(Vector2i(x, y)):
				outside = Vector2i(x, y)
				break
		if outside.x >= 0:
			break
	assert_true(outside.x >= 0, "六边形盘在包围盒里必然有空位（构造前提）")
	d.mines.clear()
	d.mines.append(outside)
	var codes: Array[String] = []
	for e in d.validate()["errors"]:
		codes.append(str((e as Dictionary)["code"]))
	assert_true(codes.has("mine_off_board"), "盘外雷位必须被报错：%s" % str(codes))


func test_hex_shape_board_plays_like_the_editor_shows() -> void:
	# 形状盘的"编辑器显示 == 玩家看到"：雷放在**形状内**，预览与 Board 载入后逐格一致。
	var d := EditorDoc.new(9, 9)
	d.shape_kind = "hex"
	d.shape_params = {"size": 3}
	d.sync_size_to_shape()
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(d.topology())
	var cells := ag.all_positions()
	assert_true(cells.size() >= 4, "构图前提：六边形应有若干格")
	d.mines.append(cells[0])
	d.mines.append(cells[cells.size() - 1])
	assert_true(bool(d.validate()["ok"]), "形状盘文档应通过校验：%s" % str(d.validate()["errors"]))
	_assert_preview_matches_board(d, "六边形盘")


func test_playtest_path_survives_the_real_level_loader() -> void:
	# 编辑器的「试玩」走的是**真加载器**（GameSession.start_level → LevelLoader），
	# 不是 Board.load_level。这条测试把那条路走完：注册规则 → 落盘 → 真加载器读回 →
	# 逐格核对线索值 == 编辑器预览（否则会出现"编辑器里好好的、一按试玩就变样"）。
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)])
	d.wrap = true
	var sid := "spec_edit_play_%d" % randi()
	d.rule_spec = _classic_spec(sid)
	var reg := d.register_rule()
	assert_true(bool(reg["ok"]), "规则应注册成功：%s" % str(reg["reason"]))
	_registered.append(sid)

	var path := "user://test_editor_play.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "应能写入试玩关卡文件")
	f.store_string(JSON.stringify(d.to_level_json(), "  "))
	f.close()

	var board := LevelLoader.load_level(path)
	assert_not_null(board, "真加载器应接受编辑器产出的关卡（含环绕盘与 spec 规则）")
	assert_eq(board.grid.cell_count(), 25, "盘面格数应与编辑器一致")
	var preview: Dictionary = d.preview_clues()["values"]
	var mismatch := 0
	var example := ""
	for p in preview:
		var cell: Cell = board.grid.get_cell(p)
		if cell == null or cell.value != preview[p]:
			mismatch += 1
			if example == "":
				example = "格 %s：加载器 %s vs 编辑器 %s" % [
					str(p), str(cell.value if cell != null else "null"), str(preview[p])]
	assert_eq(mismatch, 0, "试玩路径上的线索值必须与编辑器预览一致（%s）" % example)
	DirAccess.remove_absolute(path)


func test_wrap_board_can_be_generated_by_the_pipeline() -> void:
	# 端到端：编辑器画一个环绕盘（自定义邻域）⇒ 生成管线能真的产出关卡
	var d := _doc(5, 5, [Vector2i(0, 0), Vector2i(1, 2), Vector2i(3, 3), Vector2i(4, 4), Vector2i(2, 0)])
	d.wrap = true
	var rep := d.validate()
	assert_true(bool(rep["ok"]), "环绕盘文档应通过校验：%s" % str(rep["errors"]))
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(d.topology())
	assert_eq(ag.cell_count(), 25, "环绕盘仍是 25 格（折返不改变格数）")
	var gen := PuzzleGenerator.new()
	var level: Dictionary = gen.generate_with_rules("classic", [], Vector2i(5, 5), 5, 1, 0, 15, ag, 30_000)
	assert_false(level.is_empty(),
		"环绕盘应能生成关卡（编辑器画完就能玩）；last_call_stats=%s" % str(gen.last_call_stats))
	assert_true(level.has("mines"), "产物应含雷位")
