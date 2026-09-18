extends GutTest
## 导入工具（tools/import_batch_to_lib.gd）两个纯函数的回归测试（2026-09-19 加）。
##
## 两个函数各对应一个**静默失败型** bug —— 不报错、但结果全废，所以值得钉住：
##   · `_parse_side`：原用 `int("5x5")` 得到 **55**（不是 5）→ 关卡会被写进
##     `levels_lib/<mode>/55/`，而选关页按 size=5 找 `5/`，永远看不到（实测发现）；
##   · `_is_official_mode`：不加闸门时旧批次目录（4c_4n / clock / mx / knight）会被
##     静默归档进库并写进 catalog（选关页看不到，却白占仓库几千个文件）。
##
## 这两个函数是 static，直接静态调用即可（不实例化 SceneTree 脚本，无副作用）。

const ImportTool := preload("res://tools/import_batch_to_lib.gd")


func test_parse_side_accepts_legal_forms() -> void:
	assert_eq(ImportTool._parse_side("5x5"), 5, "量产产物格式（batch_all_variants.gd 产出）")
	assert_eq(ImportTool._parse_side("9x9"), 9)
	assert_eq(ImportTool._parse_side("5"), 5, "库内既有格式（catalog 重建侧同规则）")


func test_parse_side_rejects_ambiguous_and_non_square() -> void:
	assert_eq(ImportTool._parse_side("55"), 0, "旧命名歧义：曾被子串拼接读成 55，写进错误尺寸目录")
	assert_eq(ImportTool._parse_side("5x6"), 0, "非方形：库的尺寸键是单个 int，不支持")
	assert_eq(ImportTool._parse_side("abc"), 0)
	assert_eq(ImportTool._parse_side(""), 0)


func test_official_mode_accepts_three_axis_forms() -> void:
	for m in ["classic", "dt", "o1", "s1", "z1", "s1_o1", "s7_o10", "s1_s2", "z1+s1+o1"]:
		assert_true(ImportTool._is_official_mode(m), "%s 应被接受" % m)


func test_official_mode_rejects_legacy_and_typos() -> void:
	for m in ["4c_4n", "c_clock", "clock", "mx", "knight", "o11", "o1_s1", "z1+s1", "s1_o1_z1"]:
		assert_false(ImportTool._is_official_mode(m), "%s 应被拒绝" % m)
