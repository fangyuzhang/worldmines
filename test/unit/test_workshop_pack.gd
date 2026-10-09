# test_workshop_pack.gd —— 本地 workshop 包生成器（P3）自证
#
# 钉住的不变量：
#   1) 包内布局与 mod 目录一致（manifest / entry.gd / levels/*.json / board.json / preview.png）；
#   2) **写出去能读回来**：条目回读核对 + manifest 过仓库自己的 `ManifestParser`；
#   3) 包内关卡能被 `EditorDoc.load_from` 读回（含随包携带的规格）；
#   4) `board.json` 用 mod 约定形式（positions + adjacency）且能喂回 `AdjacencyGrid`；
#   5) 入口脚本离线自洽（内联规格 + 幂等 + 契约 return true）；
#   6) 非法文档**拒绝打包**；Steam 占位**永不返回假成功**。
extends GutTest

const OUT_DIR := "user://test_workshop_out"


func after_each() -> void:
	var d := DirAccess.open(OUT_DIR)
	if d != null:
		for f in d.get_files():
			DirAccess.remove_absolute(OUT_DIR.path_join(f))


func _doc() -> EditorDoc:
	var d := EditorDoc.new(5, 5)
	for m in [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)]:
		d.mines.append(m)
	d.title = "包测试关卡"
	d.revealed[Vector2i(1, 1)] = null
	return d


func _classic_spec(id: String) -> Dictionary:
	var refs: Array = []
	for dd in ClueEngine.ring_dirs():
		refs.append({"dx": dd.x, "dy": dd.y})
	var xs: Array = []
	for i in refs.size():
		xs.append({"t": "ref", "i": i})
	return {
		"spec_version": 1, "id": id, "title": "打包测试用经典8邻", "geometry": "rect_only",
		"clue": {"refs": refs, "expr": {"t": "sum", "xs": xs}},
	}


# ==================== P6 批量：分类随包走、装完已分类 ====================
#
# 用户原话："不要生成后就是一堆关卡放在那" + "上传创意工坊要把分类也传进去，下载到本地也要已经分类"。
# 这条用例走**真实链路**：批量产出目录 → 打包 → 安装 → 玩家侧读取器分组。

func _p6_write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _p6_lv(peak: int, r: int, c: int) -> Dictionary:
	return {"size": {"rows": 8, "cols": 8}, "total_mines": 1, "mines": [{"r": r, "c": c}],
		"revealed": [], "difficulty_profile": {"max_complexity": peak, "difficulty": 1.0}}


func _p6_rmrf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_p6_rmrf(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)


func test_batch_pack_carries_categories_and_installs_classified() -> void:
	var stage := "user://test_batch_stage"
	var levels := stage + "/levels"
	_p6_rmrf(stage)
	_p6_write(levels + "/8/easy.json", JSON.stringify({"schema": 1, "mode": "z1", "size": 8,
		"tier": "easy", "count": 2, "levels": [_p6_lv(2, 1, 1), _p6_lv(3, 2, 2)]}))
	_p6_write(levels + "/9/hard.json", JSON.stringify({"schema": 1, "mode": "z1", "size": 9,
		"tier": "hard", "count": 1, "levels": [_p6_lv(7, 3, 3)]}))
	_p6_write(stage + "/tutorial/tutorial_spec_z1_0.txt", "q\tq\n? 数字 = 周围 8 格的雷数。\n")

	var got := WorkshopPack.build(_doc(), {
		"id": "batch_pack_test", "title": "批量测试包", "dir": OUT_DIR,
		"description": "批量关卡包",
		"extra_manifest": {"categories": {"schema": 1, "8": {"easy": 2}, "9": {"hard": 1}}},
		"levels_dirs": [levels], "tutorial_dirs": [stage + "/tutorial"],
	})
	assert_true(bool(got["ok"]), "批量包应生成成功：%s" % str(got["reason"]))
	var names := _names(str(got["path"]))
	assert_true(names.has("levels/8/easy.json"), "集文件要按「大小/档位」进包：%s" % str(names))
	assert_true(names.has("levels/9/hard.json"), "第二个大小也要在：%s" % str(names))
	assert_true(names.has("tutorial/tutorial_spec_z1_0.txt"), "图文图例要随包走：%s" % str(names))
	assert_false(names.has("levels/包测试关卡.json"), "给了 levels_dirs 就不该再塞单关（免得重复）")
	# 「当前盘」的产物不该混进批量包：真机实测用户盘是一张校验不过的试验盘，
	# 而批量包的内容只跟 levels/ 下的分类关卡集有关（下面两条也是防止我"顺手删码"的钉子）。
	assert_false(names.has("preview.png"), "批量包不该带「当前盘」的预览图")
	assert_false(names.has("board.json"), "批量包不该带「当前盘」的棋盘拓扑")
	# 审查修 A5（真 bug）：批量目录**收不到文件**时，原来只凭"传了 levels_dirs 这个 key"就进批量模式 ⇒
	# 跳过校验 + 丢掉 board.json/preview.png，却把当前盘当单关塞进去 ⇒ 打出一个坏包。现在必须直接失败。
	var bad := WorkshopPack.build(_doc(), {"id": "batch_empty", "title": "空批量包", "dir": OUT_DIR,
		"levels_dirs": ["user://__不存在的批量目录__"]})
	assert_false(bool(bad["ok"]), "批量目录收不到关卡文件时必须失败，而不是打出坏包")
	assert_true(str(bad["reason"]).find("没有找到关卡文件") != -1,
		"理由要点明「目录里没有关卡文件」：%s" % str(bad["reason"]))

	var zr := ZIPReader.new()
	assert_eq(zr.open(str(got["path"])), OK, "zip 应能打开")
	var parsed: Variant = JSON.parse_string(zr.read_file("manifest.json").get_string_from_utf8())
	zr.close()
	assert_true(parsed is Dictionary, "manifest 应是 JSON 对象")
	if parsed is Dictionary:
		var man: Dictionary = parsed
		assert_eq(int((man.get("categories", {}) as Dictionary).get("8", {}).get("easy", 0)), 2,
			"分类索引要随 manifest 走（上传带分类）")

	# 装到玩家机器上：**目录层级必须保留**，否则玩家侧又变成一堆平铺关卡
	var dst := "user://test_batch_mods"
	_p6_rmrf(dst)
	var ins := WorkshopPack.install_from_zip(str(got["path"]), dst)
	assert_true(bool(ins["ok"]), "安装应成功：%s" % str(ins["reason"]))
	var mod_dir := str(ins["mod_dir"])
	assert_true(FileAccess.file_exists(mod_dir + "/levels/8/easy.json"), "装完应有 8/easy 集文件")
	assert_true(FileAccess.file_exists(mod_dir + "/tutorial/tutorial_spec_z1_0.txt"), "装完应有图例")
	# 端到端：**玩家侧读取器**在安装后的目录上要能分出大小与档位（下载后已分类）
	var got2 := LevelSets.collect(mod_dir + "/levels")
	assert_true(bool(got2["ok"]), "安装后的 levels 目录应能被玩家侧读取：%s" % str(got2["reason"]))
	assert_eq(int(got2["count"]), 3, "3 关都要读出来")
	assert_eq(got2["sizes"], [8, 9], "大小轴应升序")
	assert_eq((((got2["groups"]["8"] as Dictionary)["easy"]) as Array).size(), 2, "8×8 普通 2 关")
	assert_eq((((got2["groups"]["9"] as Dictionary)["hard"]) as Array).size(), 1, "9×9 噩梦 1 关")
	_p6_rmrf(stage)
	_p6_rmrf(dst)


func test_batch_pack_refuses_too_many_files_with_a_clear_reason() -> void:
	# 为什么批量必须用集文件：安装侧上限是 64 个文件，一关一文件必然撞它。
	# 撞墙时要**当场拒绝并说清原因**，而不是让玩家装完才发现少了关卡。
	var stage := "user://test_over_files/levels/8"
	_p6_rmrf("user://test_over_files")
	for i in WorkshopPack.MAX_INSTALL_FILES + 1:
		_p6_write("%s/l%02d.json" % [stage, i], JSON.stringify(_p6_lv(2, i, i)))
	var got := WorkshopPack.build(_doc(), {"id": "too_many", "title": "超量包", "dir": OUT_DIR,
		"levels_dirs": [stage]})
	assert_false(bool(got["ok"]), "文件数超上限必须拒绝打包")
	assert_true(str(got["reason"]).find("上限") != -1,
		"拒绝原因要说清上限与解法：%s" % str(got["reason"]))
	_p6_rmrf("user://test_over_files")


func _names(zip_path: String) -> Array[String]:
	var out: Array[String] = []
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return out
	for f in zr.get_files():
		out.append(str(f))
	zr.close()
	return out


func _text(zip_path: String, name: String) -> String:
	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return ""
	var b := zr.read_file(name)
	zr.close()
	return b.get_string_from_utf8()


# ==================== 1. 打包 + 回读 ====================

func test_build_pack_contains_expected_entries() -> void:
	var doc := _doc()
	var sid := "spec_pack_%d" % randi()
	doc.rule_spec = _classic_spec(sid)
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(r["ok"]), "打包应成功：%s" % str(r["reason"]))
	var zip_path := str(r["path"])
	assert_true(FileAccess.file_exists(zip_path), "zip 应真的落盘：%s" % zip_path)

	var names := _names(zip_path)
	assert_true(names.has("manifest.json"), "应含 manifest：%s" % str(names))
	assert_true(names.has("entry.gd"), "应含入口脚本")
	assert_true(names.has("preview.png"), "应含预览图")
	assert_true(names.has("levels/level.json"), "应含关卡（标题含中文时 slug 回退为 level）：%s" % str(names))
	assert_false(names.has("board.json"), "默认矩形盘不该写 board.json")


func test_manifest_passes_repo_parser() -> void:
	var doc := _doc()
	doc.rule_spec = _classic_spec("spec_pack_manifest_%d" % randi())
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(r["ok"]), "打包应成功：%s" % str(r["reason"]))
	var zip_path := str(r["path"])
	var mp := ManifestParser.new()
	var mv := mp.parse(_text(zip_path, "manifest.json"))
	assert_true(bool(mv["ok"]), "包内 manifest 必须过仓库校验器：%s" % str(mv["reason"]))
	var m: Dictionary = mv["manifest"]
	assert_eq(str(m["id"]), str(r["id"]), "manifest id 应与包 id 一致")
	assert_eq(str((m["entry"] as Dictionary)["runtime"]), "gdscript", "入口运行时为 gdscript")
	assert_eq(str((m["entry"] as Dictionary)["path"]), "entry.gd", "入口路径")


func test_level_inside_pack_round_trips() -> void:
	var doc := _doc()
	var sid := "spec_pack_rt_%d" % randi()
	doc.rule_spec = _classic_spec(sid)
	doc.revealed[Vector2i(3, 3)] = null
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(r["ok"]), "打包应成功：%s" % str(r["reason"]))
	var lvl: Variant = JSON.parse_string(_text(str(r["path"]), "levels/level.json"))
	assert_true(lvl is Dictionary, "包内关卡应是合法 JSON 对象")
	var back := EditorDoc.new()
	assert_true(bool(back.load_from(lvl)["ok"]), "包内关卡应能被文档模型读回")
	assert_eq(back.mines.size(), 3, "雷位往返")
	assert_eq(back.revealed.size(), 2, "初始翻开集合往返")
	assert_eq(str(back.rule_spec.get("id", "")), sid, "规格随包携带（离线自洽）")


func test_wrap_doc_writes_board_json_in_mod_convention() -> void:
	var doc := _doc()
	doc.wrap = true
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(r["ok"]), "打包应成功：%s" % str(r["reason"]))
	var zip_path := str(r["path"])
	assert_true(_names(zip_path).has("board.json"), "非默认邻域应写 board.json")
	var bj: Variant = JSON.parse_string(_text(zip_path, "board.json"))
	assert_true(bj is Dictionary, "board.json 应是 JSON 对象")
	var b: Dictionary = bj
	assert_true(b.has("positions") and b.has("adjacency"),
		"board.json 用 mod_api 约定形式（positions + adjacency）：%s" % str(b.keys()))
	var ag := AdjacencyGrid.new()
	ag.setup_from_topo(b)
	assert_eq(ag.cell_count(), 25, "环绕盘 25 格")
	assert_true(bool(AdjacencyBuilder.audit(ag)["ok"]), "包内 board.json 应通过审计器")


func test_entry_script_is_offline_self_contained() -> void:
	var doc := _doc()
	var sid := "spec_pack_entry_%d" % randi()
	doc.rule_spec = _classic_spec(sid)
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(r["ok"]), "打包应成功：%s" % str(r["reason"]))
	var entry := _text(str(r["path"]), "entry.gd")
	assert_true(entry.find(sid) != -1, "入口脚本应内联规格 id（不依赖作者机器状态）")
	assert_true(entry.find("register_from_json") != -1, "入口脚本应注册规格")
	assert_true(entry.find("func on_load() -> bool:") != -1, "入口契约：on_load 返回 bool")
	assert_true(entry.find("return true") != -1, "入口契约：必须能 return true")


func test_preview_png_is_a_real_png() -> void:
	var bytes := WorkshopPack.preview_png_bytes(_doc())
	assert_gt(bytes.size(), 0, "应产出预览图字节")
	assert_eq(int(bytes[0]), 0x89, "PNG magic 首字节应为 0x89")
	assert_eq(int(bytes[1]), 0x50, "PNG magic 次字节应为 'P'")
	assert_eq(int(bytes[2]), 0x4E, "PNG magic 第三字节应为 'N'")


# ==================== 2. 拒绝与占位 ====================

func test_refuses_to_pack_an_invalid_doc() -> void:
	var doc := EditorDoc.new(5, 5)   # 没放雷 ⇒ 校验不过
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_false(bool(r["ok"]), "非法文档不得打包（否则等于把坏关卡发给玩家）")
	assert_true(str(r["reason"]).find("校验") != -1, "理由应点明校验：%s" % str(r["reason"]))


func test_install_from_zip_lands_in_mods_dir() -> void:
	# 安装闭环：生成包 → 解包进 user://mods/<id>/ → 目录结构齐备、manifest 仍合法。
	var doc := _doc()
	var sid := "spec_pack_install_%d" % randi()
	doc.rule_spec = _classic_spec(sid)
	var built := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(built["ok"]), "打包应成功：%s" % str(built["reason"]))
	var r := WorkshopPack.install_from_zip(str(built["path"]))
	assert_true(bool(r["ok"]), "安装应成功：%s" % str(r["reason"]))
	var dest := str(r["mod_dir"])
	assert_true(dest.begins_with("user://mods/"), "应装进 user://mods/：%s" % dest)
	assert_true(FileAccess.file_exists(dest.path_join("manifest.json")), "装完应有 manifest")
	assert_true(FileAccess.file_exists(dest.path_join("entry.gd")), "装完应有入口脚本")
	assert_true(FileAccess.file_exists(dest.path_join("levels/level.json")), "装完应有自带的关卡")
	var mp := ManifestParser.new()
	assert_true(bool(mp.parse(FileAccess.get_file_as_string(dest.path_join("manifest.json")))["ok"]),
		"装完的 manifest 仍须过校验器")
	# 再装一次：必须拒绝覆盖（同名目录已存在）
	var again := WorkshopPack.install_from_zip(str(built["path"]))
	assert_false(bool(again["ok"]), "同名 Mod 目录已存在时必须拒绝覆盖")
	assert_true(str(again["reason"]).find("已存在") != -1, "理由应点明已存在：%s" % str(again["reason"]))
	# 清理（目录名即包 id）
	var id := str(built["id"])
	_remove_dir(dest)
	assert_false(DirAccess.dir_exists_absolute(dest), "清理后目录应消失（id=%s）" % id)


func test_install_rejects_pack_without_root_manifest() -> void:
	var zip_path := OUT_DIR.path_join("no_manifest.zip")
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var zp := ZIPPacker.new()
	assert_eq(zp.open(zip_path), OK, "应能建 zip")
	zp.start_file("levels/level.json")
	zp.write_file("{}".to_utf8_buffer())
	zp.close_file()
	zp.close()
	var r := WorkshopPack.install_from_zip(zip_path)
	assert_false(bool(r["ok"]), "没有根级 manifest 的包必须被拒")
	assert_true(str(r["reason"]).find("manifest") != -1, "理由应点明 manifest：%s" % str(r["reason"]))
	DirAccess.remove_absolute(zip_path)


func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_remove_dir(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)


func test_steam_placeholder_never_claims_success() -> void:
	var r := SteamWorkshop.publish_pack("user://whatever.zip", "标题", "说明")
	assert_false(bool(r["ok"]), "未集成 Steamworks 时绝不得返回成功（假成功比没功能更坏）")
	assert_true(str(r["reason"]).find("手动上传") != -1,
		"应给出「请手动上传」的明确提示：%s" % str(r["reason"]))
	assert_eq(str(r["path"]), "user://whatever.zip", "应原样带回包路径供 UI 显示")
	# code 与环境自洽：本仓带 godotsteam 插件 ⇒ 某些环境里单例存在（此时 code=not_implemented）。
	# 断言"必须是 no_steam"等于把**环境差异**写成契约，换台机器就假红——故只断言二者之一，
	# 且与 `plugin_present()` 的返回值一致。
	var code := str(r["code"])
	assert_true(code == "no_steam" or code == "not_implemented",
		"code 只能是 no_steam / not_implemented：%s" % code)
	assert_eq(bool(r["plugin_present"]), SteamWorkshop.plugin_present(),
		"上报的插件状态必须与探测函数一致")
	assert_eq(code, "not_implemented" if SteamWorkshop.plugin_present() else "no_steam",
		"code 必须与插件是否存在自洽")


func test_default_output_dir_is_under_user() -> void:
	assert_true(WorkshopPack.default_dir().begins_with("user://"),
		"默认输出目录应在 user:// 下（可写、不入 res:// 版本库）：%s" % WorkshopPack.default_dir())

# ==================== 只读分享（文档 §8）====================
# 分享包是**文件形式**：它没有短码那样的 flags 位，所以声明走**设计层**（`editor_meta.read_only`）。
# 这条用例同时钉两件事：① 声明真的写进设计层；② 结果层**不许**夹带设计层字段（两层契约）。

func test_read_only_pack_stamps_the_design_layer_only() -> void:
	var doc := _doc()
	doc.rule_spec = _classic_spec("spec_pack_ro_%d" % randi())
	var r := WorkshopPack.build(doc, {"dir": OUT_DIR, "read_only": true})
	assert_true(bool(r["ok"]), "打包应成功：%s" % str(r["reason"]))
	var zip_path := str(r["path"])
	var design: Variant = JSON.parse_string(_text(zip_path, "design/level.json"))
	assert_true(design is Dictionary, "设计层应是合法 JSON 对象")
	assert_true(ShareCode.read_only_of(design as Dictionary),
		"勾了只读 ⇒ 设计层必须带 editor_meta.read_only（接收方编辑器据此只读）")
	var lvl: Variant = JSON.parse_string(_text(zip_path, "levels/level.json"))
	assert_true(lvl is Dictionary, "结果层应是合法 JSON 对象")
	assert_false((lvl as Dictionary).has("editor_meta"),
		"结果层不得夹带 editor_meta（游戏只读结果层，两层不重叠）")
	# 默认（不传 read_only）不许冒出这个键 —— 否则所有分享包都会变成只读
	var r2 := WorkshopPack.build(doc, {"dir": OUT_DIR})
	assert_true(bool(r2["ok"]), "打包应成功：%s" % str(r2["reason"]))
	var design2: Variant = JSON.parse_string(_text(str(r2["path"]), "design/level.json"))
	assert_true(design2 is Dictionary, "设计层应是合法 JSON 对象")
	assert_false(ShareCode.read_only_of(design2 as Dictionary),
		"没勾只读 ⇒ 分享包不得带只读声明（默认不许变）")
