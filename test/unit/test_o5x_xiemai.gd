extends GutTest

## O5「斜脉」算子测试（v3.0）：golden 斜线核定 + 隐藏斜向 + k 配额 + 契约。
## 注：_s1 为规则实例状态（place_mines 决定）；测试用 registry 单例并显式清理。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o5_xiemai/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o5x")


func after_each() -> void:
	_rule.set("_s1", {})


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o5x 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_applies_all_cells() -> void:
	# 所有格均可铺：每格至少一条斜线 ≥2 格（如角格 (0,0) 的主斜线贯穿全盘 6 格；
	# 仅当 s=1 指向短副线时该格 f 恒 0——无损且 0 不扩散）。
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(6, 6))), "角格可铺（主斜线长）")
	assert_true(bool(_rule.call("applies_to", Vector2i(1, 1), Vector2i(6, 6))), "内圈可铺")
	assert_true(bool(_rule.call("applies_to", Vector2i(5, 5), Vector2i(6, 6))), "对角可铺")


func test_main_line_sum() -> void:
	# 主斜线（s=0）：(1,1) 的主斜线 = {(0,0),(1,1),(2,2),(3,3),(4,4),(5,5)}——(0,0)、(2,2) 为雷 → 2
	_rule.set("_s1", {})
	var ms := {}
	ms[Vector2i(0, 0)] = true
	ms[Vector2i(2, 2)] = true
	assert_eq(int(_rule.call("compute_clue", ms, Vector2i(1, 1), Vector2i(6, 6))), 2, "主斜线 2 雷 → 2")


func test_anti_line_sum() -> void:
	# 副斜线（s=1）：(1,1) 的副斜线 = {(3,0)?}… 6×6 中 (1,1) 的 r+c=2 线 = {(0,2),(1,1),(2,0)}——(2,0)、(0,2) 为雷 → 2
	_rule.set("_s1", {Vector2i(1, 1): true})
	var ms := {}
	ms[Vector2i(2, 0)] = true
	ms[Vector2i(0, 2)] = true
	assert_eq(int(_rule.call("compute_clue", ms, Vector2i(1, 1), Vector2i(6, 6))), 2, "副斜线 2 雷 → 2")
	# 同时验证：同盘同格若选主斜线则 0（切换语义生效）
	_rule.set("_s1", {})
	assert_eq(int(_rule.call("compute_clue", ms, Vector2i(1, 1), Vector2i(6, 6))), 0, "主斜线 0 雷 → 0")


func test_place_mines_k_quota() -> void:
	# k = 格数/4：6×6 → 9
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var mines: Array = _rule.call("place_mines", rng, 6, 6, 14)
	assert_eq(mines.size(), 14, "布雷 14")
	var s1: Dictionary = _rule.get("_s1")
	assert_eq(s1.size(), 9, "s=1 配额 = 36/4 = 9")


func test_zero_not_diffused() -> void:
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(6, 6), 0)
	assert_eq(zs.size(), 0, "斜脉 v2 零值不可扩散（方向未知）")


func test_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(8, 8))), 7, "8×8 上限 7（去心最长）")
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(9, 9))), 8, "9×9 上限 8")


func test_generated_consistency() -> void:
	# 生成一关：全格 f 与「斜线 + s 状态」独立手工重算一致
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var mines: Array = _rule.call("place_mines", rng, 6, 6, 14)
	var ms := {}
	for p in mines:
		ms[p] = true
	var s1: Dictionary = _rule.get("_s1")
	for r in 6:
		for c in 6:
			var pos := Vector2i(c, r)
			if ms.has(pos) or not bool(_rule.call("applies_to", pos, Vector2i(6, 6))):
				continue
			var f := int(_rule.call("compute_clue", ms, pos, Vector2i(6, 6)))
			# 独立重算
			var expect := 0
			if s1.has(pos):
				# 副斜线 r+c 常数
				var e := r + c
				for cc in 6:
					var rr2 := e - cc
					if rr2 < 0 or rr2 >= 6 or cc == c:
						continue
					if ms.has(Vector2i(cc, rr2)):
						expect += 1
			else:
				# 主斜线 r−c 常数
				var d := r - c
				for cc in 6:
					var rr2 := cc + d
					if rr2 < 0 or rr2 >= 6 or cc == c:
						continue
					if ms.has(Vector2i(cc, rr2)):
						expect += 1
			assert_eq(f, expect, "格 (%d,%d) 手工重算一致" % [c, r])
