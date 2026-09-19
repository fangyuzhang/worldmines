# variant_capability.gd —— 变体能力档案（v4.0 深度口径，2026-09-19）
#
# 为什么要有这个类（探针产品化）：
#   难度改按「峰值窗口」定档后，「某个变体在某一档到底供不供得出来」成了产线一级问题——
#   而它只能实测，不能推理（规则一改，深度分布就变）。此前这个答案只活在临时探针脚本
#   （tools/probe_peak_window.gd）的输出与人的记忆里：换一个变体就要重跑一遍、重读一遍。
#   现在把「跑 n 个候选 → 统计峰值分布 / 可达档位 / 命中率 / 单候选成本」收敛到这里，
#   **CLI 工具（tools/capability_probe.gd，长跑）与 UI（模组页「探测能力」按钮，进程内分帧）
#   共用同一份实现**。理由与 RuleFeasibility 收敛预筛同源：同一份知识写两遍必然漂移——
#   本项目实测过「UI 手写可行表 + 工具另写一套」导致结论不同、产出孤儿席位无人发现。
#   故这里只有一份"怎么算"：采样（probe_seed）、记账（probe_absorb）、派生（probe_finish）。
#
# 实测参考（8×8，探针 2026-09-19，帮助判读本档案的量级与结论）：
#   · 深变体 o4：噩梦命中率 56%、单候选 17.1s —— 可达，但很贵（一百关 ≈ 半小时机时）
#   · 中部 s1：命中 10%、单候选 6.6s —— 可达，命中率低（一百关要采样约千次）
#   · 浅变体 z1：命中 0%（峰值上限 8）、单候选 2.5s —— 结构性差一条，换 seed 无用
#   · 退化算子 o8：峰值上限 3 —— 一步直达型算子在深度轴上没有梯度，别指望更大盘
# 读法：命中率决定「供不供」，单候选成本决定「要烧多少机时」；0% 不是运气问题，是结构问题。
#
# 口径（与量产 batch_all_variants 对齐，避免两处结论打架）：
#   · target_difficulty 固定 0 = 最大删线索（实测命中率最高；批量工具的注释也记着"target
#     对峰值无影响，o4 56.0% vs 53.8%"）；
#   · 单关超时 maxi(30_000, side² × 3000)（同量产系数）；
#   · 生成器由调用方给：统一 `PuzzleGenerator.new()` + `num_workers = 1`（不抢核；
#     服务器分片也是"多进程 × 1 worker"口径）。
#
# 落盘：user://mods/_custom/capability/<键>.json —— 与自举产出的关卡（_custom/levels）同级，
# 都属于"本机自举产物"，一起备份/清理即可（不写进任何已安装 mod 的目录）。
class_name VariantCapability
extends RefCounted


## 档案目录（与 ui/mod_select.gd 的生成落盘目录 user://mods/_custom/levels 同级）。
const DIR := "user://mods/_custom/capability"

## 单关超时系数（与 batch_all_variants / probe_peak_window 同口径 3000 → 9×9=243s）。
const TIMEOUT_COEF := 3000


## 规则键（档案文件名 = 键 + ".json"）：无全局约束 → 就是线索 id（如 "o4"）；
## 有 → "clue+g1+g2"（如 "classic+s1"）。全局 id 先去重再**排序**：规则集语义与顺序无关，
## 排序让 `s1,o4` 与 `o4,s1` 落到同一份档案（否则同一组合会有两份互不相同的"能力"）。
static func rule_key(clue: String, globals: Array) -> String:
	if globals.is_empty():
		return clue
	var gs: Array = []
	for g in globals:
		var s := str(g)
		if not gs.has(s):
			gs.append(s)
	gs.sort()
	return "%s+%s" % [clue, "+".join(gs)]


## 档案路径：把路径分隔符/盘符换掉——规则 id 受命名契约约束（小写、无空格、无 +），
## 但路径是拼出来的，兜一道「怪 id 不写到自己目录外」的底线（一行成本，不值得省）。
static func _path(key: String) -> String:
	return DIR.path_join("%s.json" % key.replace("/", "_").replace("\\", "_").replace(":", "_"))


## 单候选采样（**唯一的采样实现**：probe_side 与 UI 的分帧驱动都调它——
## UI 需要在候选之间 `await` 分帧、显示进度、响应取消，不能整段跑在 probe_side 里）。
## 返回 {"empty": bool, "peak": int（空盘 = -1）, "cost_ms": float}。
static func probe_seed(gen: Object, clue: String, globals: Array, side: int, mines: int, seed: int,
		topo: GridInterface = null) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	# target=0（最大删线索）：实测命中率最高，且与量产口径一致。
	var level: Dictionary = gen.generate_with_rules(clue, globals, Vector2i(side, side), mines,
			seed, 0, 50, topo, maxi(30_000, side * side * TIMEOUT_COEF), 0.0)
	var cost := float(Time.get_ticks_msec() - t0)
	if level.is_empty():
		return {"empty": true, "peak": -1, "cost_ms": cost}
	return {"empty": false,
		"peak": int((level.get("difficulty_profile", {}) as Dictionary).get("max_complexity", -1)),
		"cost_ms": cost}


## 空累积器（UI 分帧驱动用：逐候选记账，中途可停）。
static func probe_new(mines: int) -> Dictionary:
	return {"mines": mines, "cand": 0, "empty": 0, "peak_hist": {}, "cost_ms_total": 0.0}


## 记一笔采样。空盘只计 empty，不进直方图（它没告诉我们任何关于峰值的信息）。
static func probe_absorb(acc: Dictionary, one: Dictionary) -> void:
	acc["cand"] = int(acc["cand"]) + 1
	acc["cost_ms_total"] = float(acc["cost_ms_total"]) + float(one.get("cost_ms", 0.0))
	if bool(one.get("empty", true)):
		acc["empty"] = int(acc["empty"]) + 1
		return
	var pk := int(one.get("peak", -1))
	var hist: Dictionary = acc["peak_hist"]
	hist[pk] = int(hist.get(pk, 0)) + 1


## 收尾：派生统计**只在这里算一次**（两条驱动路径共用，杜绝第二份实现）。
## · reachable = 峰值直方图里出现过的档位（tier_of_peak 去重，保序 intro→hard）
##   —— "出现过"= 实测可达；没出现过 ≠ 数学上不可能，但按当前采样它就是达不到。
## · hit_rate = 各档命中数 / **候选总数**（空盘计入分母）——这样"命中率"直接等于真实采样成本：
##   一百关要跑 100 / hit_rate 个候选。
## · peak_max = 采到的最高峰值（浅变体/退化算子一眼看出天花板，如 z1 上限 8 / o8 上限 3）。
static func probe_finish(acc: Dictionary) -> Dictionary:
	var cand := int(acc["cand"])
	var hist: Dictionary = acc["peak_hist"]
	var reachable: Array = []
	var hit_rate := {}
	for tid in Difficulty.PEAK_WINDOWS:      # 键序即 intro→easy→normal→hard（保序）
		var hit := 0
		for pk in hist:
			if Difficulty.tier_of_peak(int(pk)) == tid:
				hit += int(hist[pk])
		if hit > 0:
			reachable.append(tid)
			hit_rate[tid] = float(hit) / float(maxi(1, cand))
	var peak_max := -1
	for pk in hist:
		peak_max = maxi(peak_max, int(pk))
	return {"cand": cand, "empty": int(acc["empty"]), "peak_hist": hist,
		"reachable": reachable, "hit_rate": hit_rate,
		"cost_ms_mean": float(acc["cost_ms_total"]) / float(maxi(1, cand)),
		"peak_max": peak_max, "mines": int(acc.get("mines", -1))}


## 单尺寸探测：跑 n 个候选（seed = 1..n），统计峰值分布/可达档位/命中率/单候选成本。
## mine_count < 0 = 该尺寸数学不可行（调用方通常直接传 `RuleFeasibility.resolve_mines(...)["mines"]`；
## 传 -1 时这里兜底再解析一次）→ 返回 `reachable = ["unavailable"]` 的空结果：
## "这个尺寸没有内容"本身也是一条能力事实，**不能**静默变成"全档不可达"（两者含义不同）。
static func probe_side(gen: Object, clue: String, globals: Array, side: int, mine_count: int,
		n: int, topo: GridInterface = null) -> Dictionary:
	var mines := mine_count
	if mines < 0:
		mines = int(RuleFeasibility.resolve_mines(clue, globals, side)["mines"])
	if mines < 0:
		return {"cand": 0, "empty": 0, "peak_hist": {}, "reachable": ["unavailable"],
			"hit_rate": {}, "cost_ms_mean": 0.0, "peak_max": -1, "mines": -1}
	var acc := probe_new(mines)
	for seed in range(1, n + 1):
		probe_absorb(acc, probe_seed(gen, clue, globals, side, mines, seed, topo))
	return probe_finish(acc)


## 写档案（键 → user://mods/_custom/capability/<键>.json）。
static func save(key: String, data: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(_path(key), FileAccess.WRITE)
	if f == null:
		push_error("VariantCapability: 能力档案写盘失败 %s" % _path(key))
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()


## 读档案：读不到/解析失败 → {}（调用方按"无档案"处理，不当错误；档案是可选的可观测性产物）。
static func load_for(key: String) -> Dictionary:
	var f := FileAccess.open(_path(key), FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


## 合并单尺寸结果并落盘。文件结构：
##   {"updated": <unix>, "sides": {"8": {…probe_side 结果…}}, "tiers": ["intro","easy"]}
## `tiers` = 各尺寸 reachable 的并集（保序 intro→hard）：调用方（UI 的生成入口兜底）只关心
## "这个变体能不能供这一档"，不必逐尺寸翻。"unavailable" 是"该尺寸数学不可行"的标记、
## 不是档位 id，不入并集（否则它会被当成一个"档位"参与判断）。
static func upsert_side(key: String, side: int, side_data: Dictionary) -> void:
	var data := load_for(key)
	var sides: Dictionary = data.get("sides", {})
	sides[str(side)] = side_data
	var seen := {}
	for sd in sides:
		for t in (sides[sd] as Dictionary).get("reachable", []):
			seen[str(t)] = true
	var tiers: Array = []
	for tid in Difficulty.PEAK_WINDOWS:
		if seen.has(tid):
			tiers.append(tid)
	save(key, {"updated": int(Time.get_unix_time_from_system()), "sides": sides, "tiers": tiers})
