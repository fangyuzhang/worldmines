extends GutTest

# test_mod_import.gd —— ModAPI.install_from_dir（本地导入 Mod 的最小闭环）单元测试。
#
# 不测 FileDialog UI（headless 无交互），只测安装逻辑与校验：
#   合法包安装成功且文件齐、缺 manifest 拒绝、非法 id 拒绝、重复安装拒绝（不覆盖用户数据）、
#   levels/ 子目录递归复制（工坊分发单元的组成部分，此前 _copy_code_mod 只复制顶层文件）。
#
# 契约依据：变体规则编写规范 §0（交付物 = manifest.json + entry.gd 的目录）。

const SRC_ROOT := "user://test_import_mods"
const GOOD_MANIFEST := '{"id":"import_ok_mod","version":"1.0.0","api_version":"2.9","entry":{"runtime":"gdscript","path":"entry.gd"}}'
const GOOD_ENTRY := "extends RefCounted\n\nfunc on_load() -> bool:\n\treturn true\n"

var _api: Object


func before_each() -> void:
	_api = load("res://core/mod_api.gd").new()
	DirAccess.make_dir_recursive_absolute(SRC_ROOT)


func after_each() -> void:
	_dir_rm(SRC_ROOT)
	# 清掉可能装出去的产物（递归删，防污染后续跑批的真 user://mods）
	for name in ["import_ok_mod", "import_levels_mod"]:
		var p := "user://mods/%s" % name
		if DirAccess.dir_exists_absolute(p):
			_dir_rm(p)


## 好包：安装成功、文件齐全、scan_mods 可见。
func test_install_ok() -> void:
	var src := _make_good_mod("import_ok_mod")
	var r: Dictionary = _api.install_from_dir(src)
	assert_true(bool(r.get("ok", false)), "合法 Mod 应安装成功（reason=%s）" % str(r.get("reason", "")))
	assert_eq(str(r.get("id", "")), "import_ok_mod", "返回的 id 应取自 manifest")
	assert_true(DirAccess.dir_exists_absolute("user://mods/import_ok_mod"), "安装目录应存在")
	assert_true(FileAccess.file_exists("user://mods/import_ok_mod/entry.gd"), "entry.gd 应已复制")
	assert_true(_api.scan_mods().has("import_ok_mod"), "scan_mods 应能扫到新装的 Mod")


## 缺 manifest.json → 拒绝（不是有效 Mod 目录）。
func test_install_rejects_missing_manifest() -> void:
	var src := SRC_ROOT + "/no_manifest"
	DirAccess.make_dir_recursive_absolute(src)
	var r: Dictionary = _api.install_from_dir(src)
	assert_false(bool(r.get("ok", false)), "缺 manifest.json 应拒绝")
	assert_true(str(r.get("reason", "")).contains("manifest"), "reason 应说明缺 manifest")


## id 非法（空 / 带路径符号）→ 拒绝，且不产生任何目录。
func test_install_rejects_bad_id() -> void:
	for bad_id in ["", "a/b", "..", "a b"]:
		var src := SRC_ROOT + "/bad_id_mod"
		_write(src + "/manifest.json",
				'{"id":"%s","version":"1.0.0","api_version":"2.9","entry":{"runtime":"gdscript","path":"entry.gd"}}' % bad_id)
		_write(src + "/entry.gd", GOOD_ENTRY)
		var r: Dictionary = _api.install_from_dir(src)
		assert_false(bool(r.get("ok", false)), "非法 id「%s」应拒绝" % bad_id)
		# 「」与「..」拼出的路径（user://mods/、user://mods/..）本来就该存在，
		# 无法用目录存在性断言——只对其余非法 id 断言没产生目录。
		if bad_id != "" and bad_id != "..":
			assert_false(DirAccess.dir_exists_absolute("user://mods/%s" % bad_id),
					"非法 id「%s」不得产生目录" % bad_id)


## 重复安装 → 拒绝且**不覆盖**（user://mods 里的目录可能承载玩家进度与已生成关卡）。
func test_install_rejects_duplicate_without_overwrite() -> void:
	var src := _make_good_mod("import_ok_mod")
	assert_true(bool(_api.install_from_dir(src).get("ok", false)), "首次安装应成功")
	# 改动源包内容，再次安装 → 拒绝，且已装内容保持原样
	_write(src + "/entry.gd", GOOD_ENTRY + "# tampered\n")
	var r2: Dictionary = _api.install_from_dir(src)
	assert_false(bool(r2.get("ok", false)), "重复安装应拒绝")
	assert_true(str(r2.get("reason", "")).contains("同名"), "reason 应说明同名冲突")
	var dst_text := FileAccess.get_file_as_string("user://mods/import_ok_mod/entry.gd")
	assert_false(dst_text.contains("tampered"), "已安装内容不得被覆盖")


## levels/ 子目录递归复制（预生成关卡是分发单元的一部分）。
func test_install_copies_levels_subdir() -> void:
	var src := SRC_ROOT + "/import_levels_mod"
	_write(src + "/manifest.json",
			'{"id":"import_levels_mod","version":"1.0.0","api_version":"2.9","entry":{"runtime":"gdscript","path":"entry.gd"}}')
	_write(src + "/entry.gd", GOOD_ENTRY)
	_write(src + "/levels/easy_01.json", '{"total_mines":5}')
	_write(src + "/levels/sub/nested.json", '{"ok":true}')
	var r: Dictionary = _api.install_from_dir(src)
	assert_true(bool(r.get("ok", false)), "含 levels/ 的 Mod 应安装成功（reason=%s）" % str(r.get("reason", "")))
	assert_true(FileAccess.file_exists("user://mods/import_levels_mod/levels/easy_01.json"),
			"levels/ 下关卡文件应递归复制")
	assert_true(FileAccess.file_exists("user://mods/import_levels_mod/levels/sub/nested.json"),
			"levels/ 下嵌套子目录应递归复制")


# ==== helpers ====

func _make_good_mod(mod_id: String) -> String:
	var src := SRC_ROOT + "/" + mod_id
	_write(src + "/manifest.json",
			'{"id":"%s","version":"1.0.0","api_version":"2.9","entry":{"runtime":"gdscript","path":"entry.gd"}}' % mod_id)
	_write(src + "/entry.gd", GOOD_ENTRY)
	return src


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "测试准备：应能写入 " + path)
	if f != null:
		f.store_string(text)
		f.close()


func _dir_rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_dir_rm(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)
