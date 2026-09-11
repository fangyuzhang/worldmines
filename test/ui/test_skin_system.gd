# test_skin_system.gd —— Mod 皮肤系统
# 验证：ThemeManager 皮肤色板覆盖与回退、数字色覆盖、SkinService 内置皮肤与删除保护。
extends GutTest


func after_each() -> void:
	# 恢复内置深色，避免污染其他测试的取色预期
	ThemeManager.clear_skin("dark")
	ThemeManager._apply_final()


# S1：应用皮肤覆盖色板（_apply_final 跳过异步 tween 立即生效，便于断言）
func test_s1_apply_skin_overrides_palette() -> void:
	ThemeManager.apply_skin("test", {"accent": Color("#AA0000")}, [], "dark")
	ThemeManager._apply_final()
	assert_eq(ThemeManager.skin_id, "test")
	assert_eq(ThemeManager.accent(), Color("#AA0000"), "皮肤应覆盖强调色")


# S2：清除皮肤回退内置色
func test_s2_clear_skin_restores_builtin() -> void:
	ThemeManager.apply_skin("x", {"accent": Color("#00AA00")}, [], "dark")
	ThemeManager._apply_final()
	ThemeManager.clear_skin("dark")
	ThemeManager._apply_final()
	assert_eq(ThemeManager.skin_id, "")
	assert_eq(ThemeManager.accent(), ThemeManager._DARK.accent, "清除皮肤应回退内置深色")


# S3：皮肤覆盖数字 1~8 配色
func test_s3_skin_numbers_override() -> void:
	var nums: Array = []
	for i in 8:
		nums.append(Color(float(i + 1) / 255.0, 0, 0))
	ThemeManager.apply_skin("num", {}, nums, "dark")
	ThemeManager._apply_final()
	assert_eq(ThemeManager.number(1), nums[0], "数字 1 应用皮肤色")
	assert_eq(ThemeManager.number(8), nums[7], "数字 8 应用皮肤色")


# S4：内置皮肤存在且不可删除
func test_s4_builtin_skins_locked() -> void:
	SkinService.refresh()
	assert_true(SkinService.skins.size() >= 2, "至少两个内置皮肤")
	assert_true(SkinService.skins[0]["builtin"], "首项为内置")
	var r := SkinService.remove("__builtin_dark")
	assert_eq(r["ok"], false, "内置皮肤不可删除")


# S5：未知皮肤激活失败且不改变当前状态
func test_s5_unknown_skin_fails() -> void:
	var r := SkinService.activate("__no_such_skin__")
	assert_eq(r["ok"], false, "未知皮肤激活应失败")


# S6：端到端 —— 写临时皮肤 → 扫描 → 激活 → 删除
func test_s6_scan_activate_remove_mod_skin() -> void:
	var dir := "user://skins/test_skin"
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(dir.path_join("skin.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"name": "测试皮肤",
		"author": "test",
		"version": "1.0",
		"base": "dark",
		"palette": {"accent": "#FF0000"},
	}))
	f.close()

	SkinService.refresh()
	var found := false
	for s in SkinService.skins:
		if s["id"] == "test_skin":
			found = true
	assert_true(found, "扫描应发现临时皮肤")

	var r := SkinService.activate("test_skin")
	assert_eq(r["ok"], true, "激活 mod 皮肤应成功")
	assert_eq(ThemeManager.skin_id, "test_skin")
	ThemeManager._apply_final()
	assert_eq(ThemeManager.accent(), Color("#FF0000"), "皮肤强调色应生效")

	SkinService.remove("test_skin")
	assert_eq(DirAccess.dir_exists_absolute(dir), false, "删除后皮肤目录应消失")


# S7：导入 .zip 皮肤包 → 出现皮肤 → 清理
func test_s7_import_zip() -> void:
	var zip_path := "user://test_skin.zip"
	var zp := ZIPPacker.new()
	assert_eq(zp.open(zip_path), OK)
	zp.start_file("imported_skin/skin.json")
	zp.write_file(JSON.stringify({
		"name": "导入皮肤", "author": "test", "version": "1.0", "base": "dark",
		"palette": {"accent": "#00FF00"},
	}).to_utf8_buffer())
	zp.close_file()
	zp.close()

	var r := SkinService.import_zip(zip_path)
	assert_eq(r["ok"], true, "导入 zip 应成功")
	var found := false
	for s in SkinService.skins:
		if s["id"] == "imported_skin":
			found = true
	assert_true(found, "导入后应出现皮肤")

	SkinService.remove("imported_skin")
	DirAccess.remove_absolute(zip_path)
