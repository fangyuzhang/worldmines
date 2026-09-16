# verify_batch.gd —— 题库生成后门禁（防「批量跑完才发现不能用 → 复工」）
#
# 对 out_dir 下每个关卡 JSON 做五重检查：
#   1) JSON 可解析；2) Board 引擎真实构造加载；3) R07 固定雷数契约（5..9 矩形）；
#   4) schema 基础校验（雷数一致/坐标界内/不重复/revealed 非雷）；
#   5) 线索值 round-trip（Board 重算值 vs 规则独立重算；masked 格校验区间覆盖）；
#   外加 ProofLog 序贯可解 + clue_ratio 冗余告警。
# 任一失败 → 打印清单并 exit 1（可接 CI / 脚本判断）。
#
# 用法（命令行，-- 后为目录）：
#   godot --headless --path . -s res://tools/verify_batch.gd -- <out_dir>
# 例：res://levels 或 user://batch_levels
#
# v2.9.3 盲区修复：旧门禁只有①②③（且「可加载」曾长期是注释谎言）；schema/round-trip/R07
# 只在本地审计工具里（batch_audit_r07 / _test_load_rt）——服务器批量链路从未跑过。
extends SceneTree

# 可靠退出：见 cli_shutdown.gd 顶部注释。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

## R07 固定雷数契约（GDD）：尺寸 → 雷数。仅对 5..9 矩形盘生效。
const R07_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
## 线索冗余诊断（2026-09-16 改口径）：原「绝对阈值 0.5」对低档盘是**结构性误报**——
## clue_ratio 随档位单调递减，是 tiered 产线「朝档走 + 达标即停」的必然结果
## （实测三批一致：intro 中位 0.92~0.95 / easy 0.64~0.80 / normal 0.44~0.59 / hard 0.47~0.51，
## 见 tools/_diag_clue_ratio.py）。旧阈值把正常的 intro 盘 100% 判为告警，反而淹没真信号。
## 改为「相对口径」：按（尺寸 × 档）分组，组内中位数 + DELTA 以上 = 离群（疑似删线索不充分）。
const CLUE_RATIO_OUTLIER_DELTA := 0.15
## 相对口径的最小样本：组内盘数少于此值时不告警（只展示分层中位数），避免小样本误判。
const CLUE_RATIO_MIN_SAMPLE := 5

var _out_dir := "user://batch_levels"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and str(args[0]) != "":
		_out_dir = str(args[0])
	# v3.0：Mod 规则兜底加载——验证 Mod 产物（o1/o2…）必须先注册规则，
	# 否则被门禁正确拦截为「规则未注册」（-s 环境无 ModAPI autoload）。
	var mods_dir := DirAccess.open("res://demo/mods")
	if mods_dir != null:
		for sub in mods_dir.get_directories():
			var entry := "res://demo/mods/%s/entry.gd" % sub
			if ResourceLoader.exists(entry):
				var sc: Variant = load(entry)
				if sc != null:
					sc.new().call("on_load")
	var files := _list_level_json(_out_dir)
	if files.is_empty():
		print("未找到关卡 JSON：%s" % _out_dir)
		CliShutdown.request_exit(1)
		return
	var ok := 0
	var failed: Array[String] = []
	# 四档全计（2026-09-16 修复）：旧实现只有 easy/normal/hard——v3.0 新增 intro 档后
	# intro 盘**一关都不计数**（o9 250 关全 intro → 输出 easy=0 normal=0 hard=0）。
	var tiers := {"intro": 0, "easy": 0, "normal": 0, "hard": 0}
	var profiled := 0  # 有 difficulty_profile 的关卡数（手工关可能没有，不计入分布告警）
	var clue_rows: Array = []  # 冗余线索分层诊断数据 {side, tier, cr, file}（末尾 _report_clue_ratio）
	var fallback_count := 0  # 候选雷数回退关数（合法但非标准雷数，单独计数）
	for path in files:
		var level := _load_json(path)
		if level.is_empty():
			failed.append("%s (JSON 无法解析)" % path)
			continue
		# 门禁 ①：Board 引擎真实构造加载（旧实现注释声称「Board 可加载」但从未调用——
		# probe40 探测发现该承诺落空；LevelLoader 依赖 ModAPI autoload 在 -s 环境不可用，
		# Board 直接构造是同引擎路径的可用等价检查：grid 重建 + 雷数一致性）。
		var board := Board.new()
		board.load_level(level)
		if board.grid == null or board.total_mines != int(level.get("total_mines", -1)):
			failed.append("%s (Board 构造加载失败)" % path)
			continue
		# 门禁 ②：R07 雷数契约（仅 5..9 矩形盘；QD 偷调平 bug 即此审计抓出）。
		# v3.0 扩展：候选雷数回退——守恒算子的整除/奇偶要求与标准值互斥时，
		# 落盘雷数可以是候选列表内的回退值（GDD §8.1）；不在候选列表 = FAIL。
		var sz: Dictionary = level.get("size", {})
		var side := int(sz.get("cols", 0))
		if int(sz.get("rows", 0)) == side and R07_MINES.has(side):
			var mv := int(level.get("total_mines", -1))
			var cands: Array = RuleFeasibility.CANDIDATES.get(side, [])
			if not cands.has(mv):
				failed.append("%s (R07 雷数不在候选列表: %d ∉ %s)" % [path, mv, str(cands)])
				continue
			if mv != int(R07_MINES[side]):
				fallback_count += 1
		# 门禁 ③+④：schema 基础校验 + 线索值 round-trip（Board 重算 vs 规则独立重算）。
		var bad := _check_schema_roundtrip(board, level)
		if bad != "":
			failed.append("%s (%s)" % [path, bad])
			continue
		# 门禁 ⑤：序贯可解（ProofLog.build 从玩家视角逐轮推必然结论直到全定）。
		var log: Dictionary = ProofLog.build(level)
		if bool(log.get("solved", false)):
			ok += 1
			var prof: Dictionary = level.get("difficulty_profile", {})
			var d := float(prof.get("difficulty", -1.0))
			var t := ""
			if d >= 0.0:
				profiled += 1
				t = Difficulty.tier_of(d)
				if tiers.has(t):
					tiers[t] += 1
			# 冗余线索诊断（症状提示，不判死）：clue_ratio 高 = 删线索不充分 → 假 easy 倾向。
			# 2026-09-16：改「相对口径」——先收集，末尾按（尺寸 × 档）分组对比（_report_clue_ratio）。
			var cr := float(prof.get("clue_ratio", 0.0))
			if cr > 0.0 and t != "":
				clue_rows.append({"side": side, "tier": t, "cr": cr, "file": path.get_file()})
		else:
			failed.append("%s (%s)" % [path, str(log.get("reason", "推不到底"))])
	print("=== 题库验证完成 ===")
	print("  目录: %s" % _out_dir)
	print("  可解 %d / 失败 %d" % [ok, failed.size()])
	print("  难度分布: intro=%d easy=%d normal=%d hard=%d（有画像 %d 关）" % [
		tiers["intro"], tiers["easy"], tiers["normal"], tiers["hard"], profiled])
	if fallback_count > 0:
		print("  候选雷数回退关: %d（守恒算子整除/奇偶要求，合法）" % fallback_count)
	_report_clue_ratio(clue_rows)
	if profiled >= 3 and tiers["normal"] == 0 and tiers["hard"] == 0:
		# 症状提示（不判失败）。两种成因，处置相反，须按 ①/② 区分（2026-09-16 补）：
		#   ① 删线索超时不足 → 静默产出「全 easy」的偷工题库（需加大 timeout_seconds，见 batch_generate）；
		#   ② 该算子可达难度天花板本就 < normal 门槛（如 o9/o5x 等信息型算子）→ 分层口径的正常现象，
		#      **不要**加 timeout（白烧算力，产线 tiered 停滞阈值会正确退出）。
		# 判据：盯上面的「线索冗余分层」——同（尺寸×档）组内无离群、中位接近 1.0 → 判 ②（线索已删无可删）。
		print("  警告: normal/hard 档为空——需区分：①删线索超时不足（见 batch_generate 超时说明，加 timeout）"
			+ "｜②算子难度天花板 < normal 门槛（信息型算子正常现象，勿加 timeout）——判据见上方「线索冗余分层」")
	for x in failed:
		print("  FAIL: " + x)
	if failed.is_empty():
		print("=== BATCH-VERIFY-OK ===")
		CliShutdown.request_exit(0)
	else:
		print("=== BATCH-VERIFY-FAILED ===")
		CliShutdown.request_exit(1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)


## 线索冗余分层诊断（相对口径，2026-09-16）：先按档给出 clue_ratio 中位数（信息展示），
## 再按（尺寸 × 档）分组做离群检测——组内盘数 ≥ CLUE_RATIO_MIN_SAMPLE 时，
## clue_ratio > 组中位 + CLUE_RATIO_OUTLIER_DELTA 的盘列为「疑似删线索不充分」。
##
## 为什么不用绝对阈值：clue_ratio 由「档位目标」决定（tiered 产线删到 target 即停），
## intro/easy 盘天然保留大部分线索——旧口径把它们全判告警（o9 100%、o10 91%），
## 真信号被淹没。相对口径下正常批次应接近 0 离群，只有「同档同尺寸内显著偏高的盘」才报。
## 症状提示，不判失败（不影响 exit code）。
func _report_clue_ratio(rows: Array) -> void:
	if rows.is_empty():
		return
	var by_tier := {}
	var groups := {}
	for r in rows:
		var t := str(r["tier"])
		if not by_tier.has(t):
			by_tier[t] = []
		by_tier[t].append(float(r["cr"]))
		var k := "%dx%d|%s" % [int(r["side"]), int(r["side"]), t]
		if not groups.has(k):
			groups[k] = []
		groups[k].append(r)
	var parts: Array[String] = []
	for t in ["intro", "easy", "normal", "hard"]:
		if by_tier.has(t):
			var arr: Array = by_tier[t]
			arr.sort()
			parts.append("%s med=%.2f(n=%d)" % [t, float(arr[arr.size() / 2]), arr.size()])
	print("  线索冗余分层(clue_ratio 中位): %s" % (" | ".join(parts) if not parts.is_empty() else "无"))
	var outliers: Array[String] = []
	var checked := 0
	for k in groups:
		var g: Array = groups[k]
		if g.size() < CLUE_RATIO_MIN_SAMPLE:
			continue
		checked += g.size()
		var crs: Array = []
		for r in g:
			crs.append(float(r["cr"]))
		crs.sort()
		var med := float(crs[crs.size() / 2])
		for r in g:
			if float(r["cr"]) > med + CLUE_RATIO_OUTLIER_DELTA:
				outliers.append("%s clue_ratio=%.2f (组中位 %.2f, %s)" % [
					str(r["file"]), float(r["cr"]), med, k])
	if checked == 0:
		print("  线索冗余离群: 样本不足（各（尺寸×档）组 < %d 盘），仅展示分层中位不告警" % CLUE_RATIO_MIN_SAMPLE)
		return
	outliers.sort()
	if outliers.is_empty():
		print("  线索冗余离群: 0 关（%d 关参与分组对比，无盘高于同（尺寸×档）组中位 +%.2f）" % [
			checked, CLUE_RATIO_OUTLIER_DELTA])
	else:
		print("  线索冗余离群: %d 关 / %d 关参与对比——高于同（尺寸×档）组中位 +%.2f，疑似删线索不充分（相对口径，不判死）前几例: %s" % [
			outliers.size(), checked, CLUE_RATIO_OUTLIER_DELTA, ", ".join(outliers.slice(0, 3))])


func _list_level_json(dir_path: String) -> Array[String]:
	# 递归扫描：batch_all_variants 的产出为 <out_dir>/<组合>/<尺寸>/x.json 两层结构，
	# 旧实现只扫顶层——对层级题库完全失效（probe 实测只抓到 all_report.json 还把它误当关卡）。
	var out: Array[String] = []
	var skip := ["report.json", "merged_report.json", "all_report.json"]
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			out.append_array(_list_level_json(dir_path.path_join(n)))
		elif n.ends_with(".json") and not skip.has(n) and not n.begins_with("all_report"):
			out.append(dir_path.path_join(n))
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return data if data is Dictionary else {}


## 门禁 ③+④：schema 基础校验 + 线索值 round-trip。返回错误串（空 = 通过）。
## round-trip 语义：Board._compute_clues 与规则独立重算必须一致——覆盖「序列化 → 加载 →
## 规则解析 → mine_set 重建 → 值计算」整条加载链路（与 board 集成测试同口径，但面向落盘文件）。
func _check_schema_roundtrip(board: Board, level: Dictionary) -> String:
	var sz: Dictionary = level.get("size", {})
	var rows := int(sz.get("rows", 0))
	var cols := int(sz.get("cols", 0))
	if rows <= 0 or cols <= 0:
		return "size 缺失或非法"
	var mines: Array = level.get("mines", [])
	if int(level.get("total_mines", -1)) != mines.size():
		return "total_mines(%s) 与 mines 数组长度(%d) 不一致" % [str(level.get("total_mines")), mines.size()]
	var mine_seen := {}
	for m in mines:
		if not (m is Dictionary and m.has("c") and m.has("r")):
			return "mines 条目缺 c/r 字段"
		var p := Vector2i(int(m["c"]), int(m["r"]))
		if p.x < 0 or p.x >= cols or p.y < 0 or p.y >= rows:
			return "雷坐标越界 %s" % str(p)
		if mine_seen.has(p):
			return "雷坐标重复 %s" % str(p)
		mine_seen[p] = true
	var rule_id := str(level.get("clue_rule", "classic"))
	var rule: Object = RuleRegistry.default().resolve(StringName(rule_id))
	if rule == null:
		return "线索规则未注册 %s（加载环境缺规则会静默回退 classic，语义错乱）" % rule_id
	var size := Vector2i(cols, rows)
	for rv in level.get("revealed", []):
		if not (rv is Dictionary and rv.has("c") and rv.has("r")):
			return "revealed 条目缺 c/r 字段"
		var p := Vector2i(int(rv["c"]), int(rv["r"]))
		if p.x < 0 or p.x >= cols or p.y < 0 or p.y >= rows:
			return "revealed 坐标越界 %s" % str(p)
		if mine_seen.has(p):
			return "revealed 格是雷 %s" % str(p)
		var cell: Cell = board.grid.get_cell(p)
		if cell == null:
			return "grid 无该格 %s" % str(p)
		var got: Variant = cell.value
		if rv.has("interval"):
			var iv: Array = rv["interval"]
			# 仅单值（int）格可判区间；多值规则（分量对）不支持遮蔽语义，跳过该检查。
			if got is int and int(got) >= 0:
				if int(got) < int(iv[0]) or int(got) > int(iv[1]):
					return "masked 格值越区间 %s got=%d iv=%s" % [str(p), int(got), str(iv)]
		else:
			var want: Variant = rule.compute_clue(mine_seen, p, size)
			if not _value_equal(got, want):
				return "线索值不一致 %s board=%s rule=%s" % [str(p), str(got), str(want)]
	return ""


## 线索值比较（多值规则安全）：int / 分量对（Array、Vector2i）/ 字符串 都支持。
## 不能用 int() 强转——hv（水平/垂直分量）等规则的值是分量对，int(Array) 会抛
##「Nonexistent 'int' constructor」（首轮全量验收实跑暴露：测坏关时只用了 classic 关）。
static func _value_equal(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	if a is Array or b is Array:
		var aa := a as Array
		var bb := b as Array
		if aa.size() != bb.size():
			return false
		for i in aa.size():
			if int(aa[i]) != int(bb[i]):
				return false
		return true
	if a is Vector2i or b is Vector2i:
		return str(a) == str(b)
	if a is String or b is String:
		return str(a) == str(b)
	return int(a) == int(b)
