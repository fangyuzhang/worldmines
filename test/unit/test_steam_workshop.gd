extends GutTest

# test_steam_workshop.gd —— P1 工坊读取侧的**降级路径**测试。
#
# 环境无关的断言（CI/headless 里 Steam 往往不可初始化，这正是要测的场景）：
#   ① 插件在场性探测不崩；② 未初始化时 poll_subscriptions 安全降级；③ install_from_dir
#   的 dst_name 参数（工坊走 workshop_<fileid>/ 命名）；④ 目录前缀判定。
# 真·订阅同步路径依赖 Steam 客户端 + appid，属手工验收（框架 §2 验收清单）。

const SRC := "user://test_sw_src"
const DST_NAME := "workshop_999999999"


func after_each() -> void:
	for p in [SRC, "user://mods/%s" % DST_NAME]:
		if DirAccess.dir_exists_absolute(p):
			_rm(p)


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


func _make_pack(id: String) -> String:
	var src := SRC + "/" + id
	_write(src + "/manifest.json",
			'{"id":"%s","version":"1.0.0","api_version":"2.9","entry":{"runtime":"gdscript","path":"entry.gd"}}' % id)
	_write(src + "/entry.gd", "extends RefCounted\n\nfunc on_load() -> bool:\n\treturn true\n")
	return src


## 未初始化（未调 init 或 init 失败）时：poll 必须安全降级，不得崩、不得抛。
func test_poll_degrades_before_init() -> void:
	var sw := SteamWorkshop.new()
	assert_false(sw.is_available(), "未初始化时 is_available 应为 false")
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	var r: Dictionary = sw.poll_subscriptions(api)
	assert_false(bool(r.get("ok", false)), "未初始化时 poll 应返回 ok=false")
	assert_true(str(r.get("reason", "")).contains("Steam"), "reason 应说明 Steam 未初始化")
	assert_true((r.get("synced") as Array).is_empty(), "不得产生任何同步项")


## init 在无 Steam 环境返回失败字典（本机 headless 下即为该路径）；不崩即可。
func test_init_never_crashes() -> void:
	var sw := SteamWorkshop.new()
	var r: Dictionary = sw.init()
	assert_true(r.has("ok"), "init 必须返回结构化结果")
	if not bool(r.get("ok", false)):
		assert_ne(sw.last_error(), "", "失败时必须给出原因（供 UI 显示）")


## dst_name 参数：装到自定义目录名（工坊命名），manifest.id 与目录名解耦。
func test_install_from_dir_with_dst_name() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	var src := _make_pack("sw_pack_mod")
	var r: Dictionary = api.install_from_dir(src, DST_NAME)
	assert_true(bool(r.get("ok", false)), "带 dst_name 应安装成功（reason=%s）" % str(r.get("reason", "")))
	assert_true(DirAccess.dir_exists_absolute("user://mods/%s" % DST_NAME), "应装到指定目录名")
	assert_eq(str(r.get("id", "")), "sw_pack_mod", "返回的 id 仍取自 manifest")
	assert_true(SteamWorkshop.is_workshop_mod(DST_NAME), "工坊目录前缀判定")
	assert_false(SteamWorkshop.is_workshop_mod("mount_mod"), "普通 Mod 不应判为工坊来源")


## dst_name 非法（路径符号）→ 拒绝。
func test_install_rejects_bad_dst_name() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	autofree(api)
	var src := _make_pack("sw_pack_mod2")
	var r: Dictionary = api.install_from_dir(src, "a/b")
	assert_false(bool(r.get("ok", false)), "非法 dst_name 应拒绝")
