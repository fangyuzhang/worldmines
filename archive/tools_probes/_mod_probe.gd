extends SceneTree

## hpair 试验 Mod 端到端探测：加载 mod（生产路径 ModAPI.load_mod）→ 注册检查 →
## is_feasible 全尺寸 → 小范围生成（每尺寸 3 关，seed 预算按尺寸）→ ProofLog 复核 → 产出。
## 目的：验证「非内置 Mod 规则」能否走通生成器完整链路，找出接入层的问题。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
const SEED_MAX := {5: 40, 6: 40, 7: 40, 8: 30, 9: 20}  # 小题库规模
const PER_TYPE := 10
const OUT := "user://mod_probe_hpair"


func _timeout_for(side: int) -> int:
	return maxi(30_000, side * side * 1500)


func _wipe_dir(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for sub in d.get_directories():
		_wipe_dir(dir_path.path_join(sub))
	for f in d.get_files():
		d.remove(f)
	DirAccess.remove_absolute(dir_path)


func _initialize() -> void:
	# 1) 加载 mod（与玩家安装 mod 同路径：ModAPI.load_mod）
	var api: Object = load("res://core/mod_api.gd").new()
	var r: Dictionary = api.load_mod("res://demo/mods/hpair_rule_mod")
	print("mod 加载: ok=%s id=%s reason=%s" % [str(r.get("ok")), str(r.get("mod_id", "")), str(r.get("reason", ""))])
	var reg := RuleRegistry.default()
	var rule: Object = reg.resolve(&"hpair")
	if rule == null:
		print("!!! hpair 未注册——Mod 接入失败，终止")
		CliShutdown.request_exit(1)
		return
	print("规则注册成功: id=%s kind=%s desc=%s" % [
		str(rule.call("get_rule_id")), str(rule.call("get_kind")), str(rule.call("describe").get("name"))])
	print("custom_ids: " + str(reg.custom_ids()))

	# 2) 数学可行性（RuleFeasibility 真值查询对 mod 规则）
	for side in SIZES:
		var f: bool = RuleFeasibility.query("classic", ["hpair"], side, SIZES[side])
		print("is_feasible %dx%d=%d雷: %s" % [side, side, SIZES[side], str(f)])

	# 3) 小范围生成（先清掉上次产出，保证每次实验独立可比）
	_wipe_dir(OUT)
	DirAccess.make_dir_recursive_absolute(OUT)
	var stats := {"ok": 0, "empty": 0, "tier_empty": 0, "proof_fail": 0}
	var t_all := Time.get_ticks_msec()
	var gen := PuzzleGenerator.new()
	for side in SIZES:
		var side_dir := "%s/%dx%d" % [OUT, side, side]
		DirAccess.make_dir_recursive_absolute(side_dir)
		var made := 0
		var tried := 0
		var t0 := Time.get_ticks_msec()
		for seed in range(1, int(SEED_MAX[side]) + 1):
			if made >= PER_TYPE:
				break
			tried += 1
			printerr("[%dx%d] seed=%d ..." % [side, side, seed])
			var m0 := Time.get_ticks_msec()
			var level: Dictionary = gen.generate_with_rules(
				"classic", ["hpair"], Vector2i(side, side), SIZES[side], seed, 0, 50, null, _timeout_for(side))
			var cost := float(Time.get_ticks_msec() - m0) / 1000.0
			if level.is_empty():
				stats["empty"] += 1
				printerr("  empty (%.0fs)" % cost)
				continue
			var dp: Dictionary = level.get("difficulty_profile", {})
			var diff := float(dp.get("difficulty", 0.0))
			var tier := Difficulty.tier_of(diff)
			if tier == "":
				stats["tier_empty"] += 1
				printerr("  进不了档 difficulty=%.2f (%.0fs)" % [diff, cost])
				continue
			var log: Dictionary = ProofLog.build(level)
			if not bool(log.get("solved", false)):
				stats["proof_fail"] += 1
				printerr("  ProofLog 拒收: %s" % str(log.get("reason", "")))
				continue
			made += 1
			stats["ok"] += 1
			level["name"] = "%s_%02d" % [tier, made]
			level["difficulty"] = diff
			var f := FileAccess.open("%s/%s_%02d.json" % [side_dir, tier, made], FileAccess.WRITE)
			f.store_string(JSON.stringify(level, "  "))
			f.close()
			printerr("  -> %s_%02d difficulty=%.2f (%.0fs)" % [tier, made, diff, cost])
		print("%dx%d: %d/%d 关（试 %d seed，%.0fs）" % [
			side, side, made, PER_TYPE, tried, float(Time.get_ticks_msec() - t0) / 1000.0])

	var elapsed := float(Time.get_ticks_msec() - t_all) / 1000.0
	print("=== 完成（%.0fs）| 入库 %d | 空 %d | 未进档 %d | ProofLog 拒 %d ===" % [
		elapsed, stats["ok"], stats["empty"], stats["tier_empty"], stats["proof_fail"]])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
