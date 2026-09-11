# gen_standard_levels.gd —— 生成 10 个标准难度关卡（classic、5×5、10 雷、带问号）
# 用自举式规则平台 generate_with_rules；遮蔽 mask_count=1（每关 1 个 ? 格）。
extends SceneTree

const TOTAL := 10
const SIZE := Vector2i(5, 5)
const MINES := 7
const MASK := 1

func _init() -> void:
	var gen := PuzzleGenerator.new()
	var generated := 0
	var seed := 1
	var max_seed := 200
	while generated < TOTAL and seed <= max_seed:
		var level := gen.generate_with_rules("classic", [], SIZE, MINES, seed, MASK)
		if not level.is_empty():
			var name := "generated_%02d" % (generated + 1)
			level["name"] = name
			var f := FileAccess.open("res://levels/%s.json" % name, FileAccess.WRITE)
			f.store_string(JSON.stringify(level, "  "))
			f.close()
			var masked_n := 0
			for rc in level["revealed"]:
				if rc.has("interval"):
					masked_n += 1
			print("%s: seed=%d 雷=%d 初始格=%d 问号=%d" % [name, seed, level["total_mines"], level["revealed"].size(), masked_n])
			generated += 1
		seed += 1
	print("=== 完成：共生成 %d 个关卡（seed 遍历到 %d）===" % [generated, seed - 1])
	quit()
