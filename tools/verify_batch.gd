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
## 线索冗余告警阈值：clue_ratio（线索数/非雷格数）超过它 = 删线索不充分（假 easy 倾向）。
const CLUE_RATIO_WARN := 0.5

var _out_dir := "user://batch_levels"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and str(args[0]) != "":
		_out_dir = str(args[0])
	var files := _list_level_json(_out_dir)
	if files.is_empty():
		print("未找到关卡 JSON：%s" % _out_dir)
		CliShutdown.request_exit(1)
		return
	var ok := 0
	var failed: Array[String] = []
	var tiers := {"easy": 0, "normal": 0, "hard": 0}
	var profiled := 0  # 有 difficulty_profile 的关卡数（手工关可能没有，不计入分布告警）
	var ratio_warn: Array[String] = []
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
		# 门禁 ②：R07 固定雷数契约（仅 5..9 矩形盘；QD 偷调平 bug 即此审计抓出）。
		var sz: Dictionary = level.get("size", {})
		var side := int(sz.get("cols", 0))
		if int(sz.get("rows", 0)) == side and R07_MINES.has(side) \
				and int(level.get("total_mines", -1)) != int(R07_MINES[side]):
			failed.append("%s (R07 雷数不符: %s != %d)" % [path, str(level.get("total_mines")), int(R07_MINES[side])])
			continue
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
			if d >= 0.0:
				profiled += 1
				var t := Difficulty.tier_of(d)
				if tiers.has(t):
					tiers[t] += 1
			# 冗余线索告警（症状提示，不判死）：clue_ratio 高 = 删线索不充分 → 假 easy 倾向。
			var cr := float(prof.get("clue_ratio", 0.0))
			if cr > CLUE_RATIO_WARN:
				ratio_warn.append("%s clue_ratio=%.2f" % [path.get_file(), cr])
		else:
			failed.append("%s (%s)" % [path, str(log.get("reason", "推不到底"))])
	print("=== 题库验证完成 ===")
	print("  目录: %s" % _out_dir)
	print("  可解 %d / 失败 %d" % [ok, failed.size()])
	print("  难度分布: easy=%d normal=%d hard=%d（有画像 %d 关）" % [tiers["easy"], tiers["normal"], tiers["hard"], profiled])
	if ratio_warn.size() > 0:
		print("  冗余线索告警(clue_ratio>%.2f): %d 关——删线索不充分会虚低难度，前几例: %s" % [
			CLUE_RATIO_WARN, ratio_warn.size(), ", ".join(ratio_warn.slice(0, 5))])
	if profiled >= 3 and tiers["normal"] == 0 and tiers["hard"] == 0:
		# 症状提示（不判失败）：删线索超时不足会静默产出「全 easy」的偷工题库，
		# 根因见 batch_generate.gd 的超时说明。需要 normal/hard 请加大 timeout_seconds。
		print("  警告: normal/hard 档为空——可能是删线索超时不足（见 batch_generate 超时说明）")
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
