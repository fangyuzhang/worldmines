extends SceneTree

## 遮蔽前置 vs 后置难度对照实验（方向 1 验收，2026-09-16）
## o5_sanjiao 实验台（信息型简单算子，与历史 A/B/C/D 实验同台）：
##   ① 基线（无遮蔽） ② 后置（mask_pre=false） ③ 前置（mask_pre=true） ④ 前置 lo=0（完全弱化）
## 用法：godot --headless --path . -s res://tools/_probe_mask_pre.gd -- [mask_count] [seeds_per_size]
const CliShutdown := preload("res://tools/cli_shutdown.gd")

## R07 雷数表（与历史 O5 实验台/设计预检同口径）
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var mask_n := int(args[0]) if args.size() >= 1 else 12
	var seeds := int(args[1]) if args.size() >= 2 else 2
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/o5_sanjiao")
	print("mod 加载: ok=%s" % str(r.get("ok")))
	print("=== 遮蔽 前置/后置 难度对照（o5_sanjiao, mask=%d, %d seed/尺寸, 取组内最高难度）===" % [mask_n, seeds])
	print("%-7s | %-9s %-9s %-9s %-9s" % ["尺寸", "基线", "后置", "前置", "前置lo0"])
	for side in [5, 6, 7, 8, 9]:
		var mines: int = int(R07_MINES[side])
		var row: Array = []
		for cfg in [0, 1, 2, 3]:
			var best := 0.0
			var ok_n := 0
			for t in seeds:
				var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
					"o5", [], Vector2i(side, side), mines, 100 + t,
					mask_n if cfg > 0 else 0, 50, null, side * side * 6000, 0.0,
					0 if cfg == 3 else 1, 0, cfg >= 2)
				if lv.is_empty():
					continue
				ok_n += 1
				best = maxf(best, float(lv.get("difficulty_profile", {}).get("difficulty", 0.0)))
			row.append("%.2f%s" % [best, "(n%d)" % ok_n if ok_n < seeds else ""])
		print("%-7s | %-9s %-9s %-9s %-9s" % ["%dx%d" % [side, side], row[0], row[1], row[2], row[3]])
	print("=== 判读：前置组显著高于基线/后置 → 方向 1 有效（目标：基线 0.03–0.10 之上出现提升）===")
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
