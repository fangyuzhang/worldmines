# puzzle_generator.gd —— 关卡生成器（文档 §4.4 全流程）
# 确定性布雷（仅种子 RNG）→ 逆向删线索 → 遮蔽 → 序贯纯逻辑可解验证。
# 全局约束型用专用布雷策略（镜像/骨牌/象限/端点/四色/行锁）；四象布雷统一委托规则平台 QdRule。
# 入口分流：生产一律走 generate_with_rules（规则平台底座，含异形拓扑 A2）；
# generate_constructive/mixed/dual/mixed_clue/from_def 为「内置变体枚举」遗留路径，
# 仅服务 archive/tools 与集成测试——新增能力请扩展规则平台，不要再扩展旧管线。
class_name PuzzleGenerator
extends RefCounted

const MAX_MINES_RATIO := 0.4  # 默认雷密度上限

## 生成管线版本戳（2026-09-24）：**生成/删线索逻辑一变就必须递增**（守卫见 test/unit/test_gen_rev_stamp.gd）。
## 为什么需要：历史集里混着多代产物（实测**同一 peak 组内** clue_ratio 仍离散 0.09–0.82，见
## `关卡集供给对账.md`「混版集量化」），而此前没有任何字段能区分版本 → 只能用 clue_ratio 近似，
## 无法精确执行「版本优选」。有了戳：① 优选可精确；② 可回归（新盘必带最新戳）。
## 约定：老盘（2026-09-24 之前）无此字段，读取方一律按「字段缺失 = 老管线」处理。
const GEN_REV := "v4.2-0924"

var _rng := RandomNumberGenerator.new()

## 旧管线实例（2026-09 拆分：旧实现 + 旧布雷策略移入 PuzzleGeneratorLegacy）。
var _legacy := PuzzleGeneratorLegacy.new()

## C# CP-SAT 并行搜索 worker 数（0 = 用 C# 默认 4）。
## 分片批跑时应设 1：进程数 × 1 worker = 物理核数，避免 8 进程 × 4 worker 超额订阅互相抢核。
## 强制格结论与 worker 数无关（探测「假设反值不可行」与首解无关），降 worker 不改变任何质量/难度。
var num_workers: int = 0



## C# 累计探测预算覆盖（0 = 用 RuleOracle 默认 30s）。
## 只服务两类用途：① A/B 实验（比较预算对难度的影响）；② 调用方按剩余墙钟收紧。
## ⚠ 调小会让探测被截断 → 少报强制格 → 删线索保守 → **关卡变简单**，属质量红线参数。
var probe_budget_ms: int = 0


## 删线索**尝试顺序**策略（v4.1 降废品，2026-09-27）。
##
## 为什么顺序能降废品：窗口模式下的"废品"主因不是生成失败（实测 brep_fail/verify_fail/
## prune_empty/prewon/timeout 全为 0），而是 **peak_miss**——难度峰值没落进请求档。
## 而难度由「删完线索后留下的那组线索」决定；删除是单调的（先成功删掉的越多，后面的试探
## 面对更小的集合越容易失败而被恢复），所以**尝试顺序决定了最终落在哪个局部极小集上**。
##
## 安全性（为什么这不是质量红线）：**判据一字未改**——删除仍要求「删后仍序贯纯逻辑可解」
##（`_solve_rules_stepwise`，R01 真义），故任何策略产出的关卡都等价合格；变的只是"挑中
## 哪一个极小集"。策略比较必须用窗口命中率 + 难度画像做 A/B（见 tools/_ab_probe.gd）。
##   0 行优先（现状基线，确定性）
##   1 弱信息优先：值小的线索（局部约束最松）先试删 → 留下多为强线索，峰值预期抬升
##   2 强信息优先：值大的先试删（对照组，峰值预期下降）
##   3 冗余优先：邻域线索格多的（局部信息重复）先试删 → 留下稀疏线索，峰值预期抬升
## 同分一律回落到行优先，保证确定性（同 seed 可复现）。
var prune_order: int = 0


## A1-ii 短路开关（2026-09-27）：若**全量**线索集 A 的序贯演绎在某轮
## 「真·无强制格」而失败，则由单调性定理（B⊆A ⇒ forced_B(r) ⊆ D_A(r)）任何子集 B⊆A
## 同轮必失败 ⇒ `_prune_sequential` 的每条删除试探都必失败 ⇒ prune 必为 no-op。
## 此时立即返回（`active` 一字不动），省掉 O(n) 次完整演绎；产出与逐条试探**逐字节相同**。
##
## 【09-27 复核结论：默认置 **false**（不部署）】——**保留实现与可观测计数，但在生产里走旧路径**。
## 依据（全部为实测，见 docs/GEN_PERF_PLAN_0927.md §14）：
##   ① **命中率为 0**：等价性对拍在真实语料上连续 4 组 `skip=0`（短路从未触发）。
##      原因：生成路径的候选其「全量线索集」几乎总是可推完的，故②的触发条件罕见。
##   ② **不命中时有净成本**：预跑多消耗一次完整演绎 ⇒ 实测 `tprune ON 57929ms vs OFF 54783ms`
##      = **+5.7%**（seed2 +3.8%）。即"安全但略负"。
##   ③ **机制自检未通过**：`tools/_prune_equiv.gd` 的机制自检 3 项 FAIL 2 项
##      （含「欠定盘应置 stuck 却未置」）⇒ 该机制**并未被证明可用**，不应进热路径。
## 保留价值：`stats["stuck"]` 信号是「确定性判死结构零产出单元」的唯一廉价判据
##（`classic+s3@8` 一类；见 §11.6），故实现与信号保留，仅默认不启用。
## 重新启用前必须：先让机制自检 3/3 通过，并给出 `skip>0` 的真实语料证据 + `t_prune` 不劣化。
var prune_noop_shortcut: bool = false


## ⛔ **禁止启用·仅存档**（2026-09-28 实测否证）：①「逐轮白名单 D_A(r) 限制候选探测面」。
##
## 做了什么：全集线索集 A 的序贯演绎逐轮记下强制格 D_A(r)，候选 B⊆A 的第 r 轮只探测 D_A(r)。
## 理论依据（单调性）：A 的模型约束更多 ⇒ forced_B(r) ⊆ D_A(r)。
##
## 【实测否证（真 dll 首次跑通后，`tools/_i1_equiv.gd`，2026-09-28）】
##   `o4+s1@8 seed1`：OFF `tries=31/ok=31`、`clue_count=7` ｜ ON `tries=31/**ok=30**`、`clue_count=8`
##   ⇒ **一次合法删除被白名单挡住 ⇒ 产出改变**（其余 7 例一致，8 例中 1 例不等价）。
##   且 ON 在所有档上都更慢：`o4@8` 18.59→20.01s、`classic+s3@7` 58.56→63.16s、`o4+s1@8` 9.88→10.94s
##   （唯一"更快"的 `o4@6` 是噪声）。⇒ **既不等价也无收益。**
## 疑因（未定论）：轮次对应关系在"B 与 A 的知识集不同步"时可能错位——定理给的是**模型级**
##   包含关系，而按"轮号"对齐隐含了"B 的第 r 轮状态 ⊆ A 的第 r 轮状态"，这一点在有隐藏态/
##   全局规则的复合档上未必成立。**要复活它必须先给出逐轮 `new == old` 的语料证据。**
##
## 已保留的资产：C# 侧 `spec["probe_cells"]` 能力 + 两个自检守卫（旧 dll ⇒ 静默忽略时告警；
##   预算绑定 ⇒ 自动停用白名单）；`_i1_equiv.gd` 对拍工具（含空结果防假通过）。
var prune_probe_whitelist: bool = false


const _PRUNE_NEIGH8: Array[Vector2i] = [
	Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1),
]


## 删线索顺序比较器（确定性）。order 见 prune_order 说明。
func _prune_less(a: Variant, b: Variant, values: Dictionary, active: Dictionary) -> bool:
	var pa: Vector2i = a
	var pb: Vector2i = b
	var ka := _prune_rank(pa, values, active)
	var kb := _prune_rank(pb, values, active)
	if ka != kb:
		return ka < kb
	if pa.y != pb.y:
		return pa.y < pb.y
	return pa.x < pb.x


func _prune_rank(p: Vector2i, values: Dictionary, active: Dictionary) -> int:
	# ⚠ 值型安全（实测 bug，2026-09-27）：线索值**不一定是 int**——多值线索规则（同格双数字，
	# 如 hv：Array/Vector2i）会让 `int(values[p])` 在 sort_custom 比较器内抛
	# "Nonexistent 'int' constructor"，一次生成刷上百条引擎错误（GUT 记为 Unexpected Errors）。
	# 非 int 一律记 0（中性 → 同分回落行优先），不影响正确性。
	var raw: Variant = values.get(p, 0)
	var v := int(raw) if raw is int else 0
	match prune_order:
		1:
			return v
		2:
			return -v
		3:
			var n := 0
			for dp in _PRUNE_NEIGH8:
				if active.has(p + dp):
					n += 1
			return -n
		_:
			return 0


## 阶段统计（v2.9.3 服务器分析增强）：每次 generate_with_rules 重置，
## 批量工具读取后写入 issues —— 把「空返回」分解为布雷/删线索/验证各阶段失败，
## 让「布雷成功率」「端到端接受率」可按组合观测（服务器低接受率排查用）。
## attempts = 布雷尝试数；brep_fail = 布雷阶段失败（构造式+CP-SAT 兜底全空）；
## no_clues = 线索集为空（罕见）；prune_empty = 删线索后 active 空；
## verify_fail = 序贯可解验证拒；timeout = attempt 间墙钟超限；success = 1 即出关。
var last_call_stats := {}


## 内置线索型枚举 → 规则 id（自举式底座：内置变体与内置规则同源、同 API）。
func _clue_to_rule_id(clue: int) -> String:
	match clue:
		ClueEngine.Variant.CLASSIC:
			return "classic"
		ClueEngine.Variant.N4:
			return "4n"
		ClueEngine.Variant.SAME_COLOR:
			return "sc"
		ClueEngine.Variant.CLOCK:
			return "clock"
		ClueEngine.Variant.HV:
			return "hv"
		ClueEngine.Variant.FR:
			return "fr"
		ClueEngine.Variant.LOOP_RUNS:
			return "loopruns"
		ClueEngine.Variant.DIST_SUM:
			return "distsum"
		_:
			return ""


## 内置全局约束枚举 → 规则 id。
func _constraint_to_rule_id(constraint: int) -> String:
	match constraint:
		ConstraintEngine.Variant.MX:
			return "mx"
		ConstraintEngine.Variant.RL:
			return "rl"
		ConstraintEngine.Variant.PF:
			return "pf"
		ConstraintEngine.Variant.QD:
			return "qd"
		ConstraintEngine.Variant.DT:
			return "dt"
		ConstraintEngine.Variant.EP:
			return "ep"
		ConstraintEngine.Variant.FOUR_COLOR:
			return "4c"
		_:
			return ""


## 构造式生成（第三篇 P0）：逆向删线索 → 序贯纯逻辑可解验证。
## 内置变体统一路由到自举式规则平台（dogfood 底座，大盘走 CP-SAT 不受 MAX_COMBOS 限制）；
## 仅 E 类线索混合（clue2≥0，GDD R11 已禁多 C 叠加，仅服务 archive 工具）
## 与 DT 双布局（_place_mines_dual 需同时满足两约束，布雷策略复杂）保留旧路径。
func generate_constructive(variant_code: String, size: Vector2i, mine_count: int, seed: int, mask_count: int = 0) -> Dictionary:
	var def: Dictionary = VariantRegistry.resolve(variant_code)
	if def.is_empty():
		# 不在旧变体码表里 → 官方 22 席 / Mod 算子：按 **KIND** 路由到规则平台入口。
		# KIND 决定参数位置（HANDOFF 坑 #33）：线索放第一个参数，结构 / 守恒放 globals
		# —— 放反了会一路返回空，症状与「这个算子产不出关卡」一模一样。
		# 这样批量 / 存档 / 量产工具不必各自判别算子类别，直接喂 id 即可。
		var rule: Object = RuleRegistry.default().resolve(StringName(variant_code))
		if rule == null or not rule.has_method("get_kind"):
			return {}
		if str(rule.call("get_kind")) == RulePlugin.KIND_CLUE:
			return generate_with_rules(variant_code, [], size, mine_count, seed, mask_count)
		return generate_with_rules("classic", [variant_code], size, mine_count, seed, mask_count)
	var clue: int = def["clue"]
	var constraint: int = def["constraint"]
	# DT 已底座化（DtRule.place_mines 布雷 + dominoes 落盘 + 加载同步），单约束走规则平台即可。
	# 仅 E 类线索混合（clue2≥0，GDD R11 已禁多 C 叠加，仅服务 archive 工具）保留旧路径。
	if int(def["clue2"]) >= 0:
		return _legacy.generate_impl(clue, constraint, variant_code, size, mine_count, seed, mask_count)
	var globals: Array = []
	if constraint >= 0:
		globals.append(_constraint_to_rule_id(constraint))
	return generate_with_rules(_clue_to_rule_id(clue), globals, size, mine_count, seed, mask_count)


## 混合变体生成：布局（全局约束）+ 线索型 组合（plan1.8 §3.2 C 类「一布局一线索」）。
## 例：generate_mixed("mx", "4n", ...) = 镜像约束 + 四邻线索。
func generate_mixed(layout_code: String, clue_code: String, size: Vector2i, mine_count: int, seed: int, mask_count: int = 0) -> Dictionary:
	var layout: Dictionary = VariantRegistry.resolve(layout_code)
	var clue: Dictionary = VariantRegistry.resolve(clue_code)
	if layout.is_empty() or clue.is_empty():
		return {}
	return generate_with_rules(_clue_to_rule_id(int(clue["clue"])), [_constraint_to_rule_id(int(layout["constraint"]))], size, mine_count, seed, mask_count)


## 双布局生成（F 类）：两个全局约束叠加，线索为经典（plan1.8 §3.2）。
## 例：generate_dual("mx", "rl", ...) = 镜像约束 + 相邻行锁约束。
## 非 DT 双布局：委托规则平台（两个全局规则叠加）。
## DT 双布局：遗留路径（与 E 类同性质）——生产 UI 不调用，仅服务 archive/tools 与集成测试。
## _place_mines_dual 需同时满足两约束（DT 骨牌 × 另一布局），布雷策略无法用
## generate_with_rules 的「第一个规则 place_mines」表达，故保留旧实现而非融合。
func generate_dual(layout_a: String, layout_b: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var da: Dictionary = VariantRegistry.resolve(layout_a)
	var db: Dictionary = VariantRegistry.resolve(layout_b)
	if da.is_empty() or db.is_empty():
		return {}
	var ca: int = da["constraint"]
	var cb: int = db["constraint"]
	if ca == -1 or cb == -1:
		return {}  # 必须都是布局型
	if ca == ConstraintEngine.Variant.DT or cb == ConstraintEngine.Variant.DT:
		return _legacy.generate_dual_impl(ca, cb, "%s+%s" % [layout_a, layout_b], size, mine_count, seed)
	return generate_with_rules("classic", [_constraint_to_rule_id(ca), _constraint_to_rule_id(cb)], size, mine_count, seed)


## 线索混合生成（E 类）：两个线索型叠加，一格同时给出两个线索值（plan1.8 §3.2）。
## 例：generate_mixed_clue("4n", "sc", ...) = 四邻计数 + 同色计数 同时显示。
func generate_mixed_clue(clue_a: String, clue_b: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	var da: Dictionary = VariantRegistry.resolve(clue_a)
	var db: Dictionary = VariantRegistry.resolve(clue_b)
	if da.is_empty() or db.is_empty():
		return {}
	if int(da.get("constraint", -1)) != -1 or int(db.get("constraint", -1)) != -1:
		return {}  # 必须都是线索型
	return _legacy.generate_impl_clue2(da["clue"], db["clue"], "%s+%s" % [clue_a, clue_b], size, mine_count, seed)


## 从 mod Def 生成关卡（第二篇 mod 系统，用内置 DefEngine）。
## clue_def_name 必填；constraint_def_name 可选（空 = 无全局约束）。
func generate_from_def(clue_def_name: String, constraint_def_name: String, size: Vector2i, mine_count: int, seed: int) -> Dictionary:
	return generate_with_engine(DefEngine.new(), clue_def_name, constraint_def_name, size, mine_count, seed)


## 从指定 DefEngine 生成关卡（供 ModService 用含 mod Def 的共享 engine 生成 mod 关卡）。
## Def 是规则平台的严格子集：把 (window, aggregate) / op 翻译成规则 id，统一走 generate_with_rules。
## topology（P0-A）：可选异形棋盘（Mod board.json 构造的 AdjacencyGrid），null = 矩形。
func generate_with_engine(engine: DefEngine, clue_def_name: String, constraint_def_name: String, size: Vector2i, mine_count: int, seed: int, topology: GridInterface = null) -> Dictionary:
	if not engine.clue_defs.has(clue_def_name):
		return {}
	if constraint_def_name != "" and not engine.constraint_defs.has(constraint_def_name):
		return {}
	var clue_rule := _def_clue_to_rule(engine, clue_def_name)
	if clue_rule == "":
		return {}
	var globals: Array = []
	if constraint_def_name != "":
		var g := _def_constraint_to_rule(engine, constraint_def_name)
		if g == "":
			return {}
		globals.append(g)
	return generate_with_rules(clue_rule, globals, size, mine_count, seed, 0, 50, topology)


## Def 线索 (window, aggregate) → 规则 id。
## Def 的窗口/聚合是封闭枚举，与内置 C 类规则一一对应：
##   n8+sum→classic、n4→4n、diag→sc、ring8+run_count→loopruns、ring8→clock、
##   ray_right→fr、split→hv、weighted_sum→distsum。
static func _def_clue_to_rule(engine: DefEngine, def_name: String) -> String:
	var def: Dictionary = engine.clue_defs.get(def_name, {})
	if def.is_empty():
		return ""
	var window: String = str(def.get("window", ""))
	var agg: String = str(def.get("aggregate", "sum"))
	match window:
		"n8":
			return "distsum" if agg == "weighted_sum" else "classic"
		"n4":
			return "4n"
		"diag":
			return "sc"
		"ring8":
			return "loopruns" if agg == "run_count" else "clock"
		"ray_right":
			return "fr"
		"split":
			return "hv"
	return ""


## Def 约束 op → 全局规则 id（7 种操作与内置 G 类规则一一对应）。
static func _def_constraint_to_rule(engine: DefEngine, def_name: String) -> String:
	var def: Dictionary = engine.constraint_defs.get(def_name, {})
	if def.is_empty():
		return ""
	match str(def.get("op", "")):
		"symmetry_axis":
			return "mx"
		"sequence_diff":
			return "rl"
		"pattern_forbidden":
			return "pf"
		"quadrant_equal":
			return "qd"
		"endpoint_equal":
			return "ep"
		"color_equal":
			return "4c"
		"partition_pairing":
			return "dt"
	return ""


## 供 UI 用：这个 Def 相当于哪个内置变体（"" = 映射不到 → 规则平台生成不了）。
##
## 为什么需要它：Def 的 window/aggregate/op 是**封闭枚举**，永远翻译成内置 8 线索 / 7 约束之一
## （如 n4+sum ≡ 4n、symmetry_axis ≡ mx）。所以 Def 不是「新玩法」而是「声明式入口」——
## Mod 页据此如实告诉玩家「你这个 Def 相当于哪个变体、去哪儿玩」，
## 而不是给选关页塞一个与内置变体重复（或根本生成不出来）的死变体。
static func def_to_rule(engine: DefEngine, def_name: String, is_clue: bool) -> String:
	return _def_clue_to_rule(engine, def_name) if is_clue else _def_constraint_to_rule(engine, def_name)


##（Def 路径旧实现已删除：generate_with_engine 现在委托 generate_with_rules，
##  Def 的 window/aggregate/op 由 _def_clue_to_rule / _def_constraint_to_rule 翻译成规则 id。）


##（Def 路径旧实现已删除：_make_board_from_def / _prune_clues_def / _solve_with_check /
##  _build_level_from_def 已随 _generate_def_impl 一并移除，生成统一走规则平台。）




# ============ 自举式规则平台生成路径（可组合 IR → CP-SAT，文档第二篇 §2 续） ============
# 与内置变体路径并存：规则（含第三方 mod 规则）走 RuleBuilder 可组合约束 IR；
# 唯一解删线索走 C# CP-SAT 快速计数（不可用时回退 GDScript 枚举）；
# 纯逻辑可解验证走 BruteForceOracle + RuleOracle 黑盒判定（既有管线零改动）。

## 异形拓扑门控的**唯一判据**（线索型 / 全局约束型同口径）：规则声明 supports_topology() 才可用。
## has_method 守卫兜住「旧契约鸭子类型规则」（CONTRACT 未含 supports_topology）：
## 无该方法者按「未声明」处理 ⇒ 与今天一样不可用（第三方 mod 不声明时行为零变化）。
static func _rule_topology_ok(rule: Object) -> bool:
	return rule != null and rule.has_method("supports_topology") and bool(rule.call("supports_topology"))


## 异形盘上「丢弃全局约束」的用户可读原因（告警 / last_call_stats.gated_globals / 矩阵文案共用一份口径）。
static func _global_topology_gate_reason() -> String:
	return "该全局规则未声明拓扑能力或依赖矩形几何（geometry_kind=GEO_RECT_ONLY）；异形盘上按包围盒行列强算会得到另一个约束（盘外格按常量 0 参与，core/rule_builder.gd:56-59），故回退「无该约束」（等价于未勾选）"


## 从规则注册表生成关卡。
## clue_rule_id: 线索规则 id（恰一个）；global_rule_ids: 全局规则 id 列表（可空）。
## 规则来源：内置（RuleRegistry.default()）+ mod 注册（entry.on_load 里
## RuleRegistry.default().register(...)，或 ModAPI 扩展点 &"rules" + harvest）。
## 生成前可行性预筛：快速判断「该规则组合 + 尺寸 + 雷数」是否存在至少一个可行布雷。
## 返回 {ok: bool, reason: String}。
##
## 目的：对规则冗余/矛盾、雷数不可达导致的 UNSAT 组合，立即拒绝并给出原因，
## 避免调用方进入 generate_with_rules 的「换 seed 重试」——那对 UNSAT 组合是
## 纯浪费时间的暴力生成（几十次 attempt 全部失败，可能耗几十秒）。
##
## 注意：ok=true 只代表「存在可行布局」，不保证「一定能生成序贯可解关卡」——
## 序贯可解性由生成期删线索验证决定（可行组合也可能需要换几个 seed）。
static func precheck_rules(clue_rule_id: String, global_rule_ids: Array, size: Vector2i, mine_count: int, topology: GridInterface = null) -> Dictionary:
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(StringName(clue_rule_id))
	if clue_rule == null or clue_rule.get_kind() != RulePlugin.KIND_CLUE:
		return {"ok": false, "reason": "未知线索规则 %s" % clue_rule_id}
	var globals: Array = []
	for gid in global_rule_ids:
		var g: Object = reg.resolve(StringName(str(gid)))
		if g == null or g.get_kind() != RulePlugin.KIND_GLOBAL:
			return {"ok": false, "reason": "未知全局规则 %s" % str(gid)}
		globals.append(g)
	# 异形拓扑门控（与 generate_with_rules 同口径，判据 = _rule_topology_ok）：只依赖邻域的规则
	#（supports_topology）原样使用，其余回退 classic 并**大声告警**（禁止静默降级）。
	# 默认 geometry_kind() = GEO_RECT_ONLY ⇒ 未声明的第三方规则行为与今天逐位一致。
	if topology != null:
		if not _rule_topology_ok(clue_rule):
			push_warning("PuzzleGenerator.precheck_rules: 异形拓扑忽略线索规则 %s（该规则未声明拓扑能力或依赖矩形几何），回退 classic，线索值按拓扑邻域计数" % clue_rule_id)
			clue_rule = reg.resolve(&"classic")
			clue_rule_id = "classic"
		# 全局约束同口径（2026-10-03）：全局规则没有「经典」可替换 ⇒ 安全回退 = 丢弃该约束
		#（等价于未勾选）+ 告警。不丢的话 RuleOracle 会按包围盒行列强算（core/rule_builder.gd:56-59），
		# 判据层与生成期（已同步同一门控）就会给出两个不同的结论。
		var kept_globals: Array = []
		for i in globals.size():
			var g: Object = globals[i]
			if _rule_topology_ok(g):
				kept_globals.append(g)
			else:
				push_warning("PuzzleGenerator.precheck_rules: 异形拓扑忽略全局规则 %s：%s" % [
					str(global_rule_ids[i]), _global_topology_gate_reason()])
		globals = kept_globals
	var cols := size.x
	var rows := size.y
	var n := topology.cell_count() if topology != null else cols * rows
	var mc := clampi(mine_count, 1, n - 1)
	# 矩形盘：统一走 RuleFeasibility 真值查询（CP-SAT + 缓存 + dt 骨牌重采样）——
	# 与 UI 尺寸选择器、批量预筛共用唯一入口，避免两份 is_feasible 逻辑各自演化。
	# 已知规则已解析完毕（未知规则上面已明确拒绝）→ 此处 query 只回真值。
	if topology == null:
		if RuleFeasibility.query(clue_rule_id, global_rule_ids, cols, mc):
			return {"ok": true, "reason": ""}
		return {"ok": false, "reason": "该变体组合在 %d×%d 棋盘、%d 雷下无可行布局（规则约束矛盾或雷数不可达）" % [cols, rows, mc]}
	# 异形拓扑（RuleFeasibility 不覆盖）：保持 CP-SAT 直查。
	var oracle := RuleOracle.new(clue_rule, globals, size, mc, topology)
	var spec := oracle.build_spec({}, [], {})
	if not RuleCpSat.is_feasible(spec):
		return {"ok": false, "reason": "该变体组合在 %d×%d 棋盘、%d 雷下无可行布局（规则约束矛盾或雷数不可达）" % [cols, rows, mc]}
	return {"ok": true, "reason": ""}


## timeout_ms：删线索阶段墙钟上限（默认 15s）。
## 大盘（9×9+）单盘删线索可能超过 15s——超时会保留冗余线索（关卡偏简单但仍可解）。
## 离线批量出关建议放宽（如 60s）以换取线索精简度；UI 交互场景用默认保证响应。
##
## ⚠️ 2026-09-24 实测修正：墙钟的影响**不只是**"线索精简度"，它会让产物**不可推**。
## 上面那句"超时保留冗余线索"只描述了**慢机器**那一侧；实测**快机器上删得更多**
## （同一关 clue_count 12 → 8）⇒ 线索少到推理链断裂 ⇒ 序贯推演**推不完**
## （test_level_proof_coverage 门禁报"推不到底"）。也就是说：**同一批 SPEC 重跑两次，
## 可能得到"可推"与"不可推"两种产物**，取决于当时机器负载 —— 实测 ani_crab / ani_snowflake
## 就是这样从可推变成不可推的（已回滚数据）。
##
## 影响面：任何"重跑以刷数据"的操作都可能把好关卡改成坏关卡。根因是**判停用墙钟**，
## 正确的确定性判停应改用步数/迭代数（属生成算法变更，独立课题）。
## 当前缓解：① 库内数据不重跑即不受影响；② 必须重跑时，事后跑 test_level_proof_coverage
## 复核（它会点名新出现的 stuck 关卡），一旦出现即回滚该批数据。
## target_difficulty（P0-A，默认 0=不限制）：>0 时删线索改为「难度驱动」——
## 删到难度画像 difficulty 达标即停（早停=提速），同档关卡难度可控（固定 timeout 下难度波动可达 3 倍）。
func generate_with_rules(clue_rule_id: String, global_rule_ids: Array, size: Vector2i, mine_count: int, seed: int, mask_count: int = 0, attempts: int = 50, topology: GridInterface = null, timeout_ms: int = 15_000, target_difficulty: float = 0.0, mask_lo: int = 1, mask_strategy: int = 0, mask_pre: bool = false) -> Dictionary:
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(StringName(clue_rule_id))
	if clue_rule == null or clue_rule.get_kind() != RulePlugin.KIND_CLUE:
		return {}
	# 异形拓扑门控（A2 → v4.x）：邻域由邻接表定义。
	# 规则若声明 supports_topology()（只依赖邻域/邻接表）⇒ **原样使用**——这正是「异形盘 × 用户变体」
	# 的解锁点；否则回退 classic 并**大声告警**（禁止静默降级，用户点名缺陷）。
	# 默认 geometry_kind() = GEO_RECT_ONLY ⇒ 未声明的第三方规则行为与今天逐位一致。
	# 约定：可上异形的线索规则，其线索值由 compute_clue_topo 给出（基类默认 = 拓扑邻域雷数，
	# 故 classic 逐位不变）；声明 GENERIC 但语义非邻域计数的规则必须覆写 compute_clue_topo。
	# has_method 守卫兜住「旧契约鸭子类型规则」（CONTRACT 未含 supports_topology）。
	if topology != null:
		if not _rule_topology_ok(clue_rule):
			push_warning("PuzzleGenerator: 异形拓扑忽略线索规则 %s（该规则未声明拓扑能力或依赖矩形几何），回退 classic（线索值 = 拓扑邻域计数）" % clue_rule_id)
			clue_rule = reg.resolve(&"classic")
		if clue_rule == null:
			return {}
		# 落盘字段必须同步：否则 JSON 声明 knight、实际按邻域计数生成，
		# 造成「关卡自述」与「实际语义」分叉（Board 异形分支虽按邻接表算值不受影响，
		# 但 rule_clue_id 会误导后续复用与工坊展示）。
		clue_rule_id = "classic"
	# 全局约束门控（2026-10-03 补齐，与线索型**同一判据** `supports_topology()`）：
	# 此前这里只 gate 线索规则，于是 mx/rl/pf/qd/dt/ep/4c 这些全局约束型在洞盘 / 环绕盘上
	# 被**真的构建** —— 而 RuleBuilder 在邻接表盘上把盘外格按常量 0 代入
	#（core/rule_builder.gd:56-59），约束按包围盒行列强算 ⇒ 得到的是**另一个**约束
	#（如「左右镜像」退化成「镜像列是洞的格必为 0」）。运行期语义错误，且判据层/生成期分叉。
	# 全局规则没有「经典」可替换 ⇒ 安全回退 = **丢弃该约束**（等价于未勾选）+ 大声告警；
	# 落盘名单 global_rule_ids 同步 = 与上面 clue_rule_id 同步同一理由：
	# 不许关卡自述带一个实际没生效的约束（复用 / 工坊 / 规则图例都会按自述走）。
	var globals: Array = []
	var gated_globals: Dictionary = {}
	for gid in global_rule_ids:
		var g: Object = reg.resolve(StringName(str(gid)))
		if g == null or g.get_kind() != RulePlugin.KIND_GLOBAL:
			return {}
		if topology != null and not _rule_topology_ok(g):
			var why := _global_topology_gate_reason()
			push_warning("PuzzleGenerator: 异形拓扑忽略全局规则 %s：%s；落盘 global_rules 已同步（关卡不再声称它生效）" % [str(gid), why])
			gated_globals[str(gid)] = why
			continue
		globals.append(g)
	if not gated_globals.is_empty():
		var kept_ids: Array = []
		for gid in global_rule_ids:
			if not gated_globals.has(str(gid)):
				kept_ids.append(gid)
		global_rule_ids = kept_ids
	var cols := size.x
	var rows := size.y
	# 异形拓扑（A2）：格子总数 = 拓扑 cell_count（不含洞格）；坐标范围 = 包围盒。
	var n := topology.cell_count() if topology != null else cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	last_call_stats = {"attempts": 0, "brep_fail": 0, "no_clues": 0, "prune_empty": 0,
		"verify_fail": 0, "timeout": 0, "success": 0, "hs_uninit": 0,
		"t_place_ms": 0, "t_prune_ms": 0, "t_verify_ms": 0, "prune_tries": 0, "prune_ok": 0,
		# A1-ii（2026-09-27）可观测：prune 因「全量集卡住 ⇒ 必为 no-op」被整体短路的次数
		#（prune_skipped = 被跳过的 prune 调用数；prune_skip_stuck = 其中因卡住而跳过的）。
		"prune_skip_stuck": 0, "prune_skipped": 0, "t_prune_pre_ms": 0,
		# 全局约束门控可读原因（2026-10-03）：{规则 id: 为何在异形盘上被丢弃}。
		# 与「阶段失败计数」同性质的**可观测通道**（批量工具按 .get() 读，新增键不改既有字段语义）：
		# 上层不必解析 push_warning 才知道「勾的全局约束没生效、为什么」。
		"gated_globals": gated_globals}

	for attempt in attempts:
		# 种子派生：每 attempt 独立确定性随机流（同 seed+attempt 必同盘，可复现）。
		# attempts=1 即「固定种子单次尝试」——一颗种子 = 一次尝试，可复现零歧义。
		_rng.seed = _derive_seed(seed, attempt)
		last_call_stats["attempts"] = int(last_call_stats["attempts"]) + 1
		# P0（2026-09-27）：每 attempt 入口先清空线索规则的隐藏态。
		# 作用：把「残留上一盘」（注册表单例，跨关卡/跨尺寸都不清）**降级为「空」**——
		# 空是下面门禁拦得住的，残留拦不住（残留的基数是上一盘的、看起来合法）。
		# 对纯线索档零副作用：place_mines 内部本就先 clear，且本调用不消耗 rng ⇒ 逐字节不变。
		if clue_rule.has_method("import_hidden_state"):
			clue_rule.call("import_hidden_state", {})
		if Time.get_ticks_msec() > deadline:
			last_call_stats["timeout"] = int(last_call_stats["timeout"]) + 1
			push_warning("PuzzleGenerator: 规则生成超时 %s" % clue_rule_id)
			return {}
		# 1. 布雷：异形优先走线索规则的拓扑构造式（v4.x 新接口，默认空 = 维持今天行为），
		#    否则回原有随机拓扑布雷；矩形走全局规则构造式（镜像/禁形）优先，否则线索规则，最后随机
		var t_place0 := Time.get_ticks_msec()
		var mines: Array[Vector2i]
		if topology != null:
			mines = _place_mines_topo(clue_rule, topology, mine_count)
		else:
			# 传 attempt 的墙钟 deadline：布雷（多 G 时 7 次 CP-SAT 采样）也要能被截断。
			mines = _place_mines_rules(clue_rule, globals, cols, rows, mine_count, deadline)
		last_call_stats["t_place_ms"] = int(last_call_stats["t_place_ms"]) + (Time.get_ticks_msec() - t_place0)
		if mines.is_empty():
			last_call_stats["brep_fail"] = int(last_call_stats["brep_fail"]) + 1
			continue
		var mine_set := {}
		for m in mines:
			mine_set[m] = true
		# 2. 全部非雷格为候选线索，正向计算线索值（异形走规则自己的 compute_clue_topo，默认 = 拓扑邻域计数）
		var values := {}
		var clue_cells: Array[Vector2i] = []
		var positions: Array = topology.all_positions() if topology != null else _rect_positions(rows, cols)
		for pos in positions:
			if mine_set.has(pos):
				continue
			var v: Variant
			if topology != null:
				# 线索值必须由「该规则自己的语义」给出（RulePlugin.compute_clue_topo）：
				# 有接口 ⇒ 调用（classic 走基类默认实现 = 拓扑邻域计数 ⇒ 产物逐位不变）；
				# 无接口（旧契约鸭子类型）⇒ 退回今天的硬编码口径，一次性告警。
				if clue_rule.has_method("compute_clue_topo"):
					v = clue_rule.call("compute_clue_topo", mine_set, pos, topology, size)
				else:
					if not Engine.has_meta("topo_clue_value_fallback_warned"):
						Engine.set_meta("topo_clue_value_fallback_warned", true)
						push_warning("PuzzleGenerator: 线索规则 %s 未实现 compute_clue_topo，异形盘线索值退回硬编码的拓扑邻域计数" % clue_rule_id)
					v = _count_topo_mines(mine_set, topology.get_neighbors(pos))
			else:
				if not clue_rule.applies_to(pos, size):
					continue
				v = clue_rule.compute_clue(mine_set, pos, size)
			values[pos] = v
			# 0 值格也进线索集：它是「邻域全安全」的强信息，加载时连锁扩散（见 board.reveal_initial）。
			# 历史 workaround 把 0 值格排除在初始线索外，导致残局关出现「孤立的空白可点击格」
			#（未翻开的 0 值格夹在已翻开格中间）——这是用户反复报告的 bug 的根源。
			clue_cells.append(pos)
		if clue_cells.is_empty():
			last_call_stats["no_clues"] = int(last_call_stats["no_clues"]) + 1
			continue
		# 3. 逆向删线索（保持唯一解）：CP-SAT 快速唯一解计数
		# 雷数一律以「实际布雷数」为准（而非入参 mine_count）：第三方规则的 place_mines
		# 若返回数量不符，用入参会让唯一解判定静默出错，输出与验证也会对不上。
		var mine_total := mines.size()
		var oracle := RuleOracle.new(clue_rule, globals, size, mine_total, topology)
		oracle.num_workers = num_workers
		if probe_budget_ms > 0:
			oracle.probe_budget_ms = probe_budget_ms
		var active := {}
		for p in clue_cells:
			active[p] = values[p]
		# 遮蔽前置（方向 1，2026-09-16）：mask_pre 时先从「全线索」选遮蔽格（子设计 A），
		# 删线索在「弱化信息集」上运行 → MSC 重建后每条保留线索都必要 → 推理批量变小 → 难度上升。
		# 遮蔽格不允许被删（_prune_clues_rules 的 keys 排除）；mask_count=0 时与旧路径逐位一致。
		var pre_masked := {}
		if mask_pre and mask_count > 0:
			pre_masked = _select_masked_rules(clue_rule, active, mask_count, size, mask_lo, mask_strategy)
		var t_prune0 := Time.get_ticks_msec()
		var pr_state: Dictionary = _prune_clues_rules(oracle, active, deadline, size, mine_total, values, target_difficulty, pre_masked)
		last_call_stats["t_prune_ms"] = int(last_call_stats["t_prune_ms"]) + (Time.get_ticks_msec() - t_prune0)
		last_call_stats["prune_tries"] = int(last_call_stats["prune_tries"]) + int(pr_state.get("tries", 0))
		last_call_stats["prune_ok"] = int(last_call_stats["prune_ok"]) + int(pr_state.get("ok", 0))
		# 墙钟兜底触发的留痕（2026-09-24 补完消费链）：_prune_sequential 只负责把
		# prune_timeout 记进 state，这里负责转成可观测信号 —— 缺了这个中间环节，
		# 标记会被设但永远没人读，「可观测化」就成了摆设（审计实测发现的半成品）。
		if bool(pr_state.get("prune_timeout", false)):
			last_call_stats["prune_timeout"] = int(last_call_stats.get("prune_timeout", 0)) + 1
			push_warning("generate_with_rules: attempt %d 删线索墙钟触发——删减被提前截断（非确定性判停，重跑可能波动）" % attempt)
		# A1-ii 可观测：prune 被「全量集卡住」短路（省 O(n) 次演绎、active 不变）的留痕。
		# 透传 state 里的计数器，使「窗口模式下有多少候选走了短路」可直接聚合（batch unit_done
		# 用 .get() 读 last_call_stats，新增键不改变既有字段语义）。
		last_call_stats["prune_skipped"] = int(last_call_stats.get("prune_skipped", 0)) + int(pr_state.get("prune_skipped", 0))
		if bool(pr_state.get("prune_skip_stuck", false)):
			last_call_stats["prune_skip_stuck"] = int(last_call_stats.get("prune_skip_stuck", 0)) + 1
		last_call_stats["t_prune_pre_ms"] = int(last_call_stats.get("t_prune_pre_ms", 0)) + int(pr_state.get("pre_ms", 0))
		if active.is_empty():
			last_call_stats["prune_empty"] = int(last_call_stats["prune_empty"]) + 1
			continue
		# 3.5 遮蔽（问号模式）：mask_pre 时沿用前置选择（禁止删后重选）；否则按旧路径从删后 active 选。
		#（同时修复：lo/strategy 未接通调用点的实现 bug——此前双旋钮实际未生效，A/B/C/D 四组相同的实验含此因）
		var masked: Dictionary
		if mask_pre:
			masked = pre_masked
		else:
			masked = _select_masked_rules(clue_rule, active, mask_count, size, mask_lo, mask_strategy)
		# 遮蔽弱化约束后，由第 4 步 _solve_rules_stepwise（带 masked）做序贯可解验证兜底（R01 真义）。
		# 不再用静态唯一解 count_solutions==1：v2.8.3 起 0 值格不进初始线索，静态多解是正常现象，
		# 用静态唯一会误杀带遮蔽的规则关卡（与 _prune_clues_rules 同口径）。
		# 4. 纯逻辑可解验证（序贯演绎：CP-SAT forced-cell 检测，遮蔽格走 interval 语义）
		#    同时收集难度统计（P0-难度量化，成本近零——演绎本就要跑）
		var diff_stats := {"rounds": [], "complexities": []}
		var t_verify0 := Time.get_ticks_msec()
		var v_ok := _solve_rules_stepwise(size, active, masked, mine_total, oracle, values, diff_stats, deadline)
		last_call_stats["t_verify_ms"] = int(last_call_stats["t_verify_ms"]) + (Time.get_ticks_msec() - t_verify0)
		if not v_ok:
			last_call_stats["verify_fail"] = int(last_call_stats["verify_fail"]) + 1
			continue
		# 4.5 开局即胜门禁（v4.0 补齐，legacy 生成器同类门禁「settle 后不得开局即赢」）：
		# 初始线索覆盖全部非雷格 ⇒ 引擎加载时即满足胜利条件（unknown == remaining_mines）
		# ⇒ 玩家看到「全开却无结算」的死盘（真实用户 bug：98 关这样的盘进了库）。
		# 遮蔽盘同理：? 格状态也是 REVEALED，判胜口径视其为已知 → 全遮蔽盘同样当场判胜。
		# 实测：o5@5×5/10 雷 + 遮蔽 3 因「遮蔽格不许删」结构上必须给全线索 → 该配置全 seed 被拒，
		# 属预期（该盘面本就不该产出），产线改大盘面即可（7×7/14 雷起有剪枝空间）。
		var total_cells := topology.cell_count() if topology != null else rows * cols
		if total_cells - active.size() == mine_total:
			last_call_stats["prewon"] = int(last_call_stats.get("prewon", 0)) + 1
			continue
		# 5. 输出（规则关卡 JSON；播放接线见 Board 集成，本路径先供生成/验证/工坊）
		var level := _build_level_from_rules(clue_rule_id, global_rule_ids, rows, cols, mines, active, masked, seed, topology)
		# P0 门禁（2026-09-27）：声明了 hidden_state 的线索规则，状态必须真的落进关卡。
		#
		# 为什么必须是**硬门禁**而不是日志：隐藏态缺陷此前**四处门禁全放行**——线索值由
		# compute_clue **现算**（关卡不存 value）、求解器读的又是同一份状态，于是「空状态」
		# 下的盘面在门禁眼里完全自洽（实测 verify_fail=0）。但它其实已退化成另一条规则：
		# o4 空态 = 只算八邻（≈classic）、o5x 空态 = 恒走主斜线（隐藏选择消失），
		# 而玩家侧会照着同一份空状态复现 ⇒ 「自述 o4、实为 classic」的关静默入库。
		# 宁可拒收该候选（上层换 seed / 记 hs_uninit 可见），也不产出这种关。
		var hs_caps: Dictionary = {}
		if clue_rule.has_method("declares"):
			hs_caps = clue_rule.call("declares")
		if bool(hs_caps.get("hidden_state", false)) \
				and not (level.get("hidden_state", {}) as Dictionary).has(clue_rule_id):
			last_call_stats["hs_uninit"] = int(last_call_stats.get("hs_uninit", 0)) + 1
			push_warning("PuzzleGenerator: %s 声明 hidden_state 但落盘缺失 —— 拒收候选（隐藏态未初始化）" % clue_rule_id)
			continue
		# 难度画像落盘（4 组难度常量体系的筛选依据；Board 加载不读，纯元数据）。
		# 线索覆盖度一并记录：对同尺寸同密度的题，线索越少玩家信息越少 = 越难。
		var prof := difficulty_from_stats(diff_stats)
		prof["clue_count"] = active.size()
		var non_mine := maxi(1, total_cells - mine_total)
		prof["clue_ratio"] = snappedf(float(active.size()) / float(non_mine), 0.01)
		prof["target_difficulty"] = target_difficulty  # 生成标签（对标 L 字段：记录「照着哪档参数生成」）
		level["difficulty_profile"] = prof
		# 生成管线版本戳落盘（老盘无此字段；守卫 test/unit/test_gen_rev_stamp.gd）
		level["gen_rev"] = GEN_REV
		last_call_stats["success"] = 1
		return level
	return {}


## 参数对象化入口（2026-09-16，复盘评审 C1 整改 / 架构级）：以字典传参替代 15 个位置参数。
## 键（均可选，缺省 = generate_with_rules 的默认值）：
##   clue_rule_id / global_rule_ids / size(Vector2i) / mine_count / seed /
##   mask_count / attempts / topology / timeout_ms / target_difficulty /
##   mask_lo / mask_strategy / mask_pre
## 用法：gen.generate_with_opts({"clue_rule_id": "o4", "size": Vector2i(6, 6), "seed": 200})
## 说明：内部**转调 generate_with_rules**（零行为差异）；新调用方建议走本入口（新增参数不再
##       扩散到全部调用点）；旧签名保留兼容，可渐进迁移。
func generate_with_opts(opts: Dictionary) -> Dictionary:
	return generate_with_rules(
		str(opts.get("clue_rule_id", "classic")),
		opts.get("global_rule_ids", []) as Array,
		opts.get("size", Vector2i(5, 5)) as Vector2i,
		int(opts.get("mine_count", 0)),
		int(opts.get("seed", 1)),
		int(opts.get("mask_count", 0)),
		int(opts.get("attempts", 50)),
		opts.get("topology", null) as GridInterface,
		int(opts.get("timeout_ms", 15_000)),
		float(opts.get("target_difficulty", 0.0)),
		int(opts.get("mask_lo", 1)),
		int(opts.get("mask_strategy", 0)),
		bool(opts.get("mask_pre", false)))


## 从激活线索中选 mask_count 个「值 ≥1 且支持遮蔽」的格变成问号（interval [lo, hi]）。
## v3.0 双旋钮（难度体系 v2）：
##   · mask_lo：区间下界（默认 1 = 原「排除 0」语义；0 = 完全弱化该格信息）。
##   · mask_strategy：选格策略——0=随机（原行为）/ 1=高值优先 / 2=低值优先（值=1 优先）。
##     线索「值」是信息量的代理维度；策略效果以单算子（O5 实验台）probe 难度实测为准。
func _select_masked_rules(clue_rule: Object, active: Dictionary, mask_count: int, size: Vector2i = Vector2i(0, 0), lo: int = 1, strategy: int = 0) -> Dictionary:
	var masked := {}
	if mask_count <= 0 or not clue_rule.supports_mask():
		return masked
	var candidates: Array[Vector2i] = []
	for pos in active:
		var v: Variant = active[pos]
		if v is int and int(v) >= 1:
			candidates.append(pos)
	# 传真实盘面尺寸：此前固定传 (0,0)，按尺寸算上界的 mod 规则会拿到错误的 hi。
	var hi: int = clue_rule.value_upper_bound(size)
	if strategy == 1:
		candidates.sort_custom(func(a, b): return int(active[a]) > int(active[b]))
	elif strategy == 2:
		candidates.sort_custom(func(a, b): return int(active[a]) < int(active[b]))
	else:
		# 随机策略：Fisher-Yates 洗牌（保持原行为——前 N 个即随机 N 个）
		for i in candidates.size():
			var j := _rng.randi_range(i, candidates.size() - 1)
			var t := candidates[i]
			candidates[i] = candidates[j]
			candidates[j] = t
	# lo 夹至 [0, hi]（lo == hi = 单点区间、无弱化，允许但无效果——由实测判定）
	var lo_c := clampi(lo, 0, hi)
	for i in mini(mask_count, candidates.size()):
		masked[candidates[i]] = Vector2i(lo_c, hi)
	return masked


## 种子派生：seed + attempt → 确定性子种子（不同 attempt 独立随机流，同组合必同盘）。
func _derive_seed(seed: int, attempt: int) -> int:
	return seed * 1000003 + attempt


## 多解采样（v2.9.3，mod 试验修正版）：对同一约束采样 SOLUTION_SAMPLES 个候选解
##（random_seed 由确定性 RNG 派生——可复现性保持；C# 侧 FindSolution 单 worker + 固定种子），
## 按「2×2 窗口雷数方差」排序后**淘汰最差一个**，在剩余候选里用确定性 RNG 随机选。
##
## 为什么不「取方差最小」：hpair（水平配对）试验 Mod 实锤——当可行解空间的「最均匀结构」
## 唯一时，全部 seed 收敛到同一盘（每尺寸 3 关同盘、指纹校验不同盘面=1，难度也恒定）。
## 「淘汰最差」保留「避开烂结构」的收益（rl_ep 9×9 曾 0/12 靠它救活），
## 又通过候选集内随机恢复跨 seed 多样性（同 seed 仍确定）。
## 全部采样失败（UNSAT/超时）→ 返回空，交上层重试（与单次 find_solution 同语义）。
const SOLUTION_SAMPLES := 7

## deadline_ms（v4.0 挂死治理，可选，0 = 不限）：7 次采样 × 每次单解上限（默认 8s）
## = 单次布雷最长 56s，而布雷在 attempts 循环里最多跑 50 次 —— 又一处「单次有界、累计无界」。
## 已有解时预算耗尽即停采样（解照常参与择优）；一个解都没有时至少跑满 1 次，
## 避免预算为 0 时永不布雷（那是纯退化，不是保护）。
func _find_solution_best(oracle: RuleOracle, cols: int, rows: int, deadline_ms: int = 0) -> Array[Vector2i]:
	var sols: Array = []
	for _i in SOLUTION_SAMPLES:
		if not sols.is_empty() and deadline_ms > 0 and Time.get_ticks_msec() > deadline_ms:
			break
		var spec := oracle.build_spec({}, [], {})
		# random_seed 从本实例确定性 RNG 派生（_rng 已按 _derive_seed(seed,attempt) 设置）
		# → 同 seed 重放走同一条采样路径得同盘。
		spec["random_seed"] = _rng.randi()
		# 多样性扰动（v2.9.3 mod 试验修正）：CP-SAT 的「第一可行解」对简单模型往往
		# 与 random_seed 无关（presolve 定解——hpair/qd_sc 实测 5 个不同 seed 只出 1 种解，
		# 导致这些单元批量生成只能出同一张盘）。随机把 1 个自由格固定为雷/安全，
		# 从解空间切片引导出不同解；不可行的切片（返回空）自然淘汰。
		var pr := _rng.randi_range(0, rows - 1)
		var pc := _rng.randi_range(0, cols - 1)
		if _rng.randi() % 2 == 0:
			(spec["mine_cells"] as Array).append([pr, pc])
		else:
			(spec["safe_cells"] as Array).append([pr, pc])
		var sol: Array[Vector2i] = RuleCpSat.find_solution(spec)
		if not sol.is_empty():
			sols.append(sol)
	if sols.is_empty():
		return []
	if sols.size() == 1:
		return sols[0]
	sols.sort_custom(func(a: Array, b: Array) -> bool:
		return _uniformity_score(a, cols, rows) < _uniformity_score(b, cols, rows))
	var pick := _rng.randi_range(0, sols.size() - 2)  # 排除末位（方差最大）
	var out: Array[Vector2i] = sols[pick]
	return out


## 结构均匀度评分：全部 2×2 窗口雷数的方差（越小越均匀）。堆簇解方差大、均匀解接近 0。
static func _uniformity_score(mines: Array[Vector2i], cols: int, rows: int) -> float:
	if mines.is_empty() or cols < 2 or rows < 2:
		return 0.0
	var ms := {}
	for m in mines:
		ms[m] = true
	var vals: Array[float] = []
	var sum := 0.0
	for r in rows - 1:
		for c in cols - 1:
			var k := 0
			if ms.has(Vector2i(c, r)):
				k += 1
			if ms.has(Vector2i(c + 1, r)):
				k += 1
			if ms.has(Vector2i(c, r + 1)):
				k += 1
			if ms.has(Vector2i(c + 1, r + 1)):
				k += 1
			vals.append(float(k))
			sum += k
	if vals.is_empty():
		return 0.0
	var mean := sum / float(vals.size())
	var acc := 0.0
	for v in vals:
		acc += (v - mean) * (v - mean)
	return acc / float(vals.size())


## 布雷出口硬校验（机制防线，v2.9.3）：不信任任何布雷器（内置或 Mod 插件）的返回。
## 历史 bug：QD 偶数盘 place_mines 私自 count-=count%4 调平，生成器原样采信 →
## 产出「6×6 只有 12 雷」的违约关（违反 R07 固定雷数红线）。Mod 变体无法逐一修，
## 故在此统一校验：返回非空时雷数必须精确等于请求值，否则判失败（上层重试/换尺寸），
## 违规插件只会导致「该组合生成失败」（可提示），永远不会产出坏关。
func _place_mines_rules(clue_rule: Object, globals: Array, cols: int, rows: int, count: int, deadline_ms: int = 0) -> Array[Vector2i]:
	var m := _place_mines_rules_raw(clue_rule, globals, cols, rows, count, deadline_ms)
	if not m.is_empty() and m.size() != count:
		push_warning("PuzzleGenerator: 布雷器返回 %d 雷 ≠ 请求 %d（插件违约，已拒绝该布雷）" % [m.size(), count])
		return []
	return m


func _place_mines_rules_raw(clue_rule: Object, globals: Array, cols: int, rows: int, count: int, deadline_ms: int = 0) -> Array[Vector2i]:
	# 多 G 叠加（G+G / 2G+1C / 3G）：布雷必须**同时满足所有 G**。
	# 旧策略「只取第一个非空 G 的 place_mines」有两个致命缺陷：
	#   ① 状态性 G（dt 骨牌划分）不生成 → build_global_constraints 用空/残留划分，约束静默丢失；
	#   ② 布雷偏向第一个 G，其余 G 靠验证重试 → 接受率极低（mx+rl 实测 1.7s 都出不来）。
	# 正解：用 CP-SAT 直接求满足全部 G + 总雷数的布局（find_solution 第一可行解）。
	if globals.size() >= 2:
		# 状态性 G（dt）必须先 place_mines 生成骨牌划分（约束构建依赖 _dominoes），
		# 其布雷结果丢弃——find_solution 会重新采样满足该划分的布局。
		for g in globals:
			if g.get_rule_id() == &"dt":
				g.place_mines(_rng, cols, rows, count)
		# mx+pf 专用前置（v2.9.3）：镜像分层采样——镜像自动满足 mx、PF 窗口镜像封闭，
		# 一次采样同时过两约束。find_solution 第一可行解结构差 → mx_pf/5x5、6x6、8x8
		# 量产接受率趋零（110 seed 零新增）。采样失败（返回空）回落 find_solution，不破坏现路径。
		if not globals.any(func(g): return g.get_rule_id() == &"dt") \
				and globals.any(func(g): return g.get_rule_id() == &"mx") \
				and globals.any(func(g): return g.get_rule_id() == &"pf"):
			for g in globals:
				if g.get_rule_id() == &"pf":
					var mirrored: Array[Vector2i] = g.call("place_mines_mirrored", _rng, cols, rows, count)
					if not mirrored.is_empty():
						_init_clue_hidden_state(clue_rule, cols, rows, count)
						return mirrored
		var oracle := RuleOracle.new(clue_rule, globals, Vector2i(cols, rows), count, null)
		# 多解取优（v2.9.3）：find_solution 第一可行解结构差（堆簇）→ 删线索/序贯验证
		# 通过率低（PF/mx+pf 已用专用采样救活，其余多 G——如 rl+ep 9×9——仍受此影响）。
		var sol_multi := _find_solution_best(oracle, cols, rows, deadline_ms)
		if not sol_multi.is_empty():
			_init_clue_hidden_state(clue_rule, cols, rows, count)
		return sol_multi
	# 单 G：沿用构造式布雷（确定性、快）
	for g in globals:
		var m: Array[Vector2i] = g.place_mines(_rng, cols, rows, count)
		if not m.is_empty():
			_init_clue_hidden_state(clue_rule, cols, rows, count)
			return m
	# 构造式失败兜底：CP-SAT 直接求满足全局约束的布局。旧代码 fallback 到随机布雷，
	# 而随机布雷违反全局约束（如 PF 9×9=32雷，place_mines 300 次随机+过滤碰不到可行布局）
	# → 后续唯一解/序贯验证必失败，整个 attempt 白跑（实测 pf 9×9 接受率 0/12）。
	# 约束数学可行（is_feasible=Y）时 find_solution 必有解。
	if not globals.is_empty():
		var oracle_fb := RuleOracle.new(clue_rule, globals, Vector2i(cols, rows), count, null)
		var sol_fb := _find_solution_best(oracle_fb, cols, rows, deadline_ms)
		if not sol_fb.is_empty():
			_init_clue_hidden_state(clue_rule, cols, rows, count)
			return sol_fb
	# 线索规则自己的构造式布雷：**不**在此补初始化——place_mines 内部已按同序采样，
	# 重复调用会多消耗一层 rng ⇒ 单线索档（o4/o5x 无全局）产物不再逐字节可复现（黄金网会破）。
	var m2: Array[Vector2i] = clue_rule.place_mines(_rng, cols, rows, count)
	if not m2.is_empty():
		return m2
	var m3 := _place_random(cols, rows, count)
	if not m3.is_empty():
		_init_clue_hidden_state(clue_rule, cols, rows, count)
	return m3


## 隐藏态初始化（P0，2026-09-27）：雷布局**不是**由线索规则给出时（全局规则 / CP-SAT 兜底 /
## 随机兜底），为当前盘面补采样线索规则的隐藏态。
##
## 背景与实证：隐藏态原本只在 place_mines 内部采样 ⇒ 复合档从不采样，全新会话下为空
##（compute_clue 退化：o4 只算八邻、o5x 恒走主斜线；而求解器读同一份状态 ⇒ R01 仍通过
## verify_fail=0，坏关静默过关）；规则又是注册表单例，残留上一盘时落盘状态不属于本盘
##（实测 7×7 盘落 16 个 s=1 格，而 _k_of(7,7)=12 —— 跨尺寸时连 k 配额都对不上）。
##
## 幂等性由规则侧的实现契约保证（先清空再采样，见 RulePlugin.init_hidden_state）。
## 未实现该方法的规则是空实现，调用零副作用 ⇒ 本函数无需前置能力判断。
func _init_clue_hidden_state(clue_rule: Object, cols: int, rows: int, count: int) -> void:
	if clue_rule != null and clue_rule.has_method("init_hidden_state"):
		clue_rule.call("init_hidden_state", _rng, cols, rows, count)


## 经典/无约束：随机布雷（主路径兜底，用本实例 _rng 保证确定性）。
## 注：与 PuzzleGeneratorLegacy.place_random 同逻辑，但各自持有独立 _rng（seed 各自设置）。
func _place_random(cols: int, rows: int, mine_count: int) -> Array[Vector2i]:
	var cells := _rect_positions(rows, cols)
	if mine_count <= 0 or mine_count > cells.size():
		return []
	var idx: Array[int] = []
	for i in cells.size():
		idx.append(i)
	for i in range(idx.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t := idx[i]
		idx[i] = idx[j]
		idx[j] = t
	var out: Array[Vector2i] = []
	for i in mine_count:
		out.append(cells[idx[i]])
	return out


## 异形盘布雷（v4.x）：线索规则的拓扑构造式优先（place_mines_topo，基类默认返回空）。
## 为什么默认空就回落随机：place_mines_topo 是**新增可选能力**，默认空必须逐位保持今天的行为；
## 纪律上**不引入随机重试兜底**（空 = 不提供，不是「再试一次」）。
## 雷数硬校验口径与 _place_mines_rules 一致：返回非空但雷数不符 → 拒绝该布雷（插件违约）。
func _place_mines_topo(clue_rule: Object, topo: GridInterface, count: int) -> Array[Vector2i]:
	if clue_rule != null and clue_rule.has_method("place_mines_topo"):
		var m: Array[Vector2i] = clue_rule.call("place_mines_topo", _rng, topo, count)
		if not m.is_empty():
			if m.size() != count:
				push_warning("PuzzleGenerator: 拓扑布雷器返回 %d 雷 ≠ 请求 %d（插件违约，已拒绝该布雷）" % [m.size(), count])
				return []
			return m
	return _place_random_topo(topo, count)


## 拓扑随机布雷（异形棋盘）：从拓扑格子集 Fisher-Yates 采样 count 个。
func _place_random_topo(topo: GridInterface, count: int) -> Array[Vector2i]:
	var positions: Array = topo.all_positions()
	if positions.size() <= count:
		return positions.duplicate()
	var shuffled: Array = positions.duplicate()
	for i in range(shuffled.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var t = shuffled[i]
		shuffled[i] = shuffled[j]
		shuffled[j] = t
	var out: Array[Vector2i] = []
	for i in count:
		out.append(shuffled[i])
	return out


## 拓扑邻域雷计数（异形棋盘线索，等价 classic「周围格」）。
static func _count_topo_mines(mine_set: Dictionary, neighbors: Array) -> int:
	var n := 0
	for p in neighbors:
		if mine_set.has(p):
			n += 1
	return n


## 矩形全部格子坐标（拓扑为 null 时的候选集）。
static func _rect_positions(rows: int, cols: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for r in rows:
		for c in cols:
			out.append(Vector2i(c, r))
	return out


## 逆向删线索：逐条尝试删除，保持 R01 序贯可解（确定性排序保证同 seed 可复现）。
## 策略为「顺序删除」O(n) 次验证（实测优于旧「整块删 → 失败二分」~2n 次，见 _prune_sequential）。
## target_difficulty（P0-A）：>0 时改为「难度驱动」——删到难度达标即全局停（早停=提速），
## 使同档关卡难度可控（固定 timeout 下难度波动可达 3 倍，难度目标下波动收敛）。
## masked（遮蔽前置，方向 1，2026-09-16）：被选定遮蔽的格是「问号格」——不许删除
##（删了就丢失弱化信息），且删除试探的序贯判定带 interval 语义（在「剩余精确线索 + 遮蔽弱约束」下验证）。
func _prune_clues_rules(oracle: RuleOracle, active: Dictionary, deadline: int, grid_size: Vector2i, total_mines: int, values: Dictionary, target_difficulty: float = 0.0, masked: Dictionary = {}) -> Dictionary:
	var keys: Array = []
	for p in active:
		# 0 值格不参与删线索：它是「邻域全安全」的锚点，一旦删掉就从 revealed 消失，
		# 加载后变成孤立的空白可点击格（用户反复报告的 bug）。0 值格必须保留。
		if values[p] is int and int(values[p]) == 0:
			continue
		if masked.has(p):
			continue
		keys.append(p)
	# 尝试顺序由 prune_order 决定；**判据不变**（删除仍要求删后序贯可解），见 prune_order 注释。
	# 【09-28 修正：order==0 必须**完全跳过**排序】原实现无条件 `sort_custom`，把 keys 改成**行优先**；
	# 而旧路径的 keys 顺序是 `active` 的**插入序**（`:886 for p in active`，Godot 字典保序 = 线索加入
	# `active` 的顺序，即 clue_cells 顺序，一般**不是**行优先）⇒ 该排序静默改变了删线索**尝试顺序**
	# ⇒ 换到另一个局部极小集 ⇒ 产出与耗时都变（与"0 = 逐位等价旧行为"的注释假设相反）。
	# 实测证据（`classic+s3@7 seed1`，同板、同机、独占、冷热各一次）：
	#   · 09-27 19:3x 基线（无排序，`_golden_post_p0.jsonl`）：`prune_tries=29 / prune_ok=22 /
	#     t_prune=53.3s`，5/5 产出；
	#   · 加入排序后：`27 / 20 / 打满 90s` ⇒ 0/5 空返回 + `prune_timeout=1` + `verify_fail=1`；
	#   · 同机 `o4@6` 反而 ×0.81（更快）⇒ 已排除机器/C# 后端（dll 与 solver 均停在 14:55 未重建）。
	# 故 order==0 不做任何排序 = 旧路径逐位等价；策略 1/2/3 才排序（其收益必须自行 A/B）。
	if prune_order != 0:
		keys.sort_custom(func(a, b): return _prune_less(a, b, values, active))
	var state := {"target": target_difficulty, "reached": false, "tries": 0, "ok": 0, "prune_timeout": false}
	# A1-ii（2026-09-27）：全量线索集 A 的「卡住即 no-op」短路。
	#
	# 定理（单调性）：设 A = 全量 active、B ⊆ A，同口径（masked={}）。序贯演绎逐轮归纳可得
	#   forced_B(r) ⊆ D_A(r)（B 约束更少 ⇒ 模型集更大 ⇒ 蕴含的事实更少）。
	# 推论：A 在某轮「真·无强制格」而失败 ⇒ 任何 B⊆A 同轮（或更早）也失败 ⇒ 删除试探
	#（每次都在 A 的某个子集上跑）全部失败 ⇒ 逐条试探最终一条也删不掉、active 一字不动。
	# ⇒ 直接返回，产出与旧逐条试探**逐字节相同**，省掉 O(n) 次完整演绎。
	#
	# ⚠ 只有 false 的原因是「真·无强制格」时才可短路：预算耗尽（deadline / C# 累计探测预算 /
	#   单次 Solve 超时）时对 A 能否推完**一无所知**，一律按旧路径继续，**严禁**短路。
	#   「真·无强制格」的判定在 `_solve_rules_stepwise`（只在可证明未被预算截断时置 `stuck`）——
	#   这是本优化正确性的核心。
	# 预跑本身受同一 `deadline` 约束（墙钟绝对时刻，不存在重复扣预算的问题）；预跑成功时其结果
	# 无法复用到循环（循环首次演绎是在 A\{keys[0]} 上、集合不同），故不省这一次演绎。
	# 【(i) ①+② 合并（2026-09-28）】`prune_noop_shortcut` 现在是**合并开关**：
	# **同一次**全集演绎（即下面这次预跑）同时产出两样东西——
	#   ② 卡住判据：A 真·无强制格 ⇒ 由单调性定理，任何子集 B⊆A 同轮必卡住 ⇒ 整个 prune 必为 no-op
	#      ⇒ 直接返回（`active` 一字不动，与逐条试探**逐字节相同**）；
	#   ① 逐轮白名单 ∪D_A(r)：D_A(r) 之外的格在候选 B 上必不强制 ⇒ 候选只探测白名单内的格
	#      ⇒ **输出逐格相等**，少做 O(|free|−|D_A|) 次 assumption 探测。
	# 合并的意义：原先只做 ② 时，"未触发即净亏 +5.7%"（A1 实测）⇒ 默认关；合并后预跑成本被 ①
	# 的削减摊销，② 变成顺带白得。**是否默认开仍由产线聚合压缩比决定**（见 §14 / §20）。
	if (prune_noop_shortcut or prune_probe_whitelist) and not keys.is_empty() and active.size() > 1:
		var pre_stats := {"rounds": []}
		if prune_probe_whitelist:
			pre_stats["forced_sets"] = []
		var t_pre0 := Time.get_ticks_msec()
		var pre_ok := _solve_rules_stepwise(grid_size, active, {}, total_mines, oracle, values, pre_stats, deadline)
		state["pre_ms"] = Time.get_ticks_msec() - t_pre0
		if not pre_ok and bool(pre_stats.get("stuck", false)):
			state["prune_skip_stuck"] = true
			state["prune_skipped"] = int(state.get("prune_skipped", 0)) + 1
			return state
		if pre_ok and prune_probe_whitelist:
			# ⛔ 实测**不等价**（`o4+s1@8` 出现 ok 31→30）且更慢 ⇒ 仅由独立开关 `prune_probe_whitelist`
			# 控制，**与 ②（卡住即 no-op）解耦**，防止启用 ② 时连带启用这条不成立的优化。
			# 逐轮白名单 D_A(r) 直接交给候选侧按轮取用（**不要**并集化：并集在可推完的盘上等于全集 ⇒ 收益归零）。
			state["probe_sets"] = pre_stats.get("forced_sets", [])
			state["wl_sets"] = (pre_stats.get("forced_sets", []) as Array).size()
	_prune_sequential(oracle, active, keys, deadline, grid_size, total_mines, values, state, masked)
	return state


## 顺序删除（P0-性能优化·实测胜出）：逐条尝试删除，每条 1 次验证，O(n) 次验证。
## 实测对比旧二分删块（最坏 ~2n 次验证）：8×8 26雷 顺序 8.0s/9 线索 vs 二分 16.2s/10 线索——
## 40% 密度下大部分线索必要（删不掉），二分退化成 ~2n 次验证反而更慢；顺序删除快 ~2 倍且
## 线索数更少（质量不降反升）。删除顺序与旧实现同为「行优先排序」，确定性一致。
func _prune_sequential(oracle: RuleOracle, active: Dictionary, keys: Array, deadline: int,
		grid_size: Vector2i, total_mines: int, values: Dictionary, state: Dictionary, _masked: Dictionary = {}) -> void:
	for p in keys:
		if bool(state["reached"]):
			return
		if Time.get_ticks_msec() > deadline:
			# 墙钟兜底触发：**非确定性判停**（负载影响删减数量 ⇒ 重跑波动，
			# 实测同一批数据重跑后 ani_crab 从可推变不可推）。记录到 state 供上层
			# 写入 last_call_stats 并打 warning 留痕——缺口必须可见，不能静默截断。
			# 【2026-09-27 进度】根治的另一半「删减顺序按信息量排序」已实现（prune_order 旋钮，
			# 默认 0 = 行优先保持旧行为）；「判停改步数/迭代数」仍未做——但它只影响重跑波动，
			# 不影响单次产出质量，优先级低于窗口命中率。
			state["prune_timeout"] = true
			return
		# 保底：至少保留 1 条线索。全局约束自带开局信息的组合（如 mx+dt：骨牌外强制非雷
		# + 镜像锁死骨牌内选择 → 无线索即可序贯推完）会把线索全部删光，被上层
		# active.is_empty() 拒绝整个 attempt，白白浪费可行盘（实测 mx_dt 5×5 0/12 全灭于此）。
		if active.size() <= 1:
			return
		state["tries"] = int(state["tries"]) + 1
		var backup: Variant = active[p]
		active.erase(p)
		# 序贯可解保持（R01 真义）：删除后仍能序贯纯逻辑推出全雷才保留删除。
		# 遮蔽前置（方向 1）：注意判定**忽略遮蔽**（传 {}）——实测（2026-09-16 交叉验证）：
		# 若把遮蔽弱区间带入判定，任何删除都会判定失败 → 线索全保留（clue_ratio=1.0）、
		# 盘退化为「全线索」（既无删减也谈不上难度提升）。遮蔽格只受「不许删」保护（keys 排除），
		# 删减逻辑按精确线索口径找最小充分集——这才是前置的设计意图（选格前移 + MSC 照常重建）。
		var stats := {"rounds": []}
		# 【(i)①（09-28）】带上传入的**逐轮**白名单（由 `_prune_clues_rules` 的全集预跑采集）；
		# 缺省不设该键 = 旧行为（全探测）。
		if state.has("probe_sets"):
			stats["probe_sets"] = state["probe_sets"]
		# 传 deadline：删线索是 O(n) 条循环，只有让每次演绎都能被墙钟截断，
		# 上方 `Time.get_ticks_msec() > deadline` 才真正有效（否则单条线索就能冲出界）。
		if _solve_rules_stepwise(grid_size, active, {}, total_mines, oracle, values, stats, deadline):
			state["ok"] = int(state["ok"]) + 1
			if float(state["target"]) > 0.0:
				var d := float(difficulty_from_stats(stats)["difficulty"])
				if d >= float(state["target"]):
					state["reached"] = true
			continue  # 删除成立，保留
		active[p] = backup  # 必要线索，恢复


## 纯逻辑序贯演绎（无 Board 依赖）：每轮用 CP-SAT forced-cell 检测「被强制的格」，
## 翻安全格（新线索进 active）→ 确认雷 → 直到全盘确定（胜）或某轮无强制格（真二选一，败）。
## 这是替代「全盘枚举」的关键：序贯求解每次只做 O(自由格数) 次 assumption 探测。
func _minimal_clue_count(oracle: RuleOracle, cur_active: Dictionary, known_mines: Array[Vector2i], masked: Dictionary, target: Vector2i, _total_mines: int, deadline_ms: int = 0) -> int:
	if cur_active.is_empty():
		return 0
	# unsat_core 方案：直接求「推出 target 格」所需的最少线索数（见 rule_cpsat.minimal_clue_count_unsat）。
	# 实测显著优于移除顺序敏感的贪心（大盘 45 线索时贪心 11 vs unsat 2），且更快（一次 Solve vs O(N) 次）。
	# 无 C# 后端时返回 -1 → 0（难度画像退化，主路径依赖 C# 后端）。
	var spec := oracle.build_spec(cur_active, known_mines, masked)
	if deadline_ms > 0:
		var remain := deadline_ms - Time.get_ticks_msec()
		if remain <= 0:
			return 0  # 预算耗尽：不做 unsat_core（复杂度记 0，宁可画像偏保守，不进无界求解）
		spec["core_budget_ms"] = clampi(remain, 500, maxi(500, oracle.core_budget_ms))
	var k := RuleCpSat.minimal_clue_count_unsat(spec, target.y, target.x)
	return k if k >= 0 else 0


## stats（可选出参，P0-难度量化）：非空时收集每轮推出格数 → stats["rounds"] = Array[int]，
## 及每轮必要线索数 → stats["complexities"] = Array[int]（精确复杂度）。
## 成本近零（演绎本就要跑），是「4 组难度常量」体系的数据基础。
##
## 这是生成器**内部**的 CP-SAT 强制格循环（直调 find_forced_cells，带难度统计）。
## 与 ProofLog.build（玩家视角 + HintSolver，canonical 落盘路径）同构但用途不同：
## 本函数以「生成期校验 + 难度采集」为目的直接信任自己的 known_mines，不落盘、不产生证明链。
##
## deadline_ms（v4.0 挂死治理，可选，0 = 不限）：本函数是**迭代调用** CP-SAT 的循环
## （每轮 1 次强制格探测 + 1 次必要线索数），且它自己被删线索 O(n) 条 × 每轮地调用——
## 只在上层 attempt 之间判墙钟永远判不住单次调用（实测单次可冲到数百秒）。
## 传入后：每轮按剩余预算收紧 C# 侧累计预算，耗尽即返回 false（按「推不动」拒绝本盘）。
## 保守方向不变：只会少推、不会误推，绝不产出坏关（R01/R02 不破）。
##
## stats["stuck"]（A1-ii，可选出参）：返回 false 时**仅当**原因是「真·无强制格」才置 true。
## false 有两类原因且必须可区分——① 真二选一（单调性可推出子集必失败，调用方可短路 prune）；
## ② 预算/超时截断（对「推不动」一无所知，调用方**不得**短路）。②绝不置位。判定依据见函数内注释。
func _solve_rules_stepwise(grid_size: Vector2i, active: Dictionary, masked: Dictionary, total_mines: int, oracle: RuleOracle, values: Dictionary, stats: Variant = null, deadline_ms: int = 0) -> bool:
	var cur_active := active.duplicate()
	var known_mines: Array[Vector2i] = []
	# 异形拓扑：真实格子数 = 拓扑 cell_count（洞格已在 build_spec 里固定为非雷，不参与演绎）
	var total_cells := oracle.topology.cell_count() if oracle.topology != null else grid_size.x * grid_size.y
	var steps := 0
	var max_active := 0
	while cur_active.size() + known_mines.size() < total_cells:
		steps += 1
		if steps > total_cells + 8:
			return false
		var spec := oracle.build_spec(cur_active, known_mines, masked)
		# 【(i)① 白名单（09-28）】stats["probe_sets"]（入参，可选）：**逐轮**白名单 D_A(r)。
		# 单调性定理（A ⊇ B ⇒ forced_B(r) ⊆ D_A(r)）保证 D_A(r) 之外的格在第 r 轮必不强制
		# ⇒ 输出**逐格相等**，只是少做原子探测。
		# ⚠ 必须**逐轮**用，不能退化成并集 ∪D_A：对"可推完"的盘 ∪D_A 就是全部自由格 ⇒ 收益归零
		#（实测：并集版在 o4@6 / o5x@7 / classic+s3@7 上与旧路径耗时一致）。轮次超出 A 的轮数
		#（D_A(r) 无定义）时**不写该键** ⇒ 自动退回全探测（完备性靠这条兜住）。
		if stats != null and stats is Dictionary:
			var psets: Array = stats.get("probe_sets", [])
			if not psets.is_empty():
				var rr: int = (stats.get("rounds", []) as Array).size()
				if rr < psets.size():
					spec["probe_cells"] = psets[rr]
		if deadline_ms > 0:
			var remain := deadline_ms - Time.get_ticks_msec()
			if remain <= 0:
				return false  # 预算耗尽：停止演绎（保守，按不可解拒绝）
			spec["probe_budget_ms"] = clampi(remain, 500, maxi(500, oracle.probe_budget_ms))
		# A1-ii：记录本次 find_forced_cells 的墙钟耗时与下发的预算，用于区分下面两种 false。
		var t_fc0 := Time.get_ticks_msec()
		var forced := RuleCpSat.find_forced_cells(spec)
		var fc_ms := Time.get_ticks_msec() - t_fc0
		# 【09-28 深度核实：① 的两个自检守卫】（仅在"本轮确实下发了白名单"时生效）
		if spec.has("probe_cells"):
			# 守卫 A：**dll 过旧** ⇒ 白名单被静默忽略（服务器 dll 未重建时正是此状态：特性变 no-op
			# 且无人察觉）。C# 侧启用白名单时会回写 `probe_filtered`，**缺键即"未生效"**。
			if not forced.has("probe_filtered") and not Engine.has_meta("i1_wl_unsupported"):
				Engine.set_meta("i1_wl_unsupported", true)
				push_warning("PuzzleGenerator: 白名单 probe_cells 未被 C# 侧接受（dll 过旧？）——本次白名单不生效；结果仍正确但无收益；启用 ① 前请先重建 dll")
			# 守卫 B：**预算绑定** ⇒ 白名单会**改变结论**（实测 tries/ok 23/19→25/20）⇒ 立刻停用。
			# `stats["probe_sets"]` 与 `state["probe_sets"]` 是**同一个 Array 引用** ⇒ clear() 会同时
			# 清掉 prune 级状态 ⇒ 后续每条候选自动退回全探测（等价性由此重新获得保障）。
			if bool(forced.get("budget_hit", false)):
				var ps_ref: Array = stats.get("probe_sets", [])
				ps_ref.clear()
				if not Engine.has_meta("i1_wl_budget_off"):
					Engine.set_meta("i1_wl_budget_off", true)
					push_warning("PuzzleGenerator: C# 探测预算绑定 ⇒ 白名单会改变结论，已停用白名单（本 prune 退回全探测）")
		if forced.is_empty():
			# 空结果有两个来源，**只有其一**能推出「任何子集同轮也卡住」（单调性定理）：
			#   ① 真·无强制格（真二选一）→ 可短路：stats["stuck"] = true；
			#   ② C# 侧探测被截断——累计 probe_budget_ms 耗尽（RuleSolver.FindForcedCells
			#      在循环顶 `ElapsedMilliseconds >= budget` 即 break）、单次 Solve 撞 8s 墙钟
			#      （Unknown 不当 Infeasible）、或首解超时 → 空只是预算/超时的产物，
			#      **对 A 能否推完一无所知** ⇒ 严禁当成 ①（否则可能把本可删线索的候选误判成
			#      「删不掉」，改产出、破坏等价性）。
			# 保守判据（只认能证明为 ① 的情形）：
			#   · 整调用耗时 < probe_budget_ms ⇒ 未 break ⇒ 全部自由格**都跑过探测**；
			#   · 整调用耗时 < timeout_ms(8s) ⇒ 无任何 Solve 返回 Unknown、首解也非超时。
			# 两者同时成立 ⇒ 每格都拿到了明确的 Feasible 结论 ⇒ 真·无强制格。
			# 任一不成立即不置位（保守方向：宁可不短路，也不改变产出）。
			var probe_budget := int(spec.get("probe_budget_ms", 30000))
			var solve_limit := int(spec.get("timeout_ms", 8000))
			if stats != null and stats is Dictionary and fc_ms < mini(probe_budget, solve_limit):
				stats["stuck"] = true
			return false  # 无强制格 → 真二选一（或被预算截断），拒绝本盘
		var progressed := false
		var pushed := 0
		var first_target := Vector2i(-1, -1)
		var active_before := cur_active.duplicate()
		var mines_before := known_mines.duplicate()
		max_active = maxi(max_active, active_before.size())
		for m in forced.get("mine", []):
			var pos := Vector2i(int(m[1]), int(m[0]))
			if not known_mines.has(pos):
				known_mines.append(pos)
				progressed = true
				pushed += 1
				if first_target.x < 0:
					first_target = pos
		for s in forced.get("safe", []):
			var pos := Vector2i(int(s[1]), int(s[0]))
			if not cur_active.has(pos):
				cur_active[pos] = values.get(pos, null)
				progressed = true
				pushed += 1
				if first_target.x < 0:
					first_target = pos
		if stats != null and stats.has("rounds"):
			stats["rounds"].append(pushed)
			# 【(i)①（09-28）】白名单采集：把本轮强制的格收集起来（调用方用 ∪D_A(r) 限制候选探测面）。
			# 用**并集**而非逐轮集合：并集是逐轮 D_A(r) 的超集 ⇒ 限制更弱但**依然完备**
			#（forced_B(r) ⊆ D_A(r) ⊆ ∪D_A），换来"白名单与轮次无关"的简单实现（无 r>K 退化分支）。
			if stats.has("forced_sets"):
				var fcells: Array = []
				for fm in forced.get("mine", []):
					fcells.append([int(fm[0]), int(fm[1])])
				for fsc in forced.get("safe", []):
					fcells.append([int(fsc[0]), int(fsc[1])])
				(stats["forced_sets"] as Array).append(fcells)
			# 必要线索数（精确复杂度）：用推进前的线索集，算「推出第一个格」所需的最少线索
			if stats.has("complexities") and first_target.x >= 0:
				var cplx := _minimal_clue_count(oracle, active_before, mines_before, masked, first_target, total_mines, deadline_ms)
				stats["complexities"].append(cplx)
		if not progressed:
			return false
	if stats != null and stats.has("rounds"):
		stats["max_active"] = max_active
	return true


## 难度画像（P0-难度量化）：从演绎统计算难度指标。
## 核心指标：
##   · difficulty = Σ(1/批量)：演绎紧凑度（雪崩低、抠题高）
##   · max_complexity = 最难一步的「必要线索数」（精确复杂度，对齐对标游戏的 MAX）
##   · histogram = 复杂度直方图，形如 "8x1,4x2,2x3"（对齐对标游戏 "4x2,3x1,2x1,1x4"）
## 返回 { difficulty, rounds, max_batch, max_complexity, profile, histogram }。
static func difficulty_from_stats(stats: Dictionary) -> Dictionary:
	var rounds: Array = stats.get("rounds", [])
	if rounds.is_empty():
		return {"difficulty": 0.0, "rounds": 0, "max_batch": 0, "max_complexity": 0, "profile": "", "histogram": ""}
	var difficulty := 0.0
	var hist := {}
	for r in rounds:
		var b := int(r)
		if b <= 0:
			continue
		difficulty += 1.0 / float(b)
		hist[b] = int(hist.get(b, 0)) + 1
	var keys: Array = hist.keys()
	keys.sort()
	keys.reverse()
	var parts: Array = []
	for k in keys:
		parts.append("%dx%d" % [int(k), int(hist[k])])
	# 复杂度直方图（精确版：每轮必要线索数，对齐对标游戏的 SolutionSummary 格式）
	var cplx: Array = stats.get("complexities", [])
	var c_hist := {}
	for c in cplx:
		c_hist[int(c)] = int(c_hist.get(int(c), 0)) + 1
	var c_keys: Array = c_hist.keys()
	c_keys.sort()
	c_keys.reverse()
	var c_parts: Array = []
	for k in c_keys:
		c_parts.append("%dx%d" % [int(k), int(c_hist[k])])
	return {
		"difficulty": snappedf(difficulty, 0.01),
		"rounds": rounds.size(),
		"max_batch": int(keys[0]) if not keys.is_empty() else 0,
		"max_complexity": int(c_keys[0]) if not c_keys.is_empty() else 0,
		"max_active": int(stats.get("max_active", 0)),
		"profile": ",".join(parts),
		"histogram": ",".join(c_parts),
	}


func _build_level_from_rules(clue_rule_id: String, global_rule_ids: Array, rows: int, cols: int, mines: Array[Vector2i], active: Dictionary, masked: Dictionary = {}, seed_value: int = 0, topology: GridInterface = null) -> Dictionary:
	var revealed: Array = []
	for pos in active:
		if masked.has(pos):
			var iv: Vector2i = masked[pos]
			revealed.append({"r": pos.y, "c": pos.x, "interval": [iv.x, iv.y]})
		else:
			revealed.append({"r": pos.y, "c": pos.x})
	var mines_arr: Array = []
	for m in mines:
		mines_arr.append({"r": m.y, "c": m.x})
	# seed 落盘：此前只在 stdout 打印，落盘后丢失，生成关无法追溯复现。
	var out := {
		"rule_level": true,
		"clue_rule": clue_rule_id,
		"global_rules": global_rule_ids.duplicate(),
		"size": {"rows": rows, "cols": cols},
		"total_mines": mines.size(),
		"mines": mines_arr,
		"revealed": revealed,
		"seed": seed_value,
	}
	# DT 骨牌底座化：落盘采样骨牌（Board 加载后做约束判定）。
	# 此前新管线不落盘 dominoes → 加载后 Board.dominoes 为空 → 约束判定失效。
	# 格式必须 {"c":..,"r":..}（与 mines/revealed 一致）——_parse_dominoes 只认 c/r 字典，
	# 直接放 Vector2i 会被结构防御全部过滤。
	if global_rule_ids.has("dt"):
		var dt: Object = RuleRegistry.default().resolve(&"dt")
		if dt != null and dt.get_dominoes().size() > 0:
			var d_arr: Array = []
			for d in dt.get_dominoes():
				var pair: Array = []
				for p in d:
					pair.append({"c": p.x, "r": p.y})
				d_arr.append(pair)
			out["dominoes"] = d_arr
	# 异形拓扑：落盘拓扑描述（positions + adjacency），供 Board 加载复现异形棋盘。
	# 隐藏态落盘（2026-09-16，HANDOFF 已知坑 #18）：有隐藏态的规则（o4/o5x 等）导出生成时
	# 状态 → Board.load_level 恢复。此前缺失 → 载盘后 compute_clue 用空/残留状态 → 线索
	# 数字全错（门禁踩雷、游戏内错数）。导出空字典的规则不写入（无隐藏态，零影响）。
	var hs := {}
	var clue_obj: Object = RuleRegistry.default().resolve(StringName(clue_rule_id))
	if clue_obj != null and clue_obj.has_method("export_hidden_state"):
		var st: Dictionary = clue_obj.call("export_hidden_state")
		if not st.is_empty():
			hs[clue_rule_id] = st
	# k 旋钮落盘（2026-09-16）：不公开盘标记——UI/展示侧据此隐藏 k 信息（公开档默认不写字段，零影响）。
	# 能力校验（复盘评审 C3）：优先 declares()，未声明时回退 has_method（向后兼容）。
	var caps: Dictionary = {}
	if clue_obj != null and clue_obj.has_method("declares"):
		caps = clue_obj.call("declares")
	var has_k_knob := bool(caps.get("k_knob", false)) or (clue_obj != null and clue_obj.has_method("is_k_public"))
	if has_k_knob and not bool(clue_obj.call("is_k_public")):
		out["k_public"] = false
	for gid in global_rule_ids:
		var g_obj: Object = RuleRegistry.default().resolve(StringName(gid))
		if g_obj != null and g_obj.has_method("export_hidden_state"):
			var gst: Dictionary = g_obj.call("export_hidden_state")
			if not gst.is_empty():
				hs[str(gid)] = gst
	if not hs.is_empty():
		out["hidden_state"] = hs
	if topology != null:
		out["topology"] = _topology_to_dict(topology)
	return out


## 拓扑 → 可落盘/可种子化的描述（positions + adjacency 边列表；带几何风格时追加 style / params）。
##
## L1 交叉说明（2026-09-21）：本处的去重键按**遍历序** (p, nb) 写 a/b，与
## core/shape_generator.gd 的 `_add_edge`（字典序 lo/hi）**顺序不同、集合语义相同**——
## 落盘边数与运行时边数一致由集合语义保证；不要断言两处 adjacency 数组逐字节相同。
##
## style/params 只在**来源确实是带风格的 AdjacencyGrid**（T4：ShapeGenerator 三族产出）时写出：
## 矩形关卡（RectGrid）与无风格的手写异形拓扑落盘格式**逐字节不变**——这是刻意的零变化约束，
## 免得给 40+ 个既有矩形关卡的 JSON 平白加两个字段。它们只影响渲染几何，读回时由
## AdjacencyGrid.setup_from_topo 消费（board.gd load_level → 异形分支），不影响任何拓扑语义。
static func _topology_to_dict(topo: GridInterface) -> Dictionary:
	var positions: Array = []
	for p in topo.all_positions():
		positions.append({"x": p.x, "y": p.y})
	var adjacency: Array = []
	var seen := {}
	for p in topo.all_positions():
		for nb in topo.get_neighbors(p):
			var rkey := "%d,%d|%d,%d" % [nb.x, nb.y, p.x, p.y]
			if seen.has(rkey):
				continue
			seen["%d,%d|%d,%d" % [p.x, p.y, nb.x, nb.y]] = true
			adjacency.append({"a": {"x": p.x, "y": p.y}, "b": {"x": nb.x, "y": nb.y}})
	var out := {"positions": positions, "adjacency": adjacency}
	# 几何风格（T4）：读了才写得出来。无 style / style == "custom" ⇒ 不写这两个键（旧格式零变化）。
	if topo is AdjacencyGrid:
		var ag := topo as AdjacencyGrid
		if ag.style != "custom":
			out["style"] = ag.style
			if not ag.style_params.is_empty():
				out["params"] = ag.style_params
	return out
