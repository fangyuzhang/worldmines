extends GutTest

## 关卡格式内核 · **接入层** 单测：`core/level_sets.gd` / `core/workshop_pack.gd` 如何用 `core/level_format.gd`。
##
## 钉住的不变量（坏一条，玩家侧或编辑器就会踩坑）：
##   ① 写→读往返：结果层能直接开局、设计层能回编辑；
##   ② **设计层缺失 / 损坏时结果层仍可加载**（文档硬要求：故障隔离在编辑侧，不传染给玩家）；
##   ③ 迁移：v1/v2 老文件读入**自动升级且旧字段不丢**；未知更高版本**拒载 + 可读原因**（不许猜）；
##   ④ 超预算写入**被拒且有可读原因**（不静默写半份坏集）；
##   ⑤ **包内布局**（`levels/...` 结果层 + `design/...` 设计层）与读取方一致——
##      写/读共用同一组常量，断言覆盖"写出去"与"读回来"两侧。

const ROOT := "user://test_lfi_root"
const OUT_DIR := "user://test_lfi_out"


func before_each() -> void:
	_rmrf(ROOT)
	_rmrf(OUT_DIR)


func after_each() -> void:
	_rmrf(ROOT)
	_rmrf(OUT_DIR)


## 一份同时带"结果字段"与"设计字段"的关卡文档（用经典规则，便于真喂 Board）。
func _doc() -> Dictionary:
	return {
		"version": LevelFormat.CURRENT_VERSION,
		"name": "我的分层盘",
		"size": {"rows": 8, "cols": 8},
		"total_mines": 2,
		"mines": [{"r": 0, "c": 0}, {"r": 2, "c": 3}],
		"revealed": [{"r": 1, "c": 1}],
		"difficulty_profile": {"max_complexity": 4, "difficulty": 1.0},
		"cells": [
			{"r": 0, "c": 0, "mine": true, "prototype_id": "hex6",
				"transform": {"tx": 0.5, "ty": 0.25, "rot": 60, "flip": 0}},
			{"r": 2, "c": 3, "mine": true, "manual_identity": "hand-1"},
			{"r": 1, "c": 1},
		],
		"prototypes": {"hex6": {"vertices": [{"x": 0.5, "y": 0.0}, {"x": 1.0, "y": 0.8660254}]}},
		# —— 设计层字段 ——
		"shape_kind": "hex",
		"shape_params": {"size": 4},
		"generation": {"seed": 12345},
		"notes": "手改过一格",
	}


## 批量用的一关（只有结果字段 + 难度画像）。
func _b_lv(peak: int, r: int, c: int) -> Dictionary:
	return {"size": {"rows": 8, "cols": 8}, "total_mines": 1, "mines": [{"r": r, "c": c}],
		"revealed": [], "difficulty_profile": {"max_complexity": peak, "difficulty": 1.0}}


# ==================== ① 写→读往返：结果层可开局、设计层可回编辑 ====================

func test_write_read_round_trip_result_playable_design_editable() -> void:
	var path := ROOT + "/levels/8/easy.json"
	assert_true(LevelSets.write_set(path, "z1", 8, "easy", [_doc()]), "写集文件应成功")

	# 磁盘上确实是分层信封（而不是整份 doc 落盘）
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_eq((raw["levels"] as Array).size(), 1, "集内应有一关")
	var env: Dictionary = (raw["levels"] as Array)[0]
	assert_true(LevelSets.is_envelope(env), "集内关卡应以 `{version, result, design}` 分层信封落盘")

	# ①-结果层：不含任何设计字段，且能直接开局
	var result: Dictionary = env["result"]
	for k in LevelFormat.DESIGN_KEYS:
		assert_false(result.has(k), "结果层不得含设计字段：%s" % str(k))
	var play := LevelSets.playable(env)
	assert_false(play.is_empty(), "结果层必须能转成可开局的关卡")
	assert_eq(int(play["total_mines"]), 2, "开局雷数要对")
	assert_eq((play["mines"] as Array).size(), int(play["total_mines"]),
		"mines 必须与 total_mines 对齐（否则 LevelLoader 会拒载）")
	var b := Board.new()
	b.load_level(play)
	assert_eq(b.get_mine_positions().size(), 2, "结果层直接喂 Board.load_level 后雷位一致")

	# ①-设计层：形状族 / 参数 / 生成参数 / 备注都能回编辑
	var set := LevelSets.read_set(path)
	var design: Dictionary = (set["designs"] as Array)[0]
	assert_eq(str(design.get("shape_kind", "")), "hex", "设计层要带形状族")
	assert_eq(int((design.get("shape_params", {}) as Dictionary).get("size", 0)), 4, "设计层要带形状参数")
	assert_eq(int((design.get("generation", {}) as Dictionary).get("seed", 0)), 12345, "设计层要带生成种子")
	assert_eq(str(design.get("notes", "")), "手改过一格", "设计层要带备注")
	# 平铺回读把设计字段合回（编辑器据此可继续编辑）
	assert_eq(str((set["levels"] as Array)[0].get("shape_kind", "")), "hex",
		"回读的关卡要合回设计字段（否则编辑器无法再编辑）")
	# 结果层要带本仓游戏侧真正会读、而 LevelFormat 默认没覆盖的键（难度画像）
	assert_eq(LevelSets.tier_of_level((set["levels"] as Array)[0]), "normal",
		"结果层要带 difficulty_profile（难度唯一真源，分组与显示都靠它）")


# ==================== ② 设计层缺失 / 损坏 ⇒ 结果层仍可加载 ====================

func test_missing_or_corrupt_design_still_loads_result() -> void:
	# 设计层是垃圾字符串
	var env := LevelSets.envelope(_doc())
	env["design"] = "这不是字典（设计层损坏）"
	assert_eq(int(LevelSets.playable(env).get("total_mines", -1)), 2, "设计层损坏也必须能只读结果层开局")
	# 设计层整个缺失
	env.erase("design")
	assert_eq(int(LevelSets.playable(env).get("total_mines", -1)), 2, "设计层缺失也必须能开局")

	# 落成一个"设计层损坏"的集文件后，读取方仍能拿到可玩关卡
	var path := ROOT + "/levels/8/broken_design.json"
	_write_text(path, JSON.stringify({"schema": LevelSets.SCHEMA, "version": LevelFormat.CURRENT_VERSION,
		"mode": "z1", "size": 8, "tier": "easy", "count": 1, "levels": [env]}))
	var rep := LevelSets.read_set_report(path)
	assert_true(bool(rep["ok"]), "设计层坏了不该让整集拒载：%s" % str(rep["reason"]))
	var got: Dictionary = rep["set"]
	assert_eq((got["levels"] as Array).size(), 1, "设计层坏了也要能读出结果层")
	assert_eq(((got["levels"] as Array)[0] as Dictionary)["mines"].size(), 2, "读到的是可开局的结果层")
	assert_true((got["designs"] as Array)[0] is Dictionary, "损坏的设计层要收敛成空字典，不污染回读")


# ==================== ③ 迁移：老格式自动升级、旧字段不丢；更高版本拒载 ====================

func test_old_format_migrates_and_preserves_fields() -> void:
	# v1 单关：schema=1 + rows/cols + mines，没有 v2 的 size/revealed、也没有 v3 的 cells
	var v1 := {"schema": 1, "name": "老关", "rows": 5, "cols": 5,
		"mines": [{"r": 1, "c": 1}], "legacy_tag": "x"}
	var single := ROOT + "/old_v1_level.json"
	_write_text(single, JSON.stringify(v1))
	var rep := LevelSets.read_level_report(single)
	assert_true(bool(rep["ok"]), "v1 老文件应能读入：%s" % str(rep["reason"]))
	var lv: Dictionary = rep["level"]
	assert_eq(int((lv["size"] as Dictionary)["rows"]), 5, "应自动补出 size")
	assert_eq(int(lv.get("total_mines", -1)), 1, "应自动补出 total_mines")
	assert_true(lv.get("cells", null) is Array, "应自动补出 v3 的 cells")
	assert_eq(int(lv.get("version", 0)), LevelFormat.CURRENT_VERSION, "应升级到当前版本")
	# 旧字段一个都不能丢
	assert_eq(str(lv.get("legacy_tag", "")), "x", "未识别旧字段不许丢")
	assert_eq(int(lv.get("schema", 0)), 1, "旧 schema 不许被改写")
	assert_eq(int(lv.get("rows", 0)), 5, "旧 rows 不许丢")
	assert_eq(str(lv.get("name", "")), "老关", "旧 name 不许丢")

	# v2 老集文件（levels[] 是平铺关卡）
	var old_set := {"schema": 2, "mode": "z1", "size": 5, "tier": "easy", "count": 1,
		"levels": [v1.duplicate(true)]}
	var sp := ROOT + "/levels/5/easy.json"
	_write_text(sp, JSON.stringify(old_set))
	var got := LevelSets.read_set(sp)
	assert_eq((got["levels"] as Array).size(), 1, "老集文件仍要能读")
	assert_eq(str((got["levels"] as Array)[0].get("legacy_tag", "")), "x", "老集内旧字段不许丢")
	assert_eq(LevelSets.size_of((got["levels"] as Array)[0]), 5, "老集内关卡尺寸要对")


func test_unknown_higher_version_is_refused_with_reason() -> void:
	var fut := {"version": LevelFormat.CURRENT_VERSION + 96, "size": {"rows": 3, "cols": 3},
		"mines": [], "revealed": []}
	var p := ROOT + "/future.json"
	_write_text(p, JSON.stringify(fut))
	var rep := LevelSets.read_level_report(p)
	assert_false(bool(rep["ok"]), "更高版本必须拒载（不许猜语义）")
	assert_true(str(rep["reason"]).find("%d" % int(fut["version"])) != -1,
		"原因要写清拒绝的版本号：%s" % str(rep["reason"]))
	assert_true(str(rep["reason"]).find("拒绝") != -1, "原因要是人话：%s" % str(rep["reason"]))
	assert_true(LevelSets.read_level(p).is_empty(), "普通入口也拿不到关卡")

	# 集文件层面的更高版本同样拒载
	var fs := {"version": LevelFormat.CURRENT_VERSION + 1, "mode": "z1", "size": 3,
		"tier": "easy", "count": 0, "levels": []}
	var sp := ROOT + "/levels/3/easy.json"
	_write_text(sp, JSON.stringify(fs))
	var srep := LevelSets.read_set_report(sp)
	assert_false(bool(srep["ok"]), "更高版本集文件必须拒载")
	assert_true(str(srep["reason"]).find("拒绝") != -1, "集文件拒载也要有可读原因：%s" % str(srep["reason"]))


# ==================== ④ 超预算写入被拒且有原因 ====================

func test_over_budget_write_is_rejected_with_reason() -> void:
	var cells: Array = []
	for i in 5001:
		cells.append({"r": i, "c": 0})
	var big := {"size": {"rows": 1, "cols": 5001}, "total_mines": 0, "mines": [],
		"revealed": [], "cells": cells}
	var path := ROOT + "/levels/1/over.json"
	var rep := LevelSets.write_set_report(path, "z1", 1, "easy", [big])
	assert_false(bool(rep["ok"]), "超预算写入必须被拒")
	assert_true(str(rep["reason"]).find("5000") != -1, "原因要写清格数上限：%s" % str(rep["reason"]))
	assert_false(FileAccess.file_exists(path), "被拒时不许留下半份文件")

	var mrep := LevelSets.materialize_report(big, "over", ROOT + "/play")
	assert_false(bool(mrep["ok"]), "物化超预算关卡也必须被拒")
	assert_true(str(mrep["reason"]).find("5000") != -1, "物化拒绝也要有可读原因：%s" % str(mrep["reason"]))
	assert_eq(LevelSets.materialize(big, "over", ROOT + "/play"), "", "普通入口返回空路径")


# ==================== ⑤ 包内布局与读取方一致（同一份断言覆盖写与读两侧）====================

func test_pack_layout_matches_reader_sides() -> void:
	# 目录名只有一份真源：写入方（WorkshopPack）与读取方（LevelSets）必须一致。
	assert_eq(WorkshopPack.LEVELS_DIR, LevelSets.LEVELS_DIR, "结果层目录名不许两处各写一份")
	assert_eq(WorkshopPack.DESIGN_DIR, LevelSets.DESIGN_DIR, "设计层目录名不许两处各写一份")

	# —— 单关包：levels/<slug>.json（结果层） + design/<slug>.json（设计层） ——
	var doc := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(2, 2)]:
		doc.mines.append(m)
	doc.title = "分层包测试"
	var built := WorkshopPack.build(doc, {"id": "lfi_single", "title": "分层包测试", "dir": OUT_DIR})
	assert_true(bool(built["ok"]), "单关包应生成成功：%s" % str(built["reason"]))
	assert_true(int(built.get("est_bytes", -1)) > 0, "打包体积预估应走 LevelFormat.estimate_bytes")
	var names := _names(str(built["path"]))
	var slug := "level"	# 中文标题 ⇒ slug 回退（与既有工坊包测试同口径）
	var lname := "%s/%s.json" % [LevelSets.LEVELS_DIR, slug]
	var dname := "%s/%s.json" % [LevelSets.DESIGN_DIR, slug]
	assert_true(names.has(lname), "结果层应在包内：%s ｜ 实际=%s" % [lname, str(names)])
	assert_true(names.has(dname), "设计层应在包内：%s ｜ 实际=%s" % [dname, str(names)])

	# 读取侧：装到磁盘后，结果层文件**单独**就能开局（设计层不参与）
	var dst := OUT_DIR + "/mods"
	var ins := WorkshopPack.install_from_zip(str(built["path"]), dst)
	assert_true(bool(ins["ok"]), "单关包安装应成功：%s" % str(ins["reason"]))
	var mod_dir := str(ins["mod_dir"])
	var lv := LevelSets.read_level(mod_dir.path_join(lname))
	assert_false(lv.is_empty(), "装完的结果层文件应能读成关卡")
	assert_eq((lv["mines"] as Array).size(), int(lv["total_mines"]),
		"包内结果的 mines 必须与 total_mines 对齐（LevelLoader 口径）")
	var b := Board.new()
	b.load_level(lv)
	assert_eq(b.get_mine_positions().size(), 2, "结果层可直接开局（不需要设计层在场）")
	var design := LevelSets.read_level(mod_dir.path_join(dname))
	assert_eq(str(design.get("name", "")), "分层包测试", "设计层应带名称（编辑器可回编辑）")

	# —— 批量包：levels/<大小>/<档位>.json 与 design/<大小>/<档位>.json 同构并列 ——
	var stage := OUT_DIR + "/stage"
	_write_text(stage + "/levels/8/easy.json", JSON.stringify({"schema": 1, "mode": "z1", "size": 8,
		"tier": "easy", "count": 2, "levels": [_b_lv(2, 1, 1), _b_lv(3, 2, 2)]}))
	var batch := WorkshopPack.build(doc, {"id": "lfi_batch", "title": "批量分层", "dir": OUT_DIR,
		"levels_dirs": [stage + "/levels"]})
	assert_true(bool(batch["ok"]), "批量包应生成成功：%s" % str(batch["reason"]))
	var bn := _names(str(batch["path"]))
	assert_true(bn.has("levels/8/easy.json"), "批量结果层应在：%s" % str(bn))
	assert_true(bn.has("design/8/easy.json"), "批量设计层应在：%s" % str(bn))

	var bdst := OUT_DIR + "/bmods"
	var bins := WorkshopPack.install_from_zip(str(batch["path"]), bdst)
	assert_true(bool(bins["ok"]), "批量包安装应成功：%s" % str(bins["reason"]))
	var got := LevelSets.collect(str(bins["mod_dir"]).path_join(LevelSets.LEVELS_DIR))
	assert_true(bool(got["ok"]), "装完的结果层目录应能被玩家侧读取：%s" % str(got["reason"]))
	assert_eq(int(got["count"]), 2, "两关都要读出来")
	assert_eq((((got["groups"]["8"] as Dictionary)["easy"]) as Array).size(), 2, "8×8 普通应有 2 关")


# ==================== 工具 ====================

func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _names(zip_path: String) -> Array[String]:
	var out: Array[String] = []
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return out
	for f in zr.get_files():
		out.append(str(f))
	zr.close()
	return out


func _rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_rmrf(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)
