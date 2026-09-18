extends GutTest

## 童趣化小精灵（GDD 26 号「方块格子岛」）覆盖校验。
##
## 2026-09-18 重写口径：原版校验的是「恰 15 个规则」（旧 16 变体 + dt），而变体池已按
## GDD 终版 §4 收敛为**三轴 22 席 + classic + dt**，`codex.gd` 的 SPRITES 也随之补到
## 37 项（含 6 个等价席位的同名别名）。
##
## 现在的契约**面向目录**而不是某个写死的数字：
##   · 选关页 / 图鉴里会出现的每个规则都必须有小精灵名与台词；
##   · 同一**目录内**名字不得重复；
##   · 但不同 id **可以**同名——那是同一条规则的两份实现（如 o8=clock 都叫「圈圈」），
##     玩家看到的该是同一个精灵。
## 写成目录派生还能保证：以后加算子时忘了配小精灵，这里会立刻红。

const Codex := preload("res://ui/codex.gd")


## 目录里的每个规则（classic + 三轴 + dt）都要有精灵名与台词。
func test_every_catalog_rule_has_sprite() -> void:
	var ids := _catalog_rule_ids()
	assert_true(ids.size() >= 23,
			"目录应至少含 23 个规则（classic + 官方 22 席），实际 %d" % ids.size())
	for id in ids:
		assert_true(Codex.SPRITES.has(id), "规则 %s 应有小精灵名" % id)
		assert_true(Codex.SPRITE_LINES.has(id), "规则 %s 应有台词" % id)
		if Codex.SPRITE_LINES.has(id):
			assert_ne(str(Codex.SPRITE_LINES[id]), "", "规则 %s 的台词应非空" % id)


## 名字在**目录内**必须唯一（否则玩家以为两个不同规则是同一个精灵）。
func test_sprite_names_are_distinct_in_catalog() -> void:
	var seen := {}
	for id in _catalog_rule_ids():
		var nm := str(Codex.SPRITES.get(id, ""))
		assert_ne(nm, "", "目录规则 %s 应有名字" % id)
		assert_false(seen.has(nm),
				"目录内名字重复：%s（%s 与 %s）" % [nm, str(seen.get(nm, "")), id])
		seen[nm] = id


## 等价席位复用同名同台词：它们是同一条规则的两份实现，玩家看到的该是同一个精灵。
## 这同时钉住了「改一处两处同步」——只改一边就会红。
func test_equivalent_seats_share_sprite() -> void:
	for pair in [["o8", "clock"], ["o10", "loopruns"], ["s1", "pf"],
			["z1", "mx"], ["z2", "rl"], ["z3", "qd"]]:
		var a := str(pair[0])
		var b := str(pair[1])
		assert_eq(str(Codex.SPRITES.get(a, "")), str(Codex.SPRITES.get(b, "")),
				"%s 与 %s 同规则，精灵名应一致" % [a, b])
		assert_eq(str(Codex.SPRITE_LINES.get(a, "")), str(Codex.SPRITE_LINES.get(b, "")),
				"%s 与 %s 同规则，台词应一致" % [a, b])


## 目录里会出现的规则 id（与选关页 / 图鉴同一事实源）。
## 用**静态三轴常量**而不是 `clue_ids()` / `global_ids()`：后两者含运行期加载的 Mod 规则
## （测试进程由 `test/_pre_run.gd` 装配了 legacy_rules，于是膝下会多出 knight 等），
## 而「终版口径该有哪些变体」是 GDD 决定的事，不随谁加载了 Mod 而变。
func _catalog_rule_ids() -> Array:
	var ids: Array = ["classic"]
	ids.append_array(VariantCatalog.OBS_IDS)
	ids.append_array(VariantCatalog.STRUCT_IDS)
	ids.append_array(VariantCatalog.CONSERVE_IDS)
	ids.append("dt")   # 唯一保留的旧单算子：只单独成关，不进组合轴
	return ids
