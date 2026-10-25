class_name ConflictChecker
extends RefCounted
## 组合兼容性评分与冲突检测（GDD §4.2）。
##
## 公式：组合评分 = (min(各变体兼容分) + avg(各变体兼容分)) / 2 - 冲突惩罚
## 等级：>=7 绿 / 5~7 黄 / 3~5 红 / <3 强冲突

static func score(ids: Array) -> Dictionary:
	var variants: Array = []
	for id_str in ids:
		var v = VariantRegistry.get_variant(id_str)
		if v:
			variants.append(v)

	if variants.is_empty():
		return { "score": 10.0, "level": "green", "warnings": [], "desc": "经典扫雷" }

	var min_score := 100.0
	var sum := 0.0
	for v in variants:
		min_score = min(min_score, v.compat_score)
		sum += v.compat_score
	var avg := sum / variants.size()
	var base := (min_score + avg) / 2.0

	# 冲突惩罚：遍历每个变体声明的 conflict_table
	var penalty := 0.0
	var warnings: Array[String] = []
	var id_set: Dictionary = {}
	for id_str in ids:
		id_set[id_str] = true
	for v in variants:
		var table: Dictionary = v.conflict_table()
		for other_id in table.keys():
			if id_set.has(other_id):
				penalty += float(table[other_id])
				warnings.append("%s 与 %s 存在规则冲突" % [v.id, other_id])

	var score_val := maxf(0.0, base - penalty)
	var level := "green"
	var desc := "兼容性良好，每局基本都有解"
	if score_val < 3.0:
		level = "conflict"
		desc = "该组合存在规则冲突，可能无法生成有效棋盘"
	elif score_val < 5.0:
		level = "red"
		desc = "该组合极易出现无解局"
	elif score_val < 7.0:
		level = "yellow"
		desc = "该组合可能偶尔出现无解局"
	return {
		"score": score_val,
		"level": level,
		"desc": desc,
		"warnings": warnings,
	}
