extends SceneTree

# spec_check.gd —— 「用户自建变体规格（spec v1）」的自助自检 CLI（只读；--register 时注册）
#
# 为什么要它：此前作者写完一个变体，唯一能拿到的反馈是「生成失败」。到底是不合语法、
# 依赖矩形几何、数学不可行、还是难度落在档外（永远不入库），平台一概不说。本工具把
# 这四件事分开回答，并用可行动的中文写清楚「接下来该改什么」。最后一行
# `__SPEC_VERDICT__ OK|WARN|FAIL <一句话>` 供脚本 / AI 抓取。
#
# 用法：
#   godot --headless --path . -s res://tools/spec_check.gd -- \
#       --spec=<json路径> [--board=<棋盘json>] [--sizes=5,6,7,8,9] [--mines=auto]
#       [--register] [--sample=N] [--generate[=N]] [--out-dir=<dir>] [--attempts=N] [--timeout=MS]
#
# 输出字段：
#   ① 可表达性      —— SpecSchema.validate 的结论 + warnings **逐条**打印（不能表达就到此为止）；
#                      **全部保持 INFO**（2026-10-01：原先只有「端到端缺口」那条升 WARN，
#                      但该缺口已修、对应 code `e2e_gap` 已退役 ⇒ 白名单现在为空；
#                      判级逻辑与文案兜底保留，便于将来引入新的"需要升级"的 code）。
#   ② 几何适配      —— 变体 geometry_kind × 目标棋盘 ⇒ 「可用 / 不适用（原因）」。绝不打印"不可行"
#   ③ 逐尺寸可行性  —— RuleFeasibility.resolve_mines_topo ⇒ {mines, standard, reason}
#   ④ 难度可达性    —— Difficulty.tier_of_peak 说明可能落在哪档；peak≤1 与 ≥21 明确「不进任何档」
#                      （--sample=N 才做实测采样，默认「未采样」，诚实标注）
#   ⑤ 直接产出      —— --generate[=N] 时：注册 spec → 生成 N 关/尺寸 → 落盘 user://（闭环）
#                      末行 __SPEC_GEN__ OK|FAIL <成功数>/<请求数> [档位分布]
#   ⑥ 结论行        —— __SPEC_VERDICT__ OK|WARN|FAIL <一句话>
#
# 落盘位置：默认 user://spec_gen/<spec_id>/spec_<尺寸>_<序号>.json。
# **不写 res://levels/**——那是已入库产物目录，用户自建产物不能混进去。
# 禁暴力（§13.5）：只调用生成器（构造式布雷 + CP-SAT 兜底），本文件不写随机重试 / 全枚举。
#
# 依赖的 API（本批与 impl-spec / impl-topo 一起落地）：
#   SpecSchema.validate(spec) -> {ok, errors, warnings}
#   SpecRulePlugin.from_json(text) -> {ok, errors, rule}; register_from_json(text); rule.spec_id()
#   RuleFeasibility.query_topo / resolve_mines_topo / board_key
#   RuleSignature.compat_all(ids, size, mines, cells)
#   RulePlugin.geometry_kind() -> 0 GEO_ADJ_GENERIC（任意棋盘）/ 1 GEO_RECT_ONLY（仅矩形）
#
# 退出必须走 CliShutdown（见 tools/cli_shutdown.gd:3-18）：直写 quit() 在 Godot 4.7.2 mono
# 下约 7/8 概率挂住。
const CliShutdown := preload("res://tools/cli_shutdown.gd")
const GEO_ADJ_GENERIC := 0
const GEO_RECT_ONLY := 1

var _verdict := "OK"          # OK < WARN < FAIL
var _reason := ""
var _gen_failed := false      # --generate 期间一关都没产出来（配合结论行给出 FAIL）


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var spec_path := ""
	var board_path := ""
	var sizes := [5, 6, 7, 8, 9]
	var sizes_given := false
	var mines_arg := "auto"
	var do_register := false
	var want_prompt := false
	var sample := 0
	var gen_requested := false
	var gen_n := 1
	var out_root := "user://spec_gen"
	var attempts := 50
	var timeout_override := 0
	for a in args:
		var s := str(a)
		if s.begins_with("--spec="):
			spec_path = s.substr("--spec=".length())
		elif s.begins_with("--board="):
			board_path = s.substr("--board=".length())
		elif s.begins_with("--sizes="):
			sizes = []
			sizes_given = true
			for t in s.substr("--sizes=".length()).split(",", false):
				if str(t).strip_edges() != "":
					sizes.append(int(t))
		elif s.begins_with("--mines="):
			mines_arg = s.substr("--mines=".length())
		elif s.begins_with("--sample="):
			sample = int(s.substr("--sample=".length()))
		elif s.begins_with("--out-dir="):
			out_root = s.substr("--out-dir=".length())
		elif s.begins_with("--attempts="):
			attempts = maxi(1, int(s.substr("--attempts=".length())))
		elif s.begins_with("--timeout="):
			timeout_override = int(s.substr("--timeout=".length()))
		elif s == "--generate" or s.begins_with("--generate="):
			gen_requested = true
			if s.contains("="):
				gen_n = clampi(int(s.substr("--generate=".length())), 1, 20)
		elif s == "--register":
			do_register = true
		elif s == "--prompt":
			want_prompt = true
	if want_prompt:
		# --prompt：只打印「给 AI 的提示词」后退出（零代码路径的 CLI 入口）。
		# 与编辑器「AI 帮我写」页复制出来的内容是**同一份**（core/spec_helper.gd::ai_prompt），
		# 所以命令行用户 / 另一个 AI 拿到的规则说明不会和界面里说的不一致。
		print(SpecHelper.ai_prompt({}))
		_send("OK", "已输出「给 AI 的提示词」（粘给任意 AI → 拿回 JSON → 用编辑器「AI 帮我写」导入）")
		return
	if spec_path == "":
		print("用法: spec_check.gd -- --spec=<json路径> [--board=<棋盘json>] [--sizes=5,6,7,8,9] [--mines=auto] [--register] [--sample=N] [--generate[=N]] [--out-dir=<dir>] [--attempts=N] [--timeout=MS]")
		print("      spec_check.gd -- --prompt    # 只输出「给 AI 的提示词」（写规则时先发给 AI）")
		_send("FAIL", "缺少 --spec 参数")
		return

	print("=== spec 自检: %s ===" % spec_path)
	var text := _read_text(spec_path)
	if text == "":
		_send("FAIL", "无法读取 spec 文件（%s）" % spec_path)
		return
	# 宽容解析：用户很可能把 AI 的**整段回复**（带解释文字 / json 代码块 / 注释）存成文件再喂进来，
	# 而 `JSON.parse_string` 既读不懂这些、失败时还会往日志刷 ERROR（引擎错误会被 GUT 记成失败）。
	var ex: Dictionary = SpecHelper.extract_json(text)
	if not bool(ex["ok"]):
		_send("FAIL", "spec 不是合法 JSON 对象（%s）" % "；".join(_err_list(ex.get("errors", null))))
		return
	var spec: Dictionary = ex["data"]
	if str(ex["note"]) != "":
		print("（%s）" % str(ex["note"]))

	# ---- ① 可表达性 ----
	var vr: Dictionary = SpecSchema.validate(spec)
	if not bool(vr.get("ok", false)):
		print("① 可表达性: 不可表达")
		print("   %s" % _join_errors(vr.get("errors", null)))
		_send("FAIL", "该规格超出 spec v1 表达力（见上方原因）——请改用 entry.gd 手写 RulePlugin")
		return
	print("① 可表达性: OK（在 spec v1 表达力内）")
	# warnings 承载两类信息（邻居索引键语义 / K 覆盖度）+ 一条「矩形正向无意义」——逐条打印，不折叠。
	# 判级：白名单**为空** ⇒ 全部保持 INFO。原先把「端到端缺口」升为 WARN，但该缺口已于
	# 2026-10-01 修复（加载/显示与验收 round-trip 都已接 compute_clue_topo），对应 code `e2e_gap`
	# 不再产生；`_warning_is_e2e_gap` 保留只是向后兼容旧产物，不要据此以为缺口还在。
	var warns := _err_list(vr.get("warnings", null))
	# 可选平行键 `warning_codes`（impl-spec 追加，与 warnings **同序同长**）：有就按 code 判级，
	# 没有就退回文案判据（_is_e2e_gap）——两种情况下本工具都能跑，不会因对方没落而失效。
	var codes := _err_list(vr.get("warning_codes", null))
	for i in warns.size():
		var w := str(warns[i])
		var code := str(codes[i]) if i < codes.size() else ""
		print("   [提醒]%s %s" % ["（%s）" % code if code != "" else "", w])
		if _warning_is_e2e_gap(code, w):
			_note("WARN", "收到已退役的 code `e2e_gap`（端到端缺口已于 2026-10-01 修复，现行校验器不再产生它）")

	# 先编译再注册：SpecSchema.validate 会做「id 未被注册」检查，注册后再 from_json 会把自己
	# 判成"id 已被注册"而失败。顺序固定为 validate → from_json → register_from_json。
	# 传的是**提取出来的规格文本**（不是原始文件文本）：文件里可以带 AI 的解释文字与围栏，
	# 编译与注册只认那份 JSON，否则"宽容读文件"会变成半截功能（读了却能编译失败）。
	var spec_text := JSON.stringify(spec)
	var fr: Dictionary = SpecRulePlugin.from_json(spec_text)
	if not bool(fr.get("ok", false)):
		# 同一进程内重复运行（id 已注册）会让 validate 失败；此时退回注册表里的既有实例，
		# 而不是把"这条 spec 其实没问题"报成 FAIL。
		var existing := RuleRegistry.default().resolve(StringName(str(spec.get("id", ""))))
		if existing == null:
			print("   规格编译失败: %s" % _join_errors(fr.get("errors", null)))
			_send("FAIL", "规格编译失败（见上方 errors）")
			return
		print("   该 spec 已在注册表中（重复运行）：%s" % str(spec.get("id", "")))
		fr["rule"] = existing

	# ---- 注册（可选；--generate 时**必须**注册，否则生成器解析不到这条规则）----
	if gen_requested and not do_register:
		print("   [提示] --generate 需要规则在注册表里：本次自动注册（等价 --register）。")
	if do_register or gen_requested:
		var rr: Dictionary = SpecRulePlugin.register_from_json(spec_text)
		if not bool(rr.get("ok", false)):
			# 已注册（同一进程重复跑）不算失败：规则已在表里，生成照常可用。
			var probe := RuleRegistry.default().resolve(StringName(str(spec.get("id", ""))))
			if probe != null:
				print("   该 spec 已在注册表中（重复运行）：%s" % str(spec.get("id", "")))
			else:
				print("   注册失败: %s" % _join_errors(rr.get("errors", null)))
				_send("FAIL", "注册失败（见上方 errors）")
				return
		else:
			print("   已注册变体 id: %s" % str(rr.get("id", "")))

	var rule: Object = fr.get("rule", null)
	var clue_id := String(rule.spec_id()) if rule != null else str(spec.get("id", ""))
	# 规格的 globals 是**规则内部的 IR 约束**（core/spec_rule_plugin.gd:157-164），不是外部算子 id
	# ⇒ 判据调用一律传空 globals；这里只报告条数供作者核对。
	var spec_globals: Array = spec.get("globals", []) if spec.get("globals", []) is Array else []
	var gk := int(rule.geometry_kind()) if rule != null else GEO_ADJ_GENERIC
	print("   变体: clue=%s spec.globals=%d 条（内部 IR）geometry_kind=%d（%s）" % [
		clue_id, spec_globals.size(), gk,
		"任意棋盘可用" if gk == GEO_ADJ_GENERIC else "仅矩形几何"])
	# 未注册 ⇒ RuleFeasibility 对未知规则**乐观放行**（core/rule_feasibility.gd 的 unknown → true），
	# 结论会假性全绿。必须显式告知，否则作者会拿一份乐观报告去排查真实的无解组合。
	if RuleRegistry.default().resolve(StringName(clue_id)) == null:
		print("   [提示] 该 spec 尚未注册：可行性查询对未知规则乐观放行（恒 true）。")
		print("          加 --register 注册后复检，才能得到真实结论。")
		_note("WARN", "spec 未注册，可行性结论为乐观放行")

	# ---- 目标棋盘 ----
	var board_topos: Array = []
	if board_path != "":
		var bv: Variant = _read_json(board_path)
		if not (bv is Dictionary):
			_send("FAIL", "无法读取棋盘 JSON（%s）" % board_path)
			return
		var bg := AdjacencyBuilder.from_topo_dict(bv)
		if bg == null:
			_send("FAIL", "棋盘构建失败（%s）" % board_path)
			return
		board_topos.append({"label": board_path.get_file(), "topo": bg, "side": maxi(bg.size().x, bg.size().y)})
	else:
		for side in sizes:
			var tg := AdjacencyBuilder.from_tiling("rect", {"rows": int(side), "cols": int(side)})
			if tg == null:
				continue
			board_topos.append({"label": "%dx%d(矩形)" % [int(side), int(side)], "topo": tg, "side": int(side)})

	# ---- ②③ 逐棋盘：几何适配 + 可行性 ----
	print("② 几何适配 / ③ 逐尺寸可行性:")
	var any_feasible := false
	var infeasible_labels: Array = []
	for rec in board_topos:
		var topo: GridInterface = rec["topo"]
		var rect := _is_rectangular(topo)
		if gk == GEO_RECT_ONLY and not rect:
			# 「不适用」不是「不可行」：这条措辞是刻意的，避免把能力声明误读成数学结论。
			print("   [%s] 不适用（原因：该变体声明依赖矩形几何，geometry_kind=GEO_RECT_ONLY）" % rec["label"])
			_note("WARN", "%s 上该变体不适用（依赖矩形几何）" % rec["label"])
			continue
		var rr2: Dictionary = RuleFeasibility.resolve_mines_topo(clue_id, [], topo)
		var mines := int(rr2.get("mines", -1))
		var standard := bool(rr2.get("standard", false))
		var reason := str(rr2.get("reason", ""))
		print("   [%s] resolve_mines_topo -> {mines: %d, standard: %s, reason: \"%s\"}" % [
			rec["label"], mines, str(standard), reason])
		if mines_arg != "auto":
			var want := int(mines_arg)
			var ok := RuleFeasibility.query_topo(clue_id, [], topo, want)
			print("        --mines=%d -> query_topo = %s" % [want, str(ok)])
			if not ok:
				infeasible_labels.append("%s(--mines=%d)" % [rec["label"], want])
				_note("WARN", "%s 指定雷数 %d 不可行" % [rec["label"], want])
				continue
			mines = want
		if mines < 0:
			infeasible_labels.append(rec["label"])
			_note("WARN", "%s 数学不可行（全候选雷数 UNSAT）" % rec["label"])
			continue
		any_feasible = true
		# 结构性不可达警告（两两 / 合并整除约束），与 CP-SAT 真值互为补充。
		# 规格是单条规则（globals 是规则内部 IR）⇒ ids 只有它自己，此处主要捕捉「异形盘上
		# 几何依赖约束」的 WARN 原因（core/rule_signature.gd:202-241），理由不含「不可行」。
		var ids: Array[String] = [clue_id]
		var comp: Dictionary = RuleSignature.compat_all(ids, Vector2i(int(rec["side"]), int(rec["side"])),
				mines, topo.cell_count())
		var verdict := str(comp.get("verdict", "ok"))
		print("        compat_all -> %s %s" % [verdict, str(comp.get("reason", ""))])
		if verdict == RuleSignature.FORBID:
			_note("WARN", "%s 结构性不可达：%s" % [rec["label"], str(comp.get("reason", ""))])
		elif verdict == RuleSignature.WARN:
			print("        （结构性警告：需 CP-SAT 可行性复核）")
		# 棋盘指纹（缓存键，便于作者核对两次自检是否同一块盘）
		print("        board_key: %s" % RuleFeasibility.board_key(topo))

	# ---- ④ 难度可达性 ----
	print("④ 难度可达性（政策：Difficulty.PEAK_WINDOWS）:")
	print("   %s | %s | %s" % [Difficulty.tier_text("easy"), Difficulty.tier_text("normal"), Difficulty.tier_text("hard")])
	print("   peak ≤ 1 或 ≥ 21 不进任何档（不会入库）")
	if sample <= 0:
		print("   未采样（加 --sample=N 可跑 N 个候选的实测峰值直方图）")
	else:
		_sample_peaks(board_topos, clue_id, sample, mines_arg)

	# ---- ⑤ 直接产出（闭环）：写 spec → 直接出关卡 ----
	if gen_requested:
		var gen_topos := board_topos
		if not sizes_given and board_path == "":
			# 产出的默认尺寸（6,7）与自检的默认尺寸（5..9）刻意分开：自检要覆盖全档位才能
			# 说清难度可达性；产出优先取「有档位、单关成本可控」的两档。
			gen_topos = []
			for side2 in [6, 7]:
				var tg2 := AdjacencyBuilder.from_tiling("rect", {"rows": int(side2), "cols": int(side2)})
				if tg2 != null:
					gen_topos.append({"label": "%dx%d(矩形)" % [int(side2), int(side2)],
							"topo": tg2, "side": int(side2)})
		print("⑤ 直接产出（--generate=%d，落盘 %s）:" % [gen_n, out_root.path_join(clue_id)])
		_generate(gen_topos, clue_id, gk, gen_n, mines_arg, out_root, attempts, timeout_override)

	if _gen_failed:
		_send("FAIL", "spec 可表达，但一关都没产出来（见上方 __SPEC_GEN__ 与 last_call_stats）")
		return
	if not any_feasible and board_topos.size() > 0:
		_send("FAIL", "所有尺寸 / 棋盘均不可行")
		return
	if not infeasible_labels.is_empty():
		_send("WARN", "部分尺寸不可行：%s" % ", ".join(infeasible_labels))
		return
	_send(_verdict, _reason if _reason != "" else "规格可表达、几何适配、可行性通过")


## 直接产出：对每个棋盘 × N 个 seed 调生成器，成功即落盘 user://。
## **禁暴力**（§13.5）：只做「求解一个 CP-SAT 模型」（生成器内部的构造式布雷 + 求解兜底），
## 本函数不写随机重试 / 全枚举——失败就如实报 last_call_stats，让用户自己判断是规则还是规模问题。
func _generate(board_topos: Array, clue_id: String, gk: int, n: int, mines_arg: String,
		out_root: String, attempts: int, timeout_override: int) -> void:
	if not RuleCpSat.available():
		print("   生成跳过：CP-SAT 后端不可用（缺 .NET/mono 运行时）——生成必然为空。")
		print("__SPEC_GEN__ FAIL 0/0 CP-SAT 不可用")
		_gen_failed = true
		return
	var out_dir := out_root.path_join(clue_id)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var gen := PuzzleGenerator.new()
	gen.num_workers = 1
	var requested := 0
	var succeeded := 0
	var tier_hist := {}
	for rec in board_topos:
		var topo: GridInterface = rec["topo"]
		var side: int = int(rec["side"])
		# 几何不适用的盘**不生成**：生成器对「异形拓扑 + 非 supports_topology 的线索」会回退 classic
		# 并只发一条 warning，产物里的 clue_rule 会变成 "classic"——那是「自述与实际分叉」，
		# 宁可在这里明确跳过，也不产出名不副实的关卡。
		if gk == GEO_RECT_ONLY and not _is_rectangular(topo):
			print("   [%s] 跳过：该变体声明依赖矩形几何（不适用），生成会被静默回退成 classic" % rec["label"])
			continue
		var rr: Dictionary = RuleFeasibility.resolve_mines_topo(clue_id, [], topo)
		var mines := int(rr.get("mines", -1))
		if mines_arg != "auto":
			mines = int(mines_arg)
		if mines <= 0:
			print("   [%s] 跳过：无可用雷数（%s）" % [rec["label"], str(rr.get("reason", ""))])
			continue
		var timeout := timeout_override if timeout_override > 0 else maxi(30_000, side * side * 3000)
		for seed in range(1, n + 1):
			requested += 1
			var lv: Dictionary = gen.generate_with_rules(clue_id, [], Vector2i(side, side), mines,
					seed, 0, attempts, topo, timeout)
			if lv.is_empty():
				print("   [%s seed=%d] 空返回；last_call_stats=%s" % [
					rec["label"], seed, str(gen.last_call_stats)])
				continue
			succeeded += 1
			var prof: Dictionary = lv.get("difficulty_profile", {})
			var peak := int(prof.get("max_complexity", 0))
			var tier := Difficulty.tier_of_peak(peak)
			tier_hist[tier] = int(tier_hist.get(tier, 0)) + 1
			var path := out_dir.path_join("spec_%d_%02d.json" % [side, seed])
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				# 两空格：与仓库其余写 JSON 的工具（及 Python 侧 indent=2）统一
				f.store_string(JSON.stringify(lv, "  "))
				f.close()
			print("   [%s seed=%d] mines=%d revealed=%d clues=%d peak=%d tier=%s -> %s" % [
				rec["label"], seed, int(lv.get("total_mines", -1)),
				(lv.get("revealed", []) as Array).size(), int(prof.get("clue_count", -1)),
				peak, tier if tier != "" else "不进档", path])
	var dist: Array = []
	var tkeys: Array = tier_hist.keys()
	tkeys.sort()
	for k in tkeys:
		dist.append("%s:%d" % [str(k) if str(k) != "" else "不进档", int(tier_hist[k])])
	print("__SPEC_GEN__ %s %d/%d [%s]" % ["OK" if succeeded > 0 else "FAIL", succeeded, requested,
		" ".join(dist) if not dist.is_empty() else "无产出"])
	if succeeded == 0:
		_gen_failed = true


## 实测采样（可选，默认关）：口径与 tools/probe_peak_window.gd 一致（逐候选生成 → peak 直方图）。
## 成本受 --sample=N 控制；未采样时上层打印「未采样」，绝不拿猜测冒充实测。
func _sample_peaks(board_topos: Array, clue_id: String, n: int, mines_arg: String) -> void:
	if not RuleCpSat.available():
		print("   采样跳过：CP-SAT 后端不可用（缺 .NET/mono 运行时）——生成必然为空。")
		return
	var gen := PuzzleGenerator.new()
	gen.num_workers = 1
	var globals: Array = []
	for rec in board_topos:
		var topo: GridInterface = rec["topo"]
		var side: int = int(rec["side"])
		var mines := int(RuleFeasibility.resolve_mines_topo(clue_id, [], topo).get("mines", -1))
		if mines_arg != "auto" and mines >= 0:
			mines = int(mines_arg)
		if mines < 0:
			continue
		var hist := {}
		var empty := 0
		for seed in range(1, n + 1):
			var lv: Dictionary = gen.generate_with_rules(clue_id, globals, Vector2i(side, side), mines,
					seed, 0, 50, topo, 30_000)
			if lv.is_empty():
				empty += 1
				continue
			var peak := int((lv.get("difficulty_profile", {}) as Dictionary).get("max_complexity", 0))
			hist[peak] = int(hist.get(peak, 0)) + 1
		var keys: Array = hist.keys()
		keys.sort()
		var parts: Array = []
		var unreachable := false
		for k in keys:
			var tier := Difficulty.tier_of_peak(int(k))
			parts.append("%d:%d(%s)" % [int(k), int(hist[k]), tier if tier != "" else "不进档"])
			if tier == "":
				unreachable = true
		print("   [%s] 采样 %d 候选（空 %d）峰值直方图: %s" % [
			rec["label"], n, empty, " ".join(parts) if not parts.is_empty() else "（无有效关）"])
		if unreachable:
			_note("WARN", "%s 存在不进任何档的峰值（peak≤1 或 ≥21，不会入库）" % rec["label"])


# ==================== 工具 ====================

## 结论行 + 退出。verdict 只升不降（FAIL > WARN > OK）。
func _send(verdict: String, reason: String) -> void:
	var v := verdict
	if _verdict == "FAIL" or v == "FAIL":
		v = "FAIL"
	elif _verdict == "WARN" or v == "WARN":
		v = "WARN"
	else:
		v = "OK"
	print("__SPEC_VERDICT__ %s %s" % [v, reason])
	CliShutdown.request_exit(0 if v != "FAIL" else 1)


func _note(level: String, reason: String) -> void:
	if level == "FAIL":
		_verdict = "FAIL"
	elif level == "WARN" and _verdict != "FAIL":
		_verdict = "WARN"
	if _reason == "":
		_reason = reason


## errors / warnings 可能是 PackedStringArray（当前实现）或 Array —— 统一成 Array[String]，
## 避免 `as Array` 把 PackedStringArray 强转成 null 后静默丢原因。
func _err_list(v: Variant) -> Array:
	var out: Array = []
	if v is PackedStringArray:
		for e in (v as PackedStringArray):
			out.append(str(e))
	elif v is Array:
		for e2 in (v as Array):
			out.append(str(e2))
	elif v != null:
		out.append(str(v))
	return out


func _join_errors(errors: Variant) -> String:
	return " | ".join(_err_list(errors))


## 该条 warning 是否「端到端缺口」（唯一会升 WARN 的一类）。
## 优先用 impl-spec 提供的 `warning_codes`（与 warnings 同序同长）：**白名单**判定——只认
## `e2e_gap`，未知 code 一律保持 INFO（这样对方将来新增 code 不会把我们静默标黄）。
## 没有 codes 键时退回文案判据：文案含 "端到端" / "board.gd" / "verify_batch" 任一
## （impl-spec 承诺至少保留一个关键词；且三处 owner 修好后该告警会被删除、自然不再命中）。
func _warning_is_e2e_gap(code: String, text: String) -> bool:
	if code != "":
		return code == "e2e_gap"
	return text.contains("端到端") or text.contains("board.gd") or text.contains("verify_batch")


## 全矩形（Moore 8 邻的满格盘）：格数 == 包围盒面积。
func _is_rectangular(topo: GridInterface) -> bool:
	if topo == null or topo.cell_count() == 0:
		return false
	var sz := topo.size()
	return topo.cell_count() == sz.x * sz.y


func _read_text(path: String) -> String:
	var p := path
	if not p.begins_with("res://") and not p.begins_with("user://") and not p.is_absolute_path():
		p = "res://" + p
	if not FileAccess.file_exists(p):
		return ""
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t


func _read_json(path: String) -> Variant:
	var t := _read_text(path)
	if t == "":
		return null
	# 与 spec 文件同口径：宽容解析（棋盘 json 也可能是作者/AI 从对话里直接存下来的）
	var ex: Dictionary = SpecHelper.extract_json(t)
	return ex["data"] if bool(ex["ok"]) else null


func _process(_delta: float) -> bool:
	return CliShutdown.poll(self)
