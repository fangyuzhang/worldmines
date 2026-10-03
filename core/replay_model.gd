# replay_model.gd —— 推理链回放的「数据 + 窗口」模型（文档「六」推理链回放 + 「H 类」日志内存态）。
#
# 为什么单独成模块（不改 proof_log.gd、不碰 ui/*）：
#   · 文档要求「逐步回放求解器推导，每步显示依据（哪条线索 + 什么规则），点击定位格子」。
#     证明链的**数据**在 ProofLog 里（步骤 dict 由 ReasoningStep.to_dict() 产出），
#     但「怎么只渲染看得见的那几行」「这一步怎么读」是回放侧的职责，故独立成纯逻辑模型、可单测。
#   · H 类半盲区：数万步日志 + UI 一次性实例化数万个节点 = 编辑器直接卡死。
#     逃生口是**回放 UI 虚拟化**（只实例化视口内的行，滚动时回收）——
#     虚拟化要求「视口 → 行区间」的计算与 UI 彻底解耦，否则没法在无编辑器环境里验证。
#     本模块的 visible_range() 就是这段计算：**纯算术、不实例化任何节点**。
#   · 截断日志（ProofLog 数据侧已有 MAX_STEPS / MAX_BYTES）必须**如实透出**：
#     回放侧绝不能把「只剩前 N 步」当成「完整链」，否则呈现给玩家的推理链是错的。
#
# 纯逻辑硬约束（对齐 shape_dag.gd）：
#   · extends RefCounted，不 extends Node、不 preload 任何 ui/*、不产生场景节点。
#   · load() 对入参**只读**（持有引用，不复制、不修改）；除自身缓存外无副作用。
#   · 所有返回都可复现：给定相同入参与计数，窗口区间逐次一致。
class_name ReplayModel
extends RefCounted

## 已加载的步骤（ProofLog 的 `steps` 数组，元素是 ReasoningStep.to_dict() 的 dict）。
var _steps: Array = []
## 是否已 load 过（用于区分「空日志」与「从未加载」）。
var _loaded := false
## 截断信息缓存（load 时解析，step_at/UI 可直接读取，无需回看原 log）。
var _truncated := false
var _kept_steps := 0
var _dropped_steps := 0
var _reason := ""


## 从既有 ProofLog（字典）读取步骤。**只读**，不改入参。
## 返回 {ok, steps, truncated, kept_steps, dropped_steps, reason}：
##   · ok         —— 是否拿到一份可用日志（空字典 {} ⇒ false）；
##   · steps      —— 步骤数组（引用原日志数组；调用方勿改）；
##   · truncated  —— 原日志是否被截断（旧日志无该字段 ⇒ 按 false，正常日志）；
##   · kept_steps —— 保留步数：截断时优先取日志字段，缺失则退回 steps.size()；
##   · dropped_steps —— 被丢弃步数：截断时取日志字段，缺失退回 0；
##   · reason     —— **截断时保证非空**（truncated_reason 缺失也有兜底文案），
##                   未截断则透传日志自身的 reason（可空）。
func load(log: Dictionary) -> Dictionary:
	_steps = []
	_truncated = false
	_kept_steps = 0
	_dropped_steps = 0
	_reason = ""
	_loaded = true

	if log == null or log.is_empty():
		_reason = "空证明日志"
		return {"ok": false, "steps": [], "truncated": false,
			"kept_steps": 0, "dropped_steps": 0, "reason": _reason}

	var raw = log.get("steps", [])
	_steps = raw if raw is Array else []
	_truncated = bool(log.get("truncated", false))  # 旧日志无此字段 ⇒ false（正常日志）
	if _truncated:
		_kept_steps = int(log.get("kept_steps", _steps.size()))
		_dropped_steps = int(log.get("dropped_steps", 0))
		var why := str(log.get("truncated_reason", ""))
		if why == "":
			why = str(log.get("reason", ""))
		if why == "":
			why = "日志已截断（仅保留前 %d 步）" % _kept_steps
		_reason = why
	else:
		_kept_steps = _steps.size()
		_reason = str(log.get("reason", ""))

	return {"ok": true, "steps": _steps, "truncated": _truncated,
		"kept_steps": _kept_steps, "dropped_steps": _dropped_steps, "reason": _reason}


## 当前已加载步数（UI 用它给滚动条定长；空/未加载返回 0）。
func step_count() -> int:
	return _steps.size()


## 取第 index 步（0 基）。越界或未加载 ⇒ {ok:false, step:{}, reason:非空}。
func step_at(index: int) -> Dictionary:
	if not _loaded:
		return {"ok": false, "step": {}, "reason": "尚未加载证明日志"}
	if index < 0 or index >= _steps.size():
		return {"ok": false, "step": {},
			"reason": "索引越界：%d（共 %d 步）" % [index, _steps.size()]}
	var s = _steps[index]
	if not (s is Dictionary):
		return {"ok": false, "step": {},
			"reason": "第 %d 步不是字典（日志损坏？）" % index}
	return {"ok": true, "step": s, "reason": ""}


## 定高列表的虚拟化窗口（**纯算术，不实例化任何节点**）。
##
## 参数：scroll_y 滚动偏移(px)；viewport_h 视口高(px)；row_h 行高(px)；
##       overscan 视口上下各多缓冲的行数（防快速滚动露白）。
## 返回 {first, last, y_offset_of_first}（闭区间 [first, last]，两端都含）：
##   · first/last     —— 需要实例化的行下标区间；
##   · y_offset_of_first —— 第 first 行的**内容坐标**（= first * row_h；不含 scroll_y），
##                          UI 用它做容器偏移或顶部填充，而不必再乘一遍。
##
## 边界（一律不崩、返回可用值）：
##   · row_h<=0 / viewport_h<=0 / 未加载 / 无步骤 ⇒ {first:0, last:-1}（空区间，`range(first,last+1)` 不迭代）；
##   · scroll_y<0 ⇒ 视同上界 0（first 不越到列表上方）；
##   · scroll_y 超出末尾 ⇒ 视口行夹到最后一行，仍返回窗口（可能只剩末尾 overscan 行），不返回非法值。
## 不变量：有步骤且 row_h>0、viewport_h>0 时，恒有 0 <= first <= last <= step_count()-1。
func visible_range(scroll_y: float, viewport_h: float, row_h: float, overscan: int) -> Dictionary:
	var count := _steps.size()
	if count <= 0 or row_h <= 0.0 or viewport_h <= 0.0:
		return {"first": 0, "last": -1, "y_offset_of_first": 0.0}

	var top := maxf(scroll_y, 0.0)  # 负滚动夹到 0：列表上方没有内容可缓冲
	# 第一条与最后一条「与可视区 [top, top+viewport_h) 相交」的行。
	# 用 ceil 减 1 求末行：底边正好落在行边界时，那一行刚好处在可视区外（区间右开）。
	var v_first := clampi(int(floor(top / row_h)), 0, count - 1)
	var v_last := clampi(int(ceil((top + viewport_h) / row_h)) - 1, 0, count - 1)
	var first := maxi(0, v_first - overscan)
	var last := mini(count - 1, v_last + overscan)
	if last < first:
		last = first
	return {"first": first, "last": last, "y_offset_of_first": float(first) * row_h}


## 每步可读信息。**依据 = 哪条线索（sources）+ 什么规则（rule）**，全部从日志字段里取；
## 取不到的字段留空并把字段名记入 `missing`——不编造（宁可显示缺失，也不能给出假依据）。
##
## 返回 {title, evidence, rule_id, cells, missing}：
##   · title    —— 一行可读标题，如「确证雷 @ (3,1)（enumeration）」；
##   · evidence —— 依据串，如「依据线索 (0,0)、(1,0)；规则 classic；说明：…」；
##   · rule_id  —— 规则标识（step.rule），缺失为空串；
##   · cells    —— **顺序契约（UI 与测试按此写断言，勿改）**：
##                 ① 有 pos 时 `cells[0]` 恒 == 结论格 pos ⇒「点击定位」取 cells[0]；
##                 ② 其后按 `step.sources` 的**原顺序**追加依据线索格，重复坐标只保留首次出现；
##                 ③ pos 缺失时 cells 只含依据线索格（可空）；全部元素为 Vector2i。
##   · missing  —— 缺失字段名列表（如 ["sources","proof"]）；空步骤记 ["step"]。
func describe(step: Dictionary) -> Dictionary:
	var missing: Array = []
	var cells: Array[Vector2i] = []
	var title := ""
	var evidence := ""
	var rule_id := ""

	if step == null or step.is_empty():
		return {"title": "", "evidence": "", "rule_id": "",
			"cells": [], "missing": ["step"]}

	var pos: Vector2i = Vector2i.ZERO
	var has_pos := false
	var raw_pos = step.get("pos", null)
	if raw_pos is Array and (raw_pos as Array).size() >= 2:
		pos = Vector2i(int(raw_pos[0]), int(raw_pos[1]))
		has_pos = true
	else:
		missing.append("pos")

	var state := str(step.get("state", ""))
	if state == "":
		missing.append("state")
	var method := str(step.get("method", ""))
	if method == "":
		missing.append("method")
	rule_id = str(step.get("rule", ""))
	if rule_id == "":
		missing.append("rule")
	var proof := str(step.get("proof", ""))
	if proof == "":
		missing.append("proof")

	# 依据线索格：字段缺失或为空数组，都算「取不到依据」——不编。
	var sources: Array[Vector2i] = []
	var raw_src = step.get("sources", null)
	if raw_src is Array:
		for p in (raw_src as Array):
			if p is Array and (p as Array).size() >= 2:
				sources.append(Vector2i(int(p[0]), int(p[1])))
	if sources.is_empty():
		missing.append("sources")

	# cells：结论格在前（点击定位），依据线索格在后，去重。
	var seen := {}
	if has_pos:
		cells.append(pos)
		seen[pos] = true
	for p in sources:
		if not seen.has(p):
			seen[p] = true
			cells.append(p)

	var state_cn := "结论"
	match state:
		"safe":
			state_cn = "安全格"
		"mine":
			state_cn = "确证雷"
	title = "%s @ %s" % [state_cn, ("(%d,%d)" % [pos.x, pos.y]) if has_pos else "位置缺失"]
	if method != "":
		title += "（%s）" % method

	# evidence：只拼真实取到的字段，缺哪个由 missing 表达（不写"未知"之类的编造内容）。
	var parts: Array = []
	if not sources.is_empty():
		var ss: Array = []
		for p in sources:
			ss.append("(%d,%d)" % [p.x, p.y])
		parts.append("依据线索 " + "、".join(ss))
	if rule_id != "":
		parts.append("规则 " + rule_id)
	if proof != "":
		parts.append("说明：" + proof)
	evidence = "；".join(parts)

	return {"title": title, "evidence": evidence, "rule_id": rule_id,
		"cells": cells, "missing": missing}
