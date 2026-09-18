extends GutTest

# test_ui_mounts.gd —— P4「纯数据 UI 挂载」：收集 / 查询 / 非法项过滤 / 卸载摘除。
# 契约见 开放平台实施框架.md §5：挂载物只能是数据（label + body），不注册回调、不需要
# UI_INJECT 授权（数据展示不构成权限面）。

const SRC := "user://test_uimount_src"
const MOD_ID := "mount_mod"


func after_each() -> void:
	var p := "user://mods/%s" % MOD_ID
	if DirAccess.dir_exists_absolute(p):
		_rm(p)
	_rm(SRC)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	assert_true(f != null, "测试准备：应能写入 " + path)
	if f != null:
		f.store_string(text)
		f.close()


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(str(f)))
	for sub in d.get_directories():
		_rm(path.path_join(str(sub)))
	DirAccess.remove_absolute(path)


## 4 条声明：1 条合法 + 缺 slot + 缺 label + 非对象——只为验证「坏项不拖垮收集」。
func _make_mod() -> String:
	var src := SRC + "/" + MOD_ID
	_write(src + "/manifest.json",
			'{"id":"%s","version":"1.0.0","api_version":"2.9",' % MOD_ID
			+ '"entry":{"runtime":"gdscript","path":"entry.gd"},'
			+ '"ui_mounts":['
			+ '{"slot":"main_menu.footer","label":"关于 A","body":"说明文本"},'
			+ '{"slot":"","label":"坏项：缺 slot"},'
			+ '{"slot":"main_menu.footer"},'
			+ '"不是对象"]}')
	_write(src + "/entry.gd", "extends RefCounted\n\nfunc on_load() -> bool:\n\treturn true\n")
	return src


func test_collect_filter_and_unload() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	var src := _make_mod()
	assert_true(bool(api.install_from_dir(src).get("ok", false)), "安装应成功")
	assert_true(bool(api.load_mod("user://mods/%s" % MOD_ID).get("ok", false)), "加载应成功")

	var ms: Array = api.ui_mounts(UiMounts.SLOT_MAIN_MENU)
	assert_eq(ms.size(), 1, "4 条声明里应只收集 1 条合法项（其余缺 slot / label 或非对象）")
	if ms.size() == 1:
		assert_eq(str(ms[0]["label"]), "关于 A")
		assert_eq(str(ms[0]["body"]), "说明文本")
		assert_eq(str(ms[0]["mod_id"]), MOD_ID, "应记录来源 Mod（tooltip 显示用）")

	assert_true(api.ui_mounts(UiMounts.SLOT_LEVEL_SELECT).is_empty(), "未声明的 slot 应为空")

	api.unload_mod(MOD_ID)
	assert_true(api.ui_mounts(UiMounts.SLOT_MAIN_MENU).is_empty(), "卸载后不得留孤儿挂载")
