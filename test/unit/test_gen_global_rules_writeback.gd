# test_gen_global_rules_writeback.gd —— 生成工具的「全局约束门控落盘」契约（2026-10-03）
#
# 【要治的缺陷】core/puzzle_generator.gd 已对异形盘上的 GEO_RECT_ONLY 全局约束做门控
# （丢弃 + push_warning + last_call_stats.gated_globals 记录可读原因）。但生成工具若把
# **SPEC 原始请求**回写成产物 global_rules，产出的关卡 JSON 就「自称带 s2/dt 等约束、
# 实际没建」——复用 / 工坊 / 规则图例都按自述走 ⇒ 关卡自述与实际语义分叉。
#
# 【本文件钉住三件事】
#   ① tools/gen_common.gd::writeback_globals 的口径：
#        · gated_globals 非空 ⇒ 返回「原请求去掉被拦项」= 实际生效集，并带 gated 原因；
#        · gated_globals 为空 / 缺失 / gen 为 null ⇒ 原样返回请求（行为与现状一致）；
#        · **不改动调用方传入的数组**（纯函数语义，谁传谁负责回写）。
#   ② 与**真实生成器**契约对齐：洞盘上 built-in 全局规则 mx 会被门控 ⇒
#        helper 的生效集 == 生成器落盘 global_rules（产物字段 = 生效集，不是 SPEC 原始请求）。
#   ③ 四个生成工具都已接到这一处逻辑（源码级接线断言——防「改了一个忘了另一个」，
#        与 test_shape_mask_contract 读 SPECS 源码同风格）。
#   ④ **「门控前旧数据」可探测**（成对提交策略的哨兵）：用**当前门控判据**判断产物自称的
#        global_rules 在该盘拓扑上是否可能生效；不可能生效 ⇒ 标记为旧数据 + 打印提醒。
#        这样将来有人重跑 va_/vg_/sty_var_/ani_* 前会被提醒：重跑产物会写**生效集**，
#        必须把「产物 + SPEC/期望 + 库内门禁（test_geo_levels / test_shape_mask_contract）」
#        在同一次改动里成对更新（team-lead 的成对提交策略，见 tools/gen_common.gd 头注释）。
#        本用例在旧数据下只**提醒**、不判红（判红会把「新代码没问题」误报成红）。
#
# 【覆盖边界（如实说明，不得读成已端到端）】
#   · gen_geo_levels / gen_shape_levels / gen_variant_shape_levels：已做**真实 CLI 小样本跑**
#     （vg_tri_s2.json / ani_snowflake.json / --tier=easy --rule=s5 --shape=holed --count=1），
#     实测产物 global_rules == 生效集、告警可见（产物跑完已还原，故本文件用代码级断言）。
#   · gen_style_shape_levels：**未做端到端跑** —— 其最小筛选粒度是族 `variant`（19 关，跑很久
#     且覆盖面大），不支持单关/单文件筛选。本文件对它只有「源码接线断言」，不构成行为验证。
#
# 【行号纠正（免得后人按错行号找）】
#   · 真·回写 bug 只有 gen_shape_levels.gd（原 :995 `level["global_rules"] = globals` 回写了
#     SPEC 原始请求）；gen_variant_shape_levels.gd:398 / gen_style_shape_levels.gd:400 /
#     gen_geo_levels.gd:356 是 `generate_with_rules` 的**调用点**，不是回写点
#     （这三家本就用生成器返回值，核心门控后已是生效集）。
#   · SPEC 文本↔产物的 globals 比较在 test_shape_mask_contract.gd **:188**
#     （:126 比的是硬编码 ANI_CASES 期望）。
#
# 注：用的是 **built-in** 全局规则 mx（不依赖 test/_pre_run.gd 装配的备用算子包），
# 故本文件的 ① ② 在任何运行条件下都有效，不会因 mod 未装配而空转。
extends GutTest

const GenCommon := preload("res://tools/gen_common.gd")

## 四个生成工具（每个都必须在成功生成后经 GenCommon 回写 global_rules）。
const TOOL_SOURCES: Array = [
	"res://tools/gen_shape_levels.gd",
	"res://tools/gen_variant_shape_levels.gd",
	"res://tools/gen_style_shape_levels.gd",
	"res://tools/gen_geo_levels.gd",
]

## 洞盘：6×6 挖掉中央 2×2（32 格存活），洞格删格删边、不重连。
const HOLES: Array = [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]


func _holed_topo() -> AdjacencyGrid:
	var g: AdjacencyGrid = ShapeGenerator.to_adjacency_grid("holed_grid",
			{"rows": 6, "cols": 6, "holes": HOLES})
	return AdjacencyGrid.normalized(g) if g != null else null


# ==================== ① helper 口径 ====================

func test_gated_globals_rewrite_to_effective_set() -> void:
	var gen := PuzzleGenerator.new()
	gen.last_call_stats = {"gated_globals": {"s2": "依赖矩形几何，异形盘上按包围盒强算会得到另一个约束"}}
	var res: Dictionary = GenCommon.writeback_globals(gen, ["s1", "s2"], "unit_case")
	assert_eq(res["global_rules"], ["s1"], "被拦的 s2 必须从生效集里去掉")
	assert_true((res["gated"] as Dictionary).has("s2"), "被拦项必须带可读原因回传给调用方")
	assert_false(Array(res["global_rules"]).has("s2"), "被拦的全局规则不得出现在生效集")


func test_no_gating_returns_request_unchanged() -> void:
	var gen := PuzzleGenerator.new()
	gen.last_call_stats = {"gated_globals": {}}
	var requested: Array = ["s1", "s3"]
	var res: Dictionary = GenCommon.writeback_globals(gen, requested, "unit_case")
	assert_eq(res["global_rules"], requested, "没有门控时必须原样返回请求（行为不变）")
	assert_eq((res["gated"] as Dictionary).size(), 0, "没有门控时 gated 必须为空")
	assert_eq(requested, ["s1", "s3"], "helper 不得改动调用方传入的数组")


func test_missing_or_null_stats_is_safe() -> void:
	var gen := PuzzleGenerator.new()
	gen.last_call_stats = {}
	var res: Dictionary = GenCommon.writeback_globals(gen, ["s5"], "unit_case")
	assert_eq(res["global_rules"], ["s5"], "last_call_stats 缺 gated_globals 键时应原样返回")

	var res_null: Dictionary = GenCommon.writeback_globals(null, ["s5"], "unit_case")
	assert_eq(res_null["global_rules"], ["s5"], "gen 为 null 时不得崩，原样返回")


# ==================== ② 与真实生成器契约对齐 ====================

func test_real_generator_gated_set_matches_product_field() -> void:
	var topo := _holed_topo()
	assert_not_null(topo, "洞盘应能构造（本用例的判据载体）")
	if topo == null:
		return
	var gen := PuzzleGenerator.new()
	var lv: Dictionary = gen.generate_with_rules("classic", ["mx"], topo.size(), 8, 42, 0, 20,
			topo, 30_000)
	var res: Dictionary = GenCommon.writeback_globals(gen, ["mx"], "unit_case")
	# 门控发生在选 seed 之前：即便 20 次 attempt 全空，gated_globals 仍必须有记录。
	assert_true((res["gated"] as Dictionary).has("mx"),
			"built-in 全局规则 mx 在洞盘上应被门控；stats=%s" % str(gen.last_call_stats))
	assert_eq(res["global_rules"], [], "被门控后生效集应为空（等价于未勾选 mx）")
	if not lv.is_empty():
		assert_eq(Array(lv["global_rules"]), res["global_rules"],
				"产物 global_rules 必须等于 helper 的生效集（不是 SPEC 原始请求）")
		assert_false(Array(lv["global_rules"]).has("mx"), "被门控的 mx 不得出现在产物 global_rules")


func test_rect_baseline_writeback_is_identity() -> void:
	# 无 topology（矩形盘）不做异形门控 ⇒ 生效集 = 原始请求，helper 行为与现状一致。
	var gen := PuzzleGenerator.new()
	gen.generate_with_rules("classic", ["mx"], Vector2i(6, 6), 8, 7, 0, 10, null, 20_000)
	var res: Dictionary = GenCommon.writeback_globals(gen, ["mx"], "unit_case")
	assert_eq((res["gated"] as Dictionary).size(), 0, "矩形盘不得产生门控记录")
	assert_eq(res["global_rules"], ["mx"], "矩形盘上全局规则原样生效（行为不许变）")


# ==================== ③ 四个工具的接线（源码级） ====================

func test_all_four_tools_route_through_gen_common() -> void:
	for path: String in TOOL_SOURCES:
		var src := FileAccess.get_file_as_string(path)
		assert_ne(src, "", "%s 应能读到（接线断言的载体）" % path)
		if src == "":
			continue
		assert_true(src.contains("res://tools/gen_common.gd"),
				"%s 应 preload 统一门控口径 gen_common.gd" % path)
		assert_true(src.contains("GenCommon.writeback_globals("),
				"%s 应在生成成功后调用 GenCommon.writeback_globals（不许各写一份）" % path)
		assert_true(src.contains("level[\"global_rules\"] ="),
				"%s 应把生效集写进产物 global_rules（不是 SPEC 原始请求）" % path)


# ==================== ④ 「门控前旧数据」可探测（成对提交策略的哨兵） ====================

## 当前门控判据下，claimed 里在 topo 上**不可能生效**的规则 id（判据 = 生成器自己那个函数）。
func _gated_ids(claimed: Array, topo: GridInterface) -> Array:
	var out: Array = []
	if topo == null:
		return out      # 矩形盘（无 topology）不做异形门控 ⇒ 无被拦项
	var reg := RuleRegistry.default()
	for gid in claimed:
		var r: Object = reg.resolve(StringName(str(gid)))
		if r == null:
			continue    # mod 未装配：无从判断，不误报（宁可漏报也不假红）
		if not PuzzleGenerator._rule_topology_ok(r):
			out.append(str(gid))
	return out


## 产物自称的 global_rules 是否属于「门控前旧数据」：{stale: bool, message: String}。
## message 在做旧数据提醒时可读，且**必须点名**每条被拦规则。
func _stale_verdict(claimed: Array, topo: GridInterface) -> Dictionary:
	var dead := _gated_ids(claimed, topo)
	if dead.is_empty():
		return {"stale": false, "message": ""}
	return {"stale": true, "message": "产物自称 global_rules=%s，但 %s 在当前异形门控下于该盘不可能生效 ⇒ 门控落地前的旧数据；重跑该关会写生效集（tools/gen_common.gd::writeback_globals），届时须与 SPEC/期望/库内门禁成对更新" % [
		str(claimed), str(dead)]}


func _json_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func test_stale_pregating_claims_are_detectable() -> void:
	var topo := _holed_topo()
	assert_not_null(topo, "洞盘应能构造（本用例的判据载体）")
	if topo == null:
		return
	# 旧数据形态：产物自称带 mx，但 mx 在洞盘上被门控 ⇒ 必须被识别且标记可读（点名 mx）
	var stale: Dictionary = _stale_verdict(["mx"], topo)
	assert_true(bool(stale["stale"]), "应识别出门控前旧数据")
	assert_true(str(stale["message"]).contains("mx"), "标记必须点名被拦规则")
	assert_true(str(stale["message"]).contains("旧数据"), "标记必须可读（说明是门控前旧数据）")
	# 诚实形态：生效集为空 ⇒ 不是旧数据（重跑后的产物就长这样）
	assert_false(bool(_stale_verdict([], topo)["stale"]), "空 global_rules 不应被误判为旧数据")
	# 矩形盘（无 topology）不做门控 ⇒ mx 合法，不得误判为旧数据
	assert_false(bool(_stale_verdict(["mx"], null)["stale"]), "矩形盘上 mx 合法，不得误判")


## 对**真实产物**跑一遍哨兵：旧数据（如 ani_snowflake 自称 s2）会被打印成醒目提醒，
## 但不判红（判红会把「新代码没问题」误报成红）。重跑成生效集后本用例自然静默。
func test_real_level_products_are_scanned_for_pregating_claims() -> void:
	var path := "res://levels/ani_snowflake.json"
	if not FileAccess.file_exists(path):
		pending("缺少 %s —— 旧数据探测的样本（重跑 gen_shape_levels 后应存在）" % path)
		return
	var prod: Dictionary = _json_file(path)
	var claimed: Array = prod.get("global_rules", [])
	var board: Board = LevelLoader.load_level(path) as Board
	var topo: GridInterface = board.grid if board != null else null
	assert_not_null(topo, "%s 应能载入成异形棋盘（哨兵的拓扑来源）" % path)
	var dead: Array = _gated_ids(claimed, topo)
	var verdict: Dictionary = _stale_verdict(claimed, topo)
	assert_eq(bool(verdict["stale"]), not dead.is_empty(),
			"stale 标记必须与当前门控判据一致（claimed=%s）" % str(claimed))
	for gid in dead:
		assert_true(str(verdict["message"]).contains(str(gid)),
				"提醒必须点名被拦规则 %s：%s" % [str(gid), str(verdict["message"])])
	if bool(verdict["stale"]):
		print("[门控前旧数据提醒] %s：%s" % [path, str(verdict["message"])])
