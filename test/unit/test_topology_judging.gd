# test_topology_judging.gd —— 棋盘几何在判据层/接口层的自证（v4.x）
#
# 目标（用户点名缺陷）：异形棋盘可用、变体可用，但组合被判据层按「矩形模型」误判为不可行。
# 本文件钉住三件事：
#   ① RuleFeasibility 的缓存键含棋盘指纹（旧键只有尺寸 ⇒ 不同棋盘串结论）；
#   ② RuleSignature 的几何依赖项（中轴整除 / 骨牌划分 / D4 对称）在异形盘上降级为 WARN，绝不 FORBID；
#   ③ 兼容铁律：不传 cells（矩形口径）时判据逐例与改动前一致；RulePlugin.geometry_kind 默认 = 仅矩形。
extends GutTest


func before_each() -> void:
	RuleFeasibility.clear_cache()


# ===== 构造工具：AdjacencyGrid（Moore 8 邻，可挖洞）=====

## rows×cols 的 Moore 8 邻方格盘；holes 里的格从盘内移除（删格删边，不重连）。
func _grid(rows: int, cols: int, holes: Array = []) -> AdjacencyGrid:
	var hole_set := {}
	for h in holes:
		hole_set[h] = true
	var positions: Array = []
	for r in rows:
		for c in cols:
			if not hole_set.has(Vector2i(c, r)):
				positions.append({"x": c, "y": r})
	var neighbors: Dictionary = {}
	for r in rows:
		for c in cols:
			if hole_set.has(Vector2i(c, r)):
				continue
			var lst: Array = []
			for dr in [-1, 0, 1]:
				for dc in [-1, 0, 1]:
					if dr == 0 and dc == 0:
						continue
					var n := Vector2i(c + dc, r + dr)
					if n.x < 0 or n.x >= cols or n.y < 0 or n.y >= rows:
						continue
					if hole_set.has(n):
						continue
					lst.append("%d,%d" % [n.x, n.y])
			neighbors["%d,%d" % [c, r]] = lst
	var g := AdjacencyGrid.new()
	g.setup_from_topo({"positions": positions, "neighbors": neighbors})
	return g


func _holed_8x8() -> AdjacencyGrid:
	return _grid(8, 8, [Vector2i(3, 3), Vector2i(4, 3), Vector2i(3, 4), Vector2i(4, 4)])


# ===== T1：board_key 稳定 + 不同棋盘必须不同 =====

func test_t1_board_key_stable_and_distinct() -> void:
	var full := _grid(8, 8)
	var holed := _holed_8x8()
	assert_eq(full.cell_count(), 64, "满格盘应有 64 格")
	assert_eq(holed.cell_count(), 60, "挖 4 洞后应有 60 格")

	# 同一拓扑两次调用一致（稳定哈希，不依赖字典遍历序）
	assert_eq(RuleFeasibility.board_key(full), RuleFeasibility.board_key(full),
			"同一拓扑两次调用必须一致")
	assert_eq(RuleFeasibility.board_key(holed), RuleFeasibility.board_key(holed),
			"同一拓扑两次调用必须一致")

	# 两个不同拓扑必须不同指纹
	assert_ne(RuleFeasibility.board_key(full), RuleFeasibility.board_key(holed),
			"8×8 满格 vs 8×8 挖 4 洞 的棋盘指纹必须不同")

	# 矩形（RectGrid）与异形（同尺寸 AdjacencyGrid）也不得混淆
	var rect := RectGrid.new()
	rect.setup(8, 8)
	assert_eq(RuleFeasibility.board_key(rect), "rect:8x8", "矩形指纹应为稳定串 rect:WxH")
	assert_ne(RuleFeasibility.board_key(rect), RuleFeasibility.board_key(full),
			"矩形盘与同尺寸异形盘不得同指纹")
	assert_eq(RuleFeasibility.board_key(null), "rect:null", "null 拓扑应有稳定占位串")


# ===== T2：缓存不串（棋盘指纹进入键）=====

# 说明：无 C# 后端 / 无全局约束时 _evaluate 乐观放行，离线无法构造「矩形可行 vs 该异形不可行」的
# 稳定差异（本任务禁自行运行 Godot）。故按任务给的兜底断言：钉住「棋盘指纹进入缓存键」。
func test_t2_cache_not_shared_across_topologies() -> void:
	var full := _grid(8, 8)
	var holed := _holed_8x8()
	RuleFeasibility.query_topo("classic", [], holed, 24)
	RuleFeasibility.query_topo("classic", [], full, 24)
	assert_eq(RuleFeasibility._cache.size(), 2,
			"两个不同拓扑必须各占一个缓存键（旧键只带尺寸会串结论）")
	var keys: Array = RuleFeasibility._cache.keys()
	assert_ne(str(keys[0]), str(keys[1]), "两个拓扑段的缓存键必须不同")

	# 同一棋盘重复查询必须命中缓存（不新增条目）
	RuleFeasibility.query_topo("classic", [], holed, 24)
	assert_eq(RuleFeasibility._cache.size(), 2, "同一棋盘重复查询应命中缓存")

	# 同尺寸矩形盘段（rect:8x8）必须与异形盘段（topo:*）分开
	RuleFeasibility.query("classic", [], 8, 24)
	assert_eq(RuleFeasibility._cache.size(), 3,
			"矩形盘段 rect:8x8 与异形盘段 topo:* 必须各占一键")


# ===== T3：_div_ok 几何化 —— 异形盘 WARN 而非 FORBID =====

func _ids(a: Array) -> Array[String]:
	## 【主代理修】`RuleSignature.compat_all` 的形参是 `Array[String]`（旧签名就如此），
	## 而 GDScript 的字面量数组 `["dt"]` 推断为**无类型 Array** ⇒ 传参会抛
	## "does not have the same element type as the expected typed array argument"。
	## 故统一经本助手转成带类型数组（生产侧调用方本来就是带类型的，仅测试需要）。
	var out: Array[String] = []
	for x in a:
		out.append(str(x))
	return out


func test_t3_geometric_div_warns_not_forbid_on_irregular() -> void:
	var size := Vector2i(8, 8)
	# 旧口径（cells 未给）：矩形模型判 dt 在 50 雷下不可行 → FORBID（这是被修复的误判）
	assert_eq(str(RuleSignature.compat_all(_ids(["dt"]), size, 50)["verdict"]), RuleSignature.FORBID,
			"矩形口径下 dt@50 应为 FORBID（作为对照）")

	# 异形口径（存活 60 格 ≠ 包围盒 64）：几何依赖项降级 WARN，绝不 FORBID
	var r := RuleSignature.compat_all(_ids(["dt"]), size, 50, 60)
	assert_eq(str(r["verdict"]), RuleSignature.WARN,
			"异形盘上 dt 的骨牌整除项必须降级为 WARN（不得 FORBID）")
	assert_true(str(r["reason"]).contains("异形盘不适用"),
			"reason 必须写明「异形盘不适用」（实际：%s）" % str(r["reason"]))

	# 中轴型整除（qd 的 MOD_EQ_MINUS_C）同理
	var q := RuleSignature.compat_all(_ids(["qd"]), size, 20, 60)
	assert_eq(str(q["verdict"]), RuleSignature.WARN, "异形盘上 qd 的中轴整除项必须降级为 WARN")
	assert_true(str(q["reason"]).contains("异形盘不适用"), "reason 必须含「异形盘不适用」")

	# 两两判据也不得 FORBID（dt 的几何整除项跳过）
	var pair := RuleSignature.compat("dt", "o1", size, 50, 60)
	assert_ne(str(pair["verdict"]), RuleSignature.FORBID, "异形盘上几何依赖项不得产生 FORBID")

	# _div_ok 几何化：cells 参数被采纳（此处真实骨牌数 30 仍不足 50 → false，与矩形一致为 false）
	assert_false(RuleSignature._div_ok(RuleSignature.Div.EXACT_HALF, 2, size, 50),
			"矩形口径 dt@50 不可行")
	assert_false(RuleSignature._div_ok(RuleSignature.Div.EXACT_HALF, 2, size, 50, 60),
			"异形口径（60 格）dt@50 同样不可行——差异只在「不得据此 FORBID」")


# ===== T4：兼容性 —— 不传 cells（矩形口径）逐例与改动前一致 =====

func test_t4_rect_verdicts_unchanged() -> void:
	var cases := [
		{"ids": ["o1"], "size": Vector2i(7, 7), "mines": 20, "want": RuleSignature.OK},
		{"ids": ["rl"], "size": Vector2i(6, 6), "mines": 14, "want": RuleSignature.OK},
		{"ids": ["s1", "o1"], "size": Vector2i(7, 7), "mines": 20, "want": RuleSignature.OK},   # R1 跨轴
		{"ids": ["s3", "s7"], "size": Vector2i(7, 7), "mines": 20, "want": RuleSignature.WARN}, # R2 同作用域
		{"ids": ["classic", "fr"], "size": Vector2i(7, 7), "mines": 20, "want": RuleSignature.WARN}, # R3 对称群无交集
		{"ids": ["mx", "ep"], "size": Vector2i(6, 6), "mines": 26, "want": RuleSignature.FORBID},    # R4 蕴含
		{"ids": ["qd"], "size": Vector2i(6, 6), "mines": 14, "want": RuleSignature.FORBID},          # R5 中轴整除无解
		{"ids": ["dt"], "size": Vector2i(8, 8), "mines": 26, "want": RuleSignature.OK},
		{"ids": ["dt"], "size": Vector2i(8, 8), "mines": 50, "want": RuleSignature.FORBID},
	]
	for c: Dictionary in cases:
		var got: Dictionary = RuleSignature.compat_all(_ids(c["ids"]), c["size"], c["mines"])
		assert_eq(str(got["verdict"]), str(c["want"]),
				"%s@%s/%d 矩形口径判定应保持不变（实际 %s，理由 %s）" % [
					str(c["ids"]), str(c["size"]), int(c["mines"]), str(got["verdict"]), str(got["reason"])])
		assert_false(str(got["reason"]).contains("异形盘不适用"),
				"矩形口径（cells=-1）的 compat_all 不应产生异形盘原因")


# ===== T7：compat_all 的 FORBID 必须带**结构化判据码**（不是文案）=====

# 为什么钉这条：tools/spec_check.gd / test_topology_matrix.gd 要靠 rules 判「该 FORBID 是否与几何无关」；
# 若 rules 里塞的是文案（旧行为），调用方只能做字符串匹配（脆弱）。本测试锁住结构化口径。
func test_t7_forbid_carries_structured_rule_codes() -> void:
	var size := Vector2i(8, 8)
	# R4 蕴含（mx implies ep）：与棋盘几何无关的冗余
	var r4 := RuleSignature.compat_all(["mx", "ep"], Vector2i(6, 6), 26)
	assert_eq(str(r4["verdict"]), RuleSignature.FORBID, "mx+ep 应 FORBID（R4 蕴含）")
	assert_true((r4["rules"] as Array).has("R4"), "FORBID 的 rules 必须含结构化码 R4（实际 %s）" % str(r4["rules"]))
	# 非几何整除 R5（dt 的骨牌数在 50 雷下无解，与棋盘几何无关）
	var r5 := RuleSignature.compat_all(["dt"], size, 50)
	assert_eq(str(r5["verdict"]), RuleSignature.FORBID, "dt@50 应 FORBID（R5 非几何整除）")
	assert_true((r5["rules"] as Array).has("R5"), "FORBID 的 rules 必须含结构化码 R5（实际 %s）" % str(r5["rules"]))
	# 异形盘降级路径：rules 为空数组、reason 含「异形盘不适用」（不产生任何判据码）
	var warn := RuleSignature.compat_all(["dt"], size, 50, 60)
	assert_eq(str(warn["verdict"]), RuleSignature.WARN, "异形盘 dt 应降级 WARN")
	assert_eq((warn["rules"] as Array).size(), 0, "降级 WARN 不应产生判据码")
	assert_true(str(warn["reason"]).contains("异形盘不适用"), "降级 WARN 的 reason 必须含「异形盘不适用」")


# ===== T5：geometry_kind 默认值 = 今天的行为（GEO_RECT_ONLY）=====

func test_t5_geometry_kind_default_is_rect_only() -> void:
	# 第三方 mod 不声明时的默认（基类）：保守 = 仅矩形
	var stub := RulePlugin.new()
	assert_eq(stub.geometry_kind(), RulePlugin.GEO_RECT_ONLY, "默认必须 = GEO_RECT_ONLY（今天的行为）")
	assert_false(stub.supports_topology(), "未声明者不得被当作支持异形盘")
	assert_eq(stub.place_mines_topo(RandomNumberGenerator.new(), _grid(3, 3), 2).size(), 0,
			"place_mines_topo 默认必须返回空（维持今天行为，交回生成器）")

	var reg := RuleRegistry.default()
	# 只依赖邻域的内置规则：声明支持异形
	assert_eq(reg.resolve(&"classic").geometry_kind(), RulePlugin.GEO_ADJ_GENERIC,
			"classic 仅依赖邻域计数，应声明 GEO_ADJ_GENERIC")
	assert_eq(reg.resolve(&"total_mines").geometry_kind(), RulePlugin.GEO_ADJ_GENERIC,
			"total_mines 只按存活格求和，应声明 GEO_ADJ_GENERIC")
	# 依赖矩形几何的内置规则：保守 RECT_ONLY
	for rid in [&"clock", &"loopruns", &"mx", &"pf", &"rl", &"qd", &"dt"]:
		assert_eq(reg.resolve(rid).geometry_kind(), RulePlugin.GEO_RECT_ONLY,
				"%s 依赖矩形几何，应声明 GEO_RECT_ONLY" % String(rid))


# ===== T6：异形线索值契约 —— 默认 compute_clue_topo ≡ 今天的硬编码口径 =====

# 这条是「classic 及形状关产物逐位不变」的依据：基类默认实现必须与 _count_topo_mines 同义，
# 故 classic 无需覆写；声明 GENERIC 的加权/压缩型规则则**必须**覆写，否则值/约束分叉。
func test_t6_compute_clue_topo_default_equals_hardcoded_count() -> void:
	var topo := _grid(5, 5, [Vector2i(2, 2)])
	var mines := {Vector2i(0, 0): true, Vector2i(1, 1): true, Vector2i(3, 3): true, Vector2i(4, 0): true}
	var stub := RulePlugin.new()
	for pos in topo.all_positions():
		var got: Variant = stub.compute_clue_topo(mines, pos, topo, Vector2i(5, 5))
		var want: int = PuzzleGenerator._count_topo_mines(mines, topo.get_neighbors(pos))
		assert_eq(int(got), want,
				"默认 compute_clue_topo 必须与 _count_topo_mines 逐格同义（pos=%s）" % str(pos))

	# classic 走默认实现即等价 ⇒ 不需显式覆写（模型与线索值同源）
	var classic: Object = RuleRegistry.default().resolve(&"classic")
	for pos in topo.all_positions():
		assert_eq(int(classic.call("compute_clue_topo", mines, pos, topo, Vector2i(5, 5))),
				PuzzleGenerator._count_topo_mines(mines, topo.get_neighbors(pos)),
				"classic 必须无覆写而直接复用默认实现（pos=%s）" % str(pos))

	# 空拓扑守卫：不得崩（基类默认实现必须容忍 null）
	assert_eq(int(stub.compute_clue_topo(mines, Vector2i(0, 0), null, Vector2i(5, 5))), 0,
			"topo 为 null 时默认实现应返回 0（守卫，不崩）")
