extends GutTest

## 童趣化小精灵（GDD 26 号「方块格子岛」）覆盖校验。
##
## 验证 codex.gd 的 SPRITES / SPRITE_LINES 恰覆盖 15 个规则（8 线索 + 7 全局）、
## 台词非空、名字不重复。防止「加了新规则却忘了配小精灵」的漂移。

const Codex := preload("res://ui/codex.gd")

const CLUE_RULES := ["classic", "4n", "clock", "hv", "fr", "loopruns", "distsum", "sc"]
const GLOBAL_RULES := ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]


func test_sprites_cover_all_15_rules() -> void:
	var all: Array = CLUE_RULES + GLOBAL_RULES
	assert_eq(all.size(), 15, "应恰有 15 个规则（8 线索 + 7 全局）")
	for id in all:
		assert_true(Codex.SPRITES.has(id), "规则 %s 应有小精灵名" % id)
		assert_true(Codex.SPRITE_LINES.has(id), "规则 %s 应有台词" % id)
		if Codex.SPRITE_LINES.has(id):
			assert_ne(str(Codex.SPRITE_LINES[id]), "", "规则 %s 的台词应非空" % id)
	assert_eq(Codex.SPRITES.size(), 15, "小精灵名映射应恰 15 项")
	assert_eq(Codex.SPRITE_LINES.size(), 15, "台词映射应恰 15 项")


func test_sprite_names_are_distinct() -> void:
	var names := {}
	for id in Codex.SPRITES:
		names[Codex.SPRITES[id]] = true
	assert_eq(names.size(), Codex.SPRITES.size(), "小精灵名应互不相同（不重复）")
