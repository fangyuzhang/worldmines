extends GutTest

## 证明日志（ProofLog 落盘，v2.9.3）
##
## 背景：`ReasoningStep.to_dict()` 早已存在，但从没有任何地方把它存下来——
## 证明日志只有内存里的临时数组，对局结束即丢。本模块让它变成可落盘、可复验的产物。

const SIZE := Vector2i(5, 5)
const MINES := 4


func _try_generate() -> Dictionary:
	var gen := PuzzleGenerator.new()
	for s in 10:
		var level: Dictionary = gen.generate_with_rules("classic", [], SIZE, MINES, 1000 + s * 7)
		if not level.is_empty():
			return level
	return {}


## 正例：可解关卡应推出完整链，且每一步都落在盘内。
func test_build_solves_solvable_level() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate()
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var log: Dictionary = ProofLog.build(level)
	assert_true(bool(log.get("solved", false)), "序贯可解关卡应被推完；reason=%s" % log.get("reason", ""))
	var steps: Array = log.get("steps", [])
	assert_gt(steps.size(), 0, "应产出至少一条推理步骤")
	for s in steps:
		var d: Dictionary = s
		var pos: Array = d.get("pos", [])
		assert_eq(pos.size(), 2, "步骤应带 [x,y] 坐标")
		assert_true(int(pos[0]) >= 0 and int(pos[0]) < SIZE.x, "x 应在盘内")
		assert_true(int(pos[1]) >= 0 and int(pos[1]) < SIZE.y, "y 应在盘内")
		assert_true(str(d.get("state", "")) in ["safe", "mine"], "结论只能是 safe/mine")


## 反例：没有任何已翻开线索的关卡推不动，应优雅返回 solved=false 而不是报错。
func test_build_on_unsolvable_input_is_graceful() -> void:
	var log: Dictionary = ProofLog.build({
		"size": {"rows": 3, "cols": 3}, "total_mines": 1,
		"mines": [{"r": 0, "c": 0}], "revealed": [],
	})
	assert_false(bool(log.get("solved", false)), "无线索盘不应被判为已解出")
	assert_eq((log.get("steps", []) as Array).size(), 0, "不应产出步骤")
	assert_ne(str(log.get("reason", "")), "", "应给出原因")


func test_build_on_empty_input_is_graceful() -> void:
	var log: Dictionary = ProofLog.build({})
	assert_false(bool(log.get("solved", false)), "空输入不应崩溃")
	assert_ne(str(log.get("reason", "")), "", "应给出原因")


func test_key_for_sanitizes_path() -> void:
	assert_eq(ProofLog.key_for("res://levels/generated_01.json"), "generated_01", "应去掉目录与扩展名")
	assert_eq(ProofLog.key_for("user://gen_levels/classic_5_3.json"), "classic_5_3", "user:// 路径同样适用")
	assert_false(ProofLog.key_for("a b:c.json").contains(" "), "非法字符应被替换")
	assert_false(ProofLog.key_for("a b:c.json").contains(":"), "非法字符应被替换")
	assert_eq(ProofLog.key_for(""), "level", "空路径应有兜底 key")


func test_save_load_roundtrip_and_verify() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate()
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var log: Dictionary = ProofLog.build(level)
	var key := "test_proof_roundtrip"
	var path := ProofLog.save_log(key, log)
	assert_ne(path, "", "应写入成功")
	if path == "":
		return

	var back: Dictionary = ProofLog.load_log(key)
	assert_eq((back.get("steps", []) as Array).size(), (log.get("steps", []) as Array).size(),
		"读回后步数应一致")
	assert_eq(bool(back.get("solved", false)), bool(log.get("solved", false)), "solved 应一致")

	# 可复验性：重算一遍必须逐步一致
	var v: Dictionary = ProofLog.verify(back, level)
	assert_true(bool(v.get("ok", false)), "应可复验：%s" % v.get("reason", ""))


## 篡改检测：改掉任一步，复验必须失败（否则「证明」形同虚设）。
func test_verify_detects_tampering() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate()
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var log: Dictionary = ProofLog.build(level)
	var steps: Array = log.get("steps", [])
	if steps.is_empty():
		pending("该关无步骤，跳过篡改检测")
		return
	# 1) 改结论类型
	var tampered := log.duplicate(true)
	(tampered["steps"] as Array)[0]["state"] = "mine" if str((steps[0] as Dictionary)["state"]) == "safe" else "safe"
	assert_false(bool(ProofLog.verify(tampered, level).get("ok", true)), "改结论类型应被检出")
	# 2) 删一步
	var dropped := log.duplicate(true)
	(dropped["steps"] as Array).remove_at(0)
	assert_false(bool(ProofLog.verify(dropped, level).get("ok", true)), "删步骤应被检出")
	# 3) 空日志
	assert_false(bool(ProofLog.verify({}, level).get("ok", true)), "空日志应被拒")


func test_signature_is_deterministic() -> void:
	var level := _try_generate()
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var b := Board.new()
	b.load_level(level)
	var s1 := ProofLog.signature(b)
	var s2 := ProofLog.signature(b)
	assert_eq(s1, s2, "同盘面签名应稳定")
	assert_ne(s1, "", "签名应非空（有初始翻开格）")


func test_find_next_returns_first_stage_on_initial_board() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate()
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var log: Dictionary = ProofLog.build(level)
	assert_true(bool(log.get("solved", false)), "关卡应可解出完整链")
	var b := Board.new()
	b.load_level(level)
	var stage: Array = ProofLog.find_next(log, b)
	assert_gt(stage.size(), 0, "初始盘面应匹配到第一阶段")
	for s in stage:
		var d: Dictionary = s
		var pos: Array = d["pos"]
		var p := Vector2i(int(pos[0]), int(pos[1]))
		assert_eq(b.grid.get_cell(p).state, Cell.State.HIDDEN, "阶段结论格应是隐藏格")


func test_find_next_empty_on_no_match() -> void:
	var b := Board.new()
	var grid := RectGrid.new()
	grid.setup(3, 3)
	b.grid = grid
	assert_eq(ProofLog.find_next({"steps": []}, b).size(), 0, "空链应返回空")
	# 步骤缺少 precondition_signature 时不应被匹配
	var no_sig := {"steps": [{"pos": [0, 0], "state": "safe"}]}
	assert_eq(ProofLog.find_next(no_sig, b).size(), 0, "无签名步骤不应被匹配")


func test_cert_hash_present_and_stable() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var level := _try_generate()
	assert_false(level.is_empty(), "关卡应能生成")
	if level.is_empty():
		return
	var h1 := str(ProofLog.build(level).get("cert_hash", ""))
	var h2 := str(ProofLog.build(level).get("cert_hash", ""))
	assert_ne(h1, "", "cert_hash 应非空")
	assert_eq(h1, h2, "同盘面 cert_hash 应稳定")
