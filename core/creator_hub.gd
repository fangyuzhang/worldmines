# creator_hub.gd —— 创作中心（**纯本地**闭环：产出 → 版本登记 → 反馈交换）
#
# 用户口径（2026-10-09，硬约束）：「打算在 Steam 售卖，**没有任何服务器、也不打算租**」。
# 所以这里做的是**文件交换**闭环，不是联网平台：
#   作者：编辑器导出分享包/短码 → 在创作中心登记一个版本（版本号 + 变更说明）；
#   玩家：拿到包 → 玩 → 用同一套工具导出一份「反馈包」（一个 JSON 文件）发回给作者；
#   作者：导入反馈包 → 反馈挂到对应版本上 → 写下一版变更说明。
# 全程零服务器、零账号；文件通过任意渠道（Steam 创意工坊 / 群 / 邮件）传递。
#
# ⚠️ 绝不假装联网：本模块没有、也不该有「上传 / 下载 / 订阅数」字段。
#    现有 core/steam_workshop.gd 是占位实现，不要在这里造一个假的成功返回值。
#
# ⚠️ 刻意不写 class_name（坑表 #26）。调用方：const Hub := preload("res://core/creator_hub.gd")。
extends RefCounted


const PATH := "user://creator_hub.json"
## 反馈包类型标记：只认这个，避免把任意 JSON 当反馈吞进来。
const FEEDBACK_KIND := "tametsi_creator_feedback"
const VERSION := 1


# ============ 存档读写 ============

static func _blank() -> Dictionary:
	return {"version": VERSION, "packs": []}


static func load_data(path: String = PATH) -> Dictionary:
	if not FileAccess.file_exists(path):
		return _blank()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _blank()
	var text := f.get_as_text()
	f.close()
	# JSON.parse（返回错误码）：坏档静默退回空表，不刷引擎报错。
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		return _blank()
	var d: Dictionary = j.data
	if not (d.get("packs") is Array):
		return _blank()
	return d


static func save_data(d: Dictionary, path: String = PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("创作中心写入失败：" + path)
		return false
	f.store_string(JSON.stringify(d, "  "))
	f.close()
	return true


# ============ 查询 ============

static func list_packs(path: String = PATH) -> Array:
	var out: Array = []
	for p in (load_data(path).get("packs", []) as Array):
		if p is Dictionary:
			out.append((p as Dictionary).duplicate(true))
	return out


static func find_pack(d: Dictionary, id: String) -> int:
	var packs: Array = d.get("packs", [])
	for i in packs.size():
		if str((packs[i] as Dictionary).get("id", "")) == id:
			return i
	return -1


static func stats(path: String = PATH) -> Dictionary:
	var packs := list_packs(path)
	var versions := 0
	var feedback := 0
	var latest := ""
	var latest_at := -1
	for p in packs:
		versions += (p.get("history", []) as Array).size()
		feedback += (p.get("feedback", []) as Array).size()
		var at := int(p.get("published_at", 0))
		if at > latest_at:
			latest_at = at
			latest = str(p.get("title", ""))
	return {"packs": packs.size(), "versions": versions, "feedback": feedback,
		"latest_title": latest, "latest_at": latest_at}


# ============ 发布 / 登记版本 ============

## 作品 id：标题转小写短横线 slug。空标题 → "pack"。
static func slug(title: String) -> String:
	var out := ""
	for i in title.length():
		var ch := title.substr(i, 1).to_lower()
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
		elif ch == " " or ch == "-" or ch == "_":
			if not out.ends_with("-") and out != "":
				out += "-"
	while out.ends_with("-"):
		out = out.substr(0, out.length() - 1)
	return out if out != "" else "pack"


## 登记一个版本（首次 = 发布，之后 = 更新）。返回该作品条目（副本）。
## notes = 本次变更说明；pack_file = 导出的分享包路径（可为空 = 只登记，不绑定文件）。
static func publish(title: String, notes: String, pack_file: String = "", path: String = PATH,
		now_ms: int = 0) -> Dictionary:
	var d := load_data(path)
	var id := slug(title)
	var at: int = now_ms if now_ms > 0 else int(Time.get_unix_time_from_system())
	var packs: Array = d.get("packs", [])
	var i := find_pack(d, id)
	var entry: Dictionary
	if i < 0:
		entry = {"id": id, "title": title, "version": 1, "notes": notes,
			"pack_file": pack_file, "published_at": at, "history": [], "feedback": []}
		packs.append(entry)
	else:
		entry = packs[i]
		entry["version"] = int(entry.get("version", 1)) + 1
		entry["notes"] = notes
		if pack_file != "":
			entry["pack_file"] = pack_file
		entry["published_at"] = at
		packs[i] = entry
	(entry["history"] as Array).append({"version": int(entry["version"]), "notes": notes,
		"pack_file": str(entry.get("pack_file", "")), "at": at})
	d["packs"] = packs
	save_data(d, path)
	return (entry as Dictionary).duplicate(true)


static func remove_pack(id: String, path: String = PATH) -> bool:
	var d := load_data(path)
	var i := find_pack(d, id)
	if i < 0:
		return false
	var packs: Array = d.get("packs", [])
	packs.remove_at(i)
	d["packs"] = packs
	return save_data(d, path)


# ============ 反馈交换（双向都用同一个文件格式） ============

## 玩家侧：把一条反馈写成可发送的文件。返回是否写成功。
static func export_feedback_pack(pack_id: String, tester: String, rating: int, comment: String,
		out_path: String, pack_version: int = 0, now_ms: int = 0) -> bool:
	if out_path == "":
		return false
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_warning("反馈包写入失败：" + out_path)
		return false
	f.store_string(JSON.stringify({
		"kind": FEEDBACK_KIND,
		"pack_id": pack_id,
		"pack_version": pack_version,
		"tester": tester,
		"rating": clampi(rating, 0, 5),
		"comment": comment,
		"created_at": now_ms if now_ms > 0 else int(Time.get_unix_time_from_system()),
	}, "  "))
	f.close()
	return true


## 作者侧：导入一个反馈包文件。
## 返回 {"ok": bool, "error": "", "entry": {...}}；error ∈
##   "" / "missing"（文件不存在）/ "bad_json"（不是 JSON 对象）/
##   "bad_kind"（不是反馈包）/ "unknown_pack"（本地没有这个作品）/ "bad_id"
static func import_feedback(file_path: String, path: String = PATH) -> Dictionary:
	if file_path == "" or not FileAccess.file_exists(file_path):
		return {"ok": false, "error": "missing", "entry": {}}
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "missing", "entry": {}}
	var text := f.get_as_text()
	f.close()
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		return {"ok": false, "error": "bad_json", "entry": {}}
	var fb: Dictionary = j.data
	if str(fb.get("kind", "")) != FEEDBACK_KIND:
		return {"ok": false, "error": "bad_kind", "entry": {}}
	var pid := str(fb.get("pack_id", ""))
	if pid == "":
		return {"ok": false, "error": "bad_id", "entry": {}}
	var d := load_data(path)
	var i := find_pack(d, pid)
	if i < 0:
		return {"ok": false, "error": "unknown_pack", "entry": {}}
	var packs: Array = d.get("packs", [])
	var entry: Dictionary = packs[i]
	var rec := {
		"version": int(fb.get("pack_version", 0)),
		"tester": str(fb.get("tester", "")),
		"rating": clampi(int(fb.get("rating", 0)), 0, 5),
		"comment": str(fb.get("comment", "")),
		"at": int(fb.get("created_at", 0)),
	}
	(entry["feedback"] as Array).append(rec)
	packs[i] = entry
	d["packs"] = packs
	save_data(d, path)
	return {"ok": true, "error": "", "entry": rec.duplicate(true)}


## 某作品的反馈列表（副本）。
static func feedback_of(pack_id: String, path: String = PATH) -> Array:
	var d := load_data(path)
	var i := find_pack(d, pack_id)
	if i < 0:
		return []
	var entry: Dictionary = (d["packs"] as Array)[i]
	var out: Array = []
	for r in (entry.get("feedback", []) as Array):
		out.append((r as Dictionary).duplicate(true))
	return out


## 平均评分（无反馈返回 -1.0）。
static func average_rating(pack_id: String, path: String = PATH) -> float:
	var fb := feedback_of(pack_id, path)
	if fb.is_empty():
		return -1.0
	var s := 0.0
	for r in fb:
		s += float((r as Dictionary).get("rating", 0))
	return s / float(fb.size())
