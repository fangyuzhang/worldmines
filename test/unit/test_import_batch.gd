extends GutTest
## 导入工具（tools/import_batch_to_lib.gd）纯函数的回归测试（2026-09-19 加，同日扩展）。
##
## 三个函数各对应一个**静默失败型** bug —— 不报错、但结果全废，所以值得钉住：
##   · `_parse_side`：原用 `int("5x5")` 得到 **55**（不是 5）→ 关卡会被写进
##     `levels_lib/<mode>/55/`，而选关页按 size=5 找 `5/`，永远看不到（实测发现）；
##   · `_is_official_mode`：不加闸门时旧批次目录（4c_4n / clock / mx / knight）会被
##     静默归档进库并写进 catalog（选关页看不到，却白占仓库几千个文件）；
##   · `_canonical_mode` / `_mode_from_level`：**mode 必须以关卡 JSON 为准**——
##     服务器量产链的产物目录是 `x_classic_s1` / `x_o10` 形态，按目录名判会**整批拒掉**
##     （2026-09-19 探针实测：14/14 批全部被拒，等价于整条链的产出导不进库）。
##
## 这些函数是 static，直接静态调用即可（不实例化 SceneTree 脚本，无副作用）。

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


## 服务器量产链形态（`x_` + classic 底座）必须被接受 —— 否则整条链的产物导不进库。
func test_official_mode_accepts_server_chain_dir_names() -> void:
	for m in ["x_classic_s1", "x_classic_s2", "x_classic_s3", "x_classic_s4",
			"x_classic_z1", "x_classic_z4", "x_o10", "x_o2", "x_o5x"]:
		assert_true(ImportTool._is_official_mode(m), "%s（服务器链实际目录名）应被接受" % m)
	# 旧批次一字母前缀（本就声称兼容，钉住不回归）
	for m in ["c_o1", "g_s1", "c_4n", "g_mx"]:
		var ok: bool = ImportTool._is_official_mode(m)
		var expect: bool = m in ["c_o1", "g_s1"]
		assert_eq(ok, expect, "%s 兼容性判定" % m)


## mode 以关卡 JSON 为准（clue_rule + global_rules）→ 库内 mode id。
func test_canonical_mode_from_level_fields() -> void:
	var cases := [
		["classic", [], "classic"],
		["o5x", [], "o5x"],                       # 观测单算子
		["classic", ["s1"], "s1"],                # 结构单算子
		["classic", ["z1"], "z1"],                # 守恒单算子
		["classic", ["dt"], "dt"],                # 内置骨牌
		["o1", ["s1"], "s1_o1"],                  # C 类：结构_观测
		["classic", ["s2", "s1"], "s1_s2"],       # F 类：顺序归一（按轴序）
		["classic", ["s1", "s2"], "s1_s2"],
		["o1", ["z1", "s1"], "z1+s1+o1"],         # T4：守恒+结构+观测
		["o1", ["s1", "z1"], "z1+s1+o1"],
	]
	for c in cases:
		assert_eq(ImportTool._canonical_mode(str(c[0]), c[1]), str(c[2]),
				"%s + %s" % [c[0], c[1]])


func test_canonical_mode_rejects_non_official() -> void:
	var bad := [
		["4n", []], ["clock", []], ["hv", []], ["ep", []],   # 旧算子（已移 legacy_rules）
		["classic", ["mx"]], ["classic", ["pf"]],            # 已隐藏等价实现
		["classic", ["dt", "4c"]], ["classic", ["ep"]],      # 旧混合
		["o1", ["o2"]], ["s1", ["s2"]],                      # 位置放反（KIND 错位）
	]
	for c in bad:
		assert_eq(ImportTool._canonical_mode(str(c[0]), c[1]), "", "%s + %s 应拒绝" % [c[0], c[1]])


## 端到端字段级：从关卡 JSON 取 mode（模拟真实产物字典）。
func test_mode_from_level_reads_json_fields() -> void:
	assert_eq(ImportTool._mode_from_level({"clue_rule": "classic", "global_rules": ["s3"]}), "s3")
	assert_eq(ImportTool._mode_from_level({"clue_rule": "o2", "global_rules": []}), "o2")
	assert_eq(ImportTool._mode_from_level({"clue_rule": "4n", "global_rules": []}), "",
			"旧算子 → 拒绝（不进库）")
	assert_eq(ImportTool._mode_from_level({"clue_rule": "classic"}), "classic",
			"缺 global_rules 字段 → 视作空数组")
