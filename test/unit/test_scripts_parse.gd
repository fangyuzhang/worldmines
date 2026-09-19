extends GutTest
## 全局脚本可解析性守卫（2026-09-19 加）。
##
## 为什么需要：`tools/` 下的 CLI 脚本**不参与任何测试**（它们由 `godot -s tools/xxx.gd`
## 单独运行），所以改坏了没有任何测试会红。真实事故：编辑 `tools/batch_merge.gd` 时
## 一次缩进失误（顶格注释）让整个脚本无法加载（Parse Error: Unexpected "Indent"），
## 而当时**全量 647 用例全绿** —— 测试根本没碰过那个文件。
##
## 本测试用 `load()` 遍历式解析：GDScript 的 `load()` 会完整解析并编译脚本，
## 语法错误即返回 null（不会实例化、无副作用）。

const DIRS: Array = ["res://tools", "res://core", "res://ui"]


func test_all_scripts_parse() -> void:
	var bad: Array = []
	var checked := 0
	for d in DIRS:
		var da := DirAccess.open(str(d))
		if da == null:
			continue    # 目录不存在不算失败（如裁剪发行版）
		for f in da.get_files():
			var fn := str(f)
			if not fn.ends_with(".gd"):
				continue
			checked += 1
			if load("%s/%s" % [d, fn]) == null:
				bad.append("%s/%s" % [d, fn])
	assert_gt(checked, 0, "应至少扫描到若干脚本")
	assert_eq(bad, [], "以下脚本无法解析（语法/缩进错误）：%s" % ", ".join(bad))
