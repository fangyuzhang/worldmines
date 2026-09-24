extends SceneTree

# 峰值窗口探针（难度体系 P0 验证）：peak 作为验收条件时，各单元的采样成本。
#
# 为什么独立成工具：量产工具 `batch_all_variants.gd` 正在服务器跑长任务，
# 任何改动都有"改坏在跑批次"的风险；本探针只调用 `PuzzleGenerator.generate_with_rules`
# 与 `RuleFeasibility.resolve_mines`（均为只读复用），**不改内核、不改量产工具**。
#
# 用法：
#   godot --headless --path . -s res://tools/probe_peak_window.gd -- \
#       <spec> <peak_lo> <peak_hi> <max_cand> <budget_s> <mods> [timeout_coef] [targets]
#   · spec         `clue[+g1+g2]@side`，如 `s1@8`、`classic+z4@8`
#   · peak_lo/hi   目标窗口（含端点）：9 20 = 噩梦档
#   · max_cand     每臂最大候选数（时间预算内可能提前停）
#   · budget_s     每臂时间预算（秒）
#   · mods         逗号分隔的 mod 目录名（demo/mods/<name>/entry.gd 的 on_load）
#   · timeout_coef 单关超时系数（同量产默认 3000）
#   · targets      逗号分隔的 target_difficulty 多臂对比（默认 "0"）
#
# 判读：
#   命中率 = 窗口内候选 / 总候选 → 100 关需采样 = 100 / 命中率；
#   机时 = 采样数 × 单候选均值耗时。据此决定"该单元该档供不供"。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

var _spec := "s1@8"
var _peak_lo := 9
var _peak_hi := 20
var _max_cand := 200
var _budget_s := 300
var _mods := ""
var _coef := 3000
var _targets: Array = [0.0]
var _out_dir := "user://probe_peak"
const SAVE_HITS := 5  # 每臂最多落盘几关（避免探针刷爆磁盘）


func _timeout_for(side: int) -> int:
	return maxi(30_000, side * side * _coef)


## 规格解析：`clue[+g1+g2]@side`（与量产工具第 9 参同语法）
func _parse_spec(spec: String) -> Dictionary:
	var combo := spec
	var side := 0
	if spec.contains("@"):
		var p := spec.split("@", false, 1)
		combo = str(p[0])
		side = int(p[1])
	var parts := combo.split("+", false)
	var clue := str(parts[0]).strip_edges()
	var globals: Array = []
	for i in range(1, parts.size()):
		globals.append(str(parts[i]).strip_edges())
	return {"clue": clue, "globals": globals, "side": side}


func _initialize() -> void:
	if not RuleCpSat.available():
		push_error("[探针] CP-SAT 后端不可用（缺 .NET/mono 运行时）——继续跑只会零产出。")
		CliShutdown.request_exit(1)
		return
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and str(args[0]) != "": _spec = str(args[0])
	if args.size() >= 2 and str(args[1]) != "": _peak_lo = int(args[1])
	if args.size() >= 3 and str(args[2]) != "": _peak_hi = int(args[2])
	if args.size() >= 4 and str(args[3]) != "": _max_cand = int(args[3])
	if args.size() >= 5 and str(args[4]) != "": _budget_s = int(args[4])
	if args.size() >= 6: _mods = str(args[5])
	if args.size() >= 7 and str(args[6]) != "": _coef = int(args[6])
	if args.size() >= 8 and str(args[7]) != "":
		_targets = []
		for t in str(args[7]).split(",", false):
			if str(t).strip_edges() != "":
				_targets.append(float(t))
	if _targets.is_empty():
		_targets = [0.0]
	if _mods != "":
		for m in _mods.split(",", false):
			var entry := "res://demo/mods/%s/entry.gd" % str(m).strip_edges()
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
					print("  [mod] 已加载: %s" % str(m))
			else:
				push_error("Mod 入口不存在: " + entry)
	var sp := _parse_spec(_spec)
	var side := int(sp["side"])
	var clue := str(sp["clue"])
	var globals: Array = sp["globals"]
	if side <= 0:
		push_error("[探针] 规格缺少尺寸（示例 s1@8）：%s" % _spec)
		CliShutdown.request_exit(1)
		return
	var rr := RuleFeasibility.resolve_mines(clue, globals, side)
	var mines := int(rr["mines"])
	if mines < 0:
		push_error("[探针] 该规格在该尺寸数学不可行：%s" % _spec)
		CliShutdown.request_exit(1)
		return
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var gen := PuzzleGenerator.new()
	gen.num_workers = 1
	var timeout := _timeout_for(side)
	print("=== 峰值窗口探针 %s（%dx%d / %d 雷）窗口 [%d,%d]，%d 候选/臂，%d 秒/臂 ===" % [
		_spec, side, side, mines, _peak_lo, _peak_hi, _max_cand, _budget_s])
	print("    mines_standard=%s（回退=%s）" % [str(rr.get("standard", true)), str(not bool(rr.get("standard", true)))])
	var summary := {"spec": _spec, "side": side, "mines": mines,
		"window": [_peak_lo, _peak_hi], "budget_s": _budget_s, "arms": []}
	for target in _targets:
		var arm := {"target": float(target), "cand": 0, "empty": 0, "timeout_kill": 0,
			"peak_counts": {}, "hit": 0, "saved": 0, "cost_ms_total": 0, "budget_hit": false}
		var t_arm := Time.get_ticks_msec()
		var costs: Array = []
		for seed in range(1, _max_cand + 1):
			if Time.get_ticks_msec() - t_arm > _budget_s * 1000:
				arm["budget_hit"] = true
				break
			# 逐候选心跳（覆盖写）：**挂死时唯一能拿到「卡在哪个 seed」的线索**——
			# stdout 是块缓冲的，进程被挂死/OOM 杀掉时未必落盘；文件心跳不依赖缓冲。
			# 2026-09-24 实测：o4@9 曾出现单候选烧 679s CPU（名义上限 243s）且 900s 预算停不下来，
			# 当时就是因为没有心跳，只能拿到"卡住"这个事实、拿不到种子。
			var hb := FileAccess.open("%s/heartbeat.txt" % _out_dir, FileAccess.WRITE)
			if hb != null:
				hb.store_string("spec=%s side=%d seed=%d timeout_ms=%d t=%s\n" % [
					_spec, side, seed, timeout, Time.get_datetime_string_from_system()])
				hb.close()
			var t0 := Time.get_ticks_msec()
			var level: Dictionary = gen.generate_with_rules(clue, globals, Vector2i(side, side), mines, seed,
				0, 50, null, timeout, float(target))
			var cost := Time.get_ticks_msec() - t0
			arm["cand"] = int(arm["cand"]) + 1
			arm["cost_ms_total"] = int(arm["cost_ms_total"]) + cost
			costs.append(cost)
			if level.is_empty():
				arm["empty"] = int(arm["empty"]) + 1
				if cost >= timeout * 95 / 100:
					arm["timeout_kill"] = int(arm["timeout_kill"]) + 1
				continue
			var peak := int((level.get("difficulty_profile", {}) as Dictionary).get("max_complexity", 0))
			var pc: Dictionary = arm["peak_counts"]
			pc[peak] = int(pc.get(peak, 0)) + 1
			if peak >= _peak_lo and peak <= _peak_hi:
				arm["hit"] = int(arm["hit"]) + 1
				if int(arm["saved"]) < SAVE_HITS:
					arm["saved"] = int(arm["saved"]) + 1
					var tag := "%s_t%s" % [_spec.replace("@", "_"), str(target).replace(".", "")]
					level["name"] = "%s_p%02d_%d" % [tag, peak, int(arm["saved"])]
					var f := FileAccess.open("%s/%s_p%02d_%d.json" % [_out_dir, tag, peak, int(arm["saved"])], FileAccess.WRITE)
					if f != null:
						# 两空格：与仓库其余写 JSON 的工具（及 Python 侧 indent=2）统一，
						# 避免产物格式与惯例分叉（详见 fill_window.gd 的同款注释）。
						f.store_string(JSON.stringify(level, "  "))
						f.close()
		var cand := maxi(1, int(arm["cand"]))
		var hit := int(arm["hit"])
		var hit_rate := float(hit) / float(cand)
		costs.sort()
		var med: int = int(costs[costs.size() / 2]) if not costs.is_empty() else 0
		var mean_ms := float(arm["cost_ms_total"]) / float(cand)
		arm["elapsed_s"] = float(Time.get_ticks_msec() - t_arm) / 1000.0
		arm["hit_rate"] = hit_rate
		arm["cost_ms_mean"] = mean_ms
		arm["cost_ms_median"] = med
		arm["est_samples_per_100"] = 0.0 if hit_rate <= 0.0 else 100.0 / hit_rate
		arm["est_hours_per_100"] = arm["est_samples_per_100"] * mean_ms / 3600000.0
		print("  [target=%.2f] 候选 %d（空 %d / 超时杀 %d）耗时 %.1fs%s；命中 %d（%.1f%%）；单候选 均值 %.1fs / 中位 %.1fs" % [
			float(target), int(arm["cand"]), int(arm["empty"]), int(arm["timeout_kill"]),
			float(arm["elapsed_s"]), " [预算停止]" if bool(arm["budget_hit"]) else "",
			hit, hit_rate * 100.0, mean_ms / 1000.0, float(med) / 1000.0])
		var pkeys: Array = (arm["peak_counts"] as Dictionary).keys()
		pkeys.sort()
		var ptxt: Array = []
		for k in pkeys:
			ptxt.append("%d:%d" % [int(k), int((arm["peak_counts"] as Dictionary)[k])])
		print("      峰值直方图: %s" % " ".join(ptxt))
		print("      → 100 关需采样 %.0f 次 ≈ 机时 %.1f h（按单候选均值）" % [
			float(arm["est_samples_per_100"]), float(arm["est_hours_per_100"])])
		summary["arms"].append(arm)
	# 摘要按规格命名：多进程并行探测时互不覆盖
	var sum_path := "%s/summary_%s.json" % [_out_dir, _spec.replace("@", "_").replace("+", "-")]
	var f2 := FileAccess.open(sum_path, FileAccess.WRITE)
	if f2 != null:
		f2.store_string(JSON.stringify(summary, "  "))
		f2.close()
	print("=== 探针完成（摘要 %s）===" % sum_path)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
