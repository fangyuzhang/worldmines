# submission_queue.gd —— 「认证提交入口」的**本地**提交队列（文档 §8 导入导出的最后一条）
#
# 文档要求：「认证提交入口（进官方审核队列，显示流转状态）」。
#
# 【本仓能诚实做到哪一步】仓库里没有网络层、没有账号体系、也没有官方审核服务（`开放平台实施框架.md`
# 仍是框架）。所以本模块做的是**入口 + 队列 + 流转状态**三件本地事实：
#   ① 提交：把关卡快照 + 备注入队，分配一个**内容指纹**命名的提交号（同一关卡重复提交看得见）；
#   ② 流转：pending → reviewing → approved / rejected，每一步都记时间与理由（历史不可篡改式追加）；
#   ③ 状态：UI 直接显示"当前有几条、各自到哪一步"。
#   真正的上传是**传输层**的事：本模块不假装联网、不把"已入队"说成"已提交官方"，
#   用户看到的文案是「已加入本地审核队列」——接入官方服务时只需把 `submit()` 的落地点换成传输层。
#
# 【落盘口径与编辑器其它写盘一致】`.tmp` + `rename_absolute` 原子替换（见 ui/level_editor.gd 的
# 手动保存与自动存档两处，同一套口径）；坏档一律当空队列处理并在返回值里说明，绝不半崩。
#
# 【纯逻辑 + 单一事实来源】状态机只在这一份表里；UI 不自己拼状态字符串。
class_name SubmissionQueue
extends RefCounted

const DEFAULT_PATH := "user://editor/_submissions.json"
const SCHEMA := "editor/submission/v1"

const PENDING := "pending"
const REVIEWING := "reviewing"
const APPROVED := "approved"
const REJECTED := "rejected"

## 状态 → 中文标签（UI 显示的唯一来源）。
const LABELS := {
	PENDING: "已入队（等审核）",
	REVIEWING: "审核中",
	APPROVED: "已通过",
	REJECTED: "已退回",
}

## 允许的流转（唯一事实源；非法流转一律拒绝 + 可读原因，不许静默改状态）。
const TRANSITIONS := {
	PENDING: [REVIEWING, APPROVED, REJECTED],
	REVIEWING: [APPROVED, REJECTED],
	APPROVED: [REVIEWING],     # 复核：通过后仍可回炉
	REJECTED: [REVIEWING],     # 申诉：退回后可重新进审核
}


## 状态标签（未知状态原样回显，不假装认识）。
static func label_of(status: String) -> String:
	return str(LABELS.get(status, status))


## 读队列。文件不存在 ⇒ 空队列（不是错误）；坏档 / 结构不对 ⇒ 空队列 + reason。
## 返回 {ok, items: Array, reason: String}。
static func load_items(path: String = DEFAULT_PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "items": [], "reason": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": true, "items": [], "reason": "队列文件打不开（错误码 %d）：先按空队列处理" % FileAccess.get_open_error()}
	var text := f.get_as_text()
	# 【bugfix 2026-10-09】不要用 JSON.parse_string：解析失败时它会 push_error，而 GUT 把 engine error 当用例失败
	# ⇒ 坏档容错用例永远红。JSON.new().parse() 只回错误码，不刷错误。
	var j := JSON.new()
	var jerr := j.parse(text)
	if jerr != OK:
		return {"ok": true, "items": [], "reason": "队列文件不是合法 JSON（第 %d 行：%s）：先按空队列处理（不会覆盖原文件，除非你再提交）" % [j.get_error_line(), j.get_error_message()]}
	var parsed: Variant = j.data
	if not (parsed is Dictionary):
		return {"ok": true, "items": [], "reason": "队列文件不是合法 JSON 对象：先按空队列处理（不会覆盖原文件，除非你再提交）"}
	var raw: Variant = (parsed as Dictionary).get("items", [])
	if not (raw is Array):
		return {"ok": true, "items": [], "reason": "队列文件里的 items 不是数组：先按空队列处理"}
	var items: Array = []
	for it in (raw as Array):
		if it is Dictionary and str((it as Dictionary).get("id", "")) != "":
			items.append(it)
	return {"ok": true, "items": items, "reason": ""}


## 写队列（原子替换，口径同编辑器手动保存 / 自动存档）。
## 返回 {ok, reason}。
static func save_items(items: Array, path: String = DEFAULT_PATH) -> Dictionary:
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "reason": "写不了临时文件 %s（错误码 %d）" % [tmp, FileAccess.get_open_error()]}
	f.store_string(JSON.stringify({"schema": SCHEMA, "items": items}, "\t"))
	f.close()
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)     # 别留半截临时文件
		return {"ok": false, "reason": "替换队列文件失败（错误码 %d）：旧队列保持不动" % err}
	return {"ok": true, "reason": ""}


## 入队。level 只**读取**（不修改调用方的字典）；note 是给审核者的一句话。
## 返回 {ok, id, item, count, reason}。
static func submit(level: Dictionary, note: String, path: String = DEFAULT_PATH) -> Dictionary:
	var loaded := load_items(path)
	var items: Array = loaded["items"]
	var digest := digest_of(level)
	var id := "sub-%s" % digest.substr(0, 8)
	var n := 2
	# 【bugfix 2026-10-09】find_item 找不到时返回空字典 {}（不是 null）⇒ 原来写成 != null 永远成立，
	# 同一关卡第二次提交就会死循环（实测 CPU 烧满 7 分钟不出结果）。判据改用 is_empty()。
	while not find_item(items, id).is_empty():
		id = "sub-%s-%d" % [digest.substr(0, 8), n]
		n += 1
	var now := int(Time.get_unix_time_from_system())
	var sz: Variant = level.get("size", {})
	var rows := int((sz as Dictionary).get("rows", 0)) if sz is Dictionary else 0
	var cols := int((sz as Dictionary).get("cols", 0)) if sz is Dictionary else 0
	var mines: Variant = level.get("mines", [])
	var item := {
		"id": id,
		"title": str(level.get("name", "")),
		"status": PENDING,
		"note": note,
		"digest": digest,
		"rows": rows,
		"cols": cols,
		"mines": (mines as Array).size() if mines is Array else int(level.get("total_mines", 0)),
		"submitted_at": now,
		"updated_at": now,
		"history": [{"status": PENDING, "at": now, "reason": ""}],
	}
	items.append(item)
	var w := save_items(items, path)
	if not bool(w["ok"]):
		return {"ok": false, "id": "", "item": {}, "count": items.size(), "reason": str(w["reason"])}
	return {"ok": true, "id": id, "item": item, "count": items.size(), "reason": ""}


## 流转一条提交。非法状态 / 非法流转 / 找不到 id ⇒ ok=false + 可读原因（不静默改）。
## 返回 {ok, item, reason}。
static func advance(id: String, to_status: String, path: String = DEFAULT_PATH, reason: String = "") -> Dictionary:
	if not LABELS.has(to_status):
		return {"ok": false, "item": {}, "reason": "未知状态「%s」：只认 %s" % [to_status, str(LABELS.keys())]}
	var loaded := load_items(path)
	var items: Array = loaded["items"]
	var idx := -1
	for i in items.size():
		if str((items[i] as Dictionary).get("id", "")) == id:
			idx = i
			break
	if idx < 0:
		return {"ok": false, "item": {}, "reason": "队列里没有提交号「%s」" % id}
	var item: Dictionary = items[idx]
	var from := str(item.get("status", PENDING))
	if from == to_status:
		return {"ok": false, "item": item, "reason": "已经是「%s」了，不必重复流转" % label_of(to_status)}
	var allowed: Array = TRANSITIONS.get(from, [])
	if not allowed.has(to_status):
		return {"ok": false, "item": item,
			"reason": "不允许从「%s」直接变成「%s」（合法下一步：%s）" % [
				label_of(from), label_of(to_status), str(allowed.map(func(s: String) -> String: return label_of(s)))]}
	var now := int(Time.get_unix_time_from_system())
	item["status"] = to_status
	item["updated_at"] = now
	var hist: Array = item.get("history", [])
	var entry := {"status": to_status, "at": now, "reason": reason}
	hist.append(entry)
	item["history"] = hist
	items[idx] = item
	var w := save_items(items, path)
	if not bool(w["ok"]):
		return {"ok": false, "item": item, "reason": str(w["reason"])}
	return {"ok": true, "item": item, "reason": ""}


## 找一条（找不到返回 {}）。纯读。
static func find_item(items: Array, id: String) -> Dictionary:
	for it in items:
		if it is Dictionary and str((it as Dictionary).get("id", "")) == id:
			return it
	return {}


## 内容指纹：与关卡 JSON 一一对应（同一关卡重复提交 ⇒ 同一摘要前缀，看得见）。
static func digest_of(level: Dictionary) -> String:
	return JSON.stringify(level).md5_text()


## 各状态计数（顺序固定 = LABELS 的声明顺序，便于 UI 与测试对齐）。
static func counts(items: Array) -> Dictionary:
	var out: Dictionary = {}
	for k in LABELS.keys():
		out[str(k)] = 0
	for it in items:
		if not (it is Dictionary):
			continue
		var s := str((it as Dictionary).get("status", PENDING))
		out[s] = int(out.get(s, 0)) + 1
	return out


## 一条提交的可读描述（UI 列表用；确定性字符串）。
static func describe(item: Dictionary) -> String:
	var id := str(item.get("id", "?"))
	var title := str(item.get("title", "")).strip_edges()
	if title == "":
		title = "未命名变体"
	return "%s ｜ %s ｜ %d×%d ｜ %d 雷 ｜ %s" % [
		id, title, int(item.get("cols", 0)), int(item.get("rows", 0)),
		int(item.get("mines", 0)), label_of(str(item.get("status", PENDING)))]


## 整个队列的一句话摘要。
static func status_text(items: Array) -> String:
	if items.is_empty():
		return "还没有提交过：做好一关后点「加入审核队列」。"
	var c := counts(items)
	var parts: Array[String] = []
	for k in LABELS.keys():
		parts.append("%s %d" % [label_of(str(k)), int(c.get(str(k), 0))])
	return "本地审核队列：共 %d 条（%s）" % [items.size(), "、".join(parts)]