extends SceneTree

# fill_window.gd —— 按「峰值窗口」补产关卡（v4.1 三档严格梯度）
#
# 为什么单独成工具（而不是直接用 batch_all_variants.gd）：
#   ① 量产工具是 16 位置参数的重型入口，依赖 `VariantAxes` 等较新的 core 类 ——
#      服务器上的副本可能不含这些依赖（实测：整包推送后 parse error），
#      而补产只需要「生成 → 窗口验收 → 落盘」这一条最稳的链路；
#   ② 本工具只依赖长期稳定的 API（PuzzleGenerator / RuleFeasibility / Difficulty /
#      CliShutdown），**本地与服务器行为一致**，且输出目录结构直接喂现有
#      收割 → retier_stock.py → import_batch_to_lib.gd 流水线。
#
# 用法：
#   godot --headless --path . -s res://tools/fill_window.gd -- \
#       <clue> <globals_csv|-> <sizes_csv> <lo> <hi> <per_side> <max_cand> <budget_s> <mods_csv|-> <out_dir>
#   例（补 s1 噩梦档 @7-9）：
#     godot --headless --path . -s res://tools/fill_window.gd -- \
#       classic s1 7,8,9 6 20 100 3000 7200 s1_jinxing user://fill_v41_s1_hard
#
# 关键口径（与量产/入库同一判据，避免"假梯度"）：
#   · 验收 = peak ∈ [lo, hi]，peak = `difficulty_profile.max_complexity`；
#   · 生成用 target=0（最大删线索）——探针实测此口径命中率最高；
#   · 落盘 = `<out>/<combo>/<SxS>/<tier>_<NN>.json`，tier 由 `Difficulty.tier_of_peak(peak)` 定，
#     因此文件名的档位与内容**逐一致**（入库闸门会再校验一遍）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

var _clue := "classic"
var _globals: Array = []
var _sides: Array = [7, 8, 9]
var _lo := 6
var _hi := 20
var _per_side := 100
var _max_cand := 3000
var _budget_s := 7200
var _mods := ""
var _out := "user://fill_window"


func _timeout_for(side: int) -> int:
	return maxi(30_000, side * side * 3000)


func _combo_name() -> String:
	var parts: Array = [_clue]
	for g in _globals:
		parts.append(str(g))
	return "_".join(parts)


func _initialize() -> void:
	if not RuleCpSat.available():
		push_error("[补产] CP-SAT 后端不可用（缺 .NET/mono 运行时）——继续只会零产出。")
		CliShutdown.request_exit(1)
		return
	var args := OS.get_cmdline_user_args()
	if args.size() < 10:
		push_error("[补产] 参数不足。用法：-- <clue> <globals|-> <sizes> <lo> <hi> <per_side> <max_cand> <budget_s> <mods|-> <out>")
		CliShutdown.request_exit(1)
		return
	_clue = str(args[0])
	_globals = [] if str(args[1]) == "-" else str(args[1]).split(",", false)
	_sides = []
	for s in str(args[2]).split(",", false):
		_sides.append(int(s))
	_lo = int(args[3])
	_hi = int(args[4])
	_per_side = int(args[5])
	_max_cand = int(args[6])
	_budget_s = int(args[7])
	_mods = str(args[8])
	if str(args[9]) != "-":
		_out = str(args[9])
	if _mods != "" and _mods != "-":
		for m in _mods.split(",", false):
			var entry := "res://demo/mods/%s/entry.gd" % str(m).strip_edges()
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
					print("  [mod] 已加载: %s" % str(m))
			else:
				push_error("Mod 入口不存在: " + entry)
	# 窗口合法性（与量产工具同口径：宁可在启动时失败，也不要静默跑空）
	if _lo < 0 or _hi < _lo or _hi >= Difficulty.PEAK_OVER:
		push_error("[补产] 窗口非法: %d-%d（需 0 <= lo <= hi <= %d）" % [_lo, _hi, Difficulty.PEAK_OVER - 1])
		CliShutdown.request_exit(1)
		return
	var combo := _combo_name()
	print("=== 窗口补产 %s（globals=%s）窗口 [%d,%d] 尺寸 %s 每尺寸 %d 关 ===" % [
		_clue, str(_globals), _lo, _hi, str(_sides), _per_side])
	DirAccess.make_dir_recursive_absolute(_out)
	var gen := PuzzleGenerator.new()
	gen.num_workers = 1
	var total_made := 0
	for side in _sides:
		var side_i := int(side)
		var rr := RuleFeasibility.resolve_mines(_clue, _globals, side_i)
		var mines := int(rr["mines"])
		if mines < 0:
			print("  [%d×%d] 数学不可行，跳过" % [side_i, side_i])
			continue
		var dir := "%s/%s/%dx%d" % [_out, combo, side_i, side_i]
		DirAccess.make_dir_recursive_absolute(dir)
		var timeout := _timeout_for(side_i)
		var t0 := Time.get_ticks_msec()
		var made := 0
		var cand := 0
		var hist: Dictionary = {}
		for seed_v in range(1, _max_cand + 1):
			if made >= _per_side:
				break
			if Time.get_ticks_msec() - t0 > _budget_s * 1000:
				print("  [%d×%d] 预算用尽（已产 %d 关）" % [side_i, side_i, made])
				break
			var level: Dictionary = gen.generate_with_rules(_clue, _globals, Vector2i(side_i, side_i),
				mines, seed_v, 0, 50, null, timeout, 0.0)
			if level.is_empty():
				continue
			cand += 1
			var peak := int((level.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1))
			hist[peak] = int(hist.get(peak, 0)) + 1
			if not Difficulty.in_window(peak, _lo, _hi):
				continue
			var tier := Difficulty.tier_of_peak(peak)
			if tier == "":
				continue                      # 超纲/无档（理论上被窗口排除，双保险）
			made += 1
			level["name"] = "%s_%02d" % [tier, made]
			var f := FileAccess.open("%s/%s_%02d.json" % [dir, tier, made], FileAccess.WRITE)
			if f != null:
				f.store_string(JSON.stringify(level, " "))
				f.close()
		total_made += made
		var el := float(Time.get_ticks_msec() - t0) / 1000.0
		var pkeys: Array = hist.keys()
		pkeys.sort()
		var ptxt: Array = []
		for k in pkeys:
			ptxt.append("%d:%d" % [int(k), int(hist[k])])
		print("  [%d×%d] 产出 %d / 候选 %d（命中 %.1f%%）｜耗时 %.0fs｜单候选 %.1fs｜峰值分布 %s" % [
			side_i, side_i, made, cand,
			0.0 if cand == 0 else 100.0 * float(made) / float(cand), el,
			0.0 if cand == 0 else el / float(cand), " ".join(ptxt)])
	print("=== 完成：共产出 %d 关 → %s/%s/<SxS>/ ===" % [total_made, _out, combo])
	print("    下一步：retier_stock.py --src %s → import_batch_to_lib.gd（两道闸门会再校验窗口与死盘）" % _out)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
