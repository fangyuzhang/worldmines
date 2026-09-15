# test_game_over_next.gd —— 终局页「下一关」入口
#
# 关卡解锁依赖「通关上一关」，原先胜利后只有「重新开始 / 返回菜单」，
# 玩家每次都得手动退回选关页重走一遍。本测试锁死新增入口的存在性与适用边界。
extends GutTest

var _go


func before_each() -> void:
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	_go = load("res://ui/game_over.tscn").instantiate()
	add_child_autofree(_go)


func _button(text: String) -> Button:
	return _find(_go, text)


func _find(n: Node, text: String) -> Button:
	if n is Button and n.text == text:
		return n
	for c in n.get_children():
		var r: Button = _find(c, text)
		if r != null:
			return r
	return null


# G1：终局页应具备「下一关」入口
func test_g1_next_button_exists() -> void:
	assert_not_null(_button("下一关"), "胜利后应能直接进下一关")
	assert_not_null(_button("重新开始"))
	assert_not_null(_button("返回菜单"))


# G2：手工关（res://levels/…）不在生成序列里 → 不显示该入口
func test_g2_hidden_for_manual_level() -> void:
	var btn := _button("下一关")
	assert_not_null(btn)
	_go._on_game_ended(true)
	assert_false(btn.visible, "非 gen 序列关卡没有「下一关」概念")
	assert_true(_button("撤回") != null and not _button("撤回").visible,
			"胜利局不提供撤回")
