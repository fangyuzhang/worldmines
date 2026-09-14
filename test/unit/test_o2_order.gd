extends GutTest

## O2「邻序」算子测试（v3.0 S3）：golden 手算 + 契约（applies / 零扩散 / 值域）+ 固有性质 f≥v。
## 注册走与 Mod 相同的 on_load 路径（不依赖 ModAPI autoload 在测试环境的可用性）。

var _rule: Object


func before_all() -> void:
	var script: Variant = load("res://demo/mods/o2_linxu/entry.gd")
	var inst: Object = script.new()
	inst.call("on_load")
	_rule = RuleRegistry.default().resolve(&"o2")


func _ms(pairs: Array) -> Dictionary:
	var d := {}
	for p in pairs:
		d[Vector2i(int(p[0]), int(p[1]))] = true
	return d


func _val(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	return int(_rule.call("compute_clue", _ms(mines), pos, size))


func _v(mines: Array, pos: Vector2i, size: Vector2i) -> int:
	# 测试内独立重算经典 v（雷格 -1），不复用规则内部实现
	var ms := _ms(mines)
	if ms.has(pos):
		return -1
	var c := 0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			if dx == 0 and dy == 0:
				continue
			var q := pos + Vector2i(dx, dy)
			if q.x >= 0 and q.x < size.x and q.y >= 0 and q.y < size.y and ms.has(q):
				c += 1
	return c


func test_registered_as_clue() -> void:
	assert_not_null(_rule, "o2 应已注册")
	assert_eq(str(_rule.call("get_kind")), "clue")


func test_empty_board_zero() -> void:
	var size := Vector2i(5, 5)
	for p in [Vector2i(0, 0), Vector2i(2, 2), Vector2i(4, 4)]:
		assert_eq(_val([], p, size), 0, "空盘任意格 f=0（所有 v 相等，无严格小于）")


func test_all_neighbors_mined_center() -> void:
	# 3×3 除中心外全雷 → 中心 v=8，八邻全 v=-1 → f=8
	var size := Vector2i(3, 3)
	var mines: Array = []
	for r in 3:
		for c in 3:
			if not (r == 1 and c == 1):
				mines.append([c, r])
	assert_eq(_val(mines, Vector2i(1, 1), size), 8, "八邻全雷 → f=8（每个雷邻 v=-1）")


func test_single_mine_corner_far_center() -> void:
	# 5×5 只有 (0,0) 雷：中心 (2,2) v=0（邻无雷），八邻全非雷且 v≥0 → f=0
	assert_eq(_val([[0, 0]], Vector2i(2, 2), Vector2i(5, 5)), 0)


func test_f_ge_v_property() -> void:
	# GDD §4.3 固有性质：f_p = v_p + |{非雷邻: v_q < v_p}| ≥ v_p（雷邻恒计入）
	var size := Vector2i(6, 6)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for t in 12:
		var mines: Array = []
		var used := {}
		while used.size() < 14:
			var mc := rng.randi_range(0, 5)
			var mr := rng.randi_range(0, 5)
			var mp := Vector2i(mc, mr)
			if used.has(mp):
				continue
			used[mp] = true
			mines.append([mc, mr])
		for rr in 6:
			for cc in 6:
				var p := Vector2i(cc, rr)
				var v := _v(mines, p, size)
				if v < 0:
					continue
				var f := int(_rule.call("compute_clue", _ms(mines), p, size))
				assert_true(f >= v, "f≥v 性质：p=%s f=%d v=%d" % [str(p), f, v])


func test_zero_diffusion() -> void:
	var zs: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 0)
	assert_gt(zs.size(), 0, "邻序 0 值可扩散（八邻安全）")
	var zn: Array = _rule.call("zero_safe_neighbors", Vector2i(2, 2), Vector2i(5, 5), 3)
	assert_eq(zn.size(), 0, "非 0 值不扩散")


func test_applies_to_all() -> void:
	assert_true(bool(_rule.call("applies_to", Vector2i(0, 0), Vector2i(5, 5))))
	assert_true(bool(_rule.call("applies_to", Vector2i(2, 2), Vector2i(5, 5))))


func test_upper_bound() -> void:
	assert_eq(int(_rule.call("value_upper_bound", Vector2i(5, 5))), 8)


func test_no_mask_support() -> void:
	assert_false(bool(_rule.call("supports_mask")), "本版不启用遮蔽")
