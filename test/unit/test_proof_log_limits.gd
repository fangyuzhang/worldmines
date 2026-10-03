extends GutTest

## ProofLog 体积上限 + 截断标记（文档 H③，数据侧；不动回放 UI）。
##
## 钉住的不变量：
##   1) 正常日志不截断（`truncated=false`、步序完整、不是纯函数副作用）；
##   2) 超步数上限 ⇒ 截断，且保留的必定是**原链前缀**（步序不能乱）；
##   3) 超字节上限 ⇒ 同样只砍尾部、保留前缀；
##   4) 旧日志没有 `truncated` 字段时，读侧按 false 处理（向后兼容）。


## 造 n 步假日志；`pad` 给每步塞一段大字符串（用来压字节上限）。带 `i` 便于验前缀顺序。
func _steps(n: int, pad := 0) -> Array:
	var out: Array = []
	for i in n:
		var d := {"i": i, "pos": [i % 7, i / 7], "state": "safe",
			"rule_id": "classic", "precondition_signature": "sig%d" % i}
		if pad > 0:
			d["pad"] = "x".repeat(pad)
		out.append(d)
	return out


func test_normal_log_is_not_truncated() -> void:
	var steps := _steps(20)
	var lim := ProofLog.apply_limits(steps, {"solved": true})
	assert_false(bool(lim["truncated"]), "20 步远未超限，不该截断")
	assert_eq((lim["steps"] as Array).size(), 20)
	assert_eq(int(lim["kept_steps"]), 20)
	assert_eq(int(lim["dropped_steps"]), 0)
	assert_eq(str(lim["truncated_reason"]), "")
	assert_eq(steps.size(), 20, "`apply_limits` 必须是纯函数，不得就地改入参")


func test_step_cap_truncates_and_keeps_prefix_in_order() -> void:
	var lim := ProofLog.apply_limits(_steps(ProofLog.MAX_STEPS + 123))
	assert_true(bool(lim["truncated"]), "超过步数上限必须标记截断")
	var kept: Array = lim["steps"]
	assert_eq(kept.size(), ProofLog.MAX_STEPS, "应保留恰好 MAX_STEPS 步")
	assert_eq(int(lim["kept_steps"]), ProofLog.MAX_STEPS)
	assert_eq(int(lim["dropped_steps"]), 123)
	assert_true(str(lim["truncated_reason"]).find(str(ProofLog.MAX_STEPS)) != -1, "原因要说明是步数上限")
	# 关键：保留的是原链**前缀**、顺序不变（不是随便截一段，更不能乱序）
	for i in kept.size():
		assert_eq(int((kept[i] as Dictionary).get("i", -1)), i, "第 %d 步应仍是原链第 %d 步" % [i, i])


func test_byte_cap_truncates_tail_only() -> void:
	# 每步 ≈400KB，6 步 ≈2.4MB > 2MiB ⇒ 必须砍掉尾巴
	var lim := ProofLog.apply_limits(_steps(6, 400000), {"solved": false})
	assert_true(bool(lim["truncated"]), "超过字节上限必须标记截断")
	var kept: Array = lim["steps"]
	assert_gt(kept.size(), 0, "至少要留得下若干步")
	assert_lt(kept.size(), 6, "应砍掉一部分（否则不算超限）")
	assert_true(str(lim["truncated_reason"]).find("字节上限") != -1)
	for i in kept.size():
		assert_eq(int((kept[i] as Dictionary).get("i", -1)), i, "保留的必须是前缀且顺序不变")


func test_old_log_without_truncated_field_reads_as_not_truncated() -> void:
	var key := "test_proof_limits_legacy"
	var legacy := {"solved": true, "steps": _steps(3)}   # 旧格式：完全没有 truncated 字段
	var path := ProofLog.save_log(key, legacy)
	assert_ne(path, "", "应能落盘")
	var back := ProofLog.load_log(key)
	assert_false(bool(back.get("truncated", false)), "旧日志读回后调用侧应默认 false（不截断）")
	assert_eq((back.get("steps", []) as Array).size(), 3, "旧日志的步数应原样读回")


func test_build_marks_normal_log_not_truncated() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var gen := PuzzleGenerator.new()
	var level: Dictionary = {}
	for s in 10:
		level = gen.generate_with_rules("classic", [], Vector2i(5, 5), 4, 3000 + s * 11)
		if not level.is_empty():
			break
	assert_false(level.is_empty(), "应能生成一关")
	if level.is_empty():
		return
	var log := ProofLog.build(level)
	assert_true(log.has("truncated"), "正常日志也应显式带 truncated 字段（读侧无脑读）")
	assert_false(bool(log["truncated"]), "小关日志不该被截断")
	for s2 in log.get("steps", []):
		assert_true((s2 as Dictionary).has("precondition_signature"), "步序字段应完整保留")
