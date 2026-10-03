# test_editor_disclosure.gd —— EditorDisclosure 门禁（缺口 #16 第二、三块）
#
# 钉四件事：① 简单模式可见集是专家模式的子集；② 未知 id 策略与注释一致（断言写死）；
# ③ 幂等；④ 配色：两变体同色 ⇒ 冲突清单指名它们；不同色 ⇒ ok=true。
extends GutTest

const D := preload("res://core/editor_disclosure.gd")

## 含简单档 / 专家档 / 未登记（未知）三类，覆盖所有分支。
const ALL := [
	"playtest_toggle", "save", "undo", "brush", "grid_toggle", "help",
	"cheat_toggle", "hotmap", "rule_text", "batch",
	"mod_new_widget",
]


func test_simple_is_subset_of_expert() -> void:
	var simple := D.visible_controls(D.SIMPLE, ALL)
	var expert := D.visible_controls(D.EXPERT, ALL)
	assert_gt(simple.size(), 0, "简单模式应有基础控件")
	assert_eq(expert.size(), ALL.size(), "专家模式应返回全部（去重后）控件")
	for c in simple:
		assert_true(expert.has(c), "简单可见的 '%s' 必须也在专家可见集里" % str(c))
	# 不变量写成断言（防规则互相矛盾）
	assert_true(D.check_superset(ALL), "专家集 ⊇ 简单集 的自检应通过")


func test_unknown_id_policy_matches_comment() -> void:
	# 策略（见 core/editor_disclosure.gd 文件头）：显式才隐藏，未知即显示。
	var simple := D.visible_controls(D.SIMPLE, ALL)
	assert_true(simple.has("mod_new_widget"), "未知控件应默认可见（fail-visible）")
	assert_false(simple.has("hotmap"), "专家档控件在简单模式应隐藏")
	assert_false(D.is_expert_only("mod_new_widget"), "未知 id 不算专家档")
	assert_true(D.is_expert_only("hotmap"), "表内专家档 id 判定为 true")
	# 未知模式回退简单（保守）
	assert_eq(D.visible_controls("bogus_mode", ALL), simple, "未知模式应回退到简单模式")


func test_visible_controls_is_idempotent() -> void:
	var once := D.visible_controls(D.SIMPLE, ALL)
	var twice := D.visible_controls(D.SIMPLE, once)
	assert_eq(twice, once, "简单模式重复过滤应幂等")

	var e1 := D.visible_controls(D.EXPERT, ALL)
	var e2 := D.visible_controls(D.EXPERT, e1)
	assert_eq(e2, e1, "专家模式重复过滤应幂等")

	var dup := ["brush", "brush", "hotmap", "brush"]
	assert_eq(D.visible_controls(D.SIMPLE, dup), ["brush"], "重复 id 应去重")


func test_color_lock_reports_named_conflicts() -> void:
	var same := [
		{"id": "va_a", "color": "RED"},
		{"id": "va_b", "color": "RED"},
		{"id": "va_c", "color": "BLUE"},
	]
	var r := D.lock_report(same)
	assert_false(bool(r["ok"]), "两变体同色应判为冲突")
	assert_eq((r["conflicts"] as Array).size(), 1, "恰好一种颜色冲突")
	var conflict: Dictionary = (r["conflicts"] as Array)[0]
	var variants: Array = conflict["variants"]
	assert_true(variants.has("va_a") and variants.has("va_b"), "冲突应指名两个变体")
	assert_false(variants.has("va_c"), "不同色的变体不应被牵连")
	assert_ne(str(conflict["color"]), "", "冲突应指名颜色（哪个色）")

	# 同色相不同档位（PINK vs PINK_DARK）解析成不同颜色 ⇒ 不算冲突（口径来自 PaletteColor）
	var tiers := D.lock_report([{"id": "x", "color": "PINK"}, {"id": "y", "color": "PINK_DARK"}])
	assert_true(bool(tiers["ok"]), "不同档位不是同一颜色，不该报冲突")

	var distinct := [
		{"id": "va_a", "color": "RED"},
		{"id": "va_b", "color": "BLUE"},
		{"id": "va_c", "color": [0, 210, 195]},  # CYAN 的 RGB 写法
	]
	var r2 := D.lock_report(distinct)
	assert_true(bool(r2["ok"]), "不同颜色应 ok=true")
	assert_eq((r2["conflicts"] as Array).size(), 0, "无冲突清单为空")
