# test_shape_dag_mapping.gd —— 形状 → 构建器映射（ShapeDag.primitive_to_builder）的红灯自证。
#
# 为什么必须单独钉：DAG 的形状词汇表与 core/shape_generator.gd 的构建器**看着能对上、实际有两处
# 对不上**，而"就近挑一个 build_*"的后果是静默的（错几何/空几何都能混进关卡且不报错）。故钉死：
#   ① 有词汇、没生成器：必须 ok=false + 可读原因，绝不静默出空几何（本轮该桶剩 rect / freehand / text；
#      ngon / ring 已因新生成器而**接线**，见下方契约变更说明）；
#   ② 同名不同义：DAG "ring" = annulus（单个内圆挖空形状），build_ring = 同心环盘（多格 + 角向闭环，
#      返回 positions/adjacency）⇒ 映射只准指向 build_annulus，**任何**形状都不得被映射到 build_ring；
#   ③ 真能对上的必须逐字对上：circle / star / sector → build_circle / build_star / build_sector
#      （本轮新增 ngon → build_ngon）；
#   ④ 未知 / 空 / 垃圾形状有兜底：ok=false + 原因，不崩、不出空几何；
#   ⑤ 全词汇表扫一遍：返回契约恒为 {ok, kind, reason, builder_name}，且**任何**形状都不会被映射到
#      build_ring；ok 与 builder_name / reason 的耦合关系恒成立。
#
# 【2026-10-03 契约变更 · 主 Agent 授权】本文件仅翻转**因本次新增生成器而过期**的两条期望：
#   · 旧 ①「ngon ⇒ ok=false + 原因」⟵ 生成器 core/shape_generator.gd:846 build_ngon 已落地
#     ⇒ 若继续拒绝，就是"生成器存在、映射却说没有"的接线缺口 ⇒ 现期望 ok=true 且 builder_name
#     == "build_ngon"（见 test_ngon_maps_to_build_ngon）。
#   · 旧 ②「ring ⇒ ok=false + forbidden_builder="build_ring"」⟵ 生成器 core/shape_generator.gd:869
#     build_annulus 已落地 ⇒ 现期望 ok=true 且 builder_name == "build_annulus"；**防顶替的实质不放松**：
#     改判据后仍逐字断言"不是 build_ring"（见 test_ring_maps_to_annulus_never_to_build_ring）。
#   文件内 ③④⑤ 及其它断言一律未动。
#
# 用 preload 而非全局类名（与 test_shape_dag.gd 同因）：非编辑器运行时全局类缓存可能还没有新类名。
extends GutTest

const ShapeDagScript := preload("res://core/shape_dag.gd")
const FOUR_KEYS := ["ok", "kind", "reason", "builder_name"]


## 【2026-10-03 翻转旧期望】旧：ngon 无生成器 ⇒ ok=false。失效原因：2026-10-03 新增
## core/shape_generator.gd:846 `build_ngon(sides, radius, tier)` ⇒ 映射必须收口。新期望钉住新行为。
func test_ngon_maps_to_build_ngon() -> void:
	var r: Dictionary = ShapeDagScript.primitive_to_builder("ngon")
	assert_true(bool(r["ok"]), "ngon 生成器已落地（shape_generator.gd:846）⇒ 必须映射成功，禁止再报未支持")
	assert_eq(str(r["kind"]), "builder", "成功映射的 kind 应为 builder")
	assert_eq(str(r["builder_name"]), "build_ngon", "ngon 唯一语义一致的构建器就是 build_ngon")
	assert_eq(str(r["reason"]), "", "ok=true 不应带原因")


## 【2026-10-03 翻转旧期望】旧：ring 无 annulus 构建器 ⇒ ok=false + forbidden_builder="build_ring"。
## 失效原因：2026-10-03 新增 core/shape_generator.gd:869 `build_annulus(outer, inner, precision, tier)`。
## 防顶替的**实质不放松**：新期望要求映射到 build_annulus，并逐字断言**不是** build_ring
## （同名不同义：环盘多格 + 角向闭环，几何与数据结构都不同）。
func test_ring_maps_to_annulus_never_to_build_ring() -> void:
	var r: Dictionary = ShapeDagScript.primitive_to_builder("ring")
	assert_true(bool(r["ok"]), "annulus 生成器已落地（shape_generator.gd:869）⇒ 必须映射成功")
	assert_eq(str(r["kind"]), "builder", "成功映射的 kind 应为 builder")
	assert_eq(str(r["builder_name"]), "build_annulus", "ring=annulus 必须映射到 build_annulus")
	assert_ne(str(r["builder_name"]), "build_ring", "ring=annulus 与 build_ring 同名不同义，禁止顶替")
	assert_eq(str(r["reason"]), "", "ok=true 不应带原因")


func test_verified_shapes_map_to_matching_builders() -> void:
	var pairs := [["circle", "build_circle"], ["star", "build_star"], ["sector", "build_sector"]]
	for p: Array in pairs:
		var r: Dictionary = ShapeDagScript.primitive_to_builder(str(p[0]))
		assert_true(bool(r["ok"]), "%s 有语义一致的构建器" % p[0])
		assert_eq(str(r["builder_name"]), str(p[1]), "%s 必须映射到 %s" % [p[0], p[1]])
		assert_eq(str(r["kind"]), "builder", "%s 成功映射的 kind 应为 builder" % p[0])


func test_unknown_and_empty_shapes_fall_back_without_crashing() -> void:
	for s in ["", "   ", "triangle", "annulus", "build_ring", "UNKNOWN", "123"]:
		var r: Dictionary = ShapeDagScript.primitive_to_builder(str(s))
		assert_false(bool(r["ok"]), "未登记形状「%s」必须 ok=false" % s)
		assert_eq(str(r["builder_name"]), "", "未登记形状「%s」不得给出构建器名" % s)
		assert_ne(str(r["reason"]).strip_edges(), "", "未登记形状「%s」必须给原因" % s)


func test_whole_vocabulary_respects_contract_and_never_builds_ring() -> void:
	var n := 0
	for shape: String in ShapeDagScript.PRIMITIVE_SHAPES:
		var r: Dictionary = ShapeDagScript.primitive_to_builder(shape)
		n += 1
		for k in FOUR_KEYS:
			assert_true(r.has(k), "形状「%s」的返回必须含键 %s" % [shape, k])
		assert_ne(str(r["builder_name"]), "build_ring", "形状「%s」不得映射到 build_ring" % shape)
		if bool(r["ok"]):
			assert_ne(str(r["builder_name"]), "", "「%s」ok=true 必须给出构建器名" % shape)
			assert_eq(str(r["reason"]), "", "「%s」ok=true 时不应带原因" % shape)
		else:
			assert_eq(str(r["builder_name"]), "", "「%s」ok=false 不得给出构建器名" % shape)
			assert_ne(str(r["reason"]).strip_edges(), "", "「%s」ok=false 必须给原因" % shape)
	assert_eq(n, ShapeDagScript.PRIMITIVE_SHAPES.size(), "词汇表应被完整扫过（坏一个就红）")
