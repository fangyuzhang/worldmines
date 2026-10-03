# test_mega_cell.gd —— 复合格模型 + 硬规则门禁（文档「三、形状系统 · 复合格」三坑）
#
# 钉住的不变量：
#   ① 合并 / 拆分往返一致（含重复输入去重）；
#   ② 嵌套被拒绝且有可读原因（重叠格 / 直接传复合格 / 传复合格集合），失败无副作用；
#   ③ 邻接 31 → warn、81 → block、30 → ok、80 → warn（>30 / >80 同 EditorDoc 口径）；
#   ④ 密度稀释 warn 的触发与文案非空；
#   ⑤ 下钻返回的内部格集合与「逻辑一格」一致（无重复、无丢失）；
#   ⑥ 邻接去重：基础格按格去重、复合格按复合格去重；接受 GridInterface 与 Callable；
#   ⑦ 序列化 round-trip（含 1/65536 坐标量化）与 version 门禁。
#
# 用 preload 而非全局类名，避免新增脚本的全局类缓存尚未刷新时测试无法解析。
extends GutTest

const MC := preload("res://core/mega_cell.gd")


## 固定邻接来源：对任何 pos 都返回同一份邻居表（单格复合格下等价于真实邻居）。
func _fixed_neighbors(neighbors: Array) -> Callable:
	return func(_pos: Vector2i) -> Array[Vector2i]:
		var out: Array[Vector2i] = []
		for v: Vector2i in neighbors:
			out.append(v)
		return out


## n 个互不相同的邻居（远离 (0,0)，且不与任何测试盘格重合）。
func _n_neighbors(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(Vector2i(1000 + i, 500))
	return out


func _find(list: Array, code: String) -> Dictionary:
	for it in list:
		if str((it as Dictionary)["code"]) == code:
			return it
	return {}


# ==================== ① 合并 / 拆分往返一致 ====================

func test_merge_split_roundtrip() -> void:
	var reg := MC.new()
	var input := [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 1)]
	var m := reg.merge(input)
	assert_true(bool(m["ok"]), "合并应成功：%s" % str(m))
	assert_true(int(m["id"]) > 0, "合并应分配正整数 id")
	assert_eq(int(reg.count()), 1, "合并后应恰好 1 个复合格")
	var sp := reg.split(m["id"])
	assert_true(bool(sp["ok"]), "拆分应成功：%s" % str(sp))
	assert_eq((sp["cells"] as Array).size(), 3, "拆分应回到去重后的基础格（3 格）")
	assert_eq(int(reg.count()), 0, "拆分后不应剩下复合格")
	for p: Vector2i in sp["cells"]:
		assert_eq(reg.owner_of(p), 0, "拆分后基础格不应再被占用")


# ==================== ② 嵌套被拒绝且有原因（失败无副作用）====================

func test_nested_merge_rejected_with_reason() -> void:
	var reg := MC.new()
	var a := reg.merge([Vector2i(1, 1), Vector2i(1, 2)])
	assert_true(bool(a["ok"]))
	# (1,2) 已被占用 ⇒ 拒绝
	var b := reg.merge([Vector2i(1, 2), Vector2i(2, 2)])
	assert_false(bool(b["ok"]), "含已被占用的格必须被拒：%s" % str(b))
	assert_eq(str(b["code"]), "nested", "拒绝原因应是嵌套/重叠")
	assert_true(str(b["reason"]).length() > 0, "拒绝必须给人话原因")
	# 直接把「复合格记录」当基础格传 ⇒ 拒绝（禁止嵌套）
	var c := reg.merge([{"id": int(a["id"]), "cells": a["cells"]}])
	assert_false(bool(c["ok"]), "把复合格当基础格合并必须被拒")
	assert_eq(str(c["code"]), "nested")
	# 直接把「复合格集合」（一组格）传进来 ⇒ 拒绝
	var d := reg.merge([[Vector2i(5, 5), Vector2i(5, 6)]])
	assert_false(bool(d["ok"]), "传复合格集合必须被拒")
	assert_eq(str(d["code"]), "nested")
	# 失败不得产生副作用
	assert_eq(int(reg.count()), 1, "被拒的合并不得改变已有复合格数")
	assert_eq(reg.owner_of(Vector2i(2, 2)), 0, "被拒的合并不得占用任何格")
	assert_eq(reg.owner_of(Vector2i(5, 5)), 0, "被拒的合并不得占用任何格")


func test_nested_payload_blocks_on_check() -> void:
	# 手工构造一份「两个复合格共用一格」的脏存档（正常 merge 进不来）
	var payload := {
		"version": MC.VERSION,
		"groups": [
			{"id": 1, "cells": [[0, 0], [1, 0]]},
			{"id": 2, "cells": [[1, 0], [2, 0]]},
		],
	}
	var reg := MC.from_dict(payload)
	assert_eq(int(reg.count()), 2, "脏数据仍应加载（绝不静默丢复合格）")
	assert_false(reg.conflicts().is_empty(), "应记录共格嵌套")
	var rep := reg.check(1, {})
	assert_eq(str(rep["level"]), MC.LEVEL_BLOCK, "共格嵌套必须 block：%s" % str(rep["reasons"]))
	assert_false(bool(rep["ok"]), "block 必须阻止操作")
	assert_false(_find(rep["reasons"], "nested").is_empty(), "block 必须给出 nested 原因")


# ==================== ③ 邻接 31 → warn、81 → block ====================

func test_adjacency_31_warn_81_block() -> void:
	var reg := MC.new()
	var m := reg.merge([Vector2i(0, 0)])
	assert_true(bool(m["ok"]))
	var id := int(m["id"])
	# 边界：30 放行
	assert_eq(str(reg.check(id, {"provider": _fixed_neighbors(_n_neighbors(30))})["level"]),
		MC.LEVEL_OK, "邻接 30 应放行")
	# 31 → warn（>30）
	var warn := reg.check(id, {"provider": _fixed_neighbors(_n_neighbors(31))})
	assert_eq(str(warn["level"]), MC.LEVEL_WARN, "邻接 31 应 warn：%s" % str(warn["reasons"]))
	assert_true(bool(warn["ok"]), "warn 应放行（ok=true，只提醒）")
	assert_eq(int(warn["adjacency"]["base"]), 31, "邻接应按去重后的基础格计数")
	assert_true(str(_find(warn["reasons"], "neighbor_many")["text"]).length() > 0, "warn 必须带可读提示")
	# 80 → 仍只 warn
	assert_eq(str(reg.check(id, {"provider": _fixed_neighbors(_n_neighbors(80))})["level"]),
		MC.LEVEL_WARN, "邻接 80（>30 且 <=80）应只 warn")
	# 81 → block（>80）
	var block := reg.check(id, {"provider": _fixed_neighbors(_n_neighbors(81))})
	assert_eq(str(block["level"]), MC.LEVEL_BLOCK, "邻接 81 应 block：%s" % str(block["reasons"]))
	assert_false(bool(block["ok"]), "block 必须阻止操作（ok=false）")
	assert_true(str(_find(block["reasons"], "neighbor_huge")["text"]).length() > 0, "block 必须说明原因")


func test_adjacency_counts_dedupe_cells_and_megas() -> void:
	var reg := MC.new()
	var a := reg.merge([Vector2i(0, 0)])
	var b := reg.merge([Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)])
	# 反复给出同一格（(1,0) 两次）：基础格应去重为 3
	var nb := _fixed_neighbors([Vector2i(1, 0), Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2)])
	var adj := reg.adjacency(a["id"], nb)
	assert_true(bool(adj["ok"]), "邻接应可算：%s" % str(adj))
	assert_eq(int(adj["base"]), 3, "重复邻居必须去重后计数")
	assert_eq(int(adj["mega"]), 1, "3 个相邻格同属一个复合格 ⇒ 相邻复合格数为 1")
	assert_eq((adj["neighbor_ids"] as Array).size(), 1)
	assert_eq(int(adj["neighbor_ids"][0]), int(b["id"]))


func test_adjacency_accepts_grid_interface() -> void:
	var grid := RectGrid.new()
	grid.setup(9, 9)
	var reg := MC.new()
	var m := reg.merge([Vector2i(4, 4)])
	var adj := reg.adjacency(m["id"], grid)
	assert_true(bool(adj["ok"]), "应接受 GridInterface：%s" % str(adj))
	assert_eq(int(adj["base"]), 8, "9×9 中心格经 RectGrid 应得 8 邻")


# ==================== ④ 密度稀释 warn ====================

func test_density_dilution_warns_with_readable_text() -> void:
	var reg := MC.new()
	var cells: Array = []
	for i in 30:
		cells.append(Vector2i(i, 0))
	var m := reg.merge(cells)
	assert_true(bool(m["ok"]))
	var id := int(m["id"])
	var no_neighbors := _fixed_neighbors([])
	# 1 颗雷上限 / 30 格 ≈ 3.3%，低于推荐 37% ⇒ warn
	var rep := reg.check(id, {"provider": no_neighbors, "recommended_density": 0.37})
	assert_eq(str(rep["level"]), MC.LEVEL_WARN, "密度稀释应 warn：%s" % str(rep["reasons"]))
	assert_true(bool(rep["ok"]), "密度稀释是 warn（放行 + 提醒）")
	var dil := _find(rep["reasons"], "density_diluted")
	assert_false(dil.is_empty(), "应给 density_diluted：%s" % str(rep["reasons"]))
	assert_true(str(dil["text"]).length() > 0, "密度稀释原因必须可读非空")
	# 推荐密度 <=0（不查密度）⇒ 不应报密度稀释
	var off := reg.check(id, {"provider": no_neighbors, "recommended_density": 0.0})
	assert_true(_find(off["reasons"], "density_diluted").is_empty(), "未给推荐密度时不应报密度稀释")
	assert_eq(str(off["level"]), MC.LEVEL_OK, "无邻接 + 不查密度 ⇒ ok")


# ==================== ⑤ 下钻：内部集合与逻辑一格一致 ====================

func test_drilldown_internal_cells_match_logical_cell() -> void:
	var reg := MC.new()
	var input := [Vector2i(2, 2), Vector2i(3, 2), Vector2i(3, 3), Vector2i(2, 2)]
	var m := reg.merge(input)
	var id := int(m["id"])
	var inner := reg.internal_cells(id)
	assert_eq(inner.size(), 3, "内部集合应按去重后的基础格计数")
	assert_eq(reg.size_of(id), inner.size(), "逻辑一格大小 == 内部集合大小（不重复计数）")
	var uniq := {}
	for p: Vector2i in input:
		uniq[p] = true
	assert_eq(inner.size(), uniq.size(), "下钻不得丢格")
	for p2: Vector2i in inner:
		assert_true(uniq.has(p2), "内部格必须来自原始输入：%s" % str(p2))
		assert_eq(reg.owner_of(p2), id, "内部格必须归属该复合格")
	assert_eq((m["cells"] as Array).size(), inner.size(), "merge 返回的格集合应等于下钻集合")


# ==================== ⑦ 序列化 round-trip + version ====================

func test_serialize_roundtrip_and_version() -> void:
	var reg := MC.new()
	var a := reg.merge([Vector2i(2, 3), Vector2i(3, 3), Vector2i(3, 4)])
	reg.merge([Vector2i(10, 10)])
	var d := reg.to_dict()
	assert_eq(int(d["version"]), MC.VERSION, "version 字段必须落盘")
	var back := MC.from_dict(d)
	assert_eq(int(back.count()), int(reg.count()))
	assert_eq(back.ids(), reg.ids())
	assert_eq(back.internal_cells(a["id"]), reg.internal_cells(a["id"]))
	assert_eq(str(back.to_dict()), str(d), "序列化往返应逐字节一致")
	# 1/65536 坐标量化：派生重心 round-trip 不漂
	var c := reg.centroid_of(a["id"])
	assert_almost_eq(MC.dequantize(MC.quantize(c.x)), c.x, 1.0 / float(MC.COORD_SCALE), "重心 x 量化往返不漂")
	assert_almost_eq(MC.dequantize(MC.quantize(c.y)), c.y, 1.0 / float(MC.COORD_SCALE), "重心 y 量化往返不漂")
	# version 只增不改：更高版本必须拒收
	var future := d.duplicate(true)
	future["version"] = MC.VERSION + 1
	assert_eq(int(MC.from_dict(future).count()), 0, "高于本模块版本的存档应被拒收")
