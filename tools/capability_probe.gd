extends SceneTree

# 变体能力档案探针（CLI，v4.0 深度口径，2026-09-19）
#
# 薄封装：探测/统计/落盘全在 core/variant_capability.gd —— **与游戏内模组页的「探测能力」
# 按钮同一份实现**。本脚本只做三件事：解析参数、逐尺寸驱动、打印摘要；不重写任何判据
#（本项目反例：UI 与量产各写一份预筛逻辑，判据不同 → 产出"进库了但选关页不显示"的孤儿席位）。
#
# 用法：
#   godot --headless --path . -s res://tools/capability_probe.gd -- \
#       <clue> <globals_csv|-> <sides_csv> <n_per_side|-> <mods_csv|->
#   · clue         线索规则 id（如 o4 / s1 / classic）
#   · globals_csv  全局规则 id 逗号分隔；`-` = 无
#   · sides_csv    边长列表（`5,6,7`）或闭区间（`7-9`）
#   · n_per_side   每尺寸候选数（缺省/`-` = 12；与手工探针同口径，够看出命中率量级）
#   · mods_csv     逗号分隔 mod 目录名（demo/mods/<name>/entry.gd 的 on_load）；`-` = 无
#
# 例（官方深变体 o4 的 7/8 两档，12 候选/尺寸）：
#   godot --headless --path . -s res://tools/capability_probe.gd -- o4 - 7,8 12 -
# 例（Mod 规则，先加载其 mod 再探测）：
#   godot --headless --path . -s res://tools/capability_probe.gd -- my_rule - 5-7 12 my_mod
#
# 输出：逐尺寸一行摘要（雷数 / 峰值直方图 / 可达档位 / 各档命中率 / 单候选均值耗时 / 空盘数）
# + 末尾档案路径。档案与 UI 读的是同一文件、同一键（core/variant_capability.gd 的 rule_key）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const DEFAULT_N := 12


static func _split_csv(raw: String) -> Array:
	var out: Array = []
	for item in raw.split(",", false):
		var s := str(item).strip_edges()
		if s != "" and s != "-":
			out.append(s)
	return out


## 尺寸解析：`5,6,7` 或闭区间 `7-9`（与 batch_all_variants 第 9 参的尺寸写法同语法）。
static func _parse_sides(raw: String) -> Array:
	var out: Array = []
	for item in _split_csv(raw):
		var it := str(item)
		if it.contains("-"):
			var rp := it.split("-", false, 1)
			if rp.size() == 2 and rp[0].strip_edges().is_valid_int() and rp[1].strip_edges().is_valid_int():
				for sd in range(int(rp[0]), int(rp[1]) + 1):
					out.append(sd)
		elif it.is_valid_int():
			out.append(int(it))
	return out


## 预加载 Mod（与 batch_all_variants 第 10 参同一写法）：注册其规则后再探测。
static func _load_mods(raw: String) -> void:
	for mod_name in _split_csv(raw):
		var entry := "res://demo/mods/%s/entry.gd" % mod_name
		if ResourceLoader.exists(entry):
			var sc: Variant = load(entry)
			if sc != null:
				sc.new().call("on_load")
				print("  [mod] 已加载: %s" % mod_name)
		else:
			push_error("Mod 入口不存在: " + entry)


static func _tier_label(tid: String) -> String:
	return str((Difficulty.PEAK_WINDOWS.get(tid, {}) as Dictionary).get("label", tid))


static func _hist_text(hist: Dictionary) -> String:
	var keys: Array = hist.keys()
	keys.sort()
	var parts: Array = []
	for k in keys:
		parts.append("%d:%d" % [int(k), int(hist[k])])
	return " ".join(parts) if not parts.is_empty() else "（无）"


static func _tiers_text(reachable: Array) -> String:
	if reachable.has("unavailable"):
		return "unavailable（该尺寸数学不可行）"
	var parts: Array = []
	for t in reachable:
		parts.append(_tier_label(str(t)))
	return "/".join(parts) if not parts.is_empty() else "无"


static func _hit_text(hr: Dictionary) -> String:
	var parts: Array = []
	for tid in Difficulty.PEAK_WINDOWS:
		if hr.has(tid):
			parts.append("%s %.1f%%" % [_tier_label(tid), float(hr[tid]) * 100.0])
	return " / ".join(parts) if not parts.is_empty() else "无命中"


func _initialize() -> void:
	if not RuleCpSat.available():
		push_error("[能力探测] CP-SAT 后端不可用（res://solver/RuleSolver.cs 加载失败或缺 .NET/mono 运行时）——继续跑只会得到零结果。")
		CliShutdown.request_exit(1)
		return
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("[能力探测] 参数不足。用法: -- <clue> <globals_csv|-> <sides_csv> <n_per_side|-> <mods_csv|->")
		CliShutdown.request_exit(1)
		return
	var clue := str(args[0]).strip_edges()
	var globals := _split_csv(str(args[1]))
	var sides := _parse_sides(str(args[2]))
	var n := DEFAULT_N
	if args.size() >= 4 and str(args[3]).strip_edges().is_valid_int():
		n = maxi(1, int(str(args[3]).strip_edges()))
	_load_mods(str(args[4]) if args.size() >= 5 else "")
	if clue == "" or sides.is_empty():
		push_error("[能力探测] clue / sides 不能为空：clue=%r sides=%r" % [clue, str(args[2])])
		CliShutdown.request_exit(1)
		return
	if RuleRegistry.default().resolve(StringName(clue)) == null:
		push_error("[能力探测] 规则未注册：%s（Mod 规则请用第 5 参加载对应 mod；官方算子见 ui/variant_catalog.gd）" % clue)
		CliShutdown.request_exit(1)
		return
	var key := VariantCapability.rule_key(clue, globals)
	var gen := PuzzleGenerator.new()
	gen.num_workers = 1        # 与量产分片同口径：1 进程 = 1 worker，尺寸顺序跑
	var t_all := Time.get_ticks_msec()
	print("=== 能力档案探测：%s（%d 个尺寸 × %d 候选）===" % [key, sides.size(), n])
	for s in sides:
		var side := int(s)
		var rr := RuleFeasibility.resolve_mines(clue, globals, side)
		var mines := int(rr["mines"])
		if mines < 0:
			# 数学不可行：照样落一条 unavailable（"这个尺寸没内容"是能力事实），但不烧 n 个候选
			VariantCapability.upsert_side(key, side, VariantCapability.probe_side(gen, clue, globals, side, -1, 0))
			print("  %d×%d：数学不可行（候选雷数 %s 全 UNSAT）→ 记 unavailable" % [
				side, side, str(RuleFeasibility.CANDIDATES.get(side, []))])
			continue
		var t0 := Time.get_ticks_msec()
		var res := VariantCapability.probe_side(gen, clue, globals, side, mines, n)
		VariantCapability.upsert_side(key, side, res)
		print("  %d×%d（%d 雷%s）：候选 %d（空 %d）｜耗时 %.1fs｜单候选均值 %.1fs｜峰值上限 %d" % [
			side, side, mines, "" if bool(rr.get("standard", false)) else "/候选回退",
			int(res["cand"]), int(res["empty"]), float(Time.get_ticks_msec() - t0) / 1000.0,
			float(res["cost_ms_mean"]) / 1000.0, int(res["peak_max"])])
		var hist: Dictionary = res["peak_hist"]
		var reach: Array = res["reachable"]
		var hr: Dictionary = res["hit_rate"]
		print("      峰值直方图: %s" % _hist_text(hist))
		print("      可达档位: %s｜命中率: %s" % [_tiers_text(reach), _hit_text(hr)])
	print("=== 完成（%.1f 秒）｜档案: %s/%s.json ===" % [
		float(Time.get_ticks_msec() - t_all) / 1000.0, VariantCapability.DIR, key])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
