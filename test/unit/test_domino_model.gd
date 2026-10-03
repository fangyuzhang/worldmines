# test_domino_model.gd —— 骨牌划分纯逻辑模型（文档「五、变体规则配置 · 变体专用工具」）
#
# 钉住的不变量：
#   ① 相邻两格可成骨牌；不相邻 / 已占用 / 跨复合格 / 单格复合格 ⇒ 各自**可读拒绝**且无副作用；
#   ② validate 全覆盖 + 无重叠 ⇒ ok；
#   ③ 缺一格 ⇒ level="block"，`uncovered` **精确列出**该格坐标，并带可读原因；
#   ④ 重叠 ⇒ `overlaps` 列出被重复占用的格与骨牌 id；
#   ⑤ 序列化 round-trip 逐字节一致 + 稳定顺序 + 更高版本拒收；
#   ⑥ 复合格 × 骨牌未定义组合（跨复合格 / 单格复合格）在 validate 里明确 block（不静默放过）。
#
# 用 preload 而非全局类名，避免新增脚本的全局类缓存尚未刷新时测试无法解析。
extends GutTest

const DM := preload("res://core/domino_model.gd")
const MC := preload("res://core/mega_cell.gd")


func _grid(rows: int, cols: int) -> RectGrid:
	var g := RectGrid.new()
	g.setup(rows, cols)
	return g


func _codes(issues: Array) -> Dictionary:
	var out := {}
	for it in issues:
		out[str((it as Dictionary)["code"])] = true
	return out


# ==================== ① 放置：相邻可成、拒绝可读 ====================

func test_place_adjacent_two_cells_ok() -> void:
	var model := DM.new()
	var g := _grid(9, 9)
	var r := model.place(Vector2i(2, 2), Vector2i(3, 2), {"grid": g})
	assert_true(bool(r["ok"]), "相邻两格应能成骨牌：%s" % str(r))
	assert_true(int(r["id"]) > 0, "应分配正整数 id")
	assert_eq(model.count(), 1, "应恰好 1 张骨牌")
	assert_eq(model.owner_of(Vector2i(2, 2)), int(r["id"]))
	assert_eq(model.owner_of(Vector2i(3, 2)), int(r["id"]))


func test_place_requires_grid() -> void:
	var model := DM.new()
	var r := model.place(Vector2i(0, 0), Vector2i(1, 0), {})
	assert_false(bool(r["ok"]), "缺 grid 必须拒绝（相邻只能按邻接表判定）")
	assert_eq(str(r["code"]), "no_grid")
	assert_true(str(r["reason"]).length() > 0, "拒绝必须给人话原因")


func test_place_rejects_not_adjacent_and_occupied() -> void:
	var model := DM.new()
	var g := _grid(9, 9)
	var r1 := model.place(Vector2i(0, 0), Vector2i(2, 0), {"grid": g})
	assert_false(bool(r1["ok"]), "不相邻必须拒绝：%s" % str(r1))
	assert_eq(str(r1["code"]), "not_adjacent")
	assert_true(str(r1["reason"]).length() > 0, "拒绝必须给人话原因")
	assert_eq(model.count(), 0, "被拒不得有副作用")

	assert_true(bool(model.place(Vector2i(0, 0), Vector2i(1, 0), {"grid": g})["ok"]))
	var r2 := model.place(Vector2i(1, 0), Vector2i(1, 1), {"grid": g})
	assert_false(bool(r2["ok"]), "已占用的格必须拒绝：%s" % str(r2))
	assert_eq(str(r2["code"]), "occupied")
	assert_true(str(r2["reason"]).length() > 0, "拒绝必须给人话原因")
	assert_eq(model.count(), 1, "被拒不得有副作用")
	assert_eq(model.owner_of(Vector2i(1, 1)), 0, "被拒不得占用任何格")


func test_place_rejects_cross_mega_and_singleton() -> void:
	var model := DM.new()
	var g := _grid(9, 9)
	var mega := MC.new()
	mega.merge([Vector2i(3, 3), Vector2i(4, 3)])
	mega.merge([Vector2i(5, 3), Vector2i(6, 3)])
	# (4,3)-(5,3) 相邻但分属两个复合格 ⇒ 明确拒绝
	var r := model.place(Vector2i(4, 3), Vector2i(5, 3), {"grid": g, "mega": mega})
	assert_false(bool(r["ok"]), "跨复合格必须拒绝：%s" % str(r))
	assert_eq(str(r["code"]), "cross_mega")
	assert_true(str(r["reason"]).length() > 0, "跨复合格拒绝必须可读")
	assert_eq(model.count(), 0, "被拒不得有副作用")
	# 同属一个复合格 ⇒ 放行
	var ok := model.place(Vector2i(3, 3), Vector2i(4, 3), {"grid": g, "mega": mega})
	assert_true(bool(ok["ok"]), "同一复合格内的相邻两格应放行：%s" % str(ok))
	# 单格复合格 ⇒ 拒绝（那一格永远配不成骨牌）
	var mega2 := MC.new()
	mega2.merge([Vector2i(7, 7)])
	var r2 := model.place(Vector2i(7, 7), Vector2i(7, 8), {"grid": g, "mega": mega2})
	assert_false(bool(r2["ok"]), "单格复合格必须拒绝：%s" % str(r2))
	assert_eq(str(r2["code"]), "mega_singleton")
	assert_true(str(r2["reason"]).length() > 0, "单格复合格拒绝必须可读")
	# 无复合格时同一对可放行 —— 证明拒绝来自复合格门禁而非相邻
	var model2 := DM.new()
	assert_true(bool(model2.place(Vector2i(7, 7), Vector2i(7, 8), {"grid": g})["ok"]))


func test_erase_and_clear_all() -> void:
	var model := DM.new()
	var g := _grid(9, 9)
	model.place(Vector2i(0, 0), Vector2i(1, 0), {"grid": g})
	var b := model.place(Vector2i(5, 5), Vector2i(5, 6), {"grid": g})
	var e := model.erase(int(b["id"]))
	assert_true(bool(e["ok"]), "删除应成功：%s" % str(e))
	assert_eq(model.owner_of(Vector2i(5, 5)), 0, "删除后应释放所占格")
	assert_eq(model.count(), 1)
	var bad := model.erase(9999)
	assert_false(bool(bad["ok"]), "未知 id 必须拒绝")
	assert_eq(str(bad["code"]), "unknown")
	model.clear_all()
	assert_eq(model.count(), 0, "clear_all 后应为空")
	assert_eq(model.owner_of(Vector2i(0, 0)), 0)


# ==================== ②③④ validate：全覆盖 / 缺格 / 重叠 ====================

func test_validate_full_cover_ok() -> void:
	var model := DM.new()
	var g := _grid(2, 2)
	assert_true(bool(model.place(Vector2i(0, 0), Vector2i(1, 0), {"grid": g})["ok"]))
	assert_true(bool(model.place(Vector2i(0, 1), Vector2i(1, 1), {"grid": g})["ok"]))
	var v := model.validate(g)
	assert_true(bool(v["ok"]), "全覆盖应放行：%s" % str(v["issues"]))
	assert_eq(str(v["level"]), DM.LEVEL_OK, "全覆盖应 ok：%s" % str(v["issues"]))
	assert_true(bool(v["covered"]), "covered 应为 true")
	assert_eq((v["uncovered"] as Array).size(), 0, "不应有空缺格")
	assert_eq((v["overlaps"] as Array).size(), 0, "不应有重叠格")


func test_validate_missing_cell_blocks_with_exact_coord() -> void:
	var model := DM.new()
	var g := _grid(1, 5)
	assert_true(bool(model.place(Vector2i(0, 0), Vector2i(1, 0), {"grid": g})["ok"]))
	assert_true(bool(model.place(Vector2i(2, 0), Vector2i(3, 0), {"grid": g})["ok"]))
	var v := model.validate(g)
	assert_false(bool(v["ok"]), "不完整必须 block（文档：不完整阻止保存）")
	assert_eq(str(v["level"]), DM.LEVEL_BLOCK)
	assert_false(bool(v["covered"]), "不完整时 covered 应为 false")
	var unc: Array = v["uncovered"]
	assert_eq(unc.size(), 1, "应精确列出 1 个空缺格：%s" % str(unc))
	assert_eq(unc[0], Vector2i(4, 0), "空缺格应是 (4,0)")
	var it := _codes(v["issues"])
	assert_true(it.has("uncovered"), "必须给出 uncovered 可读原因：%s" % str(v["issues"]))
	var txt := ""
	for issue in v["issues"]:
		if str((issue as Dictionary)["code"]) == "uncovered":
			txt = str((issue as Dictionary)["text"])
	assert_true(txt.find("(4,0)") != -1, "block 原因必须写出具体坐标，不能只给计数：%s" % txt)


func test_validate_overlap_lists_duplicated_cells() -> void:
	# place 会挡重叠，所以用手工脏存档构造「两骨牌共格」。
	var payload := {
		"version": DM.VERSION,
		"dominoes": [
			{"id": 1, "cells": [[0, 0], [1, 0]]},
			{"id": 2, "cells": [[1, 0], [2, 0]]},
		],
	}
	var model := DM.from_dict(payload)
	assert_eq(model.count(), 2, "脏存档仍应加载（绝不静默丢骨牌）")
	var g := _grid(1, 3)
	var v := model.validate(g)
	assert_false(bool(v["ok"]), "重叠必须 block")
	assert_eq(str(v["level"]), DM.LEVEL_BLOCK)
	assert_false(bool(v["covered"]))
	var ov: Array = v["overlaps"]
	assert_eq(ov.size(), 1, "应列出 1 个重复占用的格：%s" % str(ov))
	assert_eq((ov[0] as Dictionary)["pos"], Vector2i(1, 0), "重复占用的格应是 (1,0)")
	assert_eq(int((ov[0] as Dictionary)["count"]), 2, "该格应被 2 张骨牌占用")
	assert_eq(((ov[0] as Dictionary)["ids"] as Array).size(), 2, "应列出两张骨牌的 id")
	assert_eq((v["uncovered"] as Array).size(), 0, "3 格全被覆盖 ⇒ 不应有 uncovered")
	assert_true(_codes(v["issues"]).has("overlap"), "必须给出 overlap 可读原因")


# ==================== ⑥ 复合格 × 骨牌：明确 block ====================

func test_validate_blocks_cross_mega_and_singleton() -> void:
	var mega := MC.new()
	mega.merge([Vector2i(0, 0), Vector2i(1, 0)])
	mega.merge([Vector2i(2, 0)])
	var payload := {"version": DM.VERSION, "dominoes": [{"id": 1, "cells": [[1, 0], [2, 0]]}]}
	var model := DM.from_dict(payload)
	var g := _grid(1, 3)
	var v := model.validate(g, mega)
	assert_false(bool(v["ok"]), "跨复合格 / 单格复合格必须 block：%s" % str(v["issues"]))
	var codes := _codes(v["issues"])
	assert_true(codes.has("cross_mega"), "必须明确报 cross_mega：%s" % str(v["issues"]))
	assert_true(codes.has("mega_singleton"), "必须明确报 mega_singleton：%s" % str(v["issues"]))


# ==================== ⑤ 序列化 round-trip + 稳定顺序 + version ====================

func test_serialize_roundtrip_stable_order_and_version_gate() -> void:
	var model := DM.new()
	var g := _grid(3, 3)
	# 乱序放置：稳定排序后应把 (0,0)-(1,0) 排最前
	model.place(Vector2i(2, 2), Vector2i(2, 1), {"grid": g})
	model.place(Vector2i(0, 0), Vector2i(1, 0), {"grid": g})
	model.place(Vector2i(0, 2), Vector2i(1, 2), {"grid": g})
	var d := model.to_dict()
	assert_eq(int(d["version"]), DM.VERSION, "version 字段必须落盘")
	var items: Array = d["dominoes"]
	assert_eq((items[0] as Dictionary)["cells"], [[0, 0], [1, 0]], "应按规范格序稳定排序")
	var back := DM.from_dict(d)
	assert_eq(back.count(), model.count())
	assert_eq(back.domino_ids(), model.domino_ids())
	assert_eq(str(back.to_dict()), str(d), "序列化往返应逐字节一致")
	# 更高版本必须拒收
	var future := d.duplicate(true)
	future["version"] = DM.VERSION + 1
	assert_eq(DM.from_dict(future).count(), 0, "高于本模块版本的存档应被拒收")


func test_from_dict_skips_bad_records_without_losing_good_ones() -> void:
	var payload := {
		"version": DM.VERSION,
		"dominoes": [
			{"id": 1, "cells": [[0, 0], [1, 0]]},
			{"id": 0, "cells": [[2, 0], [3, 0]]},          # id 非正 ⇒ 跳过
			{"id": 1, "cells": [[4, 0], [5, 0]]},          # id 重复 ⇒ 跳过
			{"id": 2, "cells": [[6, 0]]},                  # 只有 1 格 ⇒ 跳过
			{"id": 3, "cells": [[7, 0], [7, 0]]},          # 同格重复 ⇒ 跳过
			{"id": 4, "cells": [[8, 0], [9, 0]]},          # 正常 ⇒ 保留
		],
	}
	var model := DM.from_dict(payload)
	assert_eq(model.count(), 2, "坏记录应跳过、好记录不牵连：%s" % str(model.domino_ids()))
	assert_eq(model.owner_of(Vector2i(0, 0)), 1)
	assert_eq(model.owner_of(Vector2i(9, 0)), 4)
