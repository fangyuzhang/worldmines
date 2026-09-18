# _pre_run.gd —— GUT 前置钩子：把「备用算子包」装配进测试进程
#
# 为什么需要它（2026-09-18）：按 GDD 终版 §4 收敛变体池，8 个旧算子（4n / sc / knight /
# fr / distsum / hv / ep / 4c）从内置表移入 `demo/mods/legacy_rules`，并列入
# `ModAPI.BUNDLED_SKIP` —— **产品默认不加载**（玩家想要就在模组页自行启用）。
#
# 但测试要覆盖引擎原语、生成器、Def 翻译链、Mod 拓扑等，它们仍然按这些 id 工作，
# 于是几十个用例的「规则 X 应已注册」会集体变红。与其让每个文件各写一份加载代码
# （漏一个就红一片），不如在测试进程启动时统一装配。
#
# 边界（为什么这不污染产品口径）：
#   · 它们以 **Mod 身份**进注册表（`is_bundled_rule` = false）→ 落「Mod」页，
#     不占单项变体页，`test_level_select_interaction` 的「单项页 24 卡」断言不受影响；
#   · **不进混合档三轴**（三轴是 `VariantCatalog` 的静态常量）→ 组合口径仍是
#     GDD 的 70 / 21 / 50，不会被撑大。
extends GutHookScript


func run() -> void:
	if RuleRegistry.default().resolve(&"4n") != null:
		return   # 已在场（单脚本调试 / 重复跑）
	# 直接驱动备用包的 on_load（它做的就是把这 8 个算子注册进 RuleRegistry）。
	#
	# 两个踩过的入口坑：
	#   · `ModLoader.load_mod_dir(dir)` 是 **Def 数据包**加载器（扫 defs/*.json → DefEngine），
	#     对代码 Mod 会以 `无法打开 defs 目录` 失败、loaded=0（实测，reason 里写得很清楚）；
	#   · 以类名调用 `ModLoader.load_mod_dir(...)`（实例方法）会在编译期报 Parse error，
	#     连带 GUT 的 _init_run 校验失败、整轮测试被中止。
	#
	# 不经 ModAPI 加载是有意的：规则此刻以 source="mod" 呈现 → 归「Mod」页；而 Mod 页只列
	# `ModAPI.list_mods()`，备用包不在其中 → 它既不占单项变体页（24 卡断言不动），
	# 也不会在 Mod 页重复出现，只服务于引擎原语 / 生成器 / Def 翻译链这些测试。
	var script: GDScript = load("res://demo/mods/legacy_rules/entry.gd")
	if script == null:
		print("[pre_run] 备用算子包 entry.gd 加载失败，跳过装配")
		return
	var inst: Object = script.new()
	if not inst.has_method("on_load"):
		print("[pre_run] 备用算子包缺少 on_load，跳过装配")
		return
	inst.call("on_load")
	print("[pre_run] 备用算子包已装配：注册表现有 %d 条规则" % RuleRegistry.default().all_ids().size())
