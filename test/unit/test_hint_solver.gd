extends GutTest

## 验证提示求解器（HintSolver）的 L2 联合枚举：
## classic_01 中「3」(3,4) 与「1」(4,3) 共享 (3,3)/(4,4) 两格，
## 联立枚举应推出 (2,3)、(2,4) 必雷（用户反馈的「子集+交集」推理）。
func test_hint_l2_intersection() -> void:
	var jf := FileAccess.open("res://levels/classic_01.json", FileAccess.READ)
	assert_true(jf != null, "关卡文件存在")
	var level: Variant = JSON.parse_string(jf.get_as_text())
	jf.close()
	assert_true(level is Dictionary, "关卡 JSON 可解析")

	var b := Board.new()
	b.load_level(level)

	var hs := HintSolver.new()
	var steps: Array = hs.hint(b)

	var found_23 := false  # (2,3) -> Vector2i(3,2)
	var found_24 := false  # (2,4) -> Vector2i(4,2)
	for s in steps:
		if s.pos == Vector2i(3, 2) and s.state == "mine":
			found_23 = true
		if s.pos == Vector2i(4, 2) and s.state == "mine":
			found_24 = true

	assert_true(found_23, "(2,3) 应推为雷（3 与 1 交叉推理）")
	assert_true(found_24, "(2,4) 应推为雷（3 与 1 交叉推理）")
