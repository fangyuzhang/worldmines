extends GutTest

## 关卡可推导性门禁（v2.9.3，ProofLog 落盘后新增）
##
## 把「关卡质量」变成可回归的断言：levels/ 下每一关都应能被**玩家视角**的推理链推到底。
## 任何新关卡若不满足序贯可解、或提示能力发生回退，都会在这里失败。
##
## 已知开放项（不是「通过」，是**记录在案**的例外）：
##   classic_07 / generated_07 —— 卡住那一步 CP-SAT 报 `模型数 = 1`（唯一解），
##   却没有任何 forced 格。即 `count_solutions` 与 `find_forced_cells` 口径不一致，
##   属提示侧待查项（证据可用 tools/diag_stuck_levels.gd 复现），不是关卡数据问题。
##
## 这两条测试成对使用：第一条防「新关卡坏掉」，第二条防「例外名单腐烂」。

const KNOWN_STUCK := ["classic_07", "generated_07"]


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	return parsed if parsed is Dictionary else {}


func _level_names() -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open("res://levels")
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if not d.current_is_dir() and n.ends_with(".json"):
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


## 主门禁：除已知例外外，所有关卡都必须能推出完整证明链。
func test_all_levels_are_fully_deducible() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var names := _level_names()
	assert_gt(names.size(), 0, "levels/ 下应有关卡文件")

	var newly_stuck: Array[String] = []
	var checked := 0
	for name in names:
		var key := name.substr(0, name.length() - 5)
		if KNOWN_STUCK.has(key):
			continue
		var level := _read_json("res://levels/" + name)
		if level.is_empty():
			continue
		checked += 1
		var log: Dictionary = ProofLog.build(level)
		if not bool(log.get("solved", false)):
			newly_stuck.append(key)
	assert_gt(checked, 0, "应至少检查到一关")
	assert_eq(newly_stuck.size(), 0,
		"以下关卡推不到底（新出现的，属回归）：%s" % str(newly_stuck))


## 反向守卫：例外名单一旦失效（那两关被修好）就失败，逼着把例外删掉。
func test_known_stuck_list_has_not_rotted() -> void:
	if not RuleCpSat.available():
		pending("C# 后端不可用（跳过）")
		return
	var still_stuck := 0
	var seen := 0
	for key in KNOWN_STUCK:
		var level := _read_json("res://levels/%s.json" % key)
		if level.is_empty():
			continue
		seen += 1
		if not bool(ProofLog.build(level).get("solved", false)):
			still_stuck += 1
	assert_eq(seen, KNOWN_STUCK.size(), "例外名单里的关卡文件都应存在：%s" % str(KNOWN_STUCK))
	assert_eq(still_stuck, KNOWN_STUCK.size(),
		"例外名单已过期——这些关卡现在能推完了，请从 KNOWN_STUCK 移除：%s" % str(KNOWN_STUCK))
