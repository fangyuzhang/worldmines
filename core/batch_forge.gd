class_name BatchForge
extends RefCounted

## 批量生产关卡（P6，2026-10-02）。
##
## 用户原话：想了一个变体 → 在电脑上"生成 100 关"发布创意工坊；要进度条，要"按难度分类"
## 和"按棋盘大小分类"（每类各生成多少关由用户定）；玩家侧也要按同一套分类浏览。
##
## 【为什么是"逐帧步进"而不是一次跑完】生成一关要调 CP-SAT（`solver/RuleSolver.cs`），
## 单次调用**不可中断**（仓库既有口径：`ui/mod_select.gd` 的进度弹窗也是每候选刷一次）。
## 所以本类把"生成一关"做成一次 `step()`：UI 每帧调一次，期间还能响应取消、更新进度与 ETA、
## 显示已命中的分类统计。**界面在单次 step 期间会卡住几秒**——这一点由 UI 明说，不假装流畅。
##
## 【分类的单一真源】档位一律由 `Difficulty.tier_of_profile(level["difficulty_profile"])` **实算**
##（不读人工标签、不信文件名），候选只有落在目标档窗口内才被收下；大小来自用户勾选的边长。
## 产出落成**集文件** `levels/<大小>/<档位>.json`（为什么不能一关一文件：见 `core/level_sets.gd`）。

const LEVELS_DIR := "levels"
const INDEX_NAME := "index.json"
const DEFAULT_OUT_DIR := "user://forge/batch"

## 单次生成的候选上限（`PuzzleGenerator.attempts`）：批量要的是"多试几个 seed"，不是在一个 seed 上死磕。
const DEFAULT_ATTEMPTS := 10
## 单次生成的墙钟上限。比"单关默认 15s"短：批量里一关最多占这么久，否则进度条会长时间不动。
const DEFAULT_TIMEOUT_MS := 8000
## 单个 (大小, 档位) 桶的候选上限：打不动就认输并**如实记账**，而不是烧一整晚。
const BUCKET_ATTEMPT_CAP := 600
## 连续"空返回 / 档位不符 / 重复"的上限（沿用 `ui/mod_select.gd` 的止损口径）。
const MISS_LIMIT := 60
const SEED_BASE := 100000
## 默认雷密度：标准扫雷 9×9 / 10 雷 = 12.3%（用户可改）。
const DEFAULT_MINES_RATIO := 0.123

var _opts: Dictionary = {}
var _jobs: Array = []
var _ji := 0
var _attempts := 0
var _accepted := 0
var _total := 0
var _started_ms := 0
var _elapsed_ms := 0
var _done := false
var _cancelled := false
var _seen: Dictionary = {}
var _notes: Array[String] = []
var _per_tier: Dictionary = {}
var _per_size: Dictionary = {}
var _gen: Callable = Callable()
var _pg: PuzzleGenerator = null


## 计划（纯函数，便于单测）：sizes × 每档份数 ⇒ 每个 (大小, 档位) 一条 job。
## `tier_counts` 是**每个大小**的份数——对应用户原话"每个难度生成多少关卡 / 每个大小生成多少关卡"。
static func plan(sizes: Array, tier_counts: Dictionary) -> Array:
	var jobs: Array = []
	for size in sizes:
		for tier in Difficulty.PEAK_WINDOWS.keys():   # 档位名单唯一真源，不在此硬编码
			var want := int(tier_counts.get(tier, 0))
			if want > 0:
				jobs.append({"size": int(size), "tier": str(tier), "want": want,
					"got": 0, "attempts": 0, "misses": 0, "levels": []})
	return jobs


static func total_of(jobs: Array) -> int:
	var n := 0
	for j in jobs:
		n += int((j as Dictionary)["want"])
	return n


## 开始一次批量生产。opts：
##   clue_rule_id:String、global_rule_ids:Array、sizes:Array[int]、tier_counts:{档位:int}、
##   mode:String（集文件的 mode 字段，通常 = 变体 id）、out_dir:String（落地根目录）、
##   name_prefix:String（关卡显示名前缀）、mines_ratio:float、attempts:int、timeout_ms:int、
##   gen:Callable（可选，`(size:int, seed:int) -> Dictionary`；测试注入用，真机走 PuzzleGenerator）
func start(opts: Dictionary) -> void:
	_opts = opts
	_jobs = plan(opts.get("sizes", []), opts.get("tier_counts", {}))
	_total = total_of(_jobs)
	_ji = 0
	_attempts = 0
	_accepted = 0
	_started_ms = Time.get_ticks_msec()
	_elapsed_ms = 0
	_cancelled = false
	_done = _total <= 0
	_seen.clear()
	_notes.clear()
	_per_tier.clear()
	_per_size.clear()
	_gen = opts.get("gen", Callable())
	if _total <= 0:
		_notes.append("没有勾选任何「大小 × 档位」组合，或每档份数都是 0 —— 没有要生成的东西")


## 生成**一次尝试**（一次 CP-SAT 调用，可能耗时数秒）。UI 每帧调一次；一个桶满了自动换下一个。
func step() -> void:
	if _done:
		return
	_advance_finished()
	if _ji >= _jobs.size():
		_finish()
		return
	var job: Dictionary = _jobs[_ji]
	var size := int(job["size"])
	var seed := SEED_BASE + _attempts
	_attempts += 1
	job["attempts"] = int(job["attempts"]) + 1
	var lv := _generate(size, seed)
	if lv.is_empty():
		job["misses"] = int(job["misses"]) + 1
		_elapsed_ms = Time.get_ticks_msec() - _started_ms
		return
	var tier := Difficulty.tier_of_profile(lv.get("difficulty_profile", {}))
	if tier != str(job["tier"]):
		# 档位不符就扔掉：分类的唯一真源是**实算档位**，不是我们"希望"它是什么档
		job["misses"] = int(job["misses"]) + 1
		_elapsed_ms = Time.get_ticks_msec() - _started_ms
		return
	var fp := fingerprint(lv)
	if _seen.has(fp):
		job["misses"] = int(job["misses"]) + 1   # 同一颗盘出现两次 = 玩家眼里的重复关
		_elapsed_ms = Time.get_ticks_msec() - _started_ms
		return
	_seen[fp] = true
	job["misses"] = 0
	lv["name"] = _level_name(size, tier, int(job["got"]) + 1)
	lv["tier"] = tier
	(job["levels"] as Array).append(lv)
	job["got"] = int(job["got"]) + 1
	_accepted += 1
	_per_tier[tier] = int(_per_tier.get(tier, 0)) + 1
	var sk := str(size)
	_per_size[sk] = int(_per_size.get(sk, 0)) + 1
	_elapsed_ms = Time.get_ticks_msec() - _started_ms
	_advance_finished()
	if _ji >= _jobs.size():
		_finish()


## 停止（**已生成的关卡全部保留**并落盘：半成品对用户也有价值）。
func cancel() -> void:
	if _done:
		return
	_cancelled = true
	_notes.append("已停止——已经生成的关卡都留着")
	_finish()


func is_done() -> bool:
	return _done


func is_cancelled() -> bool:
	return _cancelled


## 进度快照。`eta_ms` 在"还没命中过"时是 **-1**：估不出来就说估不出来，不编数字。
func progress() -> Dictionary:
	return {
		"done": _done,
		"cancelled": _cancelled,
		"made": _accepted,
		"total": _total,
		"attempts": _attempts,
		"elapsed_ms": _elapsed_ms,
		"eta_ms": eta_ms(),
		"per_tier": _per_tier.duplicate(),
		"per_size": _per_size.duplicate(),
		"tier_text": tier_summary(),
		"bucket_text": bucket_text(),
		"msg": message(),
	}


func eta_ms() -> int:
	if _total <= 0 or _accepted >= _total:
		return 0
	if _accepted <= 0:
		return -1
	# 按"每命中一关实际花掉的墙钟"外推（含失败候选的代价，比按候选数外推更接近用户体感）
	return int(float(_elapsed_ms) / float(_accepted) * float(_total - _accepted))


## 一行给人看的进度（编辑器弹窗直接显示这行）。
func message() -> String:
	if _total <= 0:
		return "没有要生成的东西"
	var head := "已生成 %d/%d 关" % [_accepted, _total]
	if not _per_tier.is_empty():
		head += "（%s）" % tier_summary()
	var tail := "｜已试 %d 次｜已用 %s" % [_attempts, human_ms(_elapsed_ms)]
	if _done:
		if _cancelled:
			return "%s\n已停止。%s" % [head, tail]
		return "%s\n完成！%s" % [head, tail]
	var span := human_ms(_elapsed_ms)
	match _eta_state():
		0:
			return "%s\n%s，预计还要 %s" % [head, tail, human_ms(eta_ms())]
		1:
			return "%s\n%s（还没命中过，暂时估不出还要多久）" % [head, tail]
		_:
			return "%s\n%s，这一桶在 %s 上打不动，会跳过它继续" % [head, tail, bucket_text()]


## 分类统计的中文短句：普通 7 ・ 困难 4 ・ 噩梦 1。
func tier_summary() -> String:
	var parts: Array[String] = []
	for tier in Difficulty.PEAK_WINDOWS.keys():
		var n := int(_per_tier.get(tier, 0))
		if n > 0:
			parts.append("%s %d" % [Difficulty.tier_short(tier), n])
	return " ・ ".join(parts) if not parts.is_empty() else "还没命中"


## 当前正在啃的桶（人话）：8×8 困难。
func bucket_text() -> String:
	if _ji >= _jobs.size():
		return ""
	var j: Dictionary = _jobs[_ji]
	return LevelSets.group_label(int(j["size"]), str(j["tier"]))


## 这一档雷数用几颗（编辑器可显示出来，免得用户以为"没人问过雷数"）。
func mines_for(size: int) -> int:
	return maxi(1, int(round(float(size * size) * float(_opts.get("mines_ratio", DEFAULT_MINES_RATIO)))))


## 用**能力档案**（`VariantCapability` 的实测产物）预估这批要跑多久、哪些档可能出不来。
##
## 【为什么用实测档案而不是理论推导】能不能出某一档取决于规则、尺寸、雷数三者的组合，
## 实测数据（`core/variant_capability.gd`）是唯一有依据的来源：它给出每档命中率与单候选成本
##（含失败候选的代价——这正是用户体感的时间）。没有档案时**如实说"还没实测"**，
## 不编一个"大概"。
##
## `profile` = `VariantCapability.load_for(key)` 的整份档案（`{"sides":{"8":{...}}}`），
## 每尺寸的字段即 `probe_finish` 的产物（`hit_rate` / `cost_ms_mean` / `cand` / `reachable`）。
## 返回 {ok, eta_ms, per_bucket:[{size,tier,want,hit_rate,eta_ms,known}], missing:[同一形状], cand_min}
static func estimate(profile: Dictionary, sizes: Array, tier_counts: Dictionary) -> Dictionary:
	var sides: Dictionary = profile.get("sides", {})
	var jobs := plan(sizes, tier_counts)
	var per_bucket: Array = []
	var missing: Array = []
	var eta := 0
	var cand_min := 0
	var known_any := false
	for j in jobs:
		var job: Dictionary = j
		var size := int(job["size"])
		var tier := str(job["tier"])
		var want := int(job["want"])
		var side_data: Dictionary = sides.get(str(size), {})
		var rate := float((side_data.get("hit_rate", {}) as Dictionary).get(tier, 0.0))
		var cost := float(side_data.get("cost_ms_mean", 0.0))
		var cand := int(side_data.get("cand", 0))
		if cand > 0:
			# 样本量只在**真有数据的**尺寸上取最小（部分尺寸没测过时不能被 0 拉平 ⇒ 界面会误报"还没实测"）
			known_any = true
			cand_min = mini(cand_min, cand) if cand_min > 0 else cand
		var row := {"size": size, "tier": tier, "want": want, "hit_rate": rate,
			"cost_ms": cost, "eta_ms": 0, "known": false}
		if rate > 0.0 and cost > 0.0:
			# 期望候选数 = 想要几关 / 命中率；每候选成本取实测均值（含失败候选）
			var ms := int(round(float(want) / rate * cost))
			row["eta_ms"] = ms
			row["known"] = true
			eta += ms
		else:
			missing.append(row)
		per_bucket.append(row)
	return {"ok": missing.is_empty() and not per_bucket.is_empty(), "eta_ms": eta,
		"per_bucket": per_bucket, "missing": missing, "cand_min": cand_min, "known_any": known_any}


## 关卡指纹（去重用）：尺寸 + 全部雷位排序后的字符串。同一刻盘不同 seed 会撞同一指纹。
static func fingerprint(lv: Dictionary) -> String:
	var parts: Array[String] = []
	var mines: Variant = lv.get("mines", [])
	if mines is Array:
		for m in (mines as Array):
			if m is Dictionary:
				parts.append("%d,%d" % [int((m as Dictionary).get("r", -1)),
					int((m as Dictionary).get("c", -1))])
	parts.sort()
	return "%s#%s" % [str(lv.get("size", {})), ",".join(parts)]


## 落地根目录（本次批量的所有产出都在它下面）。
func out_root() -> String:
	return str(_opts.get("out_dir", DEFAULT_OUT_DIR))


## 把已命中的关卡写成集文件 + index.json。取消/结束都会调——**半成品也要落盘**。
## 返回 {ok, dir, files:[相对路径], failed:[相对路径], index, categories}
func flush() -> Dictionary:
	var root := out_root()
	# 【P1-2 修复】先清掉**上一批**的集文件：打包是"递归收 `levels/` 下所有 .json"，
	# 而 index/manifest 只列本批 ⇒ 留着旧文件会让玩家看到"分组里有它、索引里没有"。
	# 只删 `levels/<大小>/` 里的产品文件（不动目录、不动别的产物）。
	var lv := DirAccess.open("%s/%s" % [root, LEVELS_DIR])
	if lv != null:
		for d in lv.get_directories():
			var sub := DirAccess.open("%s/%s/%s" % [root, LEVELS_DIR, d])
			if sub == null:
				continue
			for f in sub.get_files():
				sub.remove(f)
	var mode := str(_opts.get("mode", ""))
	var written: Array[String] = []
	var failed: Array[String] = []
	var categories := {}
	var entries: Array = []
	for j in _jobs:
		var levels: Array = j["levels"]
		if levels.is_empty():
			continue
		var size := int(j["size"])
		var tier := str(j["tier"])
		var rel := "%s/%d/%s.json" % [LEVELS_DIR, size, tier]
		if LevelSets.write_set("%s/%s" % [root, rel], mode, size, tier, levels):
			written.append(rel)
		else:
			failed.append(rel)
		var sk := str(size)
		if not categories.has(sk):
			categories[sk] = {}
		(categories[sk] as Dictionary)[tier] = levels.size()
		entries.append({"file": rel, "size": size, "tier": tier, "count": levels.size()})
	var idx := {
		"schema": LevelSets.SCHEMA,
		"mode": mode,
		"clue_rule": str(_opts.get("clue_rule_id", "")),
		"global_rules": _opts.get("global_rule_ids", []),
		"sizes": _present_sizes(),
		"categories": categories,
		"count": _accepted,
		"per_tier": _per_tier.duplicate(),
		# 实测吞吐（P6c）：留着给**下一次**点开弹窗时做时间预期——
		# 不做重型预探（那要额外烧几十秒机时），用真实历史数据最诚实。
		"attempts": _attempts,
		"elapsed_ms": _elapsed_ms,
		"created_unix": int(Time.get_unix_time_from_system()),
		"levels": entries,
	}
	var f := FileAccess.open("%s/%s" % [root, INDEX_NAME], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(idx, "  "))
		f.close()
	return {"ok": failed.is_empty(), "dir": root, "files": written, "failed": failed,
		"index": INDEX_NAME, "categories": idx}


## 分类索引（工坊打包写进 manifest 的那份；端到端"上传带分类、下载已分类"就靠它）。
func categories() -> Dictionary:
	return flush()["categories"]


## 最终账本（人话 + 明细）。
func report() -> Dictionary:
	var fails: Array[String] = []
	for j in _jobs:
		var got := int(j["got"])
		var want := int(j["want"])
		if got < want:
			fails.append("%s：只出了 %d/%d 关（试了 %d 次）" % [
				LevelSets.group_label(int(j["size"]), str(j["tier"])), got, want, int(j["attempts"])])
	var out := flush()
	return {
		"ok": _accepted > 0 and (out["failed"] as Array).is_empty(),
		"total": _total, "made": _accepted, "attempts": _attempts,
		"elapsed_ms": _elapsed_ms, "per_tier": _per_tier.duplicate(),
		"per_size": _per_size.duplicate(), "short": fails, "notes": _notes.duplicate(),
		"dir": out["dir"], "files": out["files"], "index": out["index"],
		"summary": "%d/%d 关，用时 %s" % [_accepted, _total, human_ms(_elapsed_ms)],
	}


## 毫秒 → 人话（"12 秒" / "1 分 20 秒" / "1 小时 3 分"）。
static func human_ms(ms: int) -> String:
	if ms < 0:
		return "估不出来"
	if ms < 1000:
		return "%d 毫秒" % ms
	var s := int(round(float(ms) / 1000.0))
	if s < 60:
		return "%d 秒" % s
	var m := int(s / 60)
	if m < 60:
		return "%d 分 %d 秒" % [m, s % 60]
	return "%d 小时 %d 分" % [int(m / 60), m % 60]


## 0 = 有 ETA；1 = 还没有命中过（估不出来）；2 = 当前桶已打不动
func _eta_state() -> int:
	if _accepted <= 0:
		return 1
	if _ji < _jobs.size() and int((_jobs[_ji] as Dictionary)["misses"]) >= MISS_LIMIT:
		return 2
	return 0


func _advance_finished() -> void:
	while _ji < _jobs.size():
		var j: Dictionary = _jobs[_ji]
		if int(j["got"]) >= int(j["want"]):
			_ji += 1
			continue
		# 止损（两道）：连续 MISS_LIMIT 次没命中，或这一桶总共试到 CAP ——
		# 都**如实记账后跳过**，不让一个啃不动的桶把整晚烧掉（沿用 mod_select 的止损口径）。
		var stalled := int(j["misses"]) >= MISS_LIMIT
		var capped := int(j["attempts"]) >= BUCKET_ATTEMPT_CAP
		if stalled or capped:
			_notes.append("%s：试了 %d 次只出了 %d/%d 关 ⇒ 跳过这一桶（这个变体在这个大小×档位下太难命中）" % [
				LevelSets.group_label(int(j["size"]), str(j["tier"])), int(j["attempts"]),
				int(j["got"]), int(j["want"])])
			_ji += 1
			continue
		return


func _finish() -> void:
	if _done:
		return
	_done = true
	_elapsed_ms = Time.get_ticks_msec() - _started_ms
	flush()


func _generate(size: int, seed: int) -> Dictionary:
	if _gen.is_valid():
		return _gen.call(size, seed)
	if _pg == null:
		_pg = PuzzleGenerator.new()
	return _pg.generate_with_opts({
		"clue_rule_id": str(_opts.get("clue_rule_id", "classic")),
		"global_rule_ids": _opts.get("global_rule_ids", []),
		"size": Vector2i(size, size),
		"mine_count": mines_for(size),
		"seed": seed,
		"attempts": int(_opts.get("attempts", DEFAULT_ATTEMPTS)),
		"timeout_ms": int(_opts.get("timeout_ms", DEFAULT_TIMEOUT_MS)),
	})


func _present_sizes() -> Array:
	var sizes: Array = _per_size.keys()
	sizes.sort()
	return sizes


func _level_name(size: int, tier: String, idx: int) -> String:
	var prefix := str(_opts.get("name_prefix", ""))
	if prefix == "":
		prefix = str(_opts.get("mode", "关卡"))
	return "%s %d×%d %s %02d" % [prefix, size, size, Difficulty.tier_short(tier), idx]
