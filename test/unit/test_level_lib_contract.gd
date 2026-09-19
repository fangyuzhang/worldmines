extends GutTest
## 关卡库端到端契约测试（2026-09-19）。
##
## 与 `test_level_library.gd` 的分工：那个测 **API 行为**（缓存 / 优雅降级），
## 本文件测 **内容契约** —— 跑在真实库数据上，服务器量产批次导入后最该先跑它。
##
## 四条检查都是「静默失败」型：不报错，但玩家点不到 / 玩错 / 难度不符：
##   1. 库内 mode 必须能在选关页找到 —— `VariantCatalog.build_modes` 会**过滤 FORBID 组合**
##      （逻辑冗余 R4 / 整除无解 R5），而量产只做**数学可行性**预筛，两者判据不同，
##      可能产出「选关页不显示」的孤儿席位（关卡进库了也永远点不到，与 c_/g_ 前缀同类病）；
##   2. 关卡内 `clue_rule` / `global_rules` 必须与 mode 语义一致 —— mode 只是索引键，
##      玩法由关卡内字段决定，不一致 = 玩家选中 A 玩到 B；
##   3. 关卡 `difficulty` 必须落在其所在 tier 区间内 —— 档是导入时按**文件名**定的，
##      内容从未被校验（服务器量产若命名错档，这里会立刻红）；
##   4. `catalog.json` 记录的关数必须与集文件实际一致。
const LIB := "res://levels_lib"
const TIER_ORDER: Array = ["intro", "easy", "normal", "hard"]

# static：GUT 每个测试方法新建实例，成员变量不跨测试，故用静态缓存避免重复读盘/构建
static var _sets_cache: Array = []
static var _modes_cache: Dictionary = {}
static var _doc_cache: Dictionary = {}


func _read_json(path: String) -> Dictionary:
	if _doc_cache.has(path):
		return _doc_cache[path]
	var out: Dictionary = {}
	if FileAccess.file_exists(path):
		var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if v is Dictionary:
			out = v
	_doc_cache[path] = out
	return out


## 库内全部集：[{mode, side, tier, path}]（不含 catalog.json）
func _lib_sets() -> Array:
	if not _sets_cache.is_empty():
		return _sets_cache
	var out: Array = []
	var d := DirAccess.open(LIB)
	if d == null:
		return out
	for mode in d.get_directories():
		var sd := DirAccess.open("%s/%s" % [LIB, mode])
		if sd == null:
			continue
		for size_dir in sd.get_directories():
			var side := int(str(size_dir))
			if side <= 0:
				continue
			var td := DirAccess.open("%s/%s/%s" % [LIB, mode, size_dir])
			if td == null:
				continue
			for f in td.get_files():
				var tier := str(f).get_basename()
				if not TIER_ORDER.has(tier):
					continue
				out.append({"mode": str(mode), "side": side, "tier": tier,
					"path": "%s/%s/%s/%s" % [LIB, mode, size_dir, f]})
	_sets_cache = out
	return out


## 该尺寸下选关页认识的 mode 表：id → {clue, globals}
func _modes_for(side: int) -> Dictionary:
	if _modes_cache.has(side):
		return _modes_cache[side]
	var out := {}
	var mines: int = RuleFeasibility.standard_mines(side)
	for m in VariantCatalog.build_modes(Vector2i(side, side), mines):
		out[str(m["id"])] = {"clue": str(m["clue"]), "globals": m.get("globals", [])}
	_modes_cache[side] = out
	return out


func test_lib_has_content_and_sets_are_readable() -> void:
	var sets := _lib_sets()
	assert_true(sets.size() > 0, "库应当非空")
	for s in sets:
		var doc := _read_json(str((s as Dictionary)["path"]))
		assert_false(doc.is_empty(), "%s 读不出内容" % (s as Dictionary)["path"])
		assert_true((doc.get("levels", []) as Array).size() > 0,
			"%s 是空集（导入时 --min 未拦住）" % (s as Dictionary)["path"])


func test_every_lib_mode_is_reachable_in_level_select() -> void:
	## 孤儿席位守卫：库内 mode 若不在选关页 MODES 里，玩家永远点不到它
	var orphan: Array = []
	for s in _lib_sets():
		var row: Dictionary = s
		if not _modes_for(int(row["side"])).has(str(row["mode"])):
			orphan.append("%s/%d" % [row["mode"], row["side"]])
	assert_eq(orphan, [], "库内这些 mode×尺寸 不在选关页里（孤儿席位，进库也点不到）")


func test_lib_levels_match_their_mode_and_tier() -> void:
	for s in _lib_sets():
		var row: Dictionary = s
		var modes := _modes_for(int(row["side"]))
		if not modes.has(str(row["mode"])):
			continue    # 孤儿席位由上一个测试负责报错
		var exp: Dictionary = modes[str(row["mode"])]
		var exp_g: Array = (exp["globals"] as Array).duplicate()
		exp_g.sort()
		var t: Dictionary = Difficulty.TIERS[str(row["tier"])]
		var lo := float(t["min"])
		var hi := float(t["max"])
		# **抽样**：逐关断言在满额库（164 组合 × 5 尺寸 × 4 档 = 3280 集）上会把全量测试拖垮
		# （库每大一轮、断言数就线性膨胀），而这几条检查的失败模式是「整集系统性错」——
		# 每集抽首/中/末三关即可暴露（集按难度升序，两端 + 中段覆盖最广）。
		var levels: Array = _read_json(str(row["path"])).get("levels", [])
		if levels.is_empty():
			continue
		var picks: Array = [0, levels.size() / 2, levels.size() - 1]
		for pi in picks:
			var lvv: Dictionary = levels[int(pi)]
			var got_g: Array = (lvv.get("global_rules", []) as Array).duplicate()
			got_g.sort()
			assert_eq(str(lvv.get("clue_rule", "")), str(exp["clue"]),
				"%s[%d] 的 clue_rule 与 mode 不符（选中 A 会玩到 B）" % [row["path"], int(pi)])
			assert_eq(got_g, exp_g, "%s[%d] 的 global_rules 与 mode 不符" % [row["path"], int(pi)])
			var d := float(lvv.get("difficulty", -1.0))
			assert_true(d >= lo and d < hi,
				"%s[%d] 的 difficulty=%.3f 不在 %s 区间 [%.2f, %.2f)" % [
					row["path"], int(pi), d, row["tier"], lo, hi])


func test_lib_levels_can_be_loaded_by_board() -> void:
	## 「能玩」的自动化证明（不依赖真机）：库里的关卡喂给 Board.load_level 必须成功建盘。
	## 每集抽首关——集内关卡同源同格式，抽一关即可暴露「字段缺失/格式漂移/规则不识别」，
	## 全量加载留给真机抽查（真机是最终的观感验收）。
	var checked := 0
	for s in _lib_sets():
		var row: Dictionary = s
		var levels: Array = _read_json(str(row["path"])).get("levels", [])
		if levels.is_empty():
			continue
		var lv: Dictionary = levels[0]
		var b := Board.new()
		b.load_level(lv)
		assert_eq(b.total_mines, int(lv.get("total_mines", -1)),
			"%s 首关加载后 total_mines 与声明不符（加载链有问题）" % row["path"])
		checked += 1
	assert_true(checked > 0, "应至少检查到一集")


func test_lib_total_size_is_reported() -> void:
	## 包体容量守卫（数据可见化）：库随包发行（res://），体量增长必须有人看见。
	## 这里只报告不设硬阈值（阈值是产品决策）；若将来要封顶，把断言改成 assert_true(total < LIMIT)。
	var total := 0
	var sets := 0
	for s in _lib_sets():
		var row: Dictionary = s
		if FileAccess.file_exists(str(row["path"])):
			total += FileAccess.get_file_as_bytes(str(row["path"])).size()
			sets += 1
	var mb := float(total) / 1048576.0
	gut.p("库体量: %d 个集 / %.2f MB（约 %.0f 字节/集）" % [sets, mb, float(total) / maxf(1.0, float(sets))])
	assert_true(total > 0, "库应非空")


func test_lib_sampled_levels_are_sequentially_solvable() -> void:
	## 库的**质量底线**：玩家点进去的盘必须能靠推理走完，不能是「必猜」盘。
	## 抽样极少量（每档只取一集的首关）——ProofLog.build 是 CP-SAT 演绎，单盘数百 ms 级，
	## 全量跑会拖垮测试；而这四条断言守的是「整批生成时门禁失效」这类系统性事故。
	## 注：它同时受墙钟超时影响（超时也返回 solved=false），故只抽样、不追求覆盖。
	var checked := 0
	var mined := {}
	for s in _lib_sets():
		var row: Dictionary = s
		var key := str(row["tier"])
		if mined.has(key):
			continue
		mined[key] = true
		var levels: Array = _read_json(str(row["path"])).get("levels", [])
		if levels.is_empty():
			continue
		var lv: Dictionary = levels[0]
		var log: Dictionary = ProofLog.build(lv)
		assert_true(bool(log.get("solved", false)),
			"%s 首关序贯不可解（reason=%s）——库里不该有必猜的盘" % [row["path"], str(log.get("reason", ""))])
		checked += 1
	assert_true(checked > 0, "应至少抽到一关")


func test_lib_catalog_counts_match_sets() -> void:
	var cat: Dictionary = _read_json(LIB + "/catalog.json").get("catalog", {})
	assert_false(cat.is_empty(), "catalog.json 应有 catalog 字段")
	var actual := {}
	for s in _lib_sets():
		var row: Dictionary = s
		actual["%s/%d/%s" % [row["mode"], row["side"], row["tier"]]] = \
			(_read_json(str(row["path"])).get("levels", []) as Array).size()
	for mode in cat:
		for side in cat[mode]:
			for tier in cat[mode][side]:
				var key := "%s/%s/%s" % [mode, side, tier]
				assert_eq(int(cat[mode][side][tier]), int(actual.get(key, -1)),
					"catalog 记录的 %s 关数与集文件不一致" % key)
