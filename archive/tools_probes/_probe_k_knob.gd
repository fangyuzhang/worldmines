extends SceneTree

## k 旋钮实装验证（2026-09-16）：o4 的 k_ratio 生效 / k_public=false（不知 k 口径）可生成率 / 落盘标记。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}


func _initialize() -> void:
	var api: Object = load("res://core/mod_api.gd").new()
	api.load_mod("res://demo/mods/o4_bianjing")
	print("=== k 旋钮验证：o4 ===")
	var rule: Object = RuleRegistry.default().resolve(&"o4")
	# 1) k_ratio 生效：place_mines 的 _r2 规模 = floor(n × ratio)
	for r in [0.25, 0.2, 0.3]:
		rule.call("set_k_ratio", r)
		rule.call("place_mines", RandomNumberGenerator.new(), 8, 8, 26)
		var r2: Dictionary = rule.get("_r2")
		print("  ratio=%.2f -> k=%d（期望 %d）" % [r, r2.size(), int(floor(64.0 * r))])
	rule.call("set_k_ratio", 0.25)
	# 2) k_public=false（「不知 k」演绎口径）：生成成功 = 无 Σw=k 也可序贯推完（满足 R01）
	print("  --- k_public=false 生成（3 seed/尺寸）---")
	var total := 0
	var okn := 0
	for side in [5, 6, 7, 8, 9]:
		var mines: int = int(R07_MINES[side])
		for t in 3:
			total += 1
			rule.call("set_k_public", false)
			var lv: Dictionary = PuzzleGenerator.new().generate_with_rules(
				"o4", [], Vector2i(side, side), mines, 200 + t, 0, 50, null, side * side * 6000)
			var ok := not lv.is_empty()
			if ok:
				okn += 1
				print("  %dx%d seed=%d: OK  k_public=%s 难度=%.2f" % [
					side, side, 200 + t, str(lv.get("k_public", null)),
					float(lv.get("difficulty_profile", {}).get("difficulty", 0.0))])
			else:
				print("  %dx%d seed=%d: FAIL（无 Σ 演绎下推不动）" % [side, side, 200 + t])
		rule.call("set_k_public", true)
	print("=== 不公开盘可生成率：%d/%d ===" % [okn, total])
	# 3) 公开档（默认）回归：k_public 字段不应出现
	rule.call("set_k_public", true)
	var lv2: Dictionary = PuzzleGenerator.new().generate_with_rules(
		"o4", [], Vector2i(6, 6), 14, 300, 0, 50, null, 200_000)
	print("公开档：生成=%s  k_public 字段=%s（应 absent/null）" % [
		str(not lv2.is_empty()), str(lv2.get("k_public", null))])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
