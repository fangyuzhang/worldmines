# seed_recipe.gd —— 种子配方（方案 B：种子 = 拓扑 + 规则 + 参数的确定性配方）
# 纯数据结构（零行为），可 JSON 序列化，是「同种子 → 同棋盘」的确定性契约。
class_name SeedRecipe
extends RefCounted

var seed: int = 0                     # 用户输入的种子
var topology_kind: String = "rect"    # "rect" | "adjacency"（异形/六边形/自定义）
var topology_params: Dictionary = {}  # rect: {"rows":R,"cols":C}；adjacency: 邻接表
var clue_rule_id: String = "classic"  # 线索规则 id
var global_rule_ids: Array = []       # 全局规则 id 列表
var mine_count: int = 0
var mask_count: int = 0               # 遮蔽（问号）格数
var fingerprint: String = ""          # 规则实现版本指纹（RuleFingerprint.bake）


func to_dict() -> Dictionary:
	return {
		"seed": seed,
		"topology_kind": topology_kind,
		"topology_params": topology_params,
		"clue_rule_id": clue_rule_id,
		"global_rule_ids": global_rule_ids.duplicate(),
		"mine_count": mine_count,
		"mask_count": mask_count,
		"fingerprint": fingerprint,
	}


static func from_dict(d: Dictionary) -> SeedRecipe:
	var r := SeedRecipe.new()
	r.seed = int(d.get("seed", 0))
	r.topology_kind = str(d.get("topology_kind", "rect"))
	r.topology_params = d.get("topology_params", {})
	r.clue_rule_id = str(d.get("clue_rule_id", "classic"))
	r.global_rule_ids = d.get("global_rule_ids", [])
	r.mine_count = int(d.get("mine_count", 0))
	r.mask_count = int(d.get("mask_count", 0))
	r.fingerprint = str(d.get("fingerprint", ""))
	return r
