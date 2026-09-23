# test_shape_runtime.gd —— 形状关卡运行时回归门禁（2026-09-21 审计修复的钉子）
#
# 三条修复各自的回归点：
#   RH1 core/hint_solver.gd —— 提示的 Def 路径原按「包围盒双重循环 + get_cell().state」，
#       形状盘的洞格 get_cell() 返回 null ⇒ `null.state` 崩（形状关提示完全不可用）。
#   RM1 core/board.gd:455-475 —— 0 值扩散原优先走规则分支（ring_dirs 8 邻偏移），
#       蜂窝盘 HEX6 不含对角 (±1,±1) ⇒ 会"免费翻开"非拓扑邻域的格。
#   RH2 ui/level_library.gd:136-155 —— materialize 命中缓存只比 mtime、不验内容 ⇒
#       半份 JSON 永久命中，该关永久不可玩（只有手删 user://lib_play 才自愈）。
extends GutTest

const HEX5 := "res://levels/hex_01.json"          # 蜂窝 size=5（19 格）
const ART_TARGET := "res://levels/art_target.json"  # 图案关 21×21（152 格，洞 289 格；2026-09-23 升级）


func _load(path: String) -> Board:
	if not FileAccess.file_exists(path):
		pending("缺少 %s —— 先跑 tools/gen_shape_levels.gd" % path)
		return null
	var b: Board = LevelLoader.load_level(path)
	assert_not_null(b, "%s 应可载入" % path)
	return b


# ==================== RH1：形状盘提示不崩 ====================

func test_rh1_hint_def_on_hex_board_does_not_crash() -> void:
	# 直接打 bug 位置：hint_def 的线索收集循环（原包围盒循环遇洞格 null 崩）
	var b := _load(HEX5)
	if b == null:
		return
	assert_true(b.grid is AdjacencyGrid, "应为异形盘")
	var steps := HintSolver.new().hint_def(b, "classic")
	assert_true(steps is Array, "hint_def 应返回数组（不得崩溃）")


func test_rh1_hint_def_on_holed_grid_does_not_crash() -> void:
	# 图案盘同样有洞格（21×21 去掉 152 格 = 289 个盘外格）——原实现必崩
	var b := _load(ART_TARGET)
	if b == null:
		return
	assert_true(b.grid is AdjacencyGrid, "应为异形盘")
	# 洞格确实存在（get_cell 返回 null）：这是触发条件
	var found_null := false
	var size := b.grid.size()
	for r in size.y:
		for c in size.x:
			if b.grid.get_cell(Vector2i(c, r)) == null:
				found_null = true
				break
	assert_true(found_null, "本关应含洞格（否则本用例失去意义）")
	var steps := HintSolver.new().hint_def(b, "classic")
	assert_true(steps is Array, "hint_def 应返回数组（不得崩溃）")


func test_rh1_hint_entry_does_not_crash() -> void:
	# 统一入口（hint_rule → 兜底 hint_def）在形状盘上必须安全返回
	var b := _load(HEX5)
	if b == null:
		return
	var steps := HintSolver.new().hint(b)
	assert_true(steps is Array, "hint 应返回数组")


# ==================== RM1：0 值扩散必须走拓扑邻域 ====================

func test_rm1_zero_flood_uses_topology_neighbors() -> void:
	# 构造：蜂窝 size=5 盘，雷全放最外圈 ⇒ 盘心 (2,2) 的拓扑邻域（6 格）无雷 ⇒ 其线索值为 0。
	var topo := ShapeGenerator.to_adjacency_grid("hex", {"size": 5})
	assert_not_null(topo, "hex(5) 拓扑应可构建")
	var board := Board.new()
	board.grid = topo
	board.clue_variant = ClueEngine.Variant.CLASSIC
	board.rule_clue_id = "classic"
	var center := Vector2i(2, 2)
	var nbs := topo.get_neighbors(center)
	assert_eq(nbs.size(), 6, "盘心应 6 邻")
	# 雷放 (2,4)：蜂窝盘的盘内格（r+c=6 满足裁剪 |r+c−4| ≤ 2）且不在盘心 6 邻域里。
	# 注：(0,0)/(4,4) 是蜂窝盘切掉的**两个对角三角区**、根本不在盘内 —— 当雷位会让
	# topo.get_cell() 返回 null（本用例初版就踩了这个）。
	var mine := Vector2i(2, 4)
	assert_true(topo.in_board(mine), "雷位必须在盘内")
	assert_false(nbs.has(mine), "雷位不应落在盘心邻域（否则盘心非 0 值）")
	board.total_mines = 1
	board._static_mines = [mine]
	topo.get_cell(mine).is_mine = true
	board._compute_clues()
	assert_eq(int(topo.get_cell(center).value), 0, "盘心线索值应为 0（拓扑邻域无雷）")
	# 核心断言：0 值扩散的邻格集合 ⊆ 拓扑邻域
	var flood := board._flood_neighbors(center)
	assert_eq(flood.size(), 6, "应返回盘心的 6 个拓扑邻格（原实现会掺入 8 邻偏移里的非邻格）")
	for p in flood:
		assert_true(nbs.has(p), "扩散目标 %s 必须在拓扑邻域内（RM1 回归）" % str(p))


func test_rm1_zero_flood_excludes_diagonal_on_hex() -> void:
	# 反向证据：HEX6 不含 (1,1)/(-1,-1) 方向 —— 该方向上的格必须**不在**扩散集合里。
	# 盘心 (2,2) 的对角 (3,3)：hex(5) 盘内存在（|3+3-4|=2 ≤ 2），但非拓扑邻格。
	var topo := ShapeGenerator.to_adjacency_grid("hex", {"size": 5})
	if topo == null:
		pending("hex(5) 拓扑不可用")
		return
	assert_true(topo.in_board(Vector2i(3, 3)), "(3,3) 应在蜂窝盘内（本用例前提）")
	assert_false(topo.get_neighbors(Vector2i(2, 2)).has(Vector2i(3, 3)),
			"(3,3) 不是 (2,2) 的拓扑邻格（HEX6 无对角方向）")
	var board := Board.new()
	board.grid = topo
	board.clue_variant = ClueEngine.Variant.CLASSIC
	board.rule_clue_id = "classic"
	board.total_mines = 1
	var mine := Vector2i(2, 4)   # 盘内、且不在盘心邻域（同前例说明）
	board._static_mines = [mine]
	topo.get_cell(mine).is_mine = true
	board._compute_clues()
	var flood := board._flood_neighbors(Vector2i(2, 2))
	assert_false(flood.has(Vector2i(3, 3)),
			"对角线格 (3,3) 不得被 0 值扩散翻开（RM1：原实现按 8 邻偏移会掺入）")


# ==================== RH2：物化文件损坏可自愈 ====================

func test_rh2_materialize_heals_corrupted_file() -> void:
	# 前提：shape_holed / 9 / easy 至少有 1 关
	var path := LevelLibrary.materialize("shape_holed", 9, "easy", 0)
	if path == "":
		pending("库内无 shape_holed/9/easy —— 先跑 tools/import_shape_levels_to_lib.gd")
		return
	assert_true(FileAccess.file_exists(path), "物化文件应存在：%s" % path)
	# 破坏它（模拟首次物化时崩溃/断电/磁盘满留下的半份 JSON）
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_not_null(f, "应能写入物化文件")
	f.store_string("{ \"levels\": [ {broken")
	f.close()
	# 注：这里**不要**主动解析坏内容做"解析失败"断言 —— JSON.parse_string 对坏输入会触发
	# Godot 内部 error（Condition "error != Error::OK"），被 GUT 记成 Unexpected Errors 而假红。
	# 「写坏」这个动作本身已足以构成前提。
	# 再次 materialize：必须**重写**出可用文件（原实现因 mtime 判定会返回坏文件）
	var path2 := LevelLibrary.materialize("shape_holed", 9, "easy", 0)
	assert_eq(path2, path, "物化路径应稳定")
	var healed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path2))
	assert_true(healed is Dictionary, "损坏的物化文件应被自愈重写")
	if healed is Dictionary:
		var d: Dictionary = healed
		assert_true(d.has("total_mines") and d.has("mines") and d.has("size"),
				"重写后的关卡应含关键字段")
		assert_true(d.has("topology"), "形状关的物化文件必须保留 topology（否则会被矩形化）")
		# 真实可载入（端到端）
		var b: Board = LevelLoader.load_level(path2)
		assert_not_null(b, "自愈后的物化文件应能被 LevelLoader 载入")
		if b != null:
			assert_true(b.grid is AdjacencyGrid, "载入后应重建异形盘")


# ==================== RM2 / RM4：选关页的形状档行为 ====================

func _mk_view() -> Node:
	var view: Node = load("res://ui/level_select.tscn").instantiate()
	add_child_autofree(view)
	return view


func test_rm2_shape_size_availability_tracks_library() -> void:
	# 形状档的尺寸可选性 = 库内该尺寸是否有内容（无内容 → 不可选，绝不回退生成矩形关）。
	var view := _mk_view()
	await get_tree().process_frame   # 等 _ready（_refresh_modes 构建 _mode_index）
	var shape := {"id": "shape_holed", "kind": "shape", "clue": "classic", "globals": []}
	for s: int in [5, 6, 7, 8, 9]:
		assert_eq(view._size_available(shape, s), LevelLibrary.has_any("shape_holed", s),
				"形状档 %d×%d 的可选性应跟随库内容" % [s, s])
	# 库内不存在的形状 id：所有尺寸都必须不可选
	# （RM2：原实现因 clue=classic 数学可行而放行 → 点开始会生成矩形经典关，卡名不副实）
	var fake := {"id": "__no_such_shape__", "kind": "shape", "clue": "classic", "globals": []}
	for s: int in [5, 6, 7, 8, 9]:
		assert_false(view._size_available(fake, s),
				"库内无内容的形状档在 %d×%d 必须不可选（RM2）" % [s, s])


func test_rm4_shape_card_does_not_write_mock_progress() -> void:
	# 形状卡（库 mode）不得写入 gen:// 演示进度键（否则卡片显示"已通关 N"虚高）。
	var view := _mk_view()
	await get_tree().process_frame
	var mi := int(view._mode_index.get("shape_holed", -1))
	if mi < 0:
		pending("变体表无 shape_holed（库为空？先跑 tools/import_shape_levels_to_lib.gd）")
		return
	view._mode_idx = mi
	view._ensure_mock()
	# 前提校验（防"因为整个 mock 机制坏了而假绿"）：该 mode 确实有库内容（跳过分支的前提成立）
	assert_true(view._mode_has_lib("shape_holed"), "shape_holed 应有库内容（跳过 mock 的前提）")
	var gen_keys := 0
	for k in view._mock_cleared.keys():
		if str(k).begins_with("gen://shape_"):
			gen_keys += 1
	# 显式计数断言（不用"for 里 assert"——空集合时不产生断言会被 GUT 判 Risky）
	assert_eq(gen_keys, 0, "形状卡不得写入演示进度键（RM4）")


# ==================== 进度键解析契约（L3 审计项，2026-09-21 补测） ====================

func test_parse_path_shapes() -> void:
	# 生成关形态（含下划线的 mode 名）→ 不得被误判为库关卡
	var gen := LevelSequence.parse_path("user://gen_levels/shape_holed_9_0.json")
	assert_eq(str(gen.get("mode", "")), "shape_holed", "mode 名里的下划线不受影响")
	assert_eq(int(gen.get("size", -1)), 9, "size 解析")
	assert_eq(int(gen.get("idx", -1)), 0, "idx 解析")
	assert_eq(bool(gen.get("lib", true)), false, "生成关不得判为库（lib=false）")
	# 库形态（materialize 的产物路径）→ lib=true 且 tier 正确
	var lib := LevelSequence.parse_path("user://lib_play/shape_holed_9_easy_0.json")
	assert_eq(str(lib.get("mode", "")), "shape_holed", "库 mode 解析")
	assert_eq(str(lib.get("tier", "")), "easy", "tier 解析")
	assert_eq(bool(lib.get("lib", false)), true, "库关卡应判为 lib")
	# 两种进度键必须落在不同桶（分桶正确性的最小断言）
	assert_ne(LevelSequence.lib_key("shape_holed", 9, "easy", 0),
			"gen://shape_holed/9/0", "库键与生成键不得相同")


# ==================== 存档重载链（形状关） ====================

func test_shape_save_reload_chain() -> void:
	# 形状关的存档口径：拓扑**不入档**，恢复靠 metadata.level_path 重载关卡文件
	# （ui/save_coordinator.gd 的字段集里没有 topology）。这里钉住该口径的两个前提：
	#   ① 同一路径重载 → 雷位/格数完全一致（旧存档的 mine_positions 校验才有意义）；
	#   ② style 随 topology 保留（重载后不得退化成矩形渲染）。
	var path := LevelLibrary.materialize("shape_hex", 7, "easy", 0)
	if path == "":
		pending("库内无 shape_hex/7/easy —— 先跑 tools/import_shape_levels_to_lib.gd")
		return
	assert_true(FileAccess.file_exists(path), "物化文件应存在")
	var b1: Board = LevelLoader.load_level(path)
	assert_not_null(b1, "形状关应可载入")
	if b1 == null:
		return
	var mines1 := b1.get_mine_positions()
	assert_true(b1.grid is AdjacencyGrid, "首次载入应是异形盘")
	var style1 := (b1.grid as AdjacencyGrid).style
	# 模拟"重启后按存档里的 level_path 重载"
	var b2: Board = LevelLoader.load_level(path)
	assert_not_null(b2, "按同一路径重载应成功")
	if b2 == null:
		return
	assert_eq(b2.get_mine_positions().size(), mines1.size(), "重载后雷数应一致（存档校验的前提）")
	var same := true
	for m in mines1:
		if not b2.is_mine(m):
			same = false
	assert_true(same, "重载后雷位应逐一一致")
	assert_true(b2.grid is AdjacencyGrid, "重载后仍是异形盘（拓扑不入档、靠路径重载）")
	assert_eq((b2.grid as AdjacencyGrid).style, style1, "style 应随 topology 保留（防止渲染退化）")
