# test_fold_levels.gd —— 官方折叠关（levels/fold_*.json）的内容门禁。
#
# 守三件事（都是「落盘了但玩家玩不到 / 看不懂」的典型断法）：
#   ① 拓扑自述里必须有 view.kind=fold 与折痕声明 {axis, at} —— 否则呈现层不画折痕，
#      远侧跨半张盘的邻居在屏幕上没有任何提示，玩家只会觉得线索数错了；
#   ② 每一对「该叠上的格」必须在邻接表里**真的双向连通** —— 否则关卡自述的折痕与
#      引擎实际用的图不是同一条（正是 FoldModel / TopologyModel 存在的理由）；
#   ③ 「打开官方折叠关 → 另存」必须保住折痕 —— 本仓最恨的 bug 就是"打开再存把设计弄丢"。
# 另外每一关都必须能被 LevelLoader 真载入（"能保存，读不回"是本仓最恨的 bug 类型）。
extends GutTest

const SHAPE_KIND := "折叠"

## 每关的折痕（与 tools/gen_fold_levels.gd 的 SPECS 对齐）——落盘后必须一字不差。
const FOLD_BY_FILE := {
	"fold_01.json": {"axis": "x", "at": 3},
	"fold_02.json": {"axis": "x", "at": 3},
	"fold_03.json": {"axis": "x", "at": 4},
	"fold_04.json": {"axis": "x", "at": 3},
	"fold_05.json": {"axis": "y", "at": 3},
	"fold_06.json": {"axis": "x", "at": 4},
}

## 折纸族（多折痕）的折痕序列与最厚层数 —— 同样与 tools/gen_fold_levels.gd 的 SPECS 对齐。
## 【为什么单列一张表】单折落盘成 {axis, at}、多折落盘成 {folds: [...]}，两种格式并存是**故意的**
## （改单折的落盘格式等于凭空造全库 diff）；两种各有一张对齐表，改 SPEC 忘了同步就红灯。
const PAPER_FOLD_BY_FILE := {
	"fold_07.json": {"folds": [["x", 8], ["x", 4]], "layers": 3},
	"fold_08.json": {"folds": [["x", 3], ["y", 3]], "layers": 4},
	"fold_09.json": {"folds": [["x", 9], ["x", 6], ["x", 3]], "layers": 4},
	"fold_10.json": {"folds": [["y", 6], ["y", 3]], "layers": 4},
	"fold_11.json": {"folds": [["x", 4], ["x", 2]], "layers": 4},
	"fold_12.json": {"folds": [["x", 3], ["y", 4]], "layers": 4},
}


## 收集 levels/fold_*.json 的绝对 res:// 路径。
func _paths() -> Array[String]:
	var out: Array[String] = []
	for path in LevelLoader.list_levels():
		if path.get_file().begins_with("fold_") and path.get_file().ends_with(".json"):
			out.append(path)
	out.sort()
	return out


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var d: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return d if d is Dictionary else {}


func _positions_of(ag: AdjacencyGrid) -> Array[Vector2i]:
	var ps: Array[Vector2i] = []
	for p in ag.all_positions():
		ps.append(p)
	return ps


func test_fold_family_exists_and_is_loaded_cleanly() -> void:
	var paths := _paths()
	assert_gt(paths.size(), 0, "应有官方折叠关")
	for path in paths:
		var board: Board = LevelLoader.load_level(path)
		assert_not_null(board, "%s 应能载入" % path.get_file())
		if board == null:
			continue
		assert_true(board.grid is AdjacencyGrid, "%s 应走邻接表网格（带 topology）" % path.get_file())
		if not (board.grid is AdjacencyGrid):
			continue
		var ag := board.grid as AdjacencyGrid
		assert_eq(str(ag.view_meta.get("kind", "")), TopologyModel.VIEW_FOLD,
			"%s 的呈现类型必须是折叠" % path.get_file())
		var decl := TopologyModel.fold_decl(ag.view_meta)
		assert_false(decl.is_empty(), "%s 必须带折痕声明（否则呈现层看不到折痕）" % path.get_file())
		if decl.is_empty():
			continue
		var rep := FoldModel.audit_folds(FoldModel.fold_list(decl), _positions_of(ag))
		assert_true(bool(rep["ok"]), "%s 的折痕应是合法声明：%s" % [path.get_file(), str(rep["errors"])])
		var pairs: Array = rep["pairs"]
		assert_gt(pairs.size(), 0, "%s 至少应有一对叠格" % path.get_file())
		for pr: Dictionary in pairs:
			var a: Vector2i = pr["a"]
			var b: Vector2i = pr["b"]
			assert_true(ag.in_board(a) and ag.in_board(b),
				"%s：叠合两端 %s-%s 都必须在盘上" % [path.get_file(), str(a), str(b)])
			assert_true(ag.get_neighbors(a).has(b),
				"%s：%s -> %s 应有叠合边" % [path.get_file(), str(a), str(b)])
			assert_true(ag.get_neighbors(b).has(a),
				"%s：%s -> %s 应有叠合边" % [path.get_file(), str(b), str(a)])


func test_fold_levels_declare_shape_kind_and_read_back_crease() -> void:
	var checked := 0
	for path in _paths():
		var lv := _read_json(path)
		assert_false(lv.is_empty(), "%s 应是合法 JSON 对象" % path.get_file())
		if lv.is_empty():
			continue
		assert_eq(str(lv.get("shape_kind", "")), SHAPE_KIND,
			"%s 的 shape_kind 应为折叠（选关页卡片标签）" % path.get_file())
		var topo: Dictionary = lv.get("topology", {})
		assert_eq(TopologyModel.view_kind(topo), TopologyModel.VIEW_FOLD,
			"%s 的拓扑应判成折叠呈现" % path.get_file())
		var decl := TopologyModel.fold_decl(topo)
		assert_false(decl.is_empty(), "%s 应声明折痕" % path.get_file())
		# 折痕必须逐关对上生成器 SPECS（改了 SPEC 忘了同步这里 ⇒ 红灯）
		if FOLD_BY_FILE.has(path.get_file()):
			var want: Dictionary = FOLD_BY_FILE[path.get_file()]
			assert_eq(str(decl.get("axis", "")), str(want["axis"]),
				"%s 的折痕轴应与 SPECS 一致" % path.get_file())
			assert_eq(int(decl.get("at", -1)), int(want["at"]),
				"%s 的折痕位置应与 SPECS 一致" % path.get_file())
		# 拓扑自述本身必须过安全门（盘外/单向/重复一律不放过）
		var audit := TopologyModel.validate(topo)
		assert_true(bool(audit["ok"]),
			"%s 的拓扑应过安全门：%s" % [path.get_file(), str(audit["errors"])])
		checked += 1
	assert_gt(checked, 0, "应至少核到一关")


## 「折过头（overhang）/ 折不到（uncovered）」这两种边界必须有关卡覆盖 —— 它们不是错误，
## 但定位逻辑的边界分支若永远没人跑，就等于没人守（fold_04 折过头、fold_03 折不到）。
func test_fold_levels_cover_overhang_and_uncovered_cases() -> void:
	var seen_overhang := false
	var seen_uncovered := false
	for path in _paths():
		var board: Board = LevelLoader.load_level(path)
		if board == null or not (board.grid is AdjacencyGrid):
			continue
		var ag := board.grid as AdjacencyGrid
		var decl := TopologyModel.fold_decl(ag.view_meta)
		if decl.is_empty():
			continue
		var rep := FoldModel.audit_folds(FoldModel.fold_list(decl), _positions_of(ag))
		if (rep["overhang"] as Array).size() > 0:
			seen_overhang = true
		if (rep["uncovered"] as Array).size() > 0:
			seen_uncovered = true
	assert_true(seen_overhang, "应有关卡覆盖「折角伸出盘外」（overhang）")
	assert_true(seen_uncovered, "应有关卡覆盖「对面不够长、折不到」（uncovered）")


## 「打开官方折叠关 → 另存」必须保住折痕 —— 走编辑器的真实往返路径：
## `EditorDoc.load_from(原文)` → `to_level_json()` → 再读回。
## 单折与多折各挑一关跑（单折走 {axis, at}、多折走 {folds: [...]}，两条落盘路径都要守）。
func test_editor_round_trip_keeps_the_fold() -> void:
	var paths := _paths()
	assert_gt(paths.size(), 0, "应有官方折叠关")
	var mine := 0
	for path in paths:
		if PAPER_FOLD_BY_FILE.has(path.get_file()):
			mine = paths.find(path)
			break
	assert_gt(mine, 0, "折纸族文件应排在第 0 关之后（路径升序 ⇒ fold_07 起）")
	for idx in [0, mine]:
		_round_trip_one(paths[idx])


## 折纸族：多折痕必须真的落成**序列**（不是被悄悄当成单折丢掉了后几折），
## 最厚层数也要与规格一致 —— "能生成、读回少折一次"是本仓最恨的那类静默降级。
func test_paper_fold_levels_carry_the_whole_sequence() -> void:
	var seen := 0
	for path in _paths():
		if not PAPER_FOLD_BY_FILE.has(path.get_file()):
			continue
		var board: Board = LevelLoader.load_level(path)
		assert_not_null(board, "%s 应能载入" % path.get_file())
		if board == null or not (board.grid is AdjacencyGrid):
			continue
		var ag := board.grid as AdjacencyGrid
		var folds := FoldModel.fold_list(TopologyModel.fold_decl(ag.view_meta))
		var want: Dictionary = PAPER_FOLD_BY_FILE[path.get_file()]
		assert_gt(folds.size(), 1, "%s 应是多折（折痕条数 > 1）" % path.get_file())
		var axes: Array = []
		var ats: Array = []
		for f_v: Variant in folds:
			var f: Dictionary = f_v
			axes.append(str(f.get("axis", "")))
			ats.append(int(f.get("at", 0)))
		var want_axes: Array = []
		var want_ats: Array = []
		for w_v: Variant in (want["folds"] as Array):
			var w: Array = w_v
			want_axes.append(str(w[0]))
			want_ats.append(int(w[1]))
		assert_eq(axes, want_axes, "%s 的折痕轴序应与 SPECS 一致" % path.get_file())
		assert_eq(ats, want_ats, "%s 的折痕位置应与 SPECS 一致" % path.get_file())
		var rep := FoldModel.audit_folds(folds, _positions_of(ag))
		assert_true(bool(rep["ok"]), "%s 的折痕序列应合法：%s" % [path.get_file(), str(rep["errors"])])
		assert_eq(int(rep["layers_max"]), int(want["layers"]),
			"%s 的最厚层数应与 SPECS 一致" % path.get_file())
		for st_v: Variant in (rep["stacks"] as Array):
			var st: Dictionary = st_v
			var layers: Array = st["layers"]
			assert_gt(layers.size(), 1, "%s：列出来的摞至少两层" % path.get_file())
			for i in layers.size():
				for j in range(i + 1, layers.size()):
					var a: Vector2i = layers[i]
					var b: Vector2i = layers[j]
					assert_true(ag.get_neighbors(a).has(b) and ag.get_neighbors(b).has(a),
						"%s：同一摞里 %s-%s 必须有双向叠合边" % [path.get_file(), str(a), str(b)])
		seen += 1
	assert_eq(seen, PAPER_FOLD_BY_FILE.size(), "折纸族每一关都要核到（少一关 = 文件丢了或没被 list_levels 认出来）")


func _round_trip_one(path: String) -> void:
	var lv := _read_json(path)
	assert_false(lv.is_empty(), "%s 应是合法 JSON 对象" % path.get_file())
	if lv.is_empty():
		return
	var ed := EditorDoc.new()
	assert_true(bool(ed.load_from(lv)["ok"]), "%s 应能被编辑器打开" % path.get_file())
	assert_false(ed.fold.is_empty(), "编辑器应把折痕读进来（读不进 = 另存必丢）")
	var back := EditorDoc.new()
	assert_true(bool(back.load_from(ed.to_level_json())["ok"]), "另存出来的关卡应能再读回")
	assert_eq(back.fold, ed.fold, "折痕必须原样往返")
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(back.topology())
	var rep := FoldModel.audit_folds(FoldModel.fold_list(back.fold), _positions_of(ag))
	for pr: Dictionary in (rep["pairs"] as Array):
		assert_true(ag.get_neighbors(pr["a"]).has(pr["b"]),
			"另存后 %s -> %s 的叠合边必须还在" % [str(pr["a"]), str(pr["b"])])
		assert_true(ag.get_neighbors(pr["b"]).has(pr["a"]),
			"另存后 %s -> %s 的叠合边必须还在" % [str(pr["b"]), str(pr["a"])])
