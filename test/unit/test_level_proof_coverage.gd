extends GutTest

## 关卡可推导性门禁（v2.9.3，ProofLog 落盘后新增）
##
## 把「关卡质量」变成可回归的断言：levels/ 下每一关都应能被**玩家视角**的推理链推到底。
## 任何新关卡若不满足序贯可解、或提示能力发生回退，都会在这里失败。
##
## 已修复（v2.9.3）：早前 classic_07 / generated_07 卡住，根因是 C# `FindForcedCells`
## 里一个不健全的剪枝——它跳过了「未被任何线索引用的格」，但这类格仍会被
## 「其他格被线索逼定 + 总雷数」间接逼定为安全。移除剪枝后 20/20 全部可推完。
##
## 这两条测试成对使用：第一条防「新关卡坏掉」，第二条防「例外名单腐烂」
## （目前名单为空；一旦有新的暂不可推关卡，应把 key 加进 KNOWN_STUCK 并在此说明根因）。
##
## 豁免机制（2026-09-21）：**外部复刻关卡**自带 `proof_exempt: true` 时跳过本门禁。
## 与 KNOWN_STUCK 的区别：KNOWN_STUCK = 「我们自己的关卡坏了，待修复」；proof_exempt =
## 「关卡的推理体系不属本引擎，推导不出来是预期」，两者语义不同、不得混用。
## 当前豁免（3 个，均为**外部复刻关卡**）：
##   · daisy_chain —— Tametsi 2018_04_10_A（5/6 边形镶嵌），ProofLog 推 18 轮后卡住
##   · girih_01 / girih_03 —— Tametsi 2018_01_30_A/C（十边形+六边形镶嵌），同样卡住
## 其可推导性依赖 Tametsi 自身的规则集（含「非雷格连通」类全局约束，本引擎未实现）。
## 豁免不影响加载/渲染/游玩，仅不参与序贯推导门禁。
## 豁免必须显式列出并受数量上限约束（防滥用）。
##
## 两个假信号（2026-09-23 踩过，改本门禁/写独立核验脚本时先看这里）：
##   · 假红：在某脚本的 `_initialize()` 里调 ProofLog——那是**首帧之前**，autoload 还没把
##     S/Z 轴变体规则装进 RuleRegistry，带 global_rules 的关卡会被判「推不到底」。
##     独立脚本必须等首帧（`tools/diag_stuck_levels.gd` 已按此改）。
##   · 假绿：`RuleCpSat.available()` 为 false 时本门禁 `pending()` 静默跳过——后端缺失或
##     构建陈旧时套件仍全绿。诊断工具已显式打印该行，排查先看它。

const KNOWN_STUCK: Array[String] = []
## 允许的豁免关卡上限：新增豁免必须同时在此注释说明理由（当前 3 个）。
const MAX_PROOF_EXEMPT := 4
const EXPECTED_PROOF_EXEMPT: Array[String] = ["daisy_chain", "girih_01", "girih_03"]


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
	var exempt_found: Array[String] = []
	var checked := 0
	for name in names:
		var key := name.substr(0, name.length() - 5)
		if KNOWN_STUCK.has(key):
			continue
		var level := _read_json("res://levels/" + name)
		if level.is_empty():
			continue
		if bool(level.get("proof_exempt", false)):
			exempt_found.append(key)
			continue
		checked += 1
		var log: Dictionary = ProofLog.build(level)
		if not bool(log.get("solved", false)):
			newly_stuck.append(key)
	assert_gt(checked, 0, "应至少检查到一关")
	assert_eq(newly_stuck.size(), 0,
		"以下关卡推不到底（新出现的，属回归）：%s" % str(newly_stuck))
	# 豁免防滥用：数量上限 + 实际名单必须与常量一致（新增豁免须同步更新文件头理由）
	exempt_found.sort()
	assert_true(exempt_found.size() <= MAX_PROOF_EXEMPT,
		"豁免关卡过多（%d > %d）：%s" % [exempt_found.size(), MAX_PROOF_EXEMPT, str(exempt_found)])
	assert_eq(exempt_found, EXPECTED_PROOF_EXEMPT,
		"实际豁免名单与 EXPECTED_PROOF_EXEMPT 不符（新增/移除豁免须同步更新该常量与理由）")


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
