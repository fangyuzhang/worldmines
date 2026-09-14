extends GutTest

## O4「变径」算子测试（v3.0 S3）：golden 半径 1/2 对照 + k 配额 + 契约。
## 注：_r2 为规则实例状态，测试用 registry 单例并显式清理（after_each）。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o4_bianjing/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o4")


func after_each() -> void:
	_rule.set("_r2", {})   # 清理实例状态，避免测试间污染


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o4 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_5x5_disabled() -> void:
	# GDD §4.3 硬性判定：5×5 不生产（半径 2 覆盖全盘退化）
	assert_false(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(5, 5))), "5×5 停用")
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(6, 6))), "6×6 起启用")


func test_radius_contrast() -> void:
	# 对照：同一布雷，(2,2) 为半径 1 vs 半径 2
	# 布雷：内圈 (2,1)（距(2,2) dy=-1）+ 外圈 (2,4)（距(2,2) dy=2）
	var ms := {}
	ms[Vector2i(2, 1)] = true
	ms[Vector2i(2, 4)] = true
	var size := Vector2i(6, 6)
	_rule.set("_r2", {})
	var f1 := int(_rule.call("compute_clue", ms, Vector2i(2, 2), size))
	assert_eq(f1, 1, "半径 1（默认）：只计八邻 → 1")
	_rule.set("_r2", {Vector2i(2, 2): true})
	var f2 := int(_rule.call("compute_clue", ms, Vector2i(2, 2), size))
	assert_eq(f2, 2, "半径 2：内圈 1 + 外圈 1 → 2")


func test_place_mines_k_quota() -> void:
	# k = 格数/4：6×6 → 9；且布雷数正确
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var mines: Array = _rule.call("place_mines", rng, 6, 6, 14)
	assert_eq(mines.size(), 14, "布雷 14")
	var r2: Dictionary = _rule.get("_r2")
	assert_eq(r2.size(), 9, "r2 配额 = 36/4 = 9")


func test_zero_diffused() -> void:
	# f=0 → 两种半径下均无雷 → 八邻安全（保守扩散）
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(6, 6), 0)
	assert_gt(zs.size(), 0, "变径 0 值可扩散（保守八邻）")
	var zn: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(6, 6), 3)
	assert_eq(zn.size(), 0, "非 0 不扩散")


func test_applies_and_bounds() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(6, 6))), 24, "值域上限 24")
	assert_false(bool(_rule.call("supports_mask")), "本版不启用遮蔽")


func test_generated_level_consistency() -> void:
	# 生成一关，检查 f 与「布雷 + r2 状态」的一致性（独立手工重算）
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var mines: Array = _rule.call("place_mines", rng, 6, 6, 14)
	var ms := {}
	for p in mines:
		ms[p] = true
	var r2: Dictionary = _rule.get("_r2")
	for r in 6:
		for c in 6:
			var pos := Vector2i(c, r)
			if ms.has(pos):
				continue
			var f := int(_rule.call("compute_clue", ms, pos, Vector2i(6, 6)))
			var expect := 0
			for dr in range(-2, 3):
				for dc in range(-2, 3):
					if dr == 0 and dc == 0:
						continue
					var cheb := maxi(absi(dr), absi(dc))
					var rad := 2 if r2.has(pos) else 1
					if cheb > rad:
						continue
					var q := Vector2i(c + dc, r + dr)
					if q.x < 0 or q.x >= 6 or q.y < 0 or q.y >= 6:
						continue
					if ms.has(q):
						expect += 1
			assert_eq(f, expect, "格 (%d,%d) 手工重算一致" % [c, r])
