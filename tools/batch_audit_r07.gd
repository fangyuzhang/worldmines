extends SceneTree

## batch_audit_r07.gd —— 批量题库 R07 契约审计（verify_batch 不覆盖的能力）。
##
## verify_batch 的 Board 检查是「JSON 自洽」（声称 N 雷就加载 N 雷），核对不了
## 「6×6 必须 14 雷」这类固定雷数红线——当年 QD 偷调平 bug 产出的 12 雷关正是
## 「自洽但违反 R07」。本工具独立核对：
##   ① JSON 可解析（强杀半截文件检测）；
##   ② R07 雷数契约（尺寸 → 固定雷数逐关核对，10/14/20/26/32）；
##   ③ name 字段格式（tier_NN，tier ∈ easy/normal/hard）；
##   ④ 按单元（组合×尺寸）统计满额情况与难度分布。
##
## 用法：godot --headless --path . -s res://tools/batch_audit_r07.gd -- <dir>
##   dir 默认 user://batch_all。任一解析/雷数/name 失败 → exit 1（可接 CI）。
const CliShutdown := preload("res://tools/cli_shutdown.gd")

const EXPECT_MINES := {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}

var _dir := "user://batch_all"


func _list_json(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if dir.current_is_dir():
			out.append_array(_list_json(dir_path.path_join(n)))
		elif n.ends_with(".json") and not n.begins_with("all_report"):
			out.append(dir_path.path_join(n))
		n = dir.get_next()
	dir.list_dir_end()
	out.sort()
	return out


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() >= 1 and str(args[0]) != "":
		_dir = str(args[0])
	var files := _list_json(_dir)
	var parse_fail: Array[String] = []
	var mine_fail: Array[String] = []
	var name_fail: Array[String] = []
	var per_unit := {}
	var tiers := {"easy": 0, "normal": 0, "hard": 0}
	for path in files:
		var f := FileAccess.open(path, FileAccess.READ)
		var data: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
		if f != null:
			f.close()
		if not (data is Dictionary):
			parse_fail.append(path)
			continue
		var level: Dictionary = data
		var cols := int(level.get("size", {}).get("cols", 0))
		var rows := int(level.get("size", {}).get("rows", 0))
		var tm := int(level.get("total_mines", -1))
		if cols != rows or not EXPECT_MINES.has(cols) or tm != EXPECT_MINES[cols]:
			mine_fail.append("%s (size=%dx%d total_mines=%d)" % [path, cols, rows, tm])
		var nm := str(level.get("name", ""))
		var parts := nm.split("_", false)
		if parts.size() != 2 or not ["easy", "normal", "hard"].has(parts[0]) or not parts[1].is_valid_int():
			name_fail.append("%s (name='%s')" % [path, nm])
		else:
			tiers[parts[0]] += 1
		var combo := path.get_base_dir().get_base_dir().get_file()
		var unit := "%s/%dx%d" % [combo, cols, rows]
		per_unit[unit] = int(per_unit.get(unit, 0)) + 1
	print("=== R07 契约审计: %s ===" % _dir)
	print("总文件: %d | 解析失败 %d | 雷数违约 %d | name 异常 %d" % [
		files.size(), parse_fail.size(), mine_fail.size(), name_fail.size()])
	for x in parse_fail.slice(0, 5):
		print("  PARSE-FAIL: " + x)
	for x in mine_fail.slice(0, 8):
		print("  MINE-FAIL: " + x)
	for x in name_fail.slice(0, 5):
		print("  NAME-FAIL: " + x)
	var full := 0
	var partial: Array[String] = []
	for unit in per_unit:
		if int(per_unit[unit]) >= 10:
			full += 1
		else:
			partial.append("%s(%d)" % [unit, per_unit[unit]])
	print("开工单元: %d | 满额(>=10关) %d | 未满 %d" % [per_unit.size(), full, partial.size()])
	if partial.size() > 0:
		print("未满清单: " + ", ".join(partial))
	print("难度分布: easy=%d normal=%d hard=%d" % [tiers["easy"], tiers["normal"], tiers["hard"]])
	var clean := parse_fail.is_empty() and mine_fail.is_empty() and name_fail.is_empty()
	print("=== R07-AUDIT-%s ===" % ("OK" if clean else "FAILED"))
	CliShutdown.request_exit(0 if clean else 1)


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
