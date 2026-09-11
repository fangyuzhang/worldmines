# test_bench_tmp.gd —— 临时定位：5x5 4雷 各 seed 生成是否卡死（测完即删）
extends GutTest


func test_find_hang() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用")
		return
	var gen := PuzzleGenerator.new()
	for seed in range(1, 6):
		print("SEED %d 开始" % seed)
		var t0 := Time.get_ticks_msec()
		var lv := gen.generate_with_rules("classic", [], Vector2i(5, 5), 4, seed)
		print("SEED %d 完成: %s (%dms)" % [seed, "空" if lv.is_empty() else "成功", Time.get_ticks_msec() - t0])
