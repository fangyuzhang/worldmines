# test_perf_ledger.gd —— 全局性能记账 + 统一降级顺序（PerfLedger）自证
#
# 全部用**注入时钟**驱动（不依赖真实帧率、不依赖真实盘面），钉住五条不变量：
#   1) 降级顺序严格 = 热力图 → 校验 → 自动保存（文档「十.1 性能叠加」钦定，不许乱序/合并）；
#   2) 「降 → 稳 → 升」不抖动：达标不满退出窗口一档都不回爬，回爬走严格逆序且一档一档来；
#   3) `restore()` 回到全开（开关 / 频率系数 / 档位 / 幂等计数全部复位）；
#   4) 未知活名 / 未知动作一律兜底不崩（返回 false 或文档化的默认值）；
#   5) 连续超载幂等：满档后继续超载不再施加任何动作，每个动作只应用一次。
extends GutTest

## 用 preload 引用被测脚本：不依赖 `.godot/global_script_class_cache.cfg` 是否已收录新 class_name
## （首次运行/干净缓存时缓存可能尚未刷新，直接写 PerfLedger 会解析失败）。
const PerfLedgerScript := preload("res://core/perf_ledger.gd")


func _fresh() -> PerfLedger:
	return PerfLedgerScript.new()


func _plain(arr: Array) -> Array:
	var out: Array = []
	for s in arr:
		out.append(String(s))
	return out


## 按 tick 的真实窗口规则走到满档（不直接改内部字段）。返回最后一次 tick 的时刻。
func _degrade_to_full(l: PerfLedger) -> int:
	var t := 0
	l.tick(t, false)
	while l.level() < l.max_level():
		t += 1_000
		l.tick(t, false)
	return t


# ==================== 1. 降级顺序（文档钦定） ====================

func test_degrade_order_is_hotmap_then_verify_then_autosave() -> void:
	var l := _fresh()
	var plan := _plain(l.degrade_plan(false))
	assert_eq(plan.size(), 3, "满负载时剩余降级序列应是 3 步")
	assert_eq(str(plan[0]), PerfLedgerScript.ACT_DISABLE_HOTMAP, "第①步必须是关热力图")
	assert_eq(str(plan[1]), PerfLedgerScript.ACT_REDUCE_VERIFY, "第②步必须是降校验频率")
	assert_eq(str(plan[2]), PerfLedgerScript.ACT_DELAY_AUTOSAVE, "第③步必须是延后自动保存")
	assert_eq(l.degrade_plan(true).size(), 0, "负载达标时不该有降级计划")

	# 每步都带人话原因（UI 直接显示，不出现空串）
	var explained := l.plan_explained(false)
	assert_eq(explained.size(), 3)
	for step in explained:
		assert_ne(str((step as Dictionary)["reason"]), "", "每个动作都要有人话原因")
		assert_ne(str((step as Dictionary)["action"]), "", "每个动作都要有 id")
	assert_true(PerfLedgerScript.action_reason(PerfLedgerScript.ACT_DISABLE_HOTMAP).contains("热力图"),
		"①的人话原因要点明是热力图")
	assert_true(PerfLedgerScript.action_reason(PerfLedgerScript.ACT_REDUCE_VERIFY).contains("验证"),
		"②的人话原因要点明是验证")
	assert_true(PerfLedgerScript.action_reason(PerfLedgerScript.ACT_DELAY_AUTOSAVE).contains("保存"),
		"③的人话原因要点明是自动保存")

	# cost 的相对大小要与"文档为什么先关热力图"一致（先关最贵的那个）
	assert_gt(l.cost_of(PerfLedgerScript.JOB_HOTMAP), l.cost_of(PerfLedgerScript.JOB_VERIFY),
		"热力图单次构建 = 一次 verify + 逐格探测 ⇒ 应比 verify 贵")
	assert_gt(l.cost_of(PerfLedgerScript.JOB_VERIFY), l.cost_of(PerfLedgerScript.JOB_AUTOSAVE))
	assert_gt(l.cost_of(PerfLedgerScript.JOB_AUTOSAVE), l.cost_of(PerfLedgerScript.JOB_STATS))


# ==================== 2. 超载：一档一档降，顺序不乱 ====================

func test_overload_steps_down_one_level_per_window_in_order() -> void:
	var l := _fresh()
	var enter: int = PerfLedgerScript.DEFAULT_ENTER_MS      # 500
	var hold: int = PerfLedgerScript.DEFAULT_MIN_HOLD_MS     # 2000

	# 单次尖峰不构成降级理由：超载不满 enter 窗口
	assert_eq(l.tick(0, false).size(), 0, "刚超载就降 = 抖动，必须等满 enter 窗口")
	assert_eq(l.tick(enter - 1, false).size(), 0, "超载 %d ms（< %d）不该降级" % [enter - 1, enter])
	# 达标一次即打断超载窗口（滞后阈值）
	assert_eq(l.tick(enter + 10, true).size(), 0, "达标时不该执行降级动作")
	assert_eq(l.level(), 0, "窗口被打断后档位应保持 0（不累积）")

	# 重新持续超载 ⇒ ①关热力图
	assert_eq(l.tick(20_000, false).size(), 0, "重新起窗，本帧不该动作")
	assert_eq(_plain(l.tick(20_500, false)), [PerfLedgerScript.ACT_DISABLE_HOTMAP],
		"窗口满 %d ms ⇒ 只降第一档（关热力图）" % enter)
	assert_eq(l.level(), 1)
	assert_false(l.is_enabled(PerfLedgerScript.JOB_HOTMAP), "第①步要真的关掉热力图")
	assert_true(l.is_enabled(PerfLedgerScript.JOB_VERIFY), "此时还没轮到降校验频率")

	# min_hold：不许紧接着再降一档（防过降）
	assert_eq(l.tick(21_000, false).size(), 0,
		"距上次变档 500ms（< min_hold %d ms）不许再降" % hold)
	assert_eq(l.level(), 1)

	# ②降校验频率
	assert_eq(_plain(l.tick(22_500, false)), [PerfLedgerScript.ACT_REDUCE_VERIFY],
		"保持满 %d ms 且再攒满窗口 ⇒ 降第二档" % hold)
	assert_eq(l.level(), 2)
	assert_true(is_equal_approx(l.rate_of(PerfLedgerScript.JOB_VERIFY),
		PerfLedgerScript.REDUCED_VERIFY_RATE), "校验频率系数应降到 REDUCED_VERIFY_RATE")

	# ③延后自动保存
	assert_eq(_plain(l.tick(24_500, false)), [PerfLedgerScript.ACT_DELAY_AUTOSAVE],
		"同理降第三档")
	assert_eq(l.level(), 3)
	assert_true(is_equal_approx(l.rate_of(PerfLedgerScript.JOB_AUTOSAVE),
		PerfLedgerScript.DELAYED_AUTOSAVE_RATE), "自动保存频率系数应降到 DELAYED_AUTOSAVE_RATE")

	# 每个动作只应用一次（幂等）
	assert_eq(l.applied_count(PerfLedgerScript.ACT_DISABLE_HOTMAP), 1)
	assert_eq(l.applied_count(PerfLedgerScript.ACT_REDUCE_VERIFY), 1)
	assert_eq(l.applied_count(PerfLedgerScript.ACT_DELAY_AUTOSAVE), 1)


# ==================== 3. 减-稳-升：不抖动 ====================

func test_recovery_ramps_back_slowly_without_flapping() -> void:
	var l := _fresh()
	var exit_ms: int = PerfLedgerScript.DEFAULT_EXIT_MS   # 3000
	var t := _degrade_to_full(l)
	assert_eq(l.level(), 3, "前置：已降满档")
	assert_false(l.is_enabled(PerfLedgerScript.JOB_HOTMAP))

	# 「减」后的「稳」：达标不满退出窗口 ⇒ 一档都不许回爬
	var ok_start := t + 100
	assert_eq(l.tick(ok_start, true).size(), 0, "刚达标就回爬 = 抖动")
	assert_eq(l.tick(ok_start + exit_ms - 1, true).size(), 0,
		"达标 %d ms（< %d）仍不该回爬" % [exit_ms - 1, exit_ms])
	assert_eq(l.level(), 3, "退出窗口未满 ⇒ 保持满档")
	assert_false(l.is_enabled(PerfLedgerScript.JOB_HOTMAP), "热力图没被提前打开（这就是不抖动）")
	assert_eq(l.applied_count(PerfLedgerScript.ACT_RESTORE_HOTMAP), 0)

	# 「升」：达标满退出窗口 ⇒ 回爬一档，且是**最后降的最先恢复**
	var t2 := ok_start + exit_ms
	assert_eq(_plain(l.tick(t2, true)), [PerfLedgerScript.ACT_RESTORE_AUTOSAVE],
		"回爬走严格逆序：先恢复自动保存")
	assert_eq(l.level(), 2)
	assert_true(is_equal_approx(l.rate_of(PerfLedgerScript.JOB_AUTOSAVE), 1.0))
	assert_false(l.is_enabled(PerfLedgerScript.JOB_HOTMAP), "热力图最先关 ⇒ 最后才开")

	# 回爬也是一档一档来：刚升一档又立刻达标，不许连升
	assert_eq(l.tick(t2 + 500, true).size(), 0, "回爬后 500ms 内不许再升档")
	assert_eq(l.level(), 2)
	assert_eq(_plain(l.tick(t2 + exit_ms, true)), [PerfLedgerScript.ACT_RESTORE_VERIFY])
	assert_eq(l.level(), 1)
	assert_true(is_equal_approx(l.rate_of(PerfLedgerScript.JOB_VERIFY), 1.0))

	# 中途一次超载：不降档（超载窗口不满），但把达标窗口清零 ⇒ 回爬要重新攒
	var t3 := t2 + exit_ms
	assert_eq(l.tick(t3 + 100, false).size(), 0, "瞬时超载不该立刻降档")
	assert_eq(l.level(), 1)
	assert_eq(l.tick(t3 + 200, true).size(), 0, "超载把达标窗口清零 ⇒ 重新攒满才回爬")
	assert_eq(l.level(), 1)
	assert_eq(_plain(l.tick(t3 + 200 + exit_ms, true)), [PerfLedgerScript.ACT_RESTORE_HOTMAP],
		"窗口重新攒满 ⇒ 回到全开")
	assert_eq(l.level(), 0)
	assert_true(l.is_enabled(PerfLedgerScript.JOB_HOTMAP))

	# 每个恢复动作也只应用一次
	assert_eq(l.applied_count(PerfLedgerScript.ACT_RESTORE_AUTOSAVE), 1)
	assert_eq(l.applied_count(PerfLedgerScript.ACT_RESTORE_VERIFY), 1)
	assert_eq(l.applied_count(PerfLedgerScript.ACT_RESTORE_HOTMAP), 1)


# ==================== 4. 降级要真的省钱（每档负载严格下降） ====================

func test_degrade_actually_lowers_load_at_every_level() -> void:
	var l := _fresh()
	var loads: Array = [l.effective_load()]
	var t := 0
	l.tick(t, false)
	while l.level() < l.max_level():
		t += 1_000
		var before := l.level()
		l.tick(t, false)
		if l.level() != before:
			loads.append(l.effective_load())
	assert_eq(loads.size(), l.max_level() + 1, "每个档位都该记到一次相对负载")
	for i in range(1, loads.size()):
		assert_lt(float(loads[i]), float(loads[i - 1]),
			"第 %d 档负载 %s 必须严格低于上一档 %s（降级不能是空动作）"
			% [i, str(loads[i]), str(loads[i - 1])])


# ==================== 5. restore() 回全开 ====================

func test_restore_returns_everything_to_full() -> void:
	var l := _fresh()
	_degrade_to_full(l)
	assert_eq(l.level(), 3, "前置：已降满档")
	assert_false(l.is_enabled(PerfLedgerScript.JOB_HOTMAP))

	l.restore()
	assert_eq(l.level(), 0, "restore 应回到全开档")
	assert_true(l.is_enabled(PerfLedgerScript.JOB_HOTMAP), "热力图应重新打开")
	var all_on := true
	var every_rate_1 := true
	for job in l.enabled():
		all_on = all_on and bool(l.enabled()[job])
		every_rate_1 = every_rate_1 and is_equal_approx(l.rate_of(String(job)), 1.0)
	assert_true(all_on, "restore 后所有活都该是打开的")
	assert_true(every_rate_1, "restore 后所有频率系数都该回 1.0")
	assert_eq(l.degrade_plan(false).size(), 3, "restore 后降级能力完整可用（不是'降过就没得降'）")
	assert_eq(l.applied_count(PerfLedgerScript.ACT_DISABLE_HOTMAP), 0, "restore 应清空幂等计数")


# ==================== 6. 未知活名 / 未知动作兜底不崩 ====================

func test_unknown_names_fall_back_without_crashing() -> void:
	var l := _fresh()
	assert_false(l.set_enabled("no_such_job", true), "未知活名开关应返回 false（不崩）")
	assert_false(l.is_enabled("no_such_job"), "未知活名视为未开启")
	assert_eq(l.cost_of("no_such_job"), 0.0, "未知活名开销按 0")
	assert_eq(l.rate_of("no_such_job"), 1.0, "未知活名频率系数按 1.0（不装作降过频）")
	assert_false(l.report_ms("no_such_job", 12.0), "未知活名上报应返回 false")
	assert_eq(l.last_ms("no_such_job"), -1.0, "从未上报返回 -1（不假装是 0）")
	assert_false(l.apply_action("no_such_action"), "未知动作应被拒绝")
	assert_ne(PerfLedgerScript.action_reason("no_such_action"), "", "未知动作也要有兜底人话")
	assert_false(l.register_job("", 1.0), "空名不许登记")
	assert_false(l.register_job("bad", -1.0), "负开销不许登记")
	assert_false(l.configure(0, 1_000, 0), "非法阈值应被拒绝")
	assert_false(l.configure(100, -1, 0), "非法阈值应被拒绝")

	# 未知活名在场也不妨碍状态机正常降级
	assert_eq(l.tick(0, false).size(), 0)
	assert_eq(_plain(l.tick(600, false)), [PerfLedgerScript.ACT_DISABLE_HOTMAP])
	assert_eq(l.level(), 1)


# ==================== 7. 连续超载：幂等（不重复叠加降级） ====================

func test_continuous_overload_is_idempotent() -> void:
	var l := _fresh()
	var t := _degrade_to_full(l)
	assert_eq(l.level(), 3, "前置：已降满档")
	assert_eq(l.degrade_plan(false).size(), 0, "满档后没有剩余降级动作")
	assert_eq(l.pending_action(), PerfLedgerScript.ACT_RESTORE_AUTOSAVE,
		"满档时'下一步'只可能是回爬方向")

	# 继续超载一小时（每 1s 采一次）：不该有任何动作，档位不动
	var t2 := t
	for _i in 200:
		t2 += 1_000
		assert_eq(l.tick(t2, false).size(), 0, "满档后继续超载不该再动作")
	assert_eq(l.level(), 3, "档位应稳定在满档")
	assert_eq(l.applied_count(PerfLedgerScript.ACT_DISABLE_HOTMAP), 1, "关热力图只发生一次")
	assert_eq(l.applied_count(PerfLedgerScript.ACT_REDUCE_VERIFY), 1, "降校验只发生一次")
	assert_eq(l.applied_count(PerfLedgerScript.ACT_DELAY_AUTOSAVE), 1, "延后保存只发生一次")


# ==================== 8. 用实测耗时的端到端：自动降级 + 自动回爬 ====================

func test_measured_budget_drives_degrade_then_auto_recovery() -> void:
	var l := _fresh()
	var budget := 3_000.0
	var exit_ms: int = PerfLedgerScript.DEFAULT_EXIT_MS
	# 如实上报（热力图最贵：每次编辑重算；验证次之；保存/统计很轻）
	l.report_ms(PerfLedgerScript.JOB_HOTMAP, 2_500.0)
	l.report_ms(PerfLedgerScript.JOB_VERIFY, 900.0)
	l.report_ms(PerfLedgerScript.JOB_AUTOSAVE, 30.0)
	l.report_ms(PerfLedgerScript.JOB_STATS, 1.0)
	assert_false(l.budget_ok_for(budget), "全开 3431ms > 预算 3000ms ⇒ 应判超载")

	# 一直驱动到"负载够用"为止（不是一路降到底）：这正是降级的目标
	var t := 0
	while not l.budget_ok_for(budget) and t < 60_000:
		t += 500
		l.tick_measured(t, budget)
	assert_eq(l.level(), 1, "关掉热力图后实测只剩 931ms ⇒ 达标，不该继续降（不过降）")
	assert_false(l.is_enabled(PerfLedgerScript.JOB_HOTMAP))
	assert_true(is_equal_approx(l.rate_of(PerfLedgerScript.JOB_VERIFY), 1.0),
		"没继续降 ⇒ 校验频率保持原样")
	assert_true(l.budget_ok_for(budget), "关掉最贵的活后余量充足 ⇒ 达标")

	# 稳定满退出窗口 ⇒ 自动回爬（把热力图放回来）
	var ok_start := t + 100
	assert_eq(l.tick_measured(ok_start, budget).size(), 0, "起窗帧不动作")
	var t2 := ok_start + exit_ms
	assert_eq(_plain(l.tick_measured(t2, budget)), [PerfLedgerScript.ACT_RESTORE_HOTMAP],
		"负载确有富余（关热力图后 931ms）⇒ 才敢把热力图放回来")
	assert_eq(l.level(), 0)

	# 诚实：热力图一放回来实测又超预算 ⇒ 会再关一次；但周期被窗口限住，不是帧级抖动
	assert_false(l.budget_ok_for(budget), "放回热力图 + 实测 3431ms ⇒ 又超预算（真实负载如此）")
	assert_eq(l.tick_measured(t2 + 500, budget).size(), 0,
		"再降也要等满 enter 窗口（限频）")
	assert_eq(_plain(l.tick_measured(t2 + 2_000, budget)), [PerfLedgerScript.ACT_DISABLE_HOTMAP],
		"真实负载下会再关一次：周期 ≈ 秒级且有界，而非每帧抖动")
	assert_eq(l.level(), 1)
