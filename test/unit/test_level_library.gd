# test_level_library.gd —— 关卡库（量产产物 → 游戏内容）单元测试
#
# 覆盖：catalog 读取、集内计数、关卡读取、物化落盘、加载后可由引擎构造棋盘
#（Board.load_level 同路径）、以及 LevelSequence 对库方案的解析/进度键/下一关推进。
#
# 设计前提：库内容随游戏发行（levels_lib/），测试**不假设**具体关数（随量产增长），
# 只在「库非空」时验证内部一致性；库为空（未导入内容的分支）时仅验证优雅降级。
extends GutTest

## v4.1 三档名单（与 LevelLibrary.TIER_ORDER 同源；intro 已退役，catalog 不应再出现）。
const TIER_IDS := ["easy", "normal", "hard"]


func test_catalog_shape() -> void:
	var cat := LevelLibrary.catalog()
	assert_true(cat is Dictionary, "catalog 应为字典")
	if cat.is_empty():
		assert_true(LevelLibrary.is_empty(), "空库时 is_empty 应为真")
		return
	for mode in cat:
		var by_size: Dictionary = cat[mode]
		for size_s in by_size:
			assert_true(str(size_s).is_valid_int(), "尺寸键应为整数字符串")
			var by_tier: Dictionary = by_size[size_s]
			for t in by_tier:
				assert_true(TIER_IDS.has(str(t)), "档位键应为三档 id（v4.1，intro 已退役）：%s" % str(t))
				assert_gt(int(by_tier[t]), 0, "有内容的档位关数应 > 0")


func test_counts_and_levels_consistent() -> void:
	if LevelLibrary.is_empty():
		pass_test("库为空：跳过（未导入内容的环境）")
		return
	var cat := LevelLibrary.catalog()
	var checked := 0
	for mode in cat:
		for size_s in cat[mode]:
			var size := int(size_s)
			var total := 0
			for t in cat[mode][size_s]:
				var n := LevelLibrary.count(str(mode), size, str(t))
				assert_eq(n, int(cat[mode][size_s][t]), "count 应与 catalog 一致")
				assert_eq(LevelLibrary.levels(str(mode), size, str(t)).size(), n,
						"集文件关数应与 catalog 一致")
				total += n
			assert_eq(LevelLibrary.total(str(mode)), _sum_total(str(mode)), "total 应等于各尺寸合计")
			checked += 1
			if checked >= 8:
				return   # 抽查若干（尺寸×变体）即可，全库遍历留给集成脚本


func _sum_total(mode: String) -> int:
	var n := 0
	for size in LevelLibrary.SIZES:
		var c := LevelLibrary.counts(mode, int(size))
		for t in c:
			n += int(c[t])
	return n


func test_materialize_and_board_construct() -> void:
	if LevelLibrary.is_empty():
		pass_test("库为空：跳过")
		return
	# 取第一个有内容的（变体×尺寸×档），读第 1 关，物化后交给引擎构造
	var cat := LevelLibrary.catalog()
	var mode := ""
	var size := 0
	var tier := ""
	for m in cat:
		for s in cat[m]:
			for t in cat[m][s]:
				mode = str(m)
				size = int(s)
				tier = str(t)
				break
			if mode != "":
				break
		if mode != "":
			break
	assert_ne(mode, "", "应至少有一个有内容的组合")
	var lv := LevelLibrary.get_level(mode, size, tier, 0)
	assert_false(lv.is_empty(), "第 1 关应可读取")
	assert_true(lv.has("mines") and lv.has("size"), "关卡应含 mines/size")
	var path := LevelLibrary.materialize(mode, size, tier, 0)
	assert_ne(path, "", "物化应返回路径")
	assert_true(FileAccess.file_exists(path), "物化文件应存在")
	assert_eq(LevelLibrary.materialize(mode, size, tier, 0), path, "重复物化应复用同一路径")
	var board := Board.new()
	board.load_level(lv)
	assert_not_null(board.grid, "引擎应能构造棋盘")
	assert_eq(board.total_mines, int(lv.get("total_mines", -1)), "雷数应与关卡一致")


func test_sequence_lib_scheme() -> void:
	var p := LevelSequence.lib_path("o10", 7, "normal", 3)
	var parsed := LevelSequence.parse_path(p)
	assert_eq(str(parsed.get("mode", "")), "o10")
	assert_eq(int(parsed.get("size", 0)), 7)
	assert_eq(str(parsed.get("tier", "")), "normal")
	assert_eq(int(parsed.get("idx", -1)), 3)
	assert_true(bool(parsed.get("lib", false)), "应识别为库方案")
	assert_eq(LevelSequence.progress_key(p), "lib://o10/7/normal/3")
	# 含下划线的混合变体 id 也要能正确回解（mode 段允许下划线）
	var pm := LevelSequence.progress_key(LevelSequence.lib_path("pf_hv", 6, "easy", 12))
	assert_eq(pm, "lib://pf_hv/6/easy/12")
	# 生成关方案不受影响（回归）
	var pg := LevelSequence.level_path("knight", 5, 2)
	var gparsed := LevelSequence.parse_path(pg)
	assert_eq(str(gparsed.get("mode", "")), "knight")
	assert_false(bool(gparsed.get("lib", true)), "生成关不应被判为库方案")
	assert_eq(LevelSequence.progress_key(pg), "gen://knight/5/2")


func test_sequence_lib_advance() -> void:
	if LevelLibrary.is_empty():
		pass_test("库为空：跳过")
		return
	# 找一个关数 ≥ 2 的集：验证同档推进与末关越界行为
	for mode in LevelLibrary.catalog():
		for size_s in LevelLibrary.catalog()[mode]:
			for t in LevelLibrary.catalog()[mode][size_s]:
				var n := LevelLibrary.count(str(mode), int(size_s), str(t))
				if n < 2:
					continue
				var a := LevelSequence.advance(
						LevelSequence.lib_path(str(mode), int(size_s), str(t), 0))
				assert_eq(int(a.get("idx", -1)), 1, "同档应推进到下一关")
				assert_eq(str(a.get("tier", "")), str(t), "同档内不应换档")
				var last := LevelSequence.advance(
						LevelSequence.lib_path(str(mode), int(size_s), str(t), n - 1))
				# 末关之后：换档或换尺寸（库内还有内容时非空），不能停在原地
				if not last.is_empty():
					assert_true(str(last.get("tier", "")) != str(t)
							or int(last.get("size", 0)) != int(size_s),
							"末关之后应换档或换尺寸")
				return
	pass_test("未找到关数 ≥ 2 的集：跳过")


func test_level_label_format() -> void:
	if LevelLibrary.is_empty():
		pass_test("库为空：跳过")
		return
	var cat := LevelLibrary.catalog()
	for m in cat:
		for s in cat[m]:
			for t in cat[m][s]:
				var label := LevelLibrary.level_label(str(m), int(s), str(t), 0)
				# 标签第二行是「深度N」（峰值，v4.0 档位口径）——不是标量难度值。
				assert_true(label.contains("\n"), "标签应为「序号\\n深度」两行")
				return
