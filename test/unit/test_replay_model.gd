extends GutTest

## 推理链回放模型（ReplayModel，文档「六」推理链回放 + 「H 类」日志内存态）。
##
## 本文件只测**纯逻辑**：日志截断透出、虚拟化窗口计算、每步可读信息。
## 不实例化任何节点——UI 虚拟化由后续切片接，本层不依赖场景树。

const ROW_H := 20.0
const VIEW_H := 200.0   # 200 / 20 = 恰好 10 行可视
const OVER := 2


## 造一个「n 步」的模型（步骤内容不重要，窗口计算只看条数）。
func _loaded(count: int) -> ReplayModel:
	var m := ReplayModel.new()
	var steps: Array = []
	for i in count:
		steps.append({"pos": [i % 10, int(i / 10.0)], "state": "safe"})
	m.load({"steps": steps})
	return m


## ① 截断日志必须**如实透出**：truncated / kept_steps / dropped_steps / 非空 reason。
func test_load_exposes_truncation_truthfully() -> void:
	var m := ReplayModel.new()
	var log := {
		"steps": [{"pos": [0, 0], "state": "safe"}],
		"truncated": true,
		"kept_steps": 1,
		"dropped_steps": 4321,
		"truncated_reason": "字节上限 2097152",
	}
	var r: Dictionary = m.load(log)
	assert_true(bool(r["ok"]), "有 steps 的日志应可加载")
	assert_true(bool(r["truncated"]), "截断必须透出 truncated=true（不许伪装成完整）")
	assert_eq(int(r["kept_steps"]), 1, "kept_steps 应取日志字段")
	assert_eq(int(r["dropped_steps"]), 4321, "dropped_steps 应取日志字段")
	assert_ne(str(r["reason"]), "", "截断必须给出非空原因")
	assert_eq((r["steps"] as Array).size(), 1, "steps 应原样透出")

	# 正常（未截断）日志：truncated=false，kept=总步数，dropped=0。
	var m2 := ReplayModel.new()
	var r2: Dictionary = m2.load({"steps": [{"pos": [0, 0]}, {"pos": [1, 0]}]})
	assert_true(bool(r2["ok"]))
	assert_false(bool(r2["truncated"]), "无 truncated 字段的旧日志应按完整处理")
	assert_eq(int(r2["kept_steps"]), 2)
	assert_eq(int(r2["dropped_steps"]), 0)

	# 截断但缺 kept_steps / truncated_reason：仍不许当成完整，且 reason 要有兜底文案。
	var m3 := ReplayModel.new()
	var r3: Dictionary = m3.load({"steps": [{"pos": [0, 0]}], "truncated": true})
	assert_true(bool(r3["truncated"]), "只带 truncated=true 也算截断")
	assert_eq(int(r3["kept_steps"]), 1, "kept_steps 缺失应退回到 steps.size()")
	assert_ne(str(r3["reason"]), "", "truncated_reason 缺失也要有兜底原因")

	# 空字典：明确判为不可用，而不是静默当成"0 步的完整日志"。
	var m4 := ReplayModel.new()
	var r4: Dictionary = m4.load({})
	assert_false(bool(r4["ok"]))
	assert_ne(str(r4["reason"]), "")


## ② 窗口计算五态：普通 / 顶部 / 底部 / 超范围 / 空。全部不崩且可用。
func test_visible_range_normal_top_bottom_out_of_range_and_empty() -> void:
	var m := _loaded(100)

	# 普通（中部）：scroll=1000 ⇒ 可视行 50..59，上下各 overscan=2 ⇒ 48..61。
	var normal: Dictionary = m.visible_range(1000.0, VIEW_H, ROW_H, OVER)
	assert_eq(int(normal["first"]), 48, "中部窗口上界应减去 overscan")
	assert_eq(int(normal["last"]), 61, "中部窗口下界应加上 overscan")
	assert_almost_eq(float(normal["y_offset_of_first"]), 48.0 * ROW_H, 0.001,
		"y_offset_of_first 应是首行的内容坐标 first*row_h")

	# 顶部：scroll=0 ⇒ 不能向上缓冲（first 夹到 0），下方仍有 overscan。
	var top: Dictionary = m.visible_range(0.0, VIEW_H, ROW_H, OVER)
	assert_eq(int(top["first"]), 0, "顶部 first 应夹到 0")
	assert_eq(int(top["last"]), 9 + OVER, "顶部下界 = 末可视行 + overscan")
	assert_almost_eq(float(top["y_offset_of_first"]), 0.0, 0.001, "顶部首行偏移应为 0")

	# 负滚动：等价于顶部，不崩、不外溢到负数。
	var neg: Dictionary = m.visible_range(-100.0, VIEW_H, ROW_H, OVER)
	assert_eq(int(neg["first"]), 0, "负滚动应夹到顶部")
	assert_true(int(neg["last"]) >= 0, "负滚动仍应返回可用窗口")

	# 底部：scroll = 总高 - 视口高 ⇒ last 夹到最后一行（99），不越界。
	var bottom_scroll := 100.0 * ROW_H - VIEW_H
	var bottom: Dictionary = m.visible_range(bottom_scroll, VIEW_H, ROW_H, OVER)
	assert_eq(int(bottom["last"]), 99, "底部 last 应夹到 count-1")
	assert_true(int(bottom["first"]) >= 0 and int(bottom["first"]) <= 99, "底部 first 应在盘内")

	# 超范围：滚到远远超出末尾 ⇒ 不崩，仍夹在 [0, count-1]。
	var over: Dictionary = m.visible_range(100000.0, VIEW_H, ROW_H, OVER)
	assert_true(int(over["first"]) >= 0 and int(over["last"]) <= 99, "超范围应夹回合法区间")
	assert_true(int(over["first"]) <= int(over["last"]), "超范围应返回有序区间")

	# 空：无步骤 ⇒ 空区间 {first:0, last:-1}（range(first, last+1) 不迭代）。
	var empty := ReplayModel.new()
	empty.load({"steps": []})
	var e: Dictionary = empty.visible_range(0.0, VIEW_H, ROW_H, OVER)
	assert_eq(int(e["first"]), 0)
	assert_eq(int(e["last"]), -1, "空列表应返回空区间而非非法值")

	# 退化入参（行高/视口为 0）也不崩。
	assert_eq(int(m.visible_range(0.0, VIEW_H, 0.0, OVER)["last"]), -1, "row_h=0 应返回空区间")
	assert_eq(int(m.visible_range(0.0, 0.0, ROW_H, OVER)["last"]), -1, "viewport_h=0 应返回空区间")


## ③ overscan 生效：中部窗口比"纯可视行数"上下各多 overscan 行。
func test_overscan_expands_range() -> void:
	var m := _loaded(100)
	var no_over: Dictionary = m.visible_range(1000.0, VIEW_H, ROW_H, 0)
	var with_over: Dictionary = m.visible_range(1000.0, VIEW_H, ROW_H, OVER)
	var visible_rows := 10  # 200 / 20
	assert_eq(int(no_over["last"]) - int(no_over["first"]) + 1, visible_rows,
		"overscan=0 时应恰好覆盖可视行")
	var rendered := int(with_over["last"]) - int(with_over["first"]) + 1
	assert_true(rendered >= visible_rows + 2 * OVER,
		"overscan 生效：渲染行数 %d 应 ≥ 可视行数 + 2*overscan" % rendered)

	# step_count()：UI 给滚动条定长用。
	assert_eq(m.step_count(), 100)


## ④ describe 对缺字段的步骤标 missing 且不崩。
func test_describe_marks_missing_fields_without_crashing() -> void:
	var m := ReplayModel.new()

	# 只有坐标与结论：rule/sources/proof/method 全缺 ⇒ 全进 missing，但不编造。
	var d1: Dictionary = m.describe({"pos": [2, 1], "state": "mine"})
	assert_eq(str(d1["rule_id"]), "", "缺 rule 时 rule_id 应留空")
	var miss1: Array = d1["missing"]
	assert_true(miss1.has("rule"), "缺 rule 应记入 missing")
	assert_true(miss1.has("sources"), "缺 sources 应记入 missing")
	assert_true(miss1.has("proof"), "缺 proof 应记入 missing")
	assert_eq((d1["cells"] as Array).size(), 1, "无依据线索时 cells 只含结论格")
	assert_eq(d1["cells"][0], Vector2i(2, 1), "cells 首位应是结论格（点击定位）")
	assert_ne(str(d1["title"]), "", "有坐标与结论仍应给出标题")

	# 空步骤：不崩，标 step。
	var d0: Dictionary = m.describe({})
	assert_true((d0["missing"] as Array).has("step"), "空步骤应记为 missing=step")
	assert_eq((d0["cells"] as Array).size(), 0)

	# 完整步骤：无 missing；cells = 结论格 + 依据线索格（去重）。
	var full := {
		"pos": [3, 3], "state": "safe", "method": "enumeration",
		"sources": [[1, 1], [1, 2]], "rule": "classic", "proof": "枚举排除",
	}
	var df: Dictionary = m.describe(full)
	assert_eq((df["missing"] as Array).size(), 0, "字段齐全不应有 missing")
	assert_eq(str(df["rule_id"]), "classic")
	var cells: Array = df["cells"]
	assert_eq(cells.size(), 3, "cells 应是结论格 + 2 个依据线索格")
	# 顺序契约（UI 依赖）：cells[0] 恒为结论格，其后按 sources 原顺序、去重。
	assert_eq(cells[0], Vector2i(3, 3), "结论格应在首位（+点击定位取 cells[0]）")
	assert_eq(cells[1], Vector2i(1, 1), "依据线索应保持 step.sources 的原顺序")
	assert_eq(cells[2], Vector2i(1, 2), "依据线索顺序 = 日志中的顺序")
	assert_true(str(df["evidence"]).contains("classic"), "evidence 应含规则")

	# 依据线索与结论格重合时去重。
	var overlap: Dictionary = m.describe({"pos": [1, 1], "state": "safe", "sources": [[1, 1]]})
	assert_eq((overlap["cells"] as Array).size(), 1, "重复格应去重")


## step_at：越界/未加载返回空 + 原因，合法索引返回步骤。
func test_step_at_out_of_range_returns_empty_with_reason() -> void:
	var m := _loaded(3)
	var ok0: Dictionary = m.step_at(0)
	assert_true(bool(ok0["ok"]))
	assert_eq((ok0["step"] as Dictionary).size(), 2, "应返回真实步骤 dict")

	var low: Dictionary = m.step_at(-1)
	assert_false(bool(low["ok"]))
	assert_true((low["step"] as Dictionary).is_empty(), "越界应返回空步骤")
	assert_ne(str(low["reason"]), "", "越界应给出原因")

	var high: Dictionary = m.step_at(3)
	assert_false(bool(high["ok"]))
	assert_ne(str(high["reason"]), "", "越界应给出原因")

	var fresh := ReplayModel.new()
	var unloaded: Dictionary = fresh.step_at(0)
	assert_false(bool(unloaded["ok"]), "未加载应返回空")
	assert_ne(str(unloaded["reason"]), "", "未加载应给出原因")


## ⑤ 大日志（数万步）下 visible_range 只做算术：耗时应远在毫秒级。
func test_visible_range_is_pure_arithmetic_on_large_log() -> void:
	var m := _loaded(50000)
	assert_eq(m.step_count(), 50000, "应能承载数万步（与 UI 虚拟化配套）")

	var calls := 5000
	var acc := 0
	var t0 := Time.get_ticks_usec()
	for i in calls:
		var r: Dictionary = m.visible_range(float(i % 9000) * ROW_H, VIEW_H, ROW_H, 4)
		acc += int(r["first"]) + int(r["last"])
	var elapsed_us := Time.get_ticks_usec() - t0
	# 防"空循环式假通过"：累加值必须真的来自窗口结果。
	assert_gt(acc, 0, "窗口结果应可用（累加值非零）")
	# 依据：窗口计算只是几次除法/取整（µs 级）；若像真实节点那样实例化，5000 次必然秒级。
	# 阈值放宽到 1s（≈200µs/次，约为实测的数十倍），留足 CI 负载抖动余量、避免假红。
	assert_true(elapsed_us < 1000000,
		"5000 次 visible_range 应在毫秒级（实测 %d µs）" % elapsed_us)
