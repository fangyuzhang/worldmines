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


## 从关卡数据推导完整证明链。
## 返回 { "solved": bool, "rounds": int, "steps": Array[Dictionary], "reason": String }
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
	while rounds < max_rounds:
		if b.state != Board.GameState.PLAYING:
			break
		var steps: Array = solver.hint(b)
		if steps.is_empty():
			out["reason"] = "推不动了（本关在该状态下无必然结论）"
			break
		var applied := 0
		for st in steps:
			var step := st as ReasoningStep
			var cell: Cell = b.grid.get_cell(step.pos)
			if cell == null or cell.state != Cell.State.HIDDEN:
				continue  # 本轮内被前面的结论连带翻开/标记过
			all_steps.append(step.to_dict())
			if step.state == "safe":
				b.reveal(step.pos)
			elif step.state == "mine":
				# 登记「演绎确证的雷」再插旗：确证集要跨轮次保留，否则会丢信息导致假卡死
				b.mark_proven_mine(step.pos)
				b.toggle_flag(step.pos)
			applied += 1
			if b.state != Board.GameState.PLAYING:
				break
		rounds += 1
		if applied == 0:
			out["reason"] = "本轮无可应用结论（疑似重复结论）"
			break

	out["rounds"] = rounds
	out["steps"] = all_steps
	out["solved"] = b.state == Board.GameState.WON
	if out["solved"] and str(out["reason"]) == "":
		out["reason"] = "已推出全部格子"
	return out


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
static func verify(log: Dictionary, level: Dictionary) -> Dictionary:
	if log.is_empty():
		return {"ok": false, "reason": "证明日志为空", "expected": 0, "actual": 0}
	var saved: Array = log.get("steps", [])
	var fresh := build(level)
	var now: Array = fresh.get("steps", [])
	if saved.size() != now.size():
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
