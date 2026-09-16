# puzzle_generator.gd —— 关卡生成器（文档 §4.4 全流程）
# 确定性布雷（仅种子 RNG）→ 逆向删线索 → 遮蔽 → 序贯纯逻辑可解验证。
# 全局约束型用专用布雷策略（镜像/骨牌/象限/端点/四色/行锁）；四象布雷统一委托规则平台 QdRule。
# 入口分流：生产一律走 generate_with_rules（规则平台底座，含异形拓扑 A2）；
# generate_constructive/mixed/dual/mixed_clue/from_def 为「内置变体枚举」遗留路径，
# 仅服务 archive/tools 与集成测试——新增能力请扩展规则平台，不要再扩展旧管线。
class_name PuzzleGenerator
extends RefCounted

const MAX_MINES_RATIO := 0.4  # 默认雷密度上限

var _rng := RandomNumberGenerator.new()

## 旧管线实例（2026-09 拆分：旧实现 + 旧布雷策略移入 PuzzleGeneratorLegacy）。
var _legacy := PuzzleGeneratorLegacy.new()

## C# CP-SAT 并行搜索 worker 数（0 = 用 C# 默认 4）。
## 分片批跑时应设 1：进程数 × 1 worker = 物理核数，避免 8 进程 × 4 worker 超额订阅互相抢核。
## 强制格结论与 worker 数无关（探测「假设反值不可行」与首解无关），降 worker 不改变任何质量/难度。
var num_workers: int = 0

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
		return {}
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


##（Def 路径旧实现已删除：generate_with_engine 现在委托 generate_with_rules，
##  Def 的 window/aggregate/op 由 _def_clue_to_rule / _def_constraint_to_rule 翻译成规则 id。）


##（Def 路径旧实现已删除：_make_board_from_def / _prune_clues_def / _solve_with_check /
##  _build_level_from_def 已随 _generate_def_impl 一并移除，生成统一走规则平台。）




# ============ 自举式规则平台生成路径（可组合 IR → CP-SAT，文档第二篇 §2 续） ============
# 与内置变体路径并存：规则（含第三方 mod 规则）走 RuleBuilder 可组合约束 IR；
# 唯一解删线索走 C# CP-SAT 快速计数（不可用时回退 GDScript 枚举）；
# 纯逻辑可解验证走 BruteForceOracle + RuleOracle 黑盒判定（既有管线零改动）。

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
	# 异形拓扑强制 classic（与 generate_with_rules 同口径，避免方向型线索在邻接表上矛盾）
	if topology != null and clue_rule_id != "classic":
		clue_rule = reg.resolve(&"classic")
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
## target_difficulty（P0-A，默认 0=不限制）：>0 时删线索改为「难度驱动」——
## 删到难度画像 difficulty 达标即停（早停=提速），同档关卡难度可控（固定 timeout 下难度波动可达 3 倍）。
func generate_with_rules(clue_rule_id: String, global_rule_ids: Array, size: Vector2i, mine_count: int, seed: int, mask_count: int = 0, attempts: int = 50, topology: GridInterface = null, timeout_ms: int = 15_000, target_difficulty: float = 0.0, mask_lo: int = 1, mask_strategy: int = 0, mask_pre: bool = false) -> Dictionary:
	var reg := RuleRegistry.default()
	var clue_rule: Object = reg.resolve(StringName(clue_rule_id))
	if clue_rule == null or clue_rule.get_kind() != RulePlugin.KIND_CLUE:
		return {}
	# 异形拓扑（A2）：邻域由邻接表定义，只有「邻域计数」语义（等价 classic）。
	# 方向型变体（4n/sc/knight/clock…）的 dirs 偏移在异形上无意义——正向用邻域计数、
	# 约束却用方向窗口，两者自相矛盾（表现为静默生成失败，不报错难排查）。
	# 故异形强制 classic：创作者拿到的仍是同一套底座，只是异形拓扑下邻域由邻接表决定。
	if topology != null and clue_rule_id != "classic":
		push_warning("PuzzleGenerator: 异形拓扑忽略线索规则 %s，强制 classic（邻域计数）" % clue_rule_id)
		clue_rule = reg.resolve(&"classic")
		if clue_rule == null:
			return {}
		# 落盘字段必须同步：否则 JSON 声明 knight、实际按邻域计数生成，
		# 造成「关卡自述」与「实际语义」分叉（Board 异形分支虽按邻接表算值不受影响，
		# 但 rule_clue_id 会误导后续复用与工坊展示）。
		clue_rule_id = "classic"
	var globals: Array = []
	for gid in global_rule_ids:
		var g: Object = reg.resolve(StringName(str(gid)))
		if g == null or g.get_kind() != RulePlugin.KIND_GLOBAL:
			return {}
		globals.append(g)
	var cols := size.x
	var rows := size.y
	# 异形拓扑（A2）：格子总数 = 拓扑 cell_count（不含洞格）；坐标范围 = 包围盒。
	var n := topology.cell_count() if topology != null else cols * rows
	if mine_count <= 0:
		mine_count = int(n * 0.3)
	mine_count = clampi(mine_count, 1, n - 1)
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	last_call_stats = {"attempts": 0, "brep_fail": 0, "no_clues": 0, "prune_empty": 0,
		"verify_fail": 0, "timeout": 0, "success": 0,
		"t_place_ms": 0, "t_prune_ms": 0, "t_verify_ms": 0, "prune_tries": 0, "prune_ok": 0}

	for attempt in attempts:
		# 种子派生：每 attempt 独立确定性随机流（同 seed+attempt 必同盘，可复现）。
		# attempts=1 即「固定种子单次尝试」——一颗种子 = 一次尝试，可复现零歧义。
		_rng.seed = _derive_seed(seed, attempt)
		last_call_stats["attempts"] = int(last_call_stats["attempts"]) + 1
		if Time.get_ticks_msec() > deadline:
			last_call_stats["timeout"] = int(last_call_stats["timeout"]) + 1
			push_warning("PuzzleGenerator: 规则生成超时 %s" % clue_rule_id)
			return {}
		# 1. 布雷：异形走拓扑随机；矩形走全局规则构造式（镜像/禁形）优先，否则线索规则，最后随机
		var t_place0 := Time.get_ticks_msec()
		var mines: Array[Vector2i]
		if topology != null:
			mines = _place_random_topo(topology, mine_count)
		else:
			mines = _place_mines_rules(clue_rule, globals, cols, rows, mine_count)
		last_call_stats["t_place_ms"] = int(last_call_stats["t_place_ms"]) + (Time.get_ticks_msec() - t_place0)
		if mines.is_empty():
			last_call_stats["brep_fail"] = int(last_call_stats["brep_fail"]) + 1
			continue
		var mine_set := {}
		for m in mines:
			mine_set[m] = true
		# 2. 全部非雷格为候选线索，正向计算线索值（异形走拓扑邻域计数，等价 classic）
		var values := {}
		var clue_cells: Array[Vector2i] = []
		var positions: Array = topology.all_positions() if topology != null else _rect_positions(rows, cols)
		for pos in positions:
			if mine_set.has(pos):
				continue
			var v: Variant
			if topology != null:
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
		var v_ok := _solve_rules_stepwise(size, active, masked, mine_total, oracle, values, diff_stats)
		last_call_stats["t_verify_ms"] = int(last_call_stats["t_verify_ms"]) + (Time.get_ticks_msec() - t_verify0)
		if not v_ok:
			last_call_stats["verify_fail"] = int(last_call_stats["verify_fail"]) + 1
			continue
		# 5. 输出（规则关卡 JSON；播放接线见 Board 集成，本路径先供生成/验证/工坊）
		var level := _build_level_from_rules(clue_rule_id, global_rule_ids, rows, cols, mines, active, masked, seed, topology)
		# 难度画像落盘（4 组难度常量体系的筛选依据；Board 加载不读，纯元数据）。
		# 线索覆盖度一并记录：对同尺寸同密度的题，线索越少玩家信息越少 = 越难。
		var prof := difficulty_from_stats(diff_stats)
		prof["clue_count"] = active.size()
		var total_cells := topology.cell_count() if topology != null else rows * cols
		var non_mine := maxi(1, total_cells - mine_total)
		prof["clue_ratio"] = snappedf(float(active.size()) / float(non_mine), 0.01)
		prof["target_difficulty"] = target_difficulty  # 生成标签（对标 L 字段：记录「照着哪档参数生成」）
		level["difficulty_profile"] = prof
		last_call_stats["success"] = 1
		return level
	return {}


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

func _find_solution_best(oracle: RuleOracle, cols: int, rows: int) -> Array[Vector2i]:
	var sols: Array = []
	for _i in SOLUTION_SAMPLES:
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
func _place_mines_rules(clue_rule: Object, globals: Array, cols: int, rows: int, count: int) -> Array[Vector2i]:
	var m := _place_mines_rules_raw(clue_rule, globals, cols, rows, count)
	if not m.is_empty() and m.size() != count:
		push_warning("PuzzleGenerator: 布雷器返回 %d 雷 ≠ 请求 %d（插件违约，已拒绝该布雷）" % [m.size(), count])
		return []
	return m


func _place_mines_rules_raw(clue_rule: Object, globals: Array, cols: int, rows: int, count: int) -> Array[Vector2i]:
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
						return mirrored
		var oracle := RuleOracle.new(clue_rule, globals, Vector2i(cols, rows), count, null)
		# 多解取优（v2.9.3）：find_solution 第一可行解结构差（堆簇）→ 删线索/序贯验证
		# 通过率低（PF/mx+pf 已用专用采样救活，其余多 G——如 rl+ep 9×9——仍受此影响）。
		return _find_solution_best(oracle, cols, rows)
	# 单 G：沿用构造式布雷（确定性、快）
	for g in globals:
		var m: Array[Vector2i] = g.place_mines(_rng, cols, rows, count)
		if not m.is_empty():
			return m
	# 构造式失败兜底：CP-SAT 直接求满足全局约束的布局。旧代码 fallback 到随机布雷，
	# 而随机布雷违反全局约束（如 PF 9×9=32雷，place_mines 300 次随机+过滤碰不到可行布局）
	# → 后续唯一解/序贯验证必失败，整个 attempt 白跑（实测 pf 9×9 接受率 0/12）。
	# 约束数学可行（is_feasible=Y）时 find_solution 必有解。
	if not globals.is_empty():
		var oracle_fb := RuleOracle.new(clue_rule, globals, Vector2i(cols, rows), count, null)
		var sol_fb := _find_solution_best(oracle_fb, cols, rows)
		if not sol_fb.is_empty():
			return sol_fb
	var m2: Array[Vector2i] = clue_rule.place_mines(_rng, cols, rows, count)
	if not m2.is_empty():
		return m2
	return _place_random(cols, rows, count)


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
	keys.sort_custom(func(a, b):
		var pa: Vector2i = a
		var pb: Vector2i = b
		if pa.y != pb.y:
			return pa.y < pb.y
		return pa.x < pb.x)
	var state := {"target": target_difficulty, "reached": false, "tries": 0, "ok": 0}
	_prune_sequential(oracle, active, keys, deadline, grid_size, total_mines, values, state, masked)
	return state


## 顺序删除（P0-性能优化·实测胜出）：逐条尝试删除，每条 1 次验证，O(n) 次验证。
## 实测对比旧二分删块（最坏 ~2n 次验证）：8×8 26雷 顺序 8.0s/9 线索 vs 二分 16.2s/10 线索——
## 40% 密度下大部分线索必要（删不掉），二分退化成 ~2n 次验证反而更慢；顺序删除快 ~2 倍且
## 线索数更少（质量不降反升）。删除顺序与旧实现同为「行优先排序」，确定性一致。
func _prune_sequential(oracle: RuleOracle, active: Dictionary, keys: Array, deadline: int,
		grid_size: Vector2i, total_mines: int, values: Dictionary, state: Dictionary, masked: Dictionary = {}) -> void:
	for p in keys:
		if bool(state["reached"]) or Time.get_ticks_msec() > deadline:
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
		if _solve_rules_stepwise(grid_size, active, {}, total_mines, oracle, values, stats):
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
func _minimal_clue_count(oracle: RuleOracle, cur_active: Dictionary, known_mines: Array[Vector2i], masked: Dictionary, target: Vector2i, total_mines: int) -> int:
	if cur_active.is_empty():
		return 0
	# unsat_core 方案：直接求「推出 target 格」所需的最少线索数（见 rule_cpsat.minimal_clue_count_unsat）。
	# 实测显著优于移除顺序敏感的贪心（大盘 45 线索时贪心 11 vs unsat 2），且更快（一次 Solve vs O(N) 次）。
	# 无 C# 后端时返回 -1 → 0（难度画像退化，主路径依赖 C# 后端）。
	var spec := oracle.build_spec(cur_active, known_mines, masked)
	var k := RuleCpSat.minimal_clue_count_unsat(spec, target.y, target.x)
	return k if k >= 0 else 0


## stats（可选出参，P0-难度量化）：非空时收集每轮推出格数 → stats["rounds"] = Array[int]，
## 及每轮必要线索数 → stats["complexities"] = Array[int]（精确复杂度）。
## 成本近零（演绎本就要跑），是「4 组难度常量」体系的数据基础。
##
## 这是生成器**内部**的 CP-SAT 强制格循环（直调 find_forced_cells，带难度统计）。
## 与 ProofLog.build（玩家视角 + HintSolver，canonical 落盘路径）同构但用途不同：
## 本函数以「生成期校验 + 难度采集」为目的直接信任自己的 known_mines，不落盘、不产生证明链。
func _solve_rules_stepwise(grid_size: Vector2i, active: Dictionary, masked: Dictionary, total_mines: int, oracle: RuleOracle, values: Dictionary, stats: Variant = null) -> bool:
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
		var forced := RuleCpSat.find_forced_cells(oracle.build_spec(cur_active, known_mines, masked))
		if forced.is_empty():
			return false  # 无强制格 → 真二选一，拒绝本盘
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
			# 必要线索数（精确复杂度）：用推进前的线索集，算「推出第一个格」所需的最少线索
			if stats.has("complexities") and first_target.x >= 0:
				var cplx := _minimal_clue_count(oracle, active_before, mines_before, masked, first_target, total_mines)
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
	if clue_obj != null and clue_obj.has_method("is_k_public") and not bool(clue_obj.call("is_k_public")):
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


## 拓扑 → 可落盘/可种子化的描述（positions + adjacency 边列表）。
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
	return {"positions": positions, "adjacency": adjacency}
