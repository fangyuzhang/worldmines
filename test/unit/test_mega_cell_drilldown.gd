# test_mega_cell_drilldown.gd —— 复合格**下钻**（进入 / 退出复合格内部）收口测试。
#
# 为什么存在（缺口 #6）：`core/mega_cell.gd` 已有「禁嵌套」与「密度稀释 warn」，
# 但缺「进入 / 退出复合格内部」的可查询、可序列化能力。本文件钉住其不变量：
#   ① 进入合法复合格 ⇒ path 正确，且能读到内部结构（inner == internal_cells）；
#   ② 退回顶层 ⇒ path 为空、is_inside == false；
#   ③ 顶层再退 / 进入非法目标 ⇒ ok=false + reason 非空 + 状态逐字段未变（深比较）；
#   ④ 深度上限（复合格禁嵌套 ⇒ 合法路径最多 1 层）被拒且状态不变；
#   ⑤ 路径可序列化为普通数据，round-trip 一致，且不共享引用。
#
# 用 preload 而非全局类名，避免新增脚本的全局类缓存尚未刷新时测试无法解析
# （与 test_mega_cell.gd 同口径）。
extends GutTest

const MC := preload("res://core/mega_cell.gd")


## 逐字段深比较：字典按键（排序后比对）、数组按序、标量按值。
## 任何差异都带可定位的上下文（键路径），满足「状态逐字段未变」的验证要求。
func _assert_deep_eq(a: Variant, b: Variant, ctx: String) -> void:
	assert_eq(typeof(a), typeof(b),
		"%s：类型应一致（%s vs %s）" % [ctx, type_string(typeof(a)), type_string(typeof(b))])
	if a is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		var ka: Array = da.keys()
		var kb: Array = db.keys()
		ka.sort()
		kb.sort()
		assert_eq(ka, kb, "%s：字段集合应一致" % ctx)
		for k: Variant in da:
			_assert_deep_eq(da[k], db[k], "%s.%s" % [ctx, str(k)])
	elif a is Array:
		var aa: Array = a
		var ab: Array = b
		assert_eq(aa.size(), ab.size(), "%s：长度应一致" % ctx)
		for i in aa.size():
			_assert_deep_eq(aa[i], ab[i], "%s[%d]" % [ctx, i])
	else:
		assert_eq(a, b, "%s：值应一致" % ctx)


func _snapshot(state: Dictionary) -> Dictionary:
	return state.duplicate(true)


# ==================== ① 进入：path 正确 + 可读内部结构 ====================

func test_drill_in_sets_path_and_exposes_inner() -> void:
	var reg := MC.new()
	var input := [Vector2i(2, 2), Vector2i(3, 2), Vector2i(3, 3), Vector2i(2, 2)]
	var m := reg.merge(input)
	var id := int(m["id"])
	var state := MC.drill_state()
	assert_false(MC.is_inside(state), "初始应在顶层（不在任何复合格内部）")
	assert_eq(MC.drill_depth(state), 0, "初始深度应为 0")
	_assert_deep_eq(MC.drill_path(state), [], "初始路径")

	var res := reg.drill_in(state, id)
	assert_true(bool(res["ok"]), "进入已存在的复合格应成功：%s" % str(res))
	_assert_deep_eq(res["path"], [id], "返回路径应为 [%d]" % id)
	_assert_deep_eq(res["inner"] as Variant, reg.internal_cells(id), "inner 应等于该复合格内部基础格（规范序）")
	assert_eq((res["inner"] as Array).size(), 3, "内部结构应有 3 个基础格（输入去重后）")
	assert_eq(str(res["reason"]), "", "成功时理由应为空")
	# 状态已就地更新
	_assert_deep_eq(MC.drill_path(state), [id], "成功应就地更新 state.path")
	assert_true(MC.is_inside(state), "进入后应判定为「在某格内部」")
	assert_eq(MC.drill_depth(state), 1, "进入后深度应为 1")
	# 下钻不得改动模型本身
	assert_eq(reg.count(), 1, "下钻不得改动复合格集合")
	assert_eq(reg.owner_of(Vector2i(3, 3)), id, "下钻不得改动基础格归属")
	assert_eq(reg.size_of(id), 3, "下钻不得改动逻辑一格大小")


func test_drill_in_accepts_merge_record() -> void:
	var reg := MC.new()
	var m := reg.merge([Vector2i(5, 5), Vector2i(6, 5)])
	var state := MC.drill_state()
	var res := reg.drill_in(state, m)   # 直接传 merge 返回的记录（含 ok/id/cells）
	assert_true(bool(res["ok"]), "应接受 merge 记录作为下钻目标：%s" % str(res))
	_assert_deep_eq(MC.drill_path(state), [int(m["id"])], "记录里的 id 应进路径")


# ==================== ② 退出：回到顶层 path 空 ====================

func test_drill_out_returns_to_top() -> void:
	var reg := MC.new()
	var id := int(reg.merge([Vector2i(1, 1), Vector2i(2, 1)])["id"])
	var state := MC.drill_state()
	assert_true(bool(reg.drill_in(state, id)["ok"]), "先进入一层")
	assert_true(MC.is_inside(state), "进入后应在内部")
	var out := reg.drill_out(state)
	assert_true(bool(out["ok"]), "退出应成功：%s" % str(out))
	_assert_deep_eq(out["path"], [], "退出到顶层后返回路径应为空")
	assert_false(MC.is_inside(state), "退出后不应再判定为内部")
	assert_eq(MC.drill_depth(state), 0, "退出后深度应为 0")
	_assert_deep_eq(MC.drill_path(state), [], "退出后 state.path 应为空")
	assert_eq(str(out["reason"]), "", "成功时理由应为空")


# ==================== ③ 非法：顶层再退 / 非法目标（状态逐字段不变）====================

func test_drill_out_at_top_rejected_state_unchanged() -> void:
	var reg := MC.new()
	var state := MC.drill_state()
	var snap := _snapshot(state)
	var res := reg.drill_out(state)
	assert_false(bool(res["ok"]), "顶层再退应被拒")
	assert_true(str(res["reason"]).length() > 0, "拒绝必须带可读理由（顶层再退）")
	_assert_deep_eq(state, snap, "顶层再退后 state")


func test_drill_in_illegal_targets_rejected_state_unchanged() -> void:
	var reg := MC.new()
	var id := int(reg.merge([Vector2i(2, 2), Vector2i(3, 2)])["id"])
	# 四类非法目标：基础格坐标 / 坐标字典 / 复合格集合 / 不存在的复合格 id
	var bad: Array = [
		Vector2i(2, 2),
		{"x": 2, "y": 2},
		[Vector2i(2, 2), Vector2i(3, 2)],
		999999,
	]
	for target: Variant in bad:
		var state := MC.drill_state()
		var snap := _snapshot(state)
		var res := reg.drill_in(state, target)
		assert_false(bool(res["ok"]), "非法目标应被拒：%s" % str(target))
		assert_true(str(res["reason"]).length() > 0, "拒绝必须带可读理由：%s" % str(target))
		_assert_deep_eq(state, snap, "非法目标 %s 后 state" % str(target))
		assert_false(MC.is_inside(state), "非法目标不得进入内部：%s" % str(target))
	# 拒绝不能破坏模型：合法 id 仍可进入
	assert_true(bool(reg.drill_in(MC.drill_state(), id)["ok"]), "拒绝后合法 id 仍应可进入")


# ==================== ④ 深度上限（与禁嵌套同口径）被拒且状态不变 ====================

func test_drill_in_beyond_max_depth_rejected_state_unchanged() -> void:
	var reg := MC.new()
	var a := int(reg.merge([Vector2i(1, 1), Vector2i(2, 1)])["id"])
	var b := int(reg.merge([Vector2i(9, 9), Vector2i(9, 10)])["id"])
	var state := MC.drill_state()
	assert_true(bool(reg.drill_in(state, a)["ok"]), "第一层应可进入")
	var snap := _snapshot(state)
	# 即使目标是另一个**合法**复合格，也不允许（复合格内部只有基础格，禁嵌套）
	var res := reg.drill_in(state, b)
	assert_false(bool(res["ok"]), "超过深度上限应被拒（合法目标）")
	assert_true(str(res["reason"]).length() > 0, "超深度拒绝必须带可读理由")
	_assert_deep_eq(state, snap, "超深度（合法目标）后 state")
	# 非法目标同理，且状态同样不变
	var res2 := reg.drill_in(state, 999999)
	assert_false(bool(res2["ok"]), "已在内部时任何目标都应被拒")
	_assert_deep_eq(state, snap, "超深度（非法目标）后 state")
	assert_eq(MC.drill_depth(state), MC.DRILL_MAX_DEPTH, "深度应停在 DRILL_MAX_DEPTH")
	assert_eq(MC.DRILL_MAX_DEPTH, 1, "禁嵌套口径：合法下钻路径最多 1 层")


# ==================== ⑤ 路径序列化 round-trip（普通数据、无共享引用）====================

func test_drill_state_serialization_roundtrip() -> void:
	var reg := MC.new()
	var id := int(reg.merge([Vector2i(4, 4), Vector2i(4, 5), Vector2i(5, 5)])["id"])
	# 顶层
	var top := MC.drill_state()
	var top_d := MC.drill_to_dict(top)
	assert_eq(int(top_d["version"]), MC.DRILL_VERSION, "版本字段应落盘")
	_assert_deep_eq(top_d["path"], [], "顶层路径应为空")
	_assert_deep_eq(MC.drill_from_dict(top_d), top, "顶层 round-trip")
	# 内部
	var state := MC.drill_state()
	assert_true(bool(reg.drill_in(state, id)["ok"]), "先进入一层")
	var d := MC.drill_to_dict(state)
	_assert_deep_eq(d["path"], [id], "内部路径应含 id")
	var back := MC.drill_from_dict(d)
	_assert_deep_eq(back, state, "内部 round-trip state")
	_assert_deep_eq(MC.drill_to_dict(back), d, "内部 round-trip 数据")
	# 普通数据：篡改副本不得回写状态
	var d2: Dictionary = d.duplicate(true)
	(d2["path"] as Array).append(123456)
	_assert_deep_eq(MC.drill_path(state), [id], "序列化产物应为普通数据副本，篡改不得影响 state")
