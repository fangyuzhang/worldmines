# test_shape_mask_contract.gd —— mask 图案关（ani_* / art_*）的产物契约 + SPEC 一致性门禁
#
# 2026-09-23 审计新增。两个目的：
#
# ① **动物关逐关覆盖**：审计发现 ani_* 在 test/ 目录零命中——9 个动物棋盘此前没有任何
#    逐关断言（格数/雷数/bbox/seed/globals/图案指纹），与 holed/hex/art 的待遇不一致。
#    这里用与 test_shape_levels.ART_CASES 相同的口径把它们逐关钉住。
#
# ② **SPEC ↔ 产物一致性门禁**（审计发现的真问题）：TOOLS/gen_shape_levels.gd 的 SPECS 是
#    生成器的**可执行真值**，而注释不是。审计发现 ani_octopus 的 SPEC（z3 / 162 格 / 15×20）
#    与产物（s5 / 60 格 / 11×10）长期脱节：按脱节的 SPEC 跑批量会因该关失败，
#    连带「failures > 0 ⇒ 整批不提交」使 12 个 mask 关**无法整体重生成**。
#    本门禁把「SPEC 声明的 cells/mines/globals == 产物实际值」钉成红灯条件。
#
# 产物缺失 → pending（附生成命令），绝不用红测试表达「还没生成」。
extends GutTest

const LEVELS_DIR := "res://levels/"
const SPEC_PATH := "res://tools/gen_shape_levels.gd"
const GEN_CMD := "godot --headless --path . -s res://tools/gen_shape_levels.gd -- <file>"

## 动物棋盘 9 关的实际产物（2026-09-23 收尾：8 关高分辨率 + octopus 保留升级前 60 格版）。
## row_lens = mask 逐行有格数（图案指纹：形状被改必红灯）；edges = 无向边数（度数/2）。
## seed 是 SPECS 的 base_seed（换 seed 重试成功时产物 seed 会不同，此处记录实跑值）。
const ANI_CASES: Array = [
	{
		"file": "ani_turtle.json", "cells": 120, "mines": 34, "seed": 9307, "bbox": Vector2i(17, 18),
		"globals": "s2", "edges": 342,
		"row_lens": [3, 5, 5, 3, 9, 17, 12, 6, 4, 4, 6, 8, 15, 15, 1, 3, 3, 1],
	},
	{
		"file": "ani_starfish.json", "cells": 98, "mines": 27, "seed": 9301, "bbox": Vector2i(17, 16),
		"globals": "s3", "edges": 283,
		"row_lens": [1, 3, 3, 3, 3, 3, 13, 15, 13, 5, 5, 6, 8, 8, 6, 3],
	},
	{
		"file": "ani_snowflake.json", "cells": 88, "mines": 25, "seed": 9304, "bbox": Vector2i(15, 18),
		"globals": "s2", "edges": 167,
		"row_lens": [1, 1, 3, 1, 7, 9, 7, 7, 7, 3, 7, 7, 7, 9, 7, 1, 3, 1],
	},
	{
		"file": "ani_web.json", "cells": 144, "mines": 40, "seed": 9304, "bbox": Vector2i(19, 18),
		"globals": "z3", "edges": 273,
		"row_lens": [1, 5, 7, 5, 11, 7, 11, 7, 9, 19, 9, 7, 11, 7, 11, 5, 7, 5],
	},
	{
		"file": "ani_octopus.json", "cells": 60, "mines": 8, "seed": 9304, "bbox": Vector2i(11, 10),
		"globals": "s5", "edges": 147,
		"row_lens": [3, 7, 7, 7, 7, 7, 5, 5, 7, 5],
	},
	{
		"file": "ani_mushroom.json", "cells": 166, "mines": 46, "seed": 9306, "bbox": Vector2i(15, 17),
		"globals": "s4", "edges": 574,
		"row_lens": [9, 11, 15, 15, 15, 15, 15, 15, 13, 9, 3, 5, 5, 5, 5, 7, 4],
	},
	{
		"file": "ani_fish.json", "cells": 110, "mines": 30, "seed": 9306, "bbox": Vector2i(16, 12),
		"globals": "s2", "edges": 372,
		"row_lens": [1, 3, 6, 11, 13, 15, 15, 15, 13, 11, 6, 1],
	},
	{
		"file": "ani_crab.json", "cells": 112, "mines": 31, "seed": 9311, "bbox": Vector2i(21, 12),
		"globals": "s1", "edges": 321,
		"row_lens": [8, 10, 13, 11, 9, 11, 11, 11, 13, 7, 4, 4],
	},
	{
		"file": "ani_butterfly.json", "cells": 158, "mines": 45, "seed": 9309, "bbox": Vector2i(17, 18),
		"globals": "dt", "edges": 437,
		"row_lens": [2, 3, 5, 9, 13, 13, 15, 15, 13, 11, 9, 7, 5, 9, 9, 9, 7, 4],
	},
]


# ==================== ① 动物关：产物可载入 + 逐关契约 ====================

func test_ani_files_load_as_holed_grid_boards() -> void:
	for case: Dictionary in ANI_CASES:
		var b := _board(case)
		if b == null:
			continue
		var f := str(case["file"])
		assert_true(b.grid is AdjacencyGrid, "%s 应重建异形棋盘（AdjacencyGrid）" % f)
		assert_eq(b.grid.cell_count(), int(case["cells"]), "%s 格数应与 mask 有格数一致" % f)
		assert_eq(b.grid.size(), case["bbox"], "%s 包围盒应与规格一致" % f)
		assert_eq(b.total_mines, int(case["mines"]), "%s 雷数应与规格一致" % f)
		assert_eq(int(_json(case).get("seed", -1)), int(case["seed"]),
			"%s seed 应与实跑结果一致（换 seed 次数变了这里会红灯）" % f)
		for m: Vector2i in b.get_mine_positions():
			assert_true(b.grid.in_board(m), "%s 雷位 (%d,%d) 应在盘内" % [f, m.x, m.y])


func test_ani_mask_in_json_matches_cells() -> void:
	# 与 ART 同款：产物 JSON 自带审计 mask（topology.params.mask），独立数一遍与 cells 比对。
	for case: Dictionary in ANI_CASES:
		var lv := _json(case)
		if lv.is_empty():
			pending("缺少 %s —— 先跑：%s" % [_path(case), GEN_CMD])
			continue
		var f := str(case["file"])
		var topo: Dictionary = lv.get("topology", {})
		assert_eq(str(topo.get("style", "")), "holed_grid",
			"%s topology.style 应为 holed_grid" % f)
		var mask: Array = (topo.get("params", {}) as Dictionary).get("mask", [])
		assert_eq(mask.size(), int(case["bbox"].y), "%s 审计 mask 行数应与 bbox 一致" % f)
		var filled := 0
		for row in mask:
			assert_eq(str(row).length(), int(case["bbox"].x),
				"%s 审计 mask 每行列数应与 bbox 一致" % f)
			for ch in str(row):
				if "#X1".contains(ch):
					filled += 1
		assert_eq(filled, int(case["cells"]), "%s 审计 mask 有格数应与 cells 一致" % f)
		# 图案指纹：逐行有格数（形状被改必红灯，比只比总数严格得多）
		var lens: Array = []
		for row in mask:
			var n := 0
			for ch in str(row):
				if "#X1".contains(ch):
					n += 1
			lens.append(n)
		assert_eq(lens, case["row_lens"], "%s 图案逐行有格数应与期望一致" % f)
		# globals 与产物一致（换约束时两处必须同步）
		assert_eq(_norm_globals(str(lv.get("global_rules", []))), str(case["globals"]),
			"%s 的 global_rules 应与期望变体一致" % f)


func test_ani_positions_within_bbox() -> void:
	# 不变量：所有有格必须落在 bbox 内（mask 的行列即 bbox —— build_from_mask 的硬要求）。
	# 洞格（盘外格）则**不该**出现在 topology.positions 里，故这里只钉「有格在界内」这一侧。
	for case: Dictionary in ANI_CASES:
		var lv := _json(case)
		if lv.is_empty():
			pending("缺少 %s —— 先跑：%s" % [_path(case), GEN_CMD])
			continue
		var f := str(case["file"])
		var cols := int(case["bbox"].x)
		var rows := int(case["bbox"].y)
		for p in lv.get("topology", {}).get("positions", []):
			var x := int(p["x"])
			var y := int(p["y"])
			assert_true(x >= 0 and x < cols and y >= 0 and y < rows,
				"%s 有格 (%d,%d) 应落在 bbox %d×%d 内" % [f, x, y, cols, rows])


# ==================== ② ★ SPEC ↔ 产物一致性门禁（审计核心） ====================
#
# 为什么必须有：SPECS 是生成器的可执行真值，注释不是。审计抓到的真实事故——
# ani_octopus 的 SPEC 写着 z3 / 162 格 / 15×20，产物却是 s5 / 60 格 / 11×10；
# 按脱节的 SPEC 跑批量会让该关失败，而 gen_shape_levels 的「failures > 0 ⇒ 整批不提交」
# 会让 12 个 mask 关（含刚升级的）全部无法重生成。这个门禁让同类脱节当场红灯。
#
# 实现说明：用纯字符串查找而非正则——正则里的 \s \d \\[ 在 GDScript 字符串里要双重转义，
# 是这类测试最容易写错的地方；SPEC 的格式是固定的（`"cells": 152`），直接找字面量更稳。

func test_mask_specs_match_products() -> void:
	var src := _read_text(SPEC_PATH)
	assert_ne(src, "", "应能读到生成器源码（SPECS 是生成真值）")
	if src == "":
		return
	var starts := _find_all(src, '"file": "')
	assert_gt(starts.size(), 0, "SPECS 里应有关卡块")
	var checked := 0
	for idx in starts.size():
		var at: int = starts[idx]
		var fn := _file_name_at(src, at)
		if not (fn.begins_with("ani_") or fn.begins_with("art_")):
			continue
		var nxt: int = starts[idx + 1] if idx + 1 < starts.size() else src.length()
		var block := src.substr(at, nxt - at)
		var p := LEVELS_DIR + fn
		if not FileAccess.file_exists(p):
			continue    # 产物缺失由其它测试用 pending 表达，这里不重复报警
		var lv := _json_path(p)
		var cells := (lv.get("topology", {}).get("positions", []) as Array).size()
		var mines_arr: Variant = lv.get("mines", [])
		var mines: int = (mines_arr as Array).size() if mines_arr is Array else int(mines_arr)
		assert_eq(_spec_int(block, "cells"), cells,
			"%s：SPEC 的 cells 应与产物格数一致（SPEC 是生成真值——脱节会让批量生成整批失败）" % fn)
		assert_eq(_spec_int(block, "mines"), mines,
			"%s：SPEC 的 mines 应与产物雷数一致" % fn)
		# 两侧都必须归一：SPEC 侧是 `"s2"`（带引号）、产物侧是 `["s2"]`（str 化的数组），
		# 归一后都成 `s2` 才能比——首版漏了左侧归一，门禁自己先抓到这个 bug。
		assert_eq(_spec_str(block, "name"), str(lv.get("name", "")),
			"%s：SPEC 的 name 应与产物一致（曾出现子卡写精灵名「小鱼 · 稳稳」、同屏父卡写规则名「重心」的两套名字并存）" % fn)
		assert_eq(_norm_globals(_spec_globals(block)), _norm_globals(str(lv.get("global_rules", []))),
			"%s：SPEC 的 globals 应与产物 global_rules 一致（换约束必须两处同步）" % fn)
		checked += 1
	assert_gt(checked, 0, "应至少核到一个 mask 关的 SPEC 块")


# ==================== 辅助 ====================

func _path(case: Dictionary) -> String:
	return LEVELS_DIR + str(case["file"])


func _board(case: Dictionary) -> Board:
	var p := _path(case)
	if not FileAccess.file_exists(p):
		pending("缺少 %s —— 先跑：%s" % [p, GEN_CMD])
		return null
	var b: Board = LevelLoader.load_level(p)
	assert_not_null(b, "%s 应能被 LevelLoader.load_level 载入" % str(case["file"]))
	return b


func _json(case: Dictionary) -> Dictionary:
	return _json_path(_path(case))


func _json_path(p: String) -> Dictionary:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _read_text(p: String) -> String:
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


## 源码里所有 needle 的起始下标。
func _find_all(src: String, needle: String) -> Array:
	var out: Array = []
	var i := src.find(needle)
	while i >= 0:
		out.append(i)
		i = src.find(needle, i + needle.length())
	return out


## 从 `"file": "` 的起始位置取出文件名。
func _file_name_at(src: String, at: int) -> String:
	var pre := '"file": "'
	var i := src.find(pre, at)
	if i < 0 or i - at > 8:
		return ""
	i += pre.length()
	var j := src.find('"', i)
	return src.substr(i, j - i) if j > i else ""


## SPEC 块里 `"key": 123` 的整数（块内取第一个；找不到返回 -1）。
func _spec_int(block: String, key: String) -> int:
	var pat := '"%s": ' % key
	var i := block.find(pat)
	if i < 0:
		return -1
	i += pat.length()
	var j := i
	while j < block.length() and block[j] >= "0" and block[j] <= "9":
		j += 1
	return int(block.substr(i, j - i)) if j > i else -1


## SPEC 块里 `"globals": [...]` 的内容（无该键 = 经典，返回空串）。
func _spec_globals(block: String) -> String:
	var pat := '"globals": ['
	var i := block.find(pat)
	if i < 0:
		return ""
	i += pat.length()
	var j := block.find("]", i)
	return block.substr(i, j - i) if j > i else ""


## SPEC 块里 `"key": "value"` 的字符串（找不到返回空串）。
func _spec_str(block: String, key: String) -> String:
	var pat := '"%s": "' % key
	var i := block.find(pat)
	if i < 0:
		return ""
	i += pat.length()
	var j := block.find('"', i)
	return block.substr(i, j - i) if j > i else ""


## 归一化变体列表：`["s2"]` / [s2] / "s2" 都化成 `s2`（多值用逗号连接）。
func _norm_globals(s: String) -> String:
	return s.replace('"', "").replace("[", "").replace("]", "").replace(" ", "").replace("&", "")
