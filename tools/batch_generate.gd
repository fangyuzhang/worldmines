# batch_generate.gd —— 离线批量生成 + 难度筛选 + 去重 + 打包（方案 C）
# 彻底解决「40% 密度 + 庞大数量」的矛盾：离线预先跑大量题，运行时零生成直接加载。
#
# 用法（命令行，-- 后为参数）：
#   godot --headless --path . -s res://tools/batch_generate.gd -- <clue> <globals> <WxH> <mines> <seed_from> <seed_count> <per_tier> <out_dir> [shard_idx shard_total timeout_seconds]
#
# 例 1（单进程，40% 密度 classic，8×8 26雷，seed 1..100，每档 20 关，输出 user://batch40）：
#   godot --headless --path . -s res://tools/batch_generate.gd -- classic - 8x8 26 1 100 20 user://batch40
#
# 例 2（多进程分片，8 个进程各跑一段 seed，进程 0 起 shard 0/8）：
#   godot --headless --path . -s res://tools/batch_generate.gd -- classic - 9x9 32 1 80 20 user://batch40 0 8
#   godot --headless --path . -s res://tools/batch_generate.gd -- classic - 9x9 32 1 80 20 user://batch40 1 8
#   ...（其余 6 个进程同理，各改 shard_idx）
#
# 分片语义：
#   · seed 范围 [seed_from, seed_from+seed_count) 被均分成 shard_total 段，本进程跑第 shard_idx 段。
#   · 每个分片独立输出到 out_dir/shard_<idx>/，避免文件名冲突。
#   · per_tier 是「每个分片」的每档目标数（总量 = per_tier × shard_total）。
#   · 全部进程跑完后，用 batch_merge.gd 合并分片到 out_dir/ 顶层并全局编号。
#   · 分片模式自动把每进程 CP-SAT 搜索 worker 降为 1（进程数 × 1 = 核数，避免超额订阅）。
#
# 参数默认值：classic / 无全局 / 8×8 / 26雷 / seed 1..100 / 每档 20 / user://batch_levels
# globals 用逗号分隔（如 "mx,rl"），"-" 或 "none" = 无全局约束。
#
# 删线索超时（timeout_seconds，可选第 11 参）：
#   · 默认 0 = 按尺寸自动放大（max(30s, 格数×0.6s)；16×16 → ~154s）。
#   · **不要**用 15s 跑大棋盘：删线索半途而废 → 产出线索超多（clue_ratio ~0.57）的「假 easy」关，
#     normal/hard 档永远为空（实测 16×16 完整删线索需 ~100s）。
#   · 显式传 timeout_seconds 可覆盖（如 16×16 给 200）。
extends SceneTree

# 可靠退出：Godot 4.7.2 mono 在本工程里 quit() 后进程间歇性不退出（实测 7/8），
# 详见 cli_shutdown.gd 顶部注释。必须走它，不要直接 quit()。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

var _gen := PuzzleGenerator.new()
var _seen := {}  # 去重指纹 -> true

var _clue := "classic"
var _globals: Array = []
var _size := Vector2i(8, 8)
var _mines := 26
var _seed_from := 1
var _seed_count := 100
var _per_tier := 20
var _out_dir := "user://batch_levels"
var _shard_idx := -1    # -1 = 单进程（不分片）
var _shard_total := 1
var _timeout_ms := 0    # 0 = 按尺寸自动放大（见下）；>0 = 显式覆盖（毫秒）
var _target_difficulty := 0.0  # >0 = 按目标难度生成（第 12 参，删到达标即停）

var _stats := {"total": 0, "ok": 0, "fail": 0, "dup": 0, "tiers": {"easy": 0, "normal": 0, "hard": 0}}


func _initialize() -> void:
	_parse_args()
	# 分片批跑：每进程单 worker。进程数 × 1 worker = 物理核数，避免默认 4 worker × 多进程
	# 超额订阅互相抢核（墙钟不线性）。单进程模式保持 C# 默认 4 worker（单次 Solve 内并行）。
	_gen.num_workers = 1 if _shard_idx >= 0 else 0
	# 删线索超时：**不能**用 15s 默认——大棋盘（≥12×12）15s 删不完，会静默产出
	# 线索超多（clue_ratio ~0.57）的「假 easy」关，normal/hard 档永远为空（实测 16×16 完整 ~100s）。
	# 系数 1500（原 600）：实测 9×9 重线索组合单关 68~74s，600 系数会超时杀掉好关
	#（16×16 → 384s，地板 30s）；显式 -timeout 可覆盖。
	var timeout_ms := _timeout_ms
	if timeout_ms <= 0:
		timeout_ms = maxi(30_000, _size.x * _size.y * 1500)
	_timeout_ms = timeout_ms  # 回写有效值，供报告打印/落盘
	var t0 := Time.get_ticks_msec()

	# seed 范围：分片模式下切出本进程的一段
	var lo := _seed_from
	var hi := _seed_from + _seed_count
	if _shard_idx >= 0:
		var chunk := ceili(float(_seed_count) / float(_shard_total))
		lo = _seed_from + _shard_idx * chunk
		hi = mini(_seed_from + (_shard_idx + 1) * chunk, _seed_from + _seed_count)

	for seed in range(lo, hi):
		# 进度打印：每个 seed 前后各一行，卡死时能立即定位到哪个 seed（可观测性）。
		print("[seed %d] 开始..." % seed)
		var t_seed := Time.get_ticks_msec()
		var level := _gen.generate_with_rules(_clue, _globals, _size, _mines, seed, 0, 50, null, timeout_ms, _target_difficulty)
		var dt := float(Time.get_ticks_msec() - t_seed) / 1000.0
		_stats["total"] += 1
		if level.is_empty():
			_stats["fail"] += 1
			print("[seed %d] 失败（%.1fs）" % [seed, dt])
			continue
		var dp: Dictionary = level.get("difficulty_profile", {})
		var diff := float(dp.get("difficulty", 0.0))
		# v4.0：档位按峰值定（回退旧标量口径以兼容存量产物）
		var tier := Difficulty.tier_of_profile(dp)
		if tier == "":
			tier = Difficulty.tier_of(diff)
		if tier == "":
			_stats["fail"] += 1
			print("[seed %d] 无档位（%.1fs）" % [seed, dt])
			continue
		# 去重：mines 坐标指纹（同 seed 同盘，但不同 seed 也可能撞盘，去重防冗余）
		var fp := _fingerprint(level)
		if _seen.has(fp):
			_stats["dup"] += 1
			print("[seed %d] 重复（%.1fs）" % [seed, dt])
			continue
		_seen[fp] = true
		# 该档已满则跳过（但仍计入统计）
		if int(_stats["tiers"][tier]) >= _per_tier:
			print("[seed %d] %s 已满跳过（%.1fs）" % [seed, tier, dt])
			continue
		# 打包
		var idx := int(_stats["tiers"][tier]) + 1
		level["name"] = "%s_%02d" % [tier, idx]
		level["difficulty"] = diff  # 冗余落盘，便于筛选工具直接读
		_write("%s/%s_%02d.json" % [_out_dir, tier, idx], level)
		_stats["tiers"][tier] = idx
		_stats["ok"] += 1
		print("[seed %d] %s_%02d（%.1fs）" % [seed, tier, idx, dt])

	var elapsed := Time.get_ticks_msec() - t0
	_stats["elapsed_ms"] = elapsed
	_stats["accept_rate"] = snappedf(float(_stats["ok"]) / float(maxi(1, _stats["total"])), 0.001)
	_report(t0, lo, hi)
	CliShutdown.request_exit(0)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and args[0] != "":
		_clue = args[0]
	if args.size() >= 2 and args[1] != "" and args[1] != "-" and args[1] != "none":
		for g in str(args[1]).split(",", false):
			if g != "":
				_globals.append(g)
	if args.size() >= 3:
		var dims := str(args[2]).split("x", false)
		if dims.size() == 2:
			_size = Vector2i(int(dims[0]), int(dims[1]))
	if args.size() >= 4:
		_mines = int(args[3])
	if args.size() >= 5:
		_seed_from = int(args[4])
	if args.size() >= 6:
		_seed_count = int(args[5])
	if args.size() >= 7:
		_per_tier = int(args[6])
	if args.size() >= 8:
		_out_dir = args[7]
	if args.size() >= 9:
		_shard_idx = int(args[8])
	if args.size() >= 10:
		_shard_total = int(args[9])
	if args.size() >= 11 and args[10] != "":
		_timeout_ms = int(args[10]) * 1000  # 秒 → 毫秒
	if args.size() >= 12 and args[11] != "":
		_target_difficulty = float(args[11])  # 目标难度（0=不限；如定向 hard 用 2.5）
	# 分片模式：输出到独立子目录，避免多进程写同一批文件冲突
	if _shard_idx >= 0:
		_out_dir = "%s/shard_%02d" % [_out_dir, _shard_idx]
	DirAccess.make_dir_recursive_absolute(_out_dir)


## 关卡指纹：mines 坐标（排序）+ 尺寸 + 雷数。碰撞 = 同盘面（不同 seed 撞盘极罕见，去重防冗余）。
func _fingerprint(level: Dictionary) -> String:
	var parts: Array = []
	parts.append("%dx%d-%d" % [int(level["size"]["cols"]), int(level["size"]["rows"]), int(level["total_mines"])])
	var ms: Array = []
	for m in level["mines"]:
		ms.append("%d,%d" % [int(m["c"]), int(m["r"])])
	ms.sort()
	parts.append("|".join(ms))
	return "|".join(parts)


func _write(path: String, level: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(level, "  "))
		f.close()


## 统计报告落盘（每批/每分片一次），供筛选/打包工具读取。
func _report(t0: int, lo: int, hi: int) -> void:
	var r := {
		"clue": _clue,
		"globals": _globals,
		"size": [_size.x, _size.y],
		"mines": _mines,
		"seed_range": [lo, hi - 1],
		"per_tier": _per_tier,
		"timeout_ms": _timeout_ms,
		"shard": {"idx": _shard_idx, "total": _shard_total} if _shard_idx >= 0 else null,
		"stats": _stats,
	}
	_write("%s/report.json" % _out_dir, r)
	var shard_tag := " [shard %d/%d]" % [_shard_idx, _shard_total] if _shard_idx >= 0 else ""
	print("=== 批量生成完成%s ===" % shard_tag)
	print("  配置: %s+%s %dx%d %d雷（删线索超时 %.0fs）" % [_clue, str(_globals), _size.x, _size.y, _mines, float(_timeout_ms) / 1000.0])
	print("  种子: %d..%d" % [lo, hi - 1])
	print("  结果: 总 %d | 成功 %d | 失败 %d | 重复 %d | 接受率 %.0f%%" % [
		_stats["total"], _stats["ok"], _stats["fail"], _stats["dup"], _stats["accept_rate"] * 100.0])
	print("  分档: easy=%d normal=%d hard=%d" % [_stats["tiers"]["easy"], _stats["tiers"]["normal"], _stats["tiers"]["hard"]])
	print("  耗时: %.1f s (平均 %.1f s/关)" % [_stats["elapsed_ms"] / 1000.0, _stats["elapsed_ms"] / 1000.0 / float(maxi(1, _stats["total"]))])
	print("  输出: %s" % _out_dir)
	# ASCII 判据（供流水线脚本/CI 判定成功，中文串会被 PS 编码转换搞坏，见坑 #27）
	print("=== BATCH-GEN-OK ===")
