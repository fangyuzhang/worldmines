# test_example_mod.gd —— 内置示例规则包（ExampleMod.install）
# 验证：可安装、落盘正确、ModLoader 能加载（1 线索 + 1 约束）。
# 注意：install 会写 user://mods/example/defs，用例结束删除以不残留。
extends GutTest


func before_each() -> void:
	ExampleMod.uninstall()


func after_each() -> void:
	ExampleMod.uninstall()


# E1：安装返回 ok，且写出 2 个 Def 文件
func test_e1_install_writes_defs() -> void:
	var r := ExampleMod.install()
	assert_true(bool(r.get("ok", false)), "安装应成功：%s" % r.get("reason", ""))
	assert_eq(int(r.get("count", 0)), 2, "应写出 2 个 Def")
	assert_true(ExampleMod.is_installed(), "安装后 is_installed 应为 true")


# E2：ModLoader 能从安装目录加载 2 个 Def
func test_e2_modloader_loads_example() -> void:
	ExampleMod.install()
	var loader := ModLoader.new()
	var r := loader.load_mod_dir("user://mods/example")
	assert_true(bool(r.get("ok", false)), "ModLoader 加载示例包应成功：%s" % r.get("reason", ""))
	assert_eq(int(r.get("loaded", 0)), 2, "应加载 2 个 Def")


# E3：示例线索 Def 可用（compute_clue 按 n4+sum 计算）
func test_e3_example_clue_computes() -> void:
	ExampleMod.install()
	var loader := ModLoader.new()
	loader.load_mod_dir("user://mods/example")
	# (1,1) 的 n4 邻雷 = (1,0) 一颗
	var mine_set := {Vector2i(1, 0): true}
	assert_eq(loader.engine.compute_clue("ExampleN4", mine_set, Vector2i(1, 1), Vector2i(3, 3)), 1,
		"ExampleN4 应算出 1")


# E4：未安装时 is_installed 为 false
func test_e4_not_installed_initially() -> void:
	assert_false(ExampleMod.is_installed(), "uninstall 后应视为未安装")
