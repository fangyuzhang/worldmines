extends GutTest
## 量产工具的**尺寸政策**回归测试（2026-09-19 加）。
##
## 背景：《关卡集总表》对每个「层」的尺寸范围不同（守恒轴只收 7×7/8×8/9×9、变径从 6×6 起、
## C 类从 7×7 起、F 类/T4 只收 8×8/9×9）。此前工具一律按 5×5–9×9 跑 → z 轴 5×5/6×6 白产
## （表外，机时浪费）。政策固化进 `sides_for()` 后，**内置 164 组合路径与额外组合规格路径
## （`classic+z1@5-9` → id `x_classic_z1`）都受约束**（规格只能缩小、不能扩大政策范围）。

const Tool := preload("res://tools/batch_all_variants.gd")


func test_single_operator_default_full_sizes() -> void:
	assert_eq(Tool.sides_for({"id": "classic", "clue": "classic", "globals": []}), [5, 6, 7, 8, 9])
	assert_eq(Tool.sides_for({"id": "o1", "clue": "o1", "globals": []}), [5, 6, 7, 8, 9])
	assert_eq(Tool.sides_for({"id": "s1", "clue": "classic", "globals": ["s1"]}), [5, 6, 7, 8, 9])


func test_conserve_axis_starts_at_seven() -> void:
	for z in ["z1", "z2", "z3", "z4", "z5"]:
		assert_eq(Tool.sides_for({"id": z, "clue": "classic", "globals": [z]}), [7, 8, 9],
				"%s 应为 7×7–9×9" % z)


func test_variant_radius_starts_at_six() -> void:
	assert_eq(Tool.sides_for({"id": "o4", "clue": "o4", "globals": []}), [6, 7, 8, 9])


func test_extra_combo_spec_form_is_normalized() -> void:
	# 额外组合路径的 id 是规格串（x_classic_z1 / x_o4）——必须与内置路径同判
	assert_eq(Tool.sides_for({"id": "x_classic_z1", "clue": "classic", "globals": ["z1"]}), [7, 8, 9])
	assert_eq(Tool.sides_for({"id": "x_o4", "clue": "o4", "globals": []}), [6, 7, 8, 9])
	assert_eq(Tool.sides_for({"id": "x_o1", "clue": "o1", "globals": []}), [5, 6, 7, 8, 9])


func test_mixed_layers_are_narrower() -> void:
	# C 类（结构_观测）：7×7 起
	assert_eq(Tool.sides_for({"id": "s1_o1", "clue": "o1", "globals": ["s1"]}), [7, 8, 9])
	# F 类（结构_结构）：只 8×8/9×9
	assert_eq(Tool.sides_for({"id": "s1_s2", "clue": "classic", "globals": ["s1", "s2"]}), [8, 9])
	# T4（守恒+结构+观测）：只 8×8/9×9
	assert_eq(Tool.sides_for({"id": "z1+s1+o1", "clue": "o1", "globals": ["s1", "z1"]}), [8, 9])
