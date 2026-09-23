extends SceneTree

## 验证「前置遮蔽是否真正生效」：同 seed 跑 基线 / 前置，对比盘面差异。
## 判据：若前置的 revealed 集合与基线不同 → 参数生效（差异度 = 生效强度证据）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")


static func _cells(lv: Dictionary) -> Array:
	var s: Array = []
	for rv in lv.get("revealed", []):
		s.append("%d,%d" % [int(rv["c"]), int(rv["r"])])
	s.sort()
	return s


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var side := int(args[0]) if args.size() >= 1 else 8
	var seed_v := int(args[1]) if args.size() >= 2 else 100
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o5_sanjiao")
	var mines := 26 if side == 8 else (20 if side == 7 else 14)
	print("=== 前置生效性验证 %dx%d seed=%d ===" % [side, side, seed_v])
	var lv0: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"o5", [], Vector2i(side, side), mines, seed_v, 0, 50, null, side * side * 6000)
	var lv1: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"o5", [], Vector2i(side, side), mines, seed_v, 12, 50, null, side * side * 6000, 0.0, 1, 0, true)
	if lv0.is_empty() or lv1.is_empty():
		print("生成失败: base=%s pre=%s" % [str(lv0.is_empty()), str(lv1.is_empty())])
		CliShutdown.request_exit(0)
		return
	var c0 := _cells(lv0)
	var c1 := _cells(lv1)
	var s0 := {}
	for c in c0:
		s0[c] = true
	var inter := 0
	for c in c1:
		if s0.has(c):
			inter += 1
	print("基线: 线索 %d 条 难度 %.2f" % [
		(lv0.get("revealed", []) as Array).size(),
		float(lv0.get("difficulty_profile", {}).get("difficulty", 0.0))])
	print("前置: 线索 %d 条 难度 %.2f" % [
		(lv1.get("revealed", []) as Array).size(),
		float(lv1.get("difficulty_profile", {}).get("difficulty", 0.0))])
	print("revealed 交集 %d / 并集 %d —— 集合%s" % [
		inter, c0.size() + c1.size() - inter, "相同（未生效！）" if inter == c0.size() and c0.size() == c1.size() else "不同（生效）"])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
