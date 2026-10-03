# proof_log.gd —— 证明日志（GDD §6.2 / 25_HANDOFF「ProofLog 落盘」未实装项）
#
# 背景：`ReasoningStep.to_dict()` 早就存在，但**从来没有任何地方把它存下来**——
# 证明日志只有内存里的临时数组，对局结束即丢。
#
# 本模块把「一关是如何被一步步推出来的」变成**可落盘、可复验**的产物：
#   1. build()  —— 从关卡初始状态开始，每轮取提示的全部必然结论并应用，直到通关或卡住；
#   2. save_log()/load_log() —— 落盘为 user://proof/<key>.json；
#   3. verify() —— 重新推导一遍并与存档逐步比对（可复现性检验）。
#
# 用途：① 关卡质量证据（证明该关确实序贯可解，且给出完整推理链）；
#       ② CI / 离线批量的可复核产物；③ 复盘与教学素材。
#
# 注意：证明链本身**不读真实雷位**——每一步都由 HintSolver 从玩家视角约束推出，
# 因此这条链在「玩家视角」下是自洽的（这正是它可作为证明的原因）。
class_name ProofLog
extends RefCounted

const DIR := "user://proof"
## 单关最大推导轮数（防极端盘面下无限循环；一轮可含多个结论格）。
const MAX_ROUNDS := 500

## ==================== 单份日志的体积上限（数据侧，2026-10-03）====================
#
# 【为什么要有】此前只有 MAX_ROUNDS=500 的**轮数**限制，没有任何步数/字节上限：
# 一轮可含"整盘结论"（最坏 ≈ 格数），于是 500 轮 × 上千格可以撑出几十万步的日志，
# 落盘 JSON 与回放内存双双失控（编辑器回放 UI 没有虚拟化，本轮只治数据侧、不动 UI）。
#
# 【取值依据】
#   · MAX_STEPS = 5000：真实关卡单份链实测在"几十~一两百步"量级（`test_proof_log` 的 5x5 关仅数步），
#     5000 步已远大于任何能通过加载器上限（`WrapTopology.MAX_CELLS` = 4096 格）的真实关卡，
#     又足够小以免内存被撑爆。
#   · MAX_BYTES = 2 MiB：每步 ≈ 100~200B（pos + state + rule_id + precondition_signature 的 64 位 hex），
#     5000 步 ≈ 0.5~1MB；2MiB 留足余量，同时是单份日志的硬天花板。
#
# 【兼容旧数据】`truncated` / `kept_steps` / `dropped_steps` / `truncated_reason` 都是**新增可选字段**：
# 旧日志读回后没有它们 ⇒ 读侧一律按 `bool(log.get("truncated", false))` 取默认 false（正常日志）。
# 正常日志会**显式写入** `truncated = false`，便于调用方无脑读。
const MAX_STEPS := 5000
const MAX_BYTES := 2 * 1024 * 1024


## 从关卡数据推导完整证明链。
## 返回 { "solved": bool, "rounds": int, "steps": Array[Dictionary], "reason": String,
##        "cert_hash": String, "truncated": bool, ["kept_steps"/"dropped_steps"/"truncated_reason"] }。
## 尾部字段只在 `truncated == true` 时附带（见 MAX_STEPS / MAX_BYTES 的注释）。
static func build(level: Dictionary, max_rounds: int = MAX_ROUNDS) -> Dictionary:
	var out := {"solved": false, "rounds": 0, "steps": [], "reason": ""}
	if level.is_empty():
		out["reason"] = "空关卡数据"
		return out
	var b := Board.new()
	b.load_level(level)
	if b.grid == null:
		out["reason"] = "棋盘未建立"
		return out

	var all_steps: Array = []
	var solver := HintSolver.new()
	var rounds := 0
	var hit_step_cap := false
	while rounds < max_rounds:
		if b.state != Board.GameState.PLAYING:
			break
		var steps: Array = solver.hint(b)
		if steps.is_empty():
			out["reason"] = "推不动了（本关在该状态下无必然结论）"
			break
		# 本轮的玩家视角状态签名：这一批结论共享同一前提（GDD 13 号 precondition_signature）。
		var sig := signature(b)
		var applied := 0
		for st in steps:
			# 步数硬上限：到达即停止收集并标记截断（只保留**前缀**，后面不再追加 ⇒ 步序不乱）。
			if all_steps.size() >= MAX_STEPS:
				hit_step_cap = true
				break
			var step := st as ReasoningStep
			var cell: Cell = b.grid.get_cell(step.pos)
			if cell == null or cell.state != Cell.State.HIDDEN:
				continue  # 本轮内被前面的结论连带翻开/标记过
			var sd := step.to_dict()
			sd["precondition_signature"] = sig
			all_steps.append(sd)
			if step.state == "safe":
				b.reveal(step.pos)
			elif step.state == "mine":
				# 登记「演绎确证的雷」再插旗：确证集要跨轮次保留，否则会丢信息导致假卡死
				b.mark_proven_mine(step.pos)
				# 确证雷
				# 一旦被翻成
				# 该格若已被玩家插旗
				b.toggle_flag(step.pos, false)
			applied += 1
			if b.state != Board.GameState.PLAYING:
				break
		rounds += 1
		if hit_step_cap:
			break
		if applied == 0:
			out["reason"] = "本轮无可应用结论（疑似重复结论）"
			break

	out["rounds"] = rounds
	out["steps"] = all_steps
	out["solved"] = b.state == Board.GameState.WON
	if out["solved"] and str(out["reason"]) == "":
		out["reason"] = "已推出全部格子"
	# cert_hash：盘面内容哈希 ‖ 认证结果（GDD 13 号 §13.3，防「盘面被篡改却沿用旧认证」）
	out["cert_hash"] = (_canonical_level_hash(level) + "|" + str(out["solved"])).sha256_text()
	# 体积上限（步数 + 字节）：统一走 `apply_limits` 砍尾部、留前缀；截断信息写进日志。
	var limited := apply_limits(all_steps, {"solved": out["solved"], "cert_hash": out["cert_hash"]})
	out["steps"] = limited["steps"]
	out["truncated"] = bool(limited["truncated"]) or hit_step_cap
	if out["truncated"]:
		out["kept_steps"] = int(limited["kept_steps"])
		out["dropped_steps"] = int(limited["dropped_steps"])
		var why := str(limited["truncated_reason"])
		if why == "":
			why = "步数上限 %d" % MAX_STEPS
		out["truncated_reason"] = why
		if str(out["reason"]) == "":
			out["reason"] = "日志已截断（%s）：仅保留前 %d 步" % [why, int(out["kept_steps"])]
	return out


## 应用单份日志的体积上限，返回 `{steps, truncated, kept_steps, dropped_steps, truncated_reason}`。
## 【纯函数】不改入参 `steps`；截断**只砍尾部** ⇒ 保留的必定是**前缀**，步序与内容都不重排
##（回放与 `verify()` 都依赖"前 N 步 == 原链的前 N 步"这一点）。
## `extra` 用于把日志里除 steps 外的字段一并计入字节数（`build()` 传 solved/cert_hash）。
static func apply_limits(steps: Array, extra: Dictionary = {}) -> Dictionary:
	var total := steps.size()
	var kept: Array = steps
	var reason := ""
	if kept.size() > MAX_STEPS:
		kept = kept.slice(0, MAX_STEPS)
		reason = "步数上限 %d" % MAX_STEPS
	var base := extra.duplicate()
	base["steps"] = kept
	if _log_bytes(base) > MAX_BYTES:
		reason = "字节上限 %d" % MAX_BYTES
		# 二分找"最长的可行前缀"：JSON 大小随前缀单调不减 ⇒ 单调可二分，O(log n) 次序列化
		var lo := 0
		var hi := kept.size()
		while lo < hi:
			var mid := int((lo + hi + 1) / 2)
			var cand := extra.duplicate()
			cand["steps"] = kept.slice(0, mid)
			if _log_bytes(cand) <= MAX_BYTES:
				lo = mid
			else:
				hi = mid - 1
		kept = kept.slice(0, lo)
	return {
		"steps": kept,
		"truncated": reason != "",
		"kept_steps": kept.size(),
		"dropped_steps": total - kept.size(),
		"truncated_reason": reason,
	}


## 一份日志（或其中一部分）序列化后的 UTF-8 字节数——`MAX_BYTES` 的度量口径。
static func _log_bytes(d: Dictionary) -> int:
	return JSON.stringify(d).to_utf8_buffer().size()


## 关卡路径 → 存档 key（去掉目录与扩展名，并过滤 Windows 非法字符）。
static func key_for(level_path: String) -> String:
	var base := level_path.get_file()
	if base.ends_with(".json"):
		base = base.substr(0, base.length() - 5)
	if base.is_empty():
		base = "level"
	var safe := ""
	for i in base.length():
		var ch := base[i]
		if ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", " "]:
			safe += "_"
		else:
			safe += ch
	return safe


## 落盘。返回写入的完整路径；失败返回空串。
static func save_log(key: String, log: Dictionary) -> String:
	if key.is_empty():
		return ""
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := "%s/%s.json" % [DIR, key]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("ProofLog 写入失败: %s" % path)
		return ""
	f.store_string(JSON.stringify(log, "  "))
	f.close()
	return path


## 读取。不存在或损坏返回 {}。
static func load_log(key: String) -> Dictionary:
	var path := "%s/%s.json" % [DIR, key]
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		return parsed
	return {}


## 可复验性检验：重新推导一遍，与存档逐步比对（含结论格与结论类型）。
## 返回 { "ok": bool, "reason": String, "expected": int, "actual": int }
##
## 截断日志（`truncated == true`）只保证"前缀"：此时比到存档的步数为止，不因"存档少了尾巴"判红；
## 旧日志没有 `truncated` 字段 ⇒ 取默认 false，走原「逐步全比」路径（向后兼容）。
static func verify(log: Dictionary, level: Dictionary) -> Dictionary:
	if log.is_empty():
		return {"ok": false, "reason": "证明日志为空", "expected": 0, "actual": 0}
	var saved: Array = log.get("steps", [])
	var truncated := bool(log.get("truncated", false))
	var fresh := build(level)
	var now: Array = fresh.get("steps", [])
	if saved.size() != now.size():
		if not truncated or saved.size() > now.size():
			return {"ok": false, "reason": "步数不一致（存档 %d vs 重算 %d）" % [saved.size(), now.size()],
				"expected": saved.size(), "actual": now.size()}
	for i in saved.size():
		var a: Dictionary = saved[i]
		var c: Dictionary = now[i]
		if str(a.get("state", "")) != str(c.get("state", "")):
			return {"ok": false, "reason": "第 %d 步结论类型不一致" % (i + 1),
				"expected": saved.size(), "actual": now.size()}
		# 坐标必须按**数值**比较：JSON 没有整数类型，落盘再读回后 2 会变成 2.0，
		# 而 Godot 的数组比较对元素类型是严格的（[2] != [2.0]）→ 直接比数组会假失败。
		if not _same_pos(a.get("pos", []), c.get("pos", [])):
			return {"ok": false, "reason": "第 %d 步坐标不一致" % (i + 1),
				"expected": saved.size(), "actual": now.size()}
	if truncated and saved.size() < now.size():
		return {"ok": true, "reason": "前 %d 步一致（存档已截断）" % saved.size(),
			"expected": saved.size(), "actual": now.size()}
	return {"ok": true, "reason": "逐步一致", "expected": saved.size(), "actual": now.size()}


## 坐标数值等价（兼容 JSON 往返带来的 int → float）。
static func _same_pos(a: Variant, b: Variant) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	var pa: Array = a
	var pb: Array = b
	if pa.size() != 2 or pb.size() != 2:
		return false
	return int(pa[0]) == int(pb[0]) and int(pa[1]) == int(pb[1])


## 玩家视角棋盘状态的稳定签名（GDD 13 号 reasoning_chain 的 precondition_signature）。
## 只含玩家可知的信息：已翻开格的线索值 + 已演绎确证的雷；玩家插的**错旗**不计入。
## 用途：按盘面匹配证明链的「下一阶段」——玩家不按链操作（先翻别的格/插旗/撤销）时，
## 仍能凭签名匹配到适用的下一步，而不是线性回放必然失效。
static func signature(board: Board) -> String:
	var items: Array = []
	for pos in board.grid.all_positions():
		var cell: Cell = board.grid.get_cell(pos)
		if cell == null:
			continue
		if cell.state == Cell.State.REVEALED:
			items.append("r%d,%d%s" % [pos.x, pos.y, _con_sig(board.get_player_constraint(pos))])
		elif cell.state == Cell.State.FLAGGED and board.proven_mines.has(pos):
			items.append("m%d,%d" % [pos.x, pos.y])
	items.sort()
	return "|".join(items).sha256_text()


## 关卡内容规范哈希（雷位/翻开格排序后序列化），用于 cert_hash 防篡改。
static func _canonical_level_hash(level: Dictionary) -> String:
	var mines: Array = []
	for m in level.get("mines", []):
		mines.append([int(m["c"]), int(m["r"])])
	mines.sort()
	var revealed: Array = []
	for rc in level.get("revealed", []):
		revealed.append([int(rc["c"]), int(rc["r"])])
	revealed.sort()
	var canon := {"mines": mines, "revealed": revealed, "total_mines": int(level.get("total_mines", 0))}
	return JSON.stringify(canon).sha256_text()


## 线索值 → 签名片段（确定性，不依赖字典字段顺序）。
static func _con_sig(con: Dictionary) -> String:
	match str(con.get("type", "")):
		"equality":
			return "=%s" % str(con.get("value", ""))
		"interval":
			return "[%s,%s]" % [str(con.get("lo", "")), str(con.get("hi", ""))]
		"equality_pair":
			return "{%s,%s}" % [str(con.get("a", "")), str(con.get("b", ""))]
		_:
			return "?"  # 星号格 / 无线索格：只知道「已翻开」，不知道值


## 按盘面签名匹配证明链，返回「前提已满足且结论均未应用」的下一**阶段**的全部步骤（数组）。
## 一个阶段 = 同一前提下推出的一批结论（GDD 13 号 stage 语义）；整批应用后再进入下一阶段。
## 运行时回放离线链用；匹配不到返回空数组（调用方应退回运行时重算，如 CP-SAT 强制格检测）。
static func find_next(log: Dictionary, board: Board) -> Array:
	var sig := signature(board)
	var out: Array = []
	for s in log.get("steps", []):
		var d: Dictionary = s
		if str(d.get("precondition_signature", "")) != sig:
			continue
		var pos: Array = d.get("pos", [])
		if pos.size() != 2:
			continue
		var p := Vector2i(int(pos[0]), int(pos[1]))
		var cell: Cell = board.grid.get_cell(p)
		if cell == null or cell.state != Cell.State.HIDDEN:
			continue  # 该结论已被应用（或该格已翻开/标记）
		out.append(d)
	return out
