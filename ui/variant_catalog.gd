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

## 观测轴展示顺序（GDD §4.1~4.2）：O0 经典（底座）+ 官方观测十席。
const CLUE_ORDER: Array = ["classic", "o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10"]
## 结构与守恒轴展示顺序（GDD §4.4 / §4.5）：S1~S7 + Z1~Z5。
## 末尾的 `dt`（骨牌）是**唯一保留的旧单算子**：只单独成关，不进任何组合轴（见下方三轴常量）。
const GLOBAL_ORDER: Array = ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "z1", "z2", "z3", "z4", "z5", "dt"]

## ==== 三轴切分（GDD §4.1）====
## 代码里的 KIND_GLOBAL 是个筐，同时装 S 轴与 Z 轴（`pf` 是 S1、`mx` 是 Z1）。但 GDD §5.1
## 的硬限制是「观测恰 1 + 结构 ≤2 + 守恒 ≤1」——所以组合必须**按轴**配对，不能按 KIND 一锅端：
## 两个 Z 同关即「守恒 2 个」，直接违规（早先按 KIND 做的「约束×约束」表就踩了这个）。
const OBS_IDS: Array = VariantAxes.OBS
const STRUCT_IDS: Array = VariantAxes.STRUCT
const CONSERVE_IDS: Array = VariantAxes.CONSERVE

## 不作为独立变体呈现的规则：
##   · `total_mines`：元规则（只是「总雷数」约束，不是玩法变体）；
##   · 6 个与官方席位**等价**的旧内置实现（`clock`=O8 钟点 / `loopruns`=O10 环游 /
##     `pf`=S1 局部禁形 / `mx`=Z1 镜像 / `rl`=Z2 相邻行锁 / `qd`=Z3 四象）——
##     选关页只显示官方 id（与 GDD 编号一致），避免同一规则出现两次。
##     实现本身保留（RuleFeasibility / RuleCpSat 等仍按这些 id 工作）。
const HIDDEN_RULES: Array = ["total_mines", "clock", "loopruns", "pf", "mx", "rl", "qd"]


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


## 混合档的**观测轴**（交叉表的行）：官方观测十席（GDD §4.2）。
## 不含 O0 经典——基线与自身组合没有信息量。
## 轴用**静态常量**而非注册表派生：口径由 GDD 决定，注册表只决定「此刻能不能玩」
## （官方 Mod 未加载只影响 is_available，不影响表结构）。
static func mixed_clue_ids() -> Array[String]:
	var out: Array[String] = []
	out.assign(OBS_IDS)
	return out


## 混合档的**结构轴**（交叉表的列）：官方结构七席（GDD §4.4）。
## 注意命名：此处「global」指 KIND_GLOBAL（结构 + 守恒的统称），故列轴只取 S 轴；
## 守恒走 mixed_conserve_ids()（T4，且每关至多 1 个——GDD §5.1 硬限制 3）。
static func mixed_global_ids() -> Array[String]:
	var out: Array[String] = []
	out.assign(STRUCT_IDS)
	return out


## 混合档的**守恒轴**（T4「守恒叠加」的第三个算子）：官方守恒五席（GDD §4.5）。
static func mixed_conserve_ids() -> Array[String]:
	var out: Array[String] = []
	out.assign(CONSERVE_IDS)
	return out


## 该规则此刻是否可用（已注册）。无头环境（-s 工具 / 测试）没有 autoload，
## 官方 22 席不会自动加载 —— 组合表据此跳过不可用条目，避免留下「点了生成不出来」的死格。
static func is_available(rule_id: String) -> bool:
	return RuleRegistry.default().resolve(StringName(rule_id)) != null


## 按轴序取**可用**的 id（跳过未注册，保持轴顺序）。
static func _available_of(ids: Array) -> Array[String]:
	var out: Array[String] = []
	for id in ids:
		if is_available(str(id)):
			out.append(str(id))
	return out


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


# ============ 混合档一：结构 × 观测（GDD §10.1 T3 C 类）============

## 全部「结构 × 观测」组合（7 结构 × 10 观测 = 70 对，GDD §10.1 T3 C 类）。
##
## 硬限制（GDD §5.1）：每关观测恰 1 个、结构 ≤2、守恒 ≤1 —— 本表每组恰 1 观测 + 1 结构。
##
## 判据走 RuleSignature.compat：官方 22 席签名已入表（2026-09-18，commit `20e0021`）——
## R4 逻辑冗余 / R5 整除无解会在此被**真实排除**；其余为 J1 正交或 J2 警告
## （警告照常产出，与 GDD §5.3「J2 警告但全量生产」一致。此处注释此前写着「尚未入表」，
## 是签名补全前的旧描述，已更正）。
static func mixed_all(size: Vector2i, mines: int) -> Array[Dictionary]:
	var obs := _available_of(OBS_IDS)          # 行轴
	var structs := _available_of(STRUCT_IDS)   # 列轴
	var out: Array[Dictionary] = []
	for c in obs:
		for s in structs:
			var v := RuleSignature.compat(s, c, size, mines)
			if str(v["verdict"]) == RuleSignature.FORBID:
				continue  # 逻辑冗余 / 矛盾：不产生，避免「点了生成不出来」的死格
			out.append({
				"id": "%s_%s" % [s, c],
				"clue": c,
				"globals": [s],
				"parents": [s, c],
				# 组合判据（ok / warn）：交叉表格子据此标注「可行域偏窄」
				"verdict": str(v["verdict"]),
			})
	return out


# ============ 混合档二：结构 × 结构（GDD §10.1 T3 F 类）============

## 全部「结构 × 结构」组合（C(7,2) = 21 对，GDD §10.1 T3 F 类）。
##
## 结构算子**允许 ≤2 个**（GDD §5.1 硬限制 2），所以这张表是唯一允许多约束同关的地方；
## 守恒轴仍是每关 ≤1（单独走 T4），故此处只有 S 轴配对——**不是**早先那种「任意两约束配对」。
## 同轴配对多为 J2 警告（§5.3：无环 × 分量数K 同约束雷的图拓扑，可行域收窄但可生产）。
static func gg_all(size: Vector2i, mines: int) -> Array[Dictionary]:
	var structs := _available_of(STRUCT_IDS)
	var out: Array[Dictionary] = []
	for i in structs.size():
		for j in range(i + 1, structs.size()):
			var s1: String = structs[i]
			var s2: String = structs[j]
			var v := RuleSignature.compat(s1, s2, size, mines)
			if str(v["verdict"]) == RuleSignature.FORBID:
				continue  # 逻辑冗余 / 矛盾：不产生，避免死格
			out.append({
				"id": "%s_%s" % [s1, s2],
				"clue": "classic",
				"globals": [s1, s2],
				"parents": [s1, s2],
				"verdict": str(v["verdict"]),
			})
	return out


# ============ 混合档三：守恒叠加（GDD §10.1 T4）============

## T4「结构 × 观测 + 1 守恒」共 50 组（5 守恒 × 10 观测）。
##
## 结构按 GDD §10.1 的**循环构造**选取：第 z 个守恒的第 i 组 = 结构 ((i+z) mod 7) + 观测 i。
## 循环而非全交叉是有意的——全交叉会炸成 350 组，远超 GDD 的 50 组口径
## （§10.2：T4 = 150 关卡集 = 50 组 × 3 档）。
static func conserved_all(size: Vector2i, mines: int) -> Array[Dictionary]:
	if STRUCT_IDS.is_empty():
		return []
	var obs := _available_of(OBS_IDS)
	var structs := _available_of(STRUCT_IDS)
	var cons := _available_of(CONSERVE_IDS)
	var out: Array[Dictionary] = []
	for z in CONSERVE_IDS.size():
		var g: String = str(CONSERVE_IDS[z])
		if not cons.has(g):
			continue
		for i in OBS_IDS.size():
			var c: String = str(OBS_IDS[i])
			if not obs.has(c):
				continue
			var s: String = str(STRUCT_IDS[(i + z) % STRUCT_IDS.size()])
			if not structs.has(s):
				continue
			var ids: Array[String] = [g, s, c]
			var v := RuleSignature.compat_all(ids, size, mines)
			if str(v["verdict"]) == RuleSignature.FORBID:
				continue
			out.append({
				"id": "%s+%s+%s" % [g, s, c],
				"clue": c,
				"globals": [s, g],
				"parents": [g, s, c],
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

	# 混合档轴（编号用 S / O / Z 前缀，与 GDD 的三轴编号一致）
	var structs := mixed_global_ids()
	var obs := mixed_clue_ids()
	var cons := mixed_conserve_ids()
	var s_index := {}
	for j in structs.size():
		s_index[structs[j]] = j + 1
	var o_index := {}
	for i in obs.size():
		o_index[obs[i]] = i + 1
	var z_index := {}
	for k in cons.size():
		z_index[cons[k]] = k + 1

	# 混合档一（T3 C 类）：结构 × 观测，顺序与交叉表一致（按观测分行、结构分列）
	for p in mixed_all(size, mines):
		var d: Dictionary = p
		var s: String = str((d["globals"] as Array)[0])
		var c: String = str(d["clue"])
		out.append({
			"id": str(d["id"]),
			"name": "%s·%s" % [display_name(s), display_name(c)],
			"kind": "mixed",
			"clue": c,
			"globals": [s],
			"parents": d["parents"],
			"verdict": str(d.get("verdict", RuleSignature.OK)),
			"tip": "S%d+O%d" % [int(s_index.get(s, 0)), int(o_index.get(c, 0))],
			"enabled": true,
			"source": "builtin",
		})

	# 混合档二（T3 F 类）：结构 × 结构，每对只出现一次（上三角）
	for p in gg_all(size, mines):
		var d: Dictionary = p
		var sids: Array = d["globals"]
		var s1: String = str(sids[0])
		var s2: String = str(sids[1])
		out.append({
			"id": str(d["id"]),
			"name": "%s·%s" % [display_name(s1), display_name(s2)],
			"kind": "mixed",
			"clue": "classic",
			"globals": sids,
			"parents": d["parents"],
			"verdict": str(d.get("verdict", RuleSignature.OK)),
			"tip": "S%d+S%d" % [int(s_index.get(s1, 0)), int(s_index.get(s2, 0))],
			"enabled": true,
			"source": "builtin",
		})

	# 混合档三（T4）：结构 × 观测 + 1 守恒（循环构造，50 组）
	for p in conserved_all(size, mines):
		var d: Dictionary = p
		var z: String = str((d["parents"] as Array)[0])
		var s: String = str((d["globals"] as Array)[0])
		var c: String = str(d["clue"])
		out.append({
			"id": str(d["id"]),
			"name": "%s·%s·%s" % [display_name(c), display_name(s), display_name(z)],
			"kind": "mixed",
			"clue": c,
			"globals": d["globals"],
			"parents": d["parents"],
			"verdict": str(d.get("verdict", RuleSignature.OK)),
			"tip": "Z%d+S%d+O%d" % [int(z_index.get(z, 0)), int(s_index.get(s, 0)), int(o_index.get(c, 0))],
			"enabled": true,
			"source": "builtin",
		})

	# 形状档（异形棋盘）：拓扑层玩法，不是规则/守恒轴——成员资格由关卡库内容决定
	#（levels_lib/shape_*，由 tools/import_shape_levels_to_lib.gd 量产入库）。
	# 库为空/某形状尚未入库 ⇒ 卡片不出现（不显示点进去没有内容的空卡片）。
	# L4（2026-09-21）：成员资格读 LevelLibrary.catalog() 的**进程内静态缓存**——
	# 运行中（游戏已启动后）往 res://levels_lib 新导入形状关，需重启进程才会出现新卡片。
	# 形状关是随包发行内容（不进运行时热更新场景），故不为此引入缓存失效入口；此注为约定。
	# 2026-09-22：卡片表扩为 7 席（新几何族 iso/tri/trihex/t31212/ring 走同一机制；
	# t31212/ring 暂无 5~9 尺寸的纯 classic 关，catalog 无键 ⇒ 守卫自动隐藏卡片）。
	for spec in [
		["shape_holed", "挖洞方格", "T1·挖洞"],
		["shape_hex", "蜂窝", "T2·蜂窝"],
		["shape_iso", "等轴菱面", "T4·菱面"],
		["shape_tri", "三角网格", "T5·三角"],
		["shape_trihex", "编织", "T6·编织"],
		["shape_t31212", "十二边", "T7·十二边"],
		["shape_ring", "环盘", "T8·环盘"],
	]:
		var sid := str(spec[0])
		if LevelLibrary.catalog().has(sid):
			out.append({
				"id": sid, "name": str(spec[1]), "kind": "shape",
				"clue": "classic", "globals": [], "tip": str(spec[2]),
				"enabled": true, "source": "builtin",
			})
	return out
