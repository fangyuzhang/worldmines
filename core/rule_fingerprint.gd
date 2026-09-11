# rule_fingerprint.gd —— 规则实现版本指纹（方案 B）
# 守护「规则代码变了，同种子结果可能变」：指纹变了 → 明示此种子产出的棋盘已随规则版本变化。
# 当前用「插件版本 + 规则 id 集合」做粗略指纹；精确到逐规则源码哈希需按来源（内置/mod）拆分，留作后续。
class_name RuleFingerprint
extends RefCounted


## 计算一组规则的版本指纹（规则 id 集合 + 插件版本 → 16 字符 hex）。
static func bake(rule_ids: Array, plugin_version: String) -> String:
	var ids: Array = rule_ids.duplicate()
	ids.sort()
	var s := str(plugin_version) + ":" + ",".join(ids)
	return s.sha256_text().substr(0, 16)
