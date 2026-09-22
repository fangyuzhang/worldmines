# test_shape_library.gd —— 异形关卡「入库 + 选关页可见」门禁（接线任务）
#
# 这个测试存在的意义：形状关（res://levels/ 里带 topology.style 的关卡）**曾产出但玩家找不到**——
# 选关页只认关卡库（levels_lib/），而 res://levels/ 没有 UI 入口。三件事缺一不可，
# 缺任何一件「玩家找不到形状关」就会复发：
#   ① 库索引/集文件：形状 mode 在 catalog 里有键，且**实际落盘的每个 (mode,size,tier)**
#      关数与期望表一致（期望表 = 生成产物经导入工具双重过滤——源前缀白名单 + 库尺寸窗 5~9——后的结果）；
#   ② 内容可用：库内每一关都能 LevelLoader.load_level → Board，且 board.grid 是 AdjacencyGrid
#      （形状语义不在入库路上丢），集内按难度升序（选关页按序推进的前提）；
#   ③ 选关页可见：VariantCatalog.build_modes 里有库内形状 mode 的卡片（字段口径正确）——
#      「选关页真有这张卡」的唯一断言点；catalog 无键的 mode **不应**出卡（守卫生效）。
#
# 被测产物 = tools/gen_shape_levels.gd + tools/gen_geo_levels.gd（产关）
#          + tools/import_shape_levels_to_lib.gd（入库）。
# 产物缺失 → 红（不是 pending）：本任务的目标就是让它出现，缺了就是链路断了。
extends GutTest

const SIZES: Array = [5, 6, 7, 8, 9]
## 全尺寸契约组：参数化方阵族（gen_shape_levels 全 5 尺寸量产，尺寸窗全绿）。
## 与 CONTENT_MODES 保持同序——SHAPE_MODES = 前者 + 后者（7 席，勿增删中间项）。
const FULL_SIZE_MODES: Array = [["shape_holed", "挖洞方格"], ["shape_hex", "蜂窝"]]
## 内容依赖组（2026-09-22 新几何族）：只对实际落盘且落在尺寸窗 5~9 的 (mode,size) 断言；
## 尺寸窗外的关（t31212 的 37/51 宽 bbox、ring 12/18、trihex_02 的 11、iso_02~05 的 12~15）
## 留在手工异形页（ui/level_select 第四页），不进库——扩窗后重跑导入即可收录。
const CONTENT_MODES: Array = [
	["shape_iso", "等轴菱面"], ["shape_tri", "三角网格"], ["shape_trihex", "编织"],
	["shape_t31212", "十二边"], ["shape_ring", "环盘"],
]
## 形状档名单（id / 卡片名）：与 ui/variant_catalog.gd 的 shape 卡片、导入工具的 STYLE_TO_MODE 同源。
const SHAPE_MODES: Array = [
	["shape_holed", "挖洞方格"], ["shape_hex", "蜂窝"],
	["shape_iso", "等轴菱面"], ["shape_tri", "三角网格"], ["shape_trihex", "编织"],
	["shape_t31212", "十二边"], ["shape_ring", "环盘"],
]
## mode → 关卡 style（形状语义的落盘标记，入库后必须原样保留）。
const STYLE_OF := {
	"shape_holed": "holed_grid", "shape_hex": "hex", "shape_iso": "iso_cubes",
	"shape_tri": "tri_grid", "shape_trihex": "trihex",
	"shape_t31212": "t31212", "shape_ring": "ring",
}
## 各 (mode → tier → {size: 关数}) 的期望表（v4.1 峰值分档口径）：
## · shape_holed：8×8 两关（holed_01/02）；9×9 四关（holed_03 + 3 个 T7 mask 图案关）；
## · shape_iso：等轴 01 peak=5 → normal（v4.1 窗口 [4,5]）；其余等轴关尺寸越界（3~4 行）不入库；
## · shape_tri：三角 01 peak=2 → easy（4 行 bbox 越界，side=8 恰在窗内）；
## · shape_trihex：编织 01 peak=3 → easy（9×9 恰在窗内；编织 02 是 11×11 越界）；
## · shape_t31212 / shape_ring：全部越界（37/51、12/18 宽）→ catalog 无键、卡片自动隐藏。
const EXPECTED_COUNTS := {
	"shape_holed": {"easy": {5: 1, 6: 1, 7: 1, 8: 2, 9: 4}},
	"shape_hex": {"easy": {5: 1, 6: 1, 7: 1, 8: 1, 9: 1}},
	"shape_iso": {"normal": {9: 1}},
	"shape_tri": {"easy": {8: 1}},
	"shape_trihex": {"easy": {9: 1}},
}


# ==================== ① 库索引：catalog 有键 + 期望表逐席核对 ====================

func test_catalog_has_shape_modes() -> void:
	var cat := LevelLibrary.catalog()
	for entry in SHAPE_MODES:
		var mode := str(entry[0])
		if mode in ["shape_t31212", "shape_ring"]:
			# 尺寸窗内暂无纯 classic 关 → catalog 不该有键（有键反而说明过滤失守）。
			assert_false(cat.has(mode),
				"%s 当前不应有 catalog 键（全部源关尺寸越界 5~9；扩窗重导后本断言随期望表一起改）" % mode)
			continue
		assert_true(cat.has(mode), "catalog 应含 %s（先跑 tools/import_shape_levels_to_lib.gd）" % mode)


func test_full_size_modes_have_content_on_all_sizes() -> void:
	# 参数化方阵族的强契约：缺某尺寸 → 选关页该尺寸回退「按种子生成矩形关」→ 卡名不副实。
	var cat := LevelLibrary.catalog()
	for entry in FULL_SIZE_MODES:
		var mode := str(entry[0])
		assert_true(cat.has(mode), "catalog 应含 %s（先跑 tools/import_shape_levels_to_lib.gd）" % mode)
		for size in SIZES:
			assert_gt(LevelLibrary.count(mode, int(size), "easy"), 0,
				"%s 在 %d×%d 必有 easy 内容——否则选关页该尺寸回退生成矩形关（卡名不副实）" % [
				mode, int(size), int(size)])


func test_counts_match_generated_levels() -> void:
	var checked := 0
	for mode in EXPECTED_COUNTS:
		var by_tier: Dictionary = EXPECTED_COUNTS[mode]
		for tier_s in by_tier:
			var tier := str(tier_s)
			for size in by_tier[tier_s]:
				var want := int(by_tier[tier_s][size])
				assert_eq(LevelLibrary.count(str(mode), int(size), tier), want,
					"count(%s, %d, %s) 应为 %d（实际产物：生成落盘 + 前缀白名单 + 尺寸窗 5~9 过滤后）" % [
					str(mode), int(size), tier, want])
				checked += 1
	var want_pairs := 0
	for mode in EXPECTED_COUNTS:
		for tier_s in EXPECTED_COUNTS[mode]:
			want_pairs += (EXPECTED_COUNTS[mode][tier_s] as Dictionary).size()
	assert_eq(checked, want_pairs, "期望表的每个 (mode,size,tier) 席位都应核对到")


func test_specific_counts_from_spec() -> void:
	# 任务口径直查（与上面的表同源，单列出来当最直白的钉子）。
	# 值来自 JSON 解析（一律 float），故取 int 再比——不写字面量 {"easy": 2}
	#（GUT 的字典比较对 float/int 严格，2.0 ≠ 2）。
	assert_eq(int(LevelLibrary.counts("shape_holed", 8).get("easy", 0)), 2, "shape_holed 8×8 应有 2 关")
	assert_eq(int(LevelLibrary.counts("shape_hex", 9).get("easy", 0)), 1, "shape_hex 9×9 应有 1 关")
	assert_eq(int(LevelLibrary.counts("shape_holed", 9).get("easy", 0)), 4,
			"shape_holed 9×9 应有 4 关（holed_03 + 3 个 mask 图案关）")
	assert_eq(int(LevelLibrary.counts("shape_iso", 9).get("normal", 0)), 1,
			"shape_iso 9×9 应有 1 关（normal 档：等轴 01 peak=5）")
	assert_eq(int(LevelLibrary.counts("shape_tri", 8).get("easy", 0)), 1, "shape_tri 8 宽应有 1 关")
	assert_eq(int(LevelLibrary.counts("shape_trihex", 9).get("easy", 0)), 1, "shape_trihex 9×9 应有 1 关")


func test_shape_holed_9_contains_art_levels() -> void:
	# 三关 mask 图案关真的进库了（不是只改了 catalog 计数）：按名字逐个点名。
	var names: Array = []
	for lv in LevelLibrary.levels("shape_holed", 9, "easy"):
		names.append(str((lv as Dictionary).get("name", "")))
	for want in ["图案 01 · 同心靶", "图案 02 · 分形地毯", "图案 03 · 小水母"]:
		assert_true(names.has(want),
			"shape_holed 9×9 应含 mask 图案关「%s」（实际：%s）" % [want, ", ".join(names)])


# ==================== ② 内容可用：加载成异形棋盘 + 集内升序 ====================

func test_library_levels_load_as_shape_boards() -> void:
	var checked := 0
	for mode in EXPECTED_COUNTS:
		var by_tier: Dictionary = EXPECTED_COUNTS[mode]
		for tier_s in by_tier:
			var tier := str(tier_s)
			for size in by_tier[tier_s]:
				var side := int(size)
				var n := LevelLibrary.count(str(mode), side, tier)
				for idx in n:
					var lv := LevelLibrary.get_level(str(mode), side, tier, idx)
					assert_false(lv.is_empty(), "%s %d×%d %s 第 %d 关应可读取" % [mode, side, side, tier, idx])
					if lv.is_empty():
						continue
					# 形状语义：集内关卡应带 topology.style（入库不剥字段）
					var topo: Dictionary = lv.get("topology", {})
					assert_eq(str(topo.get("style", "")), str(STYLE_OF.get(str(mode), "")),
						"%s %d×%d %s 第 %d 关的 topology.style 应保持形状语义" % [mode, side, side, tier, idx])
					# 与选关页同一条加载链：materialize → LevelLoader.load_level → Board
					var path := LevelLibrary.materialize(str(mode), side, tier, idx)
					assert_ne(path, "", "%s %d×%d %s 第 %d 关应可物化" % [mode, side, side, tier, idx])
					var board: Board = LevelLoader.load_level(path)
					assert_not_null(board, "%s %d×%d %s 第 %d 关（%s）应能载入成 Board" % [mode, side, side, tier, idx, path])
					if board == null:
						continue
					assert_true(board.grid is AdjacencyGrid,
						"%s %d×%d %s 第 %d 关应是异形棋盘（AdjacencyGrid），不是矩形盘" % [mode, side, side, tier, idx])
					assert_eq(board.total_mines, int(lv.get("total_mines", -1)),
						"%s %d×%d %s 第 %d 关雷数应与集内关卡一致" % [mode, side, side, tier, idx])
					checked += 1
	assert_gt(checked, 0, "期望表里的形状集应有内容可查（空库 = 卡片点进去没内容）")


func test_library_levels_sorted_by_difficulty_ascending() -> void:
	for mode in EXPECTED_COUNTS:
		var by_tier: Dictionary = EXPECTED_COUNTS[mode]
		for tier_s in by_tier:
			var tier := str(tier_s)
			for size in by_tier[tier_s]:
				var side := int(size)
				var arr := LevelLibrary.levels(str(mode), side, tier)
				var prev := -INF
				for i in arr.size():
					var d := LevelLibrary.level_difficulty(str(mode), side, tier, i)
					assert_gte(d, prev, "%s %d×%d %s 集内应按难度升序（第 %d 关 %.3f < 上一关 %.3f）" % [
						mode, side, side, tier, i, d, prev])
					prev = d


# ==================== ③ 选关页可见：变体表里有形状卡 ====================

func test_build_modes_has_shape_cards() -> void:
	var modes := VariantCatalog.build_modes(Vector2i(8, 8), LevelSequence.mine_count(8))
	var by_id := {}
	for m in modes:
		by_id[str((m as Dictionary)["id"])] = m as Dictionary
	for entry in SHAPE_MODES:
		var mode := str(entry[0])
		var in_lib := LevelLibrary.catalog().has(mode)
		assert_eq(by_id.has(mode), in_lib,
			"%s 卡片可见性必须 == catalog 有键（守卫：库空不出卡）" % mode)
		if not in_lib:
			continue
		var d: Dictionary = by_id[mode]
		assert_eq(str(d.get("name", "")), str(entry[1]), "%s 卡片名" % mode)
		assert_eq(str(d.get("kind", "")), "shape", "%s 应是形状档（拓扑层，不是规则/守恒轴）" % mode)
		assert_eq(str(d.get("clue", "")), "classic", "%s 线索走经典（形状不叠加规则轴）" % mode)
		assert_eq((d.get("globals", []) as Array).size(), 0, "%s 不应带全局约束" % mode)
		assert_true(bool(d.get("enabled", false)), "%s 卡片应可选" % mode)
		assert_eq(str(d.get("source", "")), "builtin", "%s 来源应为内置" % mode)
