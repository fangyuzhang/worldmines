# variant_catalog.gd —— 变体目录（选关页 / 规则图鉴 的唯一事实源）
#
# 背景（本模块存在的原因）：
#   原先 ui/level_select.gd 有一张写死的 MODES 表（15 个条目，含手写混合组合），
#   ui/codex.gd 也各有一张写死的规则文字表。引擎侧换变体（新增 knight、新增 O/S/Z 系列
#   Mod 算子）后，这两张表完全不知情 —— 于是「引擎换了、UI 没动」。
#
#   这与 HANDOFF 里已被治掉的那类问题同源：手写表必然漏。可行性那张手写 UNSAT 表当年
#   就漏过 rl 6×6 / qd 6×6、8×8，最后用 RuleFeasibility 换成真值查询。
#   本模块做同样的事：把「有哪些变体」从**规则注册表的实时内容**推导出来。
#
# 设计取舍：
#   · 成员（membership）一律实时派生 —— 新增/卸载规则，UI 自动跟上；
#   · 顺序（order）用 preferred 表作为**观感提示**，只影响展示先后，不影响成员；
#     未知 id（新算子 / Mod）自动追加在末尾，无需改本文件。
class_name VariantCatalog
extends RefCounted

## 线索型规则的展示顺序（仅排序用；不在表里的新规则自动追加）。
const CLUE_ORDER: Array = ["classic", "4n", "clock", "hv", "fr", "loopruns", "distsum", "sc", "knight"]
## 全局约束的展示顺序。
const GLOBAL_ORDER: Array = ["mx", "rl", "pf", "qd", "dt", "ep", "4c"]
## 不作为独立变体呈现的规则（元规则：它只是「总雷数」约束，不是玩法变体）。
const HIDDEN_RULES: Array = ["total_mines"]


## 当前注册表里全部线索型规则 id（按展示顺序）。
static func clue_ids() -> Array[String]:
	return _ids_of_kind(RulePlugin.KIND_CLUE, CLUE_ORDER)


## 当前注册表里全部全局约束规则 id（按展示顺序）。
static func global_ids() -> Array[String]:
	return _ids_of_kind(RulePlugin.KIND_GLOBAL, GLOBAL_ORDER)


static func _ids_of_kind(kind: String, preferred: Array) -> Array[String]:
	var reg := RuleRegistry.default()
	var known: Array[String] = []
	var extra: Array[String] = []
	for id in reg.all_ids():
		if HIDDEN_RULES.has(id):
			continue
		var r := reg.resolve(StringName(id))
		if r == null or not r.has_method("get_kind"):
			continue
		if str(r.call("get_kind")) != kind:
			continue
		if preferred.has(id):
			known.append(id)
		else:
			extra.append(id)
	extra.sort()
	var out: Array[String] = []
	for p in preferred:
		if known.has(p):
			out.append(p)
	out.append_array(extra)
	return out


static func rule_of(rule_id: String) -> Object:
	return RuleRegistry.default().resolve(StringName(rule_id))


## 是否为 Mod 来源的规则（非内置）。选关页据此打「·Mod」标，图鉴据此区分来源。
## 注意：**加载/卸载 Mod 会实时改变这个结果** —— 卸载 Mod 时其注册的规则会被注销
## （mod_api.unload_mod），目录随之自动更新，无需任何手动同步。
static func is_mod_rule(rule_id: String) -> bool:
	if RuleRegistry.default().builtin_ids().has(rule_id):
		return false
	return not _is_bundled_rule(rule_id)


## 随包内置算子（官方 22 席 O/S/Z）的规则 id 白名单。
## 与 ModAPI.is_bundled_rule 同源；这里留一份是为了**无头环境**（-s 工具/测试，
## 无 SceneTree、autoload 不可用）下也能正确判定——autoload 可用时以它为准（真源）。
const OFFICIAL_RULE_IDS: Array = [
	"o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10",
	"s1", "s2", "s3", "s4", "s5", "s6", "s7",
	"z1", "z2", "z3", "z4", "z5",
]


## 该规则是否来自随包内置 Mod（官方算子）。官方算子**不算玩家 Mod**：
## 它们应与内置 8 线索 / 7 约束同页展示（否则玩家得去模组页里找官方变体）。
static func _is_bundled_rule(rule_id: String) -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null and tree.root.has_node("ModAPI"):
		var api: Node = tree.root.get_node("ModAPI")
		if api.has_method("is_bundled_rule"):
			return bool(api.call("is_bundled_rule", rule_id))
	return OFFICIAL_RULE_IDS.has(rule_id)


## 混合档的行轴：参与配对的**内置**线索型（不含经典——中心基线与自身组合没有信息量）。
## 交叉表的行序 = 此顺序，故它同时决定表长什么样。
static func mixed_clue_ids() -> Array[String]:
	var all := _builtin_ids_of_kind(RulePlugin.KIND_CLUE)
	var out: Array[String] = []
	for c in all:
		if c != "classic":
			out.append(c)
	return out


## 混合档的列轴：参与配对的**内置**全局约束（交叉表的列序）。
static func mixed_global_ids() -> Array[String]:
	return _builtin_ids_of_kind(RulePlugin.KIND_GLOBAL)


## 混合组合只在**内置**规则间配对。
## 原因：Mod 算子的构造式布雷 / 可行性尚未经过量产验证（`place_mines` 基类默认返回空），
## 让它们进混合档会成倍产生「点了生成不出来」的死节点。等单个 Mod 变体在独立档验证过
## 生成质量后，再考虑放开。
static func _builtin_ids_of_kind(kind: String) -> Array[String]:
	var reg := RuleRegistry.default()
	var matched: Array[String] = []
	for id in reg.builtin_ids():
		if HIDDEN_RULES.has(id):
			continue
		var r := reg.resolve(StringName(id))
		if r == null or not r.has_method("get_kind"):
			continue
		if str(r.call("get_kind")) == kind:
			matched.append(id)
	var ordered: Array[String] = []
	var pref: Array = CLUE_ORDER if kind == RulePlugin.KIND_CLUE else GLOBAL_ORDER
	for p in pref:
		if matched.has(p):
			ordered.append(p)
	return ordered


## 展示名：优先 describe()["name"]，其次旧 VariantRegistry 表，最后退回 id 本身。
static func display_name(rule_id: String) -> String:
	var r := rule_of(rule_id)
	if r != null and r.has_method("describe"):
		var d = r.call("describe")
		if d is Dictionary and str((d as Dictionary).get("name", "")) != "":
			return str((d as Dictionary)["name"])
	var legacy := VariantRegistry.definitions()
	if legacy.has(rule_id):
		return str((legacy[rule_id] as Dictionary)["name"])
	return rule_id


## 规则说明文字：describe()["rule_text"]（图鉴直接消费）。
static func rule_text(rule_id: String) -> String:
	var r := rule_of(rule_id)
	if r != null and r.has_method("describe"):
		var d = r.call("describe")
		if d is Dictionary:
			return str((d as Dictionary).get("rule_text", ""))
	return ""


## 难度标注（旧 VariantRegistry 才有；新算子 / Mod 返回 "—"）。
static func difficulty(rule_id: String) -> String:
	var legacy := VariantRegistry.definitions()
	if legacy.has(rule_id):
		return str((legacy[rule_id] as Dictionary)["diff"])
	return "—"


## 条目表（图鉴用）：[{id, name, text, difficulty, source}]
static func entries(kind: String) -> Array[Dictionary]:
	var ids := clue_ids() if kind == RulePlugin.KIND_CLUE else global_ids()
	var out: Array[Dictionary] = []
	for id in ids:
		out.append({
			"id": id,
			"name": display_name(id),
			"text": rule_text(id),
			"difficulty": difficulty(id),
			"source": "mod" if is_mod_rule(id) else "builtin",
		})
	return out


# ============ 混合组合（G + C）============

## 全部「全局约束 × 线索型」组合（v3.2 起为完整交叉：8 线索 × 7 约束 = 56 个）。
##
## 旧实现每个 G 只配一个 C（共 7 个）——那是**径向图「每条枝干只能挂一个」的排布限制**，
## 不是规则的限制：规则本身就是「约束 + 线索」的正交组合，交叉表正好对应它的代数结构。
## 改为交叉表后 56 个组合全部可达（选关页「混合档」页即此表）。
##
## 实测（RuleSignature 判据 + RuleFeasibility 真值查询，5×5 与 7×7）：
##   56 个组合**无一判 forbid**，全部数学可行 → 没有死格；
##   pf（局部禁形）列全部为 warn（同作用域叠加，可行域偏窄、生成更慢），标记但不拦。
static func mixed_all(size: Vector2i, mines: int) -> Array[Dictionary]:
	var clues := mixed_clue_ids()      # 行轴（= 交叉表的行序）
	var globals := mixed_global_ids()  # 列轴（= 交叉表的列序）
	var out: Array[Dictionary] = []
	for c in clues:
		for g in globals:
			var v := RuleSignature.compat(g, c, size, mines)
			if str(v["verdict"]) == RuleSignature.FORBID:
				continue  # 逻辑冗余 / 矛盾：直接不产生，避免「点了生成不出来」的死格
			out.append({
				"id": "%s_%s" % [g, c],
				"clue": c,
				"globals": [g],
				"parents": [g, c],
				# 组合判据（ok / warn）：交叉表格子据此标注「可行域偏窄」
				"verdict": str(v["verdict"]),
			})
	return out


# ============ 混合组合（G + G，双约束）============

## 全部「全局约束 × 全局约束」组合（C(7,2) = 21 对，判 forbid 的不产生）。
##
## 与 mixed_all 同源同构：clue 走 classic（不加线索），globals 是两个约束。
## 判据走 RuleSignature.compat：a==b 判 forbid 天然处理对角线；R4 蕴含判冗余
## （mx 逻辑蕴含 ep → mx+ep 不产生，二者同关时 ep 完全冗余、没有信息增量）。
##
## 实测（RuleFeasibility 真值查询，5~9 全尺寸）：21 对中 mx+ep 判 forbid → **20 个可玩**；
## 尺寸级不可行比 G+C 常见（mx+rl 的 6×6/8×8、rl+qd 的 5×5/6×6、qd+dt 的 5×5/8×8），
## 但 20 个在 7×7 与 9×9 全部可行——弹窗的「尺寸按钮禁用 + 自动切到最近可行尺寸」已覆盖。
static func gg_all(size: Vector2i, mines: int) -> Array[Dictionary]:
	var globals := mixed_global_ids()
	var out: Array[Dictionary] = []
	for i in globals.size():
		for j in range(i + 1, globals.size()):
			var g1: String = globals[i]
			var g2: String = globals[j]
			var v := RuleSignature.compat(g1, g2, size, mines)
			if str(v["verdict"]) == RuleSignature.FORBID:
				continue  # 逻辑冗余 / 矛盾（如 mx 蕴含 ep）：不产生，避免死格
			out.append({
				"id": "%s_%s" % [g1, g2],
				"clue": "classic",
				"globals": [g1, g2],
				"parents": [g1, g2],
				"verdict": str(v["verdict"]),
			})
	return out


# ============ 选关页节点表 ============

## 生成选关页的 MODES 表（替代原先写死的 15 条常量）。
## 结构与旧表一致（kind / id / name / tip / clue / globals / parents / enabled），
## 因此 _layout_nodes / _draw / 进度键等下游逻辑无需改动。
static func build_modes(size: Vector2i, mines: int) -> Array:
	var out: Array = []

	var clues := clue_ids()
	var globals := global_ids()

	# 中心：经典基线
	out.append({
		"id": "classic", "name": display_name("classic"), "kind": "core",
		"clue": "classic", "globals": [], "tip": "C0", "enabled": true,
		"source": "builtin",
	})

	# 内圈：C 类线索型
	for i in clues.size():
		var cid: String = clues[i]
		if cid == "classic":
			continue
		var tip := "C%d" % i
		if is_mod_rule(cid):
			tip += "·Mod"   # 让玩家一眼看出这个变体来自已加载的 Mod
		out.append({
			"id": cid, "name": display_name(cid), "kind": "clue",
			"clue": cid, "globals": [], "tip": tip, "enabled": true,
			"source": "mod" if is_mod_rule(cid) else "builtin",
		})

	# 外圈：G 类全局约束（线索走经典）
	for j in globals.size():
		var gid: String = globals[j]
		var gtip := "G%d" % (j + 1)
		if is_mod_rule(gid):
			gtip += "·Mod"
		out.append({
			"id": gid, "name": display_name(gid), "kind": "global",
			"clue": "classic", "globals": [gid], "tip": gtip, "enabled": true,
			"source": "mod" if is_mod_rule(gid) else "builtin",
		})

	# 混合档：完整交叉（8 线索 × 7 约束），顺序与交叉表一致（按线索分行、约束分列）
	var pairs := mixed_all(size, mines)
	var g_index := {}
	for j in globals.size():
		g_index[globals[j]] = j + 1
	var c_index := {}
	for i in clues.size():
		c_index[clues[i]] = i
	for p in pairs:
		var g: String = str((p as Dictionary)["globals"][0])
		var c: String = str((p as Dictionary)["clue"])
		out.append({
			"id": str((p as Dictionary)["id"]),
			"name": "%s·%s" % [display_name(g), display_name(c)],
			"kind": "mixed",
			"clue": c,
			"globals": [g],
			"parents": [g, c],
			"verdict": str((p as Dictionary).get("verdict", RuleSignature.OK)),
			"tip": "G%d+C%d" % [int(g_index.get(g, 0)), int(c_index.get(c, 0))],
			"enabled": true,
			"source": "builtin",
		})

	# 双约束档（G+G）：C(7,2) 完整配对，顺序与上三角表的行/列一致
	for p in gg_all(size, mines):
		var d: Dictionary = p
		var gids: Array = d["globals"]
		var g1: String = str(gids[0])
		var g2: String = str(gids[1])
		out.append({
			"id": str(d["id"]),
			"name": "%s·%s" % [display_name(g1), display_name(g2)],
			"kind": "mixed",
			"clue": "classic",
			"globals": gids,
			"parents": gids,
			"verdict": str(d.get("verdict", RuleSignature.OK)),
			"tip": "G%d+G%d" % [int(g_index.get(g1, 0)), int(g_index.get(g2, 0))],
			"enabled": true,
			"source": "builtin",
		})
	return out
