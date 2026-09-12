extends SceneTree

# 全变体 + 混合 × 5 尺寸 × 每类 N 关 批量生成驱动。
#
# 组合清单（GDD 01 号 3.1.1 / 3.2）：
#   单 C（8）+ 单 G（7）+ G+C（7×8=56）+ G+G（C(7,2)=21）= 92 组合
# 尺寸：5×5~9×9（R07 雷数 10/14/20/26/32）。
#
# 用法：
#   godot --headless --path . -s res://tools/batch_all_variants.gd -- [out_dir] [per_type] [seed_max] [limit_combos] [shard_idx shard_total] [seed_start]
#   · out_dir  默认 user://batch_all
#   · per_type 每 (组合×尺寸) 目标关卡数，默认 10
#   · seed_max 每个单元尝试的 seed 上限（概率性进档组合需更大），默认 40
#   · limit_combos 只跑前 N 组合（冒烟用，0=全部）
#   · shard_idx/shard_total 分片并行（按组合取模切分；9×9 重线索单关可达 ~200s，
#     全量单进程 5~10h，8 进程分片约 1~1.5h）。断点续跑：同命令重跑即自动跳过满额单元。
#   · seed_start 续跑起始 seed（默认 1）。补跑未满单元时设为上次 seed_max+1，
#     避免从 1 重扫——已成功 seed 的重放虽然会被指纹去重跳过，但生成时间照付
#     （9×9 重线索单关 ~175s，重放 9 个就是半小时白花）。
#
# 关键设计（防废品/防复工）：
#   1. is_feasible 预筛：不含 dt 的组合在生成前判数学可行性，UNSAT（如 RL 6×6 奇偶矛盾、
#      QD 6×6/8×8 雷数非 4 倍数）直接跳过，不进入「换 seed 白跑几十秒」。
#   2. 含 dt 的组合不预筛（骨牌划分随机、is_feasible 单次采样不可靠），交给生成器多 attempt 重试。
#   3. 生成后用 ProofLog.build 复核序贯可解（与 verify_batch 同口径），不过即拒。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const CLUES := ["classic", "4n", "clock", "hv", "fr", "loopruns", "distsum", "sc"]
const GLOBALS := ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]
const SIZES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}

var _out_dir := "user://batch_all"
var _per_type := 10
var _seed_max := 40
var _limit_combos := 0  # 0 = 全部；>0 = 只跑前 N 组合（冒烟用）
var _shard_idx := 0
var _shard_total := 1  # >1 = 分片并行（第 5/6 参数）
var _seed_start := 1   # 补跑起始 seed（第 7 参数；避免重扫已成功 seed 白花生成时间）


## 组合清单：92 项 {id, clue, globals}。
func _build_combos() -> Array:
	var combos: Array = []
	for c in CLUES:
		combos.append({"id": "c_%s" % c, "clue": c, "globals": []})
	for g in GLOBALS:
		combos.append({"id": "g_%s" % g, "clue": "classic", "globals": [g]})
	for g in GLOBALS:
		for c in CLUES:
			combos.append({"id": "%s_%s" % [g, c], "clue": c, "globals": [g]})
	for i in GLOBALS.size():
		for j in range(i + 1, GLOBALS.size()):
			combos.append({"id": "%s_%s" % [GLOBALS[i], GLOBALS[j]], "clue": "classic", "globals": [GLOBALS[i], GLOBALS[j]]})
	return combos


## 数学可行性预筛（不含 dt；dt 骨牌划分随机，单次采样不可靠，跳过预筛）。
func _is_feasible(clue: String, globals: Array, side: int, mines: int) -> bool:
	if globals.has("dt"):
		return true
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(StringName(clue))
	var gs: Array = []
	for gid in globals:
		var g: Object = reg.resolve(StringName(gid))
		if g != null and g.get_kind() == RulePlugin.KIND_GLOBAL:
			gs.append(g)
	var oracle := RuleOracle.new(clue_rule, gs, Vector2i(side, side), mines, null)
	return RuleCpSat.is_feasible(oracle.build_spec({}, [], {}))


func _timeout_for(side: int) -> int:
	# 系数 1500（原 600）：实测 9×9 重线索组合单关 68~74s（rl_loopruns 74.2s、rl_pf 68.1s），
	# 600 系数（9×9=48.6s）会把它们超时杀掉。1500 → 9×9=121s、16×16=384s，留足余量。
	# 代价仅是失败关多等一会（成功关不受影响）。
	return maxi(30_000, side * side * 1500)


func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("无法写入: " + path)
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


## 关卡指纹（与 batch_merge 同口径）：尺寸+雷数+雷坐标集。
func _fingerprint(level: Dictionary) -> String:
	var parts: Array = []
	var sz: Dictionary = level.get("size", {})
	parts.append("%dx%d-%d" % [int(sz.get("cols", 0)), int(sz.get("rows", 0)), int(level.get("total_mines", -1))])
	var ms: Array = []
	for m in level.get("mines", []):
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	parts.append("|".join(ms))
	return "|".join(parts)


## 断点续跑：扫描单元目录已有关卡（总数 / 各档最大编号 / 指纹集）。
func _scan_unit(combo_dir: String) -> Dictionary:
	var out := {"count": 0, "max_idx": {}, "fps": {}}
	var d := DirAccess.open(combo_dir)
	if d == null:
		return out
	for f in d.get_files():
		if not str(f).ends_with(".json"):
			continue
		out["count"] = int(out["count"]) + 1
		var level := _load_json("%s/%s" % [combo_dir, f])
		if not level.is_empty():
			out["fps"][_fingerprint(level)] = true
		var parts := str(f.get_basename()).split("_", false)
		if parts.size() == 2:
			var tier := str(parts[0])
			var idx := int(parts[1])
			if int(out["max_idx"].get(tier, 0)) < idx:
				out["max_idx"][tier] = idx
	return out


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and args[0] != "":
		_out_dir = args[0]
	if args.size() >= 2 and args[1] != "":
		_per_type = int(args[1])
	if args.size() >= 3 and args[2] != "":
		_seed_max = int(args[2])
	if args.size() >= 4 and args[3] != "":
		_limit_combos = int(args[3])
	if args.size() >= 6 and args[4] != "" and args[5] != "":
		_shard_idx = int(args[4])
		_shard_total = int(args[5])
	if args.size() >= 7 and args[6] != "":
		_seed_start = int(args[6])
	DirAccess.make_dir_recursive_absolute(_out_dir)

	var combos := _build_combos()
	if _limit_combos > 0 and _limit_combos < combos.size():
		combos.resize(_limit_combos)
	# 分片并行：按组合下标取模切分（i % total == idx 归本进程），各进程写各自单元目录互不冲突。
	# 分片时每进程生成器单 worker（进程数 × 1 = 核数，避免 CP-SAT 4 worker 超额订阅抢核）。
	if _shard_total > 1:
		var sharded: Array = []
		for i in combos.size():
			if i % _shard_total == _shard_idx:
				sharded.append(combos[i])
		combos = sharded
	var gen := PuzzleGenerator.new()
	gen.num_workers = 1 if _shard_total > 1 else 0
	var t0 := Time.get_ticks_msec()
	var stats := {"units": 0, "ok": 0, "partial": 0, "skipped": 0, "design_skip": 0, "resumed": 0, "fail": 0,
		"tiers": {"easy": 0, "normal": 0, "hard": 0}}
	var skipped: Array = []
	var design_skip: Array = []
	var partial: Array = []

	print("=== 全变体+混合批量生成（%d 组合 × 5 尺寸 × 每类 %d 关）[shard %d/%d]===" % [
		combos.size(), _per_type, _shard_idx, _shard_total])
	for combo in combos:
		for side in SIZES:
			var mines: int = SIZES[side]
			stats["units"] += 1
			var combo_dir := "%s/%s/%dx%d" % [_out_dir, combo["id"], side, side]
			# FR（首雷）设计跳过（v2.9.3 决策）：FR 线索「向右首雷距离」直接锁定雷位、
			# 无弱信息值（GDD 3.3 原话），difficulty 恒 <0.3（实测 0.06~0.28，含 G+FR 混合），
			# 进不了最低 easy 档，无法作为标准三档关卡生成——这是变体特性，非代码 bug。
			# mx_dt（G+G）同理：镜像+骨牌全局约束自带全部开局信息（骨牌外强制非雷 + 镜像
			# 锁死骨牌内选择），0 条线索即可序贯推完 → 生成关难度恒 <0.3（实测 0.04~0.17）。
			if combo["clue"] == "fr" or (combo["clue"] == "classic" and combo["globals"] == ["mx", "dt"]):
				stats["design_skip"] += 1
				design_skip.append("%s %dx%d" % [combo["id"], side, side])
				continue
			if not _is_feasible(combo["clue"], combo["globals"], side, mines):
				stats["skipped"] += 1
				skipped.append("%s %dx%d" % [combo["id"], side, side])
				continue
			DirAccess.make_dir_recursive_absolute(combo_dir)
			# 断点续跑：扫描已有产出。满额单元直接跳过（重跑安全、不重复生成）；
			# 未满单元编号接续 + 指纹去重（同 seed 重跑撞已有盘时跳过，不产生冗余文件）。
			var existing := _scan_unit(combo_dir)
			if int(existing["count"]) >= _per_type:
				stats["resumed"] = int(stats.get("resumed", 0)) + 1
				stats["ok"] += int(existing["count"])
				continue
			var made := int(existing["count"])
			var next_idx: Dictionary = existing["max_idx"]
			var fps: Dictionary = existing["fps"]
			for seed in range(_seed_start, _seed_max + 1):
				var level: Dictionary = gen.generate_with_rules(
					combo["clue"], combo["globals"], Vector2i(side, side), mines, seed,
					0, 50, null, _timeout_for(side))
				if level.is_empty():
					continue
				var dp: Dictionary = level.get("difficulty_profile", {})
				var diff := float(dp.get("difficulty", 0.0))
				var tier := Difficulty.tier_of(diff)
				if tier == "":
					continue
				# 生成后复核：可加载 + 序贯可解（与 verify_batch 同口径，杜绝废品入库）
				var log: Dictionary = ProofLog.build(level)
				if not bool(log.get("solved", false)):
					continue
				var fp := _fingerprint(level)
				if fps.has(fp):
					continue
				fps[fp] = true
				var idx := int(next_idx.get(tier, 0)) + 1
				next_idx[tier] = idx
				level["name"] = "%s_%02d" % [tier, idx]
				level["difficulty"] = diff
				_write("%s/%s_%02d.json" % [combo_dir, tier, idx], level)
				made += 1
				stats["tiers"][tier] = int(stats["tiers"].get(tier, 0)) + 1
				if made >= _per_type:
					break
			stats["ok"] += made
			if made < _per_type:
				stats["partial"] += 1
				partial.append("%s %dx%d (%d/%d)" % [combo["id"], side, side, made, _per_type])

	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	print("=== 完成（%.1fs）===" % elapsed)
	print("  单元(组合×尺寸): %d | 入库总关数 %d | 设计跳过(FR难度) %d | 跳过(数学UNSAT) %d | 续跑满额跳过 %d | 部分成功 %d" % [
		stats["units"], stats["ok"], stats["design_skip"], stats["skipped"], stats.get("resumed", 0), stats["partial"]])
	print("  难度分布: easy=%d normal=%d hard=%d" % [
		stats["tiers"]["easy"], stats["tiers"]["normal"], stats["tiers"]["hard"]])
	if design_skip.size() > 0:
		print("  设计跳过清单(%d，FR难度天然<0.3，见GDD 3.3): %s" % [design_skip.size(), ", ".join(design_skip)])
	if skipped.size() > 0:
		print("  跳过清单(%d): %s" % [skipped.size(), ", ".join(skipped)])
	if partial.size() > 0:
		print("  部分成功清单(%d): %s" % [partial.size(), ", ".join(partial)])
	# 报告文件按分片命名：8 个分片进程写同一路径会互相覆盖（实测 probe40 丢了 7 片的 partial 清单）。
	var report_name := "all_report_shard_%02d.json" % _shard_idx if _shard_total > 1 else "all_report.json"
	_write("%s/%s" % [_out_dir, report_name], {
		"elapsed_s": elapsed, "stats": stats,
		"design_skip": design_skip, "skipped": skipped, "partial": partial,
	})
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
