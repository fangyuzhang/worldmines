extends GutTest
## 字体子集化回归测试（2026-10-25 降体积专项）
## 断言口径见 assets/fonts/README.md：全局默认字体 = project.godot [gui] theme/custom_font。

const PROJECT_GODOT := "res://project.godot"
const FULL_FONT := "res://assets/fonts/WenYuanRoundedSCVF.ttf"
const SUBSET_FONT := "res://assets/fonts/WenYuanRoundedSCVF-subset.ttf"


func _custom_font_path() -> String:
	var cfg := ConfigFile.new()
	var err := cfg.load(PROJECT_GODOT)
	if err != OK:
		return ""
	return cfg.get_value("gui", "theme/custom_font", "")


func test_project_points_to_subset_font() -> void:
	var path := _custom_font_path()
	assert_true(path.begins_with("res://assets/fonts/"), "custom_font 应在 assets/fonts 下，实际 %s" % path)
	assert_true(path.contains("subset"), "custom_font 应指向子集字体（降体积定案），实际 %s" % path)


func test_font_files_exist() -> void:
	assert_true(FileAccess.file_exists(_custom_font_path()), "custom_font 指向的文件必须存在")
	# 原字体原地保留（回滚与重子集化的源），不许删。
	assert_true(FileAccess.file_exists(FULL_FONT), "原可变字体必须保留（回滚需要）")


func test_subset_font_loads_and_measures() -> void:
	var font := load(_custom_font_path())
	assert_not_null(font, "字体资源应可 load")
	if font == null:
		return
	assert_true(font is Font or font is FontFile or font is FontVariation, "应为 Font 家族类型")
	var w := (font as Font).get_string_size("世界扫雷", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	assert_gt(w, 0.0, "核心标题字符串应有非零测量宽")


func test_subset_size_guard() -> void:
	# 回归闸：若有人把 custom_font 指回 46.5MB 全量字体，这里立刻红。
	var fa := FileAccess.open(_custom_font_path(), FileAccess.READ)
	assert_not_null(fa, "可打开 custom_font 文件")
	if fa == null:
		return
	var len := fa.get_length()
	fa.close()
	assert_lt(len, 2_000_000, "子集字体应 < 2MB，实际 %d 字节（若指回全量字体会 >46MB）" % len)
