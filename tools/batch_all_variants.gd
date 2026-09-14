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
#   · target_difficulty 目标难度（默认 0=不限）。>0 时删线索「达标即停」（早停提速），
#     并按目标难度分层生产——例如定向补 hard 关：target=2.5（hard 区间 2.2+）。
#
# 关键设计（防废品/防复工）：
#   1. is_feasible 预筛：不含 dt 的组合在生成前判数学可行性，UNSAT（如 RL 6×6 奇偶矛盾、
#      QD 6×6/8×8 雷数非 4 倍数）直接跳过，不进入「换 seed 白跑几十秒」。
#   2. 含 dt 的组合不预筛（骨牌划分随机、is_feasible 单次采样不可靠），交给生成器多 attempt 重试。
#   3. 生成后用 ProofLog.build 复核序贯可解（与 verify_batch 同口径），不过即拒。
#
# 记录功能（服务器长跑/远程分析用）：
#   · issues_shard_XX.jsonl：逐事件记录（empty / empty_timeout / tier_empty / proof_fail /
#     dup_fp / similar）+ 每单元完成行（unit_done：尝试数/产出/各分类计数/耗时）——
#     一行一个 JSON，追加写、单元粒度落盘（进程被杀也不丢已完成单元的事件）。
#   · unit_done 行兼作心跳：远程 getfile 拉最后几行即可看进度。
#   · 分析入口：跑完后 collect_report.py（本地）拉回汇总。
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
var _target_difficulty := 0.0  # >0 = 按目标难度生成（第 8 参数，删到达标即停）
var _extra_combos_spec := ""   # 第 9 参数：额外组合规格（Mod/自定义规则）
var _issues_path := ""  # issues jsonl 路径（记录功能，分片命名）


func _append_issues(lines: Array) -> void:
	if lines.is_empty() or _issues_path == "":
		return
	var f := FileAccess.open(_issues_path, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(_issues_path, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	for ln in lines:
		f.store_line(str(ln))
	f.close()


static func _ev(d: Dictionary) -> String:
	return JSON.stringify(d)


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


## 额外组合（Mod/自定义规则）规格解析：`clue[+g1+g2][@5,6,7]`，逗号分隔多项。
## sides 为空 = 全部尺寸；非空 = 仅这些尺寸（Mod 规则常只对部分尺寸有意义，如变径 5×5 停用）。
func _build_extra_combos() -> Array:
	var out: Array = []
	if _extra_combos_spec == "":
		return out
	for item in _extra_combos_spec.split(",", false):
		var spec := str(item).strip_edges()
		if spec == "":
			continue
		var sides: Array = []
		var combo_part := spec
		if spec.contains("@"):
			var at_parts := spec.split("@", false, 1)
			combo_part = at_parts[0]
			# 尺寸区段：`5`（单）或 `5-7`（闭区间）——逗号是「多项分隔符」，尺寸内禁用（曾歧义）。
			var side_str := str(at_parts[1]).strip_edges()
			if side_str.contains("-"):
				var rp := side_str.split("-", false, 1)
				for sd in range(int(rp[0]), int(rp[1]) + 1):
					sides.append(sd)
			elif side_str != "":
				sides.append(int(side_str))
		var cparts := combo_part.split("+", false)
		var clue := str(cparts[0]).strip_edges()
		var globals2: Array = []
		for i in range(1, cparts.size()):
			globals2.append(str(cparts[i]).strip_edges())
		out.append({
			"id": "x_%s" % combo_part.replace("+", "_"),
			"clue": clue, "globals": globals2, "sides": sides,
		})
	return out


## 数学可行性预筛：统一走 RuleFeasibility 真值查询（CP-SAT + 缓存 + dt 骨牌重采样）。
## 曾经此处与 UI 各写一套预筛逻辑（UI 手写规则表、这里跳过 dt）——知识重复是 bug 温床，
## v2.9.3 收敛为唯一真值入口，新增/Mod 变体自动正确。
func _is_feasible(clue: String, globals: Array, side: int, mines: int) -> bool:
	return RuleFeasibility.query(clue, globals, side, mines)


func _timeout_for(side: int) -> int:
	# 系数 3000（600 → 1500 → 3000）：9×9 重线索组合单关实测 68~193s（本地），
	# 服务器 CPU 更慢，1500 系数（9×9=121s）会把好关超时杀掉。3000 → 9×9=243s。
	# 代价仅是失败关多等一会（成功关不受影响）。
	return maxi(30_000, side * side * 3000)


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


## 断点续跑：扫描单元目录已有关卡（总数 / 各档最大编号 / 指纹集 / 雷位集用于相似度门）。
func _scan_unit(combo_dir: String) -> Dictionary:
	var out := {"count": 0, "max_idx": {}, "fps": {}, "mine_sets": []}
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
			var ms := {}
			for m in level.get("mines", []):
				ms[Vector2i(int(m["c"]), int(m["r"]))] = true
			(out["mine_sets"] as Array).append(ms)
		var parts := str(f.get_basename()).split("_", false)
		if parts.size() == 2:
			var tier := str(parts[0])
			var idx := int(parts[1])
			if int(out["max_idx"].get(tier, 0)) < idx:
				out["max_idx"][tier] = idx
	return out


## 与组内已有盘的峰值 Jaccard 相似度（雷位集 交/并）。> SIMILARITY_MAX 时拒收新关——
## 强约束小盘（如 dt_4c 5×5：骨牌恰1雷+黑白相等压可行空间）不同 seed 会撞出高度
## 相似的盘（多样性审计实测峰值 J=0.905、640 对 >0.6）。随机独立盘期望 J≈0.25，
## 阈值 0.85 只拦「几乎同盘」不误伤正常多样性。
const SIMILARITY_MAX := 0.85

## 难度可达性预筛（v2.9.3 服务器实测修复）：前 DIFF_PRECHECK 次尝试全部「生成成功但进不了档」
## 且难度上限远低于 easy 门槛 → 判定该「组合×尺寸」**在难度维不可达**（与数学 UNSAT 同类，
## 只是维度不同：不是无解，而是不存在「够难」的解）→ 停止白白耗尽 seed_max。
## 实测依据：mx_ep/8x8、mx_4c/8x8 跑满 40 seed 产出 0 关（tier_empty 100%）；
## mx_ep 全局 195 次尝试仅 17 关（8.7%）、dt_4c 169 次 42 关（24.9%）。
## 阈值取 easy 门槛（0.3）的一半留足余量——只截「永远够不到」的单元，不误杀波动组合。
const DIFF_PRECHECK := 4
const DIFF_UNREACHABLE_MAX := 0.15

func _max_similarity(mine_sets: Array, new_set: Dictionary) -> float:
	var worst := 0.0
	for ms in mine_sets:
		var inter := 0
		for p in new_set:
			if ms.has(p):
				inter += 1
		var union: int = new_set.size() + int(ms.size()) - inter
		if union > 0:
			worst = maxf(worst, float(inter) / float(union))
	return worst


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
	if args.size() >= 8 and args[7] != "":
		_target_difficulty = float(args[7])
	# 第 9 参：额外组合（Mod/自定义规则）规格——逗号分隔多项，每项 `clue[+g1+g2][@5,6]`。
	# 例："o1@5,6,7"、"o1+hpair@6,7"。这些组合追加在内置 92 组合之后（v3.0 平台能力：
	# 旧版组合表硬编码内置规则，Mod 规则无法进批量——新算子量产的前置缺口）。
	if args.size() >= 9 and args[8] != "":
		_extra_combos_spec = args[8]
	# 第 10 参：预加载 Mod 目录名（逗号分隔，demo/mods/<name>/entry.gd 的 on_load 注册）。
	# 可复现：量产命令自带 Mod 清单，不依赖全局安装状态。
	if args.size() >= 10 and args[9] != "":
		for mod_name in str(args[9]).split(",", false):
			var entry := "res://demo/mods/%s/entry.gd" % str(mod_name)
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
					print("  [mod] 已加载: %s" % str(mod_name))
			else:
				push_error("Mod 入口不存在: " + entry)
	DirAccess.make_dir_recursive_absolute(_out_dir)
	# 记录文件路径（分片命名——多进程写同一文件会互相覆盖，v2.9.3 probe 实测教训）
	_issues_path = "%s/%s" % [_out_dir,
		"issues_shard_%02d.jsonl" % _shard_idx if _shard_total > 1 else "issues.jsonl"]

	var combos := _build_combos()
	# 额外组合（Mod/自定义规则）追加在内置组合之后（limit 不影响它们——limit 是冒烟用）
	if _extra_combos_spec != "":
		combos.append_array(_build_extra_combos())
	# limit 语义：0=全部；>0=前 N 项（内置冒烟）；-1=仅额外组合（Mod 规则冒烟/量产的干净入口）
	if _limit_combos == -1:
		combos = _build_extra_combos()
	elif _limit_combos > 0 and _limit_combos < combos.size():
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
		"similar_skipped": 0, "tiers": {"easy": 0, "normal": 0, "hard": 0}}
	var skipped: Array = []
	var design_skip: Array = []
	var partial: Array = []
	var diff_unreach: Array = []

	print("=== 全变体+混合批量生成（%d 组合 × 5 尺寸 × 每类 %d 关）[shard %d/%d]===" % [
		combos.size(), _per_type, _shard_idx, _shard_total])
	for combo in combos:
		var combo_sides: Array = combo.get("sides", [])
		for side in SIZES:
			if not combo_sides.is_empty() and not combo_sides.has(side):
				continue
			var mines: int = SIZES[side]
			stats["units"] += 1
			var combo_dir := "%s/%s/%dx%d" % [_out_dir, combo["id"], side, side]
			# 注：mines 在下方可行性预筛处可能被候选回退覆盖（见 resolve_mines 段）。
			# FR（首雷）设计跳过（v2.9.3 决策）：FR 线索「向右首雷距离」直接锁定雷位、
			# 无弱信息值（GDD 3.3 原话），difficulty 恒 <0.3（实测 0.06~0.28，含 G+FR 混合），
			# 进不了最低 easy 档，无法作为标准三档关卡生成——这是变体特性，非代码 bug。
			# mx_dt（G+G）同理：镜像+骨牌全局约束自带全部开局信息（骨牌外强制非雷 + 镜像
			# 锁死骨牌内选择），0 条线索即可序贯推完 → 生成关难度恒 <0.3（实测 0.04~0.17）。
			if combo["clue"] == "fr" or (combo["clue"] == "classic" and combo["globals"] == ["mx", "dt"]):
				stats["design_skip"] += 1
				design_skip.append("%s %dx%d" % [combo["id"], side, side])
				continue
			# 候选雷数回退（v3.0，GDD §8.1）：标准雷数不可行时按候选列表回退
			#（守恒算子整除/奇偶要求与标准值互斥，如「相邻行锁」6×6 需奇数雷）。
			# 全候选不可行 → 该单元数学上无解，跳过（与旧 UNSAT 语义一致）。
			var rr := RuleFeasibility.resolve_mines(combo["clue"], combo["globals"], side)
			if int(rr["mines"]) < 0:
				stats["skipped"] += 1
				skipped.append("%s %dx%d" % [combo["id"], side, side])
				continue
			mines = int(rr["mines"])
			var mines_fallback := not bool(rr["standard"])
			DirAccess.make_dir_recursive_absolute(combo_dir)
			# 断点续跑：扫描已有产出。满额单元直接跳过（重跑安全、不重复生成）；
			# 未满单元编号接续 + 指纹去重（同 seed 重跑撞已有盘时跳过，不产生冗余文件）。
			var existing := _scan_unit(combo_dir)
			if int(existing["count"]) >= _per_type:
				stats["resumed"] = int(stats.get("resumed", 0)) + 1
				stats["ok"] += int(existing["count"])
				_append_issues([_ev({"t": "unit_done", "combo": combo["id"], "side": side,
					"made": int(existing["count"]), "tried": 0, "empty": 0, "tier_empty": 0,
					"proof_fail": 0, "dup": 0, "similar": 0, "cost_s": 0.0, "resumed": true})])
				continue
			var made := int(existing["count"])
			var next_idx: Dictionary = existing["max_idx"]
			var fps: Dictionary = existing["fps"]
			var mine_sets: Array = existing["mine_sets"]
			# 单元级事件收集（单元粒度落盘：进程被杀也不丢已完成单元的事件）
			var unit_lines: Array = []
			var u_tried := 0
			var u_empty := 0
			var u_tier := 0
			var u_proof := 0
			var u_dup := 0
			var u_sim := 0
			# 阶段统计累计（v2.9.3 检测器增强）：布雷/删线索/验证各阶段失败可观测
			var u_attempts := 0
			var u_brep_fail := 0
			var u_prune_empty := 0
			var u_verify_fail := 0
			var u_timeout := 0
			var u_t0 := Time.get_ticks_msec()
			var max_diff_seen := -1.0
			var unreachable := false
			for seed in range(_seed_start, _seed_max + 1):
				# 难度可达性预筛（放循环开头：失败分支会 continue，只有迭代开始处才必然执行到）—
				# 前若干次尝试全「进不了档」且难度上限远低于门槛 → 该单元在难度维不可达，
				# 停止耗尽 seed_max（mx_ep/8x8 等实测 40 seed 全废，省下 90% 白跑）。
				if made == 0 and u_tried >= DIFF_PRECHECK and u_tier == u_tried \
						and max_diff_seen < DIFF_UNREACHABLE_MAX:
					unreachable = true
					unit_lines.append(_ev({"t": "diff_unreachable", "combo": combo["id"], "side": side,
						"max_diff": max_diff_seen, "tried": u_tried}))
					break
				var t_seed := Time.get_ticks_msec()
				var level: Dictionary = gen.generate_with_rules(
					combo["clue"], combo["globals"], Vector2i(side, side), mines, seed,
					0, 50, null, _timeout_for(side), _target_difficulty)
				var cost_ms := Time.get_ticks_msec() - t_seed
				u_tried += 1
				# 阶段统计差分累计（generate_with_rules 内每次调用重置）
				var s: Dictionary = gen.last_call_stats
				u_attempts += int(s.get("attempts", 0))
				u_brep_fail += int(s.get("brep_fail", 0))
				u_prune_empty += int(s.get("prune_empty", 0))
				u_verify_fail += int(s.get("verify_fail", 0))
				u_timeout += int(s.get("timeout", 0))
				if level.is_empty():
					u_empty += 1
					# 超时启发式：耗时贴到超时上限 → 大概率是删线索/CP-SAT 超时被杀（非真无解）
					var to_ms := _timeout_for(side)
					var kind := "empty_timeout" if cost_ms >= to_ms * 95 / 100 else "empty"
					unit_lines.append(_ev({"t": kind, "combo": combo["id"], "side": side,
						"seed": seed, "cost_s": cost_ms / 1000.0}))
					continue
				var dp: Dictionary = level.get("difficulty_profile", {})
				var diff := float(dp.get("difficulty", 0.0))
				var tier := Difficulty.tier_of(diff)
				if tier == "":
					u_tier += 1
					max_diff_seen = maxf(max_diff_seen, diff)
					unit_lines.append(_ev({"t": "tier_empty", "combo": combo["id"], "side": side,
						"seed": seed, "diff": diff, "cost_s": cost_ms / 1000.0}))
					continue
				# 生成后复核：可加载 + 序贯可解（与 verify_batch 同口径，杜绝废品入库）
				var log: Dictionary = ProofLog.build(level)
				if not bool(log.get("solved", false)):
					u_proof += 1
					unit_lines.append(_ev({"t": "proof_fail", "combo": combo["id"], "side": side,
						"seed": seed, "reason": str(log.get("reason", "")), "cost_s": cost_ms / 1000.0}))
					continue
				var fp := _fingerprint(level)
				if fps.has(fp):
					u_dup += 1
					unit_lines.append(_ev({"t": "dup_fp", "combo": combo["id"], "side": side,
						"seed": seed, "cost_s": cost_ms / 1000.0}))
					continue
				fps[fp] = true
				# 多样性门：与组内已有盘峰值 J > 0.85（几乎同盘）→ 拒收换 seed
				var new_set := {}
				for m in level.get("mines", []):
					new_set[Vector2i(int(m["c"]), int(m["r"]))] = true
				var peak_j := _max_similarity(mine_sets, new_set)
				if peak_j > SIMILARITY_MAX:
					u_sim += 1
					stats["similar_skipped"] = int(stats.get("similar_skipped", 0)) + 1
					unit_lines.append(_ev({"t": "similar", "combo": combo["id"], "side": side,
						"seed": seed, "j": peak_j, "cost_s": cost_ms / 1000.0}))
					continue
				mine_sets.append(new_set)
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
			# 单元完成行（兼心跳：远程 getfile 拉最后几行即可看进度）
			# 阶段字段（v2.9.3）：attempts=布雷尝试总数；brep_fail/prune_empty/verify_fail/timeout
			# 为各阶段失败数——「布雷成功率」= 1 - brep_fail/attempts，「端到端接受率」= made/tried。
			unit_lines.append(_ev({"t": "unit_done", "combo": combo["id"], "side": side,
				"made": made, "tried": u_tried, "empty": u_empty, "tier_empty": u_tier,
				"proof_fail": u_proof, "dup": u_dup, "similar": u_sim,
				"attempts": u_attempts, "brep_fail": u_brep_fail, "prune_empty": u_prune_empty,
				"verify_fail": u_verify_fail, "timeout": u_timeout,
				"mines": mines, "mines_fallback": mines_fallback,
				"cost_s": (Time.get_ticks_msec() - u_t0) / 1000.0}))
			if mines_fallback:
				stats["mines_fallback"] = int(stats.get("mines_fallback", 0)) + 1
			_append_issues(unit_lines)
			if unreachable:
				# 单独归类：不可达单元补跑也没用（与数学 UNSAT 同口径），不计入 partial。
				stats["diff_unreachable"] = int(stats.get("diff_unreachable", 0)) + 1
				diff_unreach.append("%s %dx%d (max_diff=%.2f)" % [combo["id"], side, side, max_diff_seen])
			elif made < _per_type:
				stats["partial"] += 1
				partial.append("%s %dx%d (%d/%d)" % [combo["id"], side, side, made, _per_type])

	var elapsed := float(Time.get_ticks_msec() - t0) / 1000.0
	print("=== 完成（%.1fs）===" % elapsed)
	print("  单元(组合×尺寸): %d | 入库总关数 %d | 设计跳过(FR难度) %d | 跳过(数学UNSAT) %d | 续跑满额跳过 %d | 相似拒收 %d | 部分成功 %d" % [
		stats["units"], stats["ok"], stats["design_skip"], stats["skipped"], stats.get("resumed", 0),
		stats.get("similar_skipped", 0), stats["partial"]])
	print("  难度分布: easy=%d normal=%d hard=%d | 候选雷数回退单元 %d" % [
		stats["tiers"]["easy"], stats["tiers"]["normal"], stats["tiers"]["hard"],
		int(stats.get("mines_fallback", 0))])
	if design_skip.size() > 0:
		print("  设计跳过清单(%d，FR难度天然<0.3，见GDD 3.3): %s" % [design_skip.size(), ", ".join(design_skip)])
	if skipped.size() > 0:
		print("  跳过清单(%d): %s" % [skipped.size(), ", ".join(skipped)])
	if partial.size() > 0:
		print("  部分成功清单(%d): %s" % [partial.size(), ", ".join(partial)])
	if diff_unreach.size() > 0:
		print("  难度不可达单元(%d，不存在够难的关卡——非 bug，补跑无效): %s" % [
			diff_unreach.size(), ", ".join(diff_unreach)])
	# 报告文件按分片命名：8 个分片进程写同一路径会互相覆盖（实测 probe40 丢了 7 片的 partial 清单）。
	var report_name := "all_report_shard_%02d.json" % _shard_idx if _shard_total > 1 else "all_report.json"
	_write("%s/%s" % [_out_dir, report_name], {
		"elapsed_s": elapsed, "stats": stats,
		"design_skip": design_skip, "skipped": skipped, "partial": partial,
		"diff_unreachable": diff_unreach,
		"issues_file": _issues_path.get_file(),
	})
	print("  事件记录: %s（%d 单元行 + 全量失败事件，可远程拉回分析）" % [_issues_path, stats["units"]])
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
