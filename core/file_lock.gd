class_name LevelFileLock
extends RefCounted

## 存档占用锁（缺口 #13 前半）：同一份关卡文件不允许被两个编辑会话同时写。
##
## 【为什么需要】存档协调器（`ui/save_coordinator.gd`）能做原子替换，但**跨会话**没有任何互斥：
##   两个编辑器窗口 / 编辑器 + 批量生产脚本同时保存同一关 ⇒ 后写者静默覆盖前者。
##   本模块只解决"谁在写"的**在场可见性**，并让**崩溃后不会永久卡死**。
##
## 【锁文件契约】`<dir>/.level.lock`，JSON：
##   `{owner, acquired_at, ttl, expires_at}` —— 所有者标识 + 获取时间戳 + 存活秒数 + 到期时间。
##   锁文件只是**提示 + 互斥**，不含关卡数据；用户删掉它等同"强制解锁"（可接受）。
##
## 【陈旧锁回收】进程崩溃不会删锁文件。因此锁带到期时间：`now >= expires_at` 即视为**陈旧**，
##   任何后来者可直接覆盖回收，无需人工干预。阈值 = 获取时传入的 `ttl_seconds`。
##
## 【时间可注入】`set_time_source()` 注入时钟，测试据此**无需真实等待**即可跨过 TTL；
##   另提供 `now` 显式参数（≥0 时优先），二者皆可。
##
## 【路径纪律】本模块**只操作调用方传入的目录**，绝不硬编码任何真实存档路径；
##   生产接线由 UI 层负责传正确目录，测试一律传 `user://` 下的临时子目录并自行清理。

## 锁文件名（放在目标目录内）。
const LOCK_FILE := ".level.lock"

## 陈旧锁默认阈值（秒）——依据：
##   · 编辑器一次完整"保存 + 体积估算 + 写盘"实测在秒级（5000 格硬上限下仍远小于 1 分钟）；
##   · 再加人工确认 / 弹窗停留的缓冲；
##   · 取 900 秒（= 15 分钟，约 15 倍缓冲）：短到崩溃后 15 分钟内自动解锁，
##     长到不会把一次慢保存误判成陈旧锁。太短 ⇒ 正常保存被抢；太长 ⇒ 崩溃后久锁。
const DEFAULT_TTL_SECONDS := 900

## 注入时钟（空 Callable ⇒ 用系统时间）。测试用，避免真实等待。
static var _time_source: Callable = Callable()


## 注入时间源：回调须返回 int（或可转 int）的 unix 秒。
static func set_time_source(cb: Callable) -> void:
	_time_source = cb


## 恢复真实系统时钟。
static func clear_time_source() -> void:
	_time_source = Callable()


# ==================== 对外 API ====================

## 获取锁。`ttl_seconds` 为陈旧阈值；`now` ≥ 0 时显式指定当前时间。
## 返回 `{ok, reason, lock_path, owner, acquired_at, expires_at, reclaimed}`。
## 冲突（活锁 + 不同所有者）⇒ `ok=false` 且 `reason` 为**可读文本**（谁持有 / 何时 / 多旧）。
static func acquire(dir: String, owner: String, ttl_seconds: int = DEFAULT_TTL_SECONDS,
		now: int = -1) -> Dictionary:
	if dir.strip_edges().is_empty():
		return {"ok": false, "reason": "未指定锁目录（拒绝在空路径上建锁）", "lock_path": "", "owner": owner}
	if owner.strip_edges().is_empty():
		return {"ok": false, "reason": "未指定锁所有者（无法区分是谁在写）",
			"lock_path": _lock_path(dir), "owner": owner}
	if ttl_seconds < 1:
		return {"ok": false, "reason": "锁阈值非法（%d 秒），必须 ≥ 1" % ttl_seconds,
			"lock_path": _lock_path(dir), "owner": owner}
	var lock_path := _lock_path(dir)
	var t := _now(now)
	var existing := _read(lock_path)
	var reclaimed := false
	if not existing.is_empty():
		var e_owner := str(existing.get("owner", ""))
		var e_expires := int(existing.get("expires_at", 0))
		var stale := t >= e_expires
		if not stale and e_owner != owner:
			var e_acquired := int(existing.get("acquired_at", 0))
			return {
				"ok": false,
				"reason": "该存档正被 %s 占用：%s 起持有，已 %d 秒（%d 秒后到期）。请等其释放或确认对方已退出。" % [
					e_owner, _fmt_time(e_acquired), maxi(t - e_acquired, 0), maxi(e_expires - t, 0)],
				"lock_path": lock_path,
				"owner": e_owner,
				"acquired_at": e_acquired,
				"expires_at": e_expires,
			}
		reclaimed = stale
	var err := _ensure_dir(dir)
	if err != "":
		return {"ok": false, "reason": err, "lock_path": lock_path, "owner": owner}
	var rec := {"owner": owner, "acquired_at": t, "ttl": ttl_seconds, "expires_at": t + ttl_seconds}
	var f := FileAccess.open(lock_path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "reason": "无法写入锁文件：%s" % lock_path, "lock_path": lock_path, "owner": owner}
	f.store_string(JSON.stringify(rec))
	f.close()
	return {
		"ok": true, "reason": "已获取锁（%s）" % _fmt_time(t), "lock_path": lock_path,
		"owner": owner, "acquired_at": t, "expires_at": t + ttl_seconds, "reclaimed": reclaimed,
	}


## 释放**自己**持有的锁。无锁 / 非本人持有 ⇒ `false`（不越权抢别人的锁）。
static func release(dir: String, owner: String) -> bool:
	var lock_path := _lock_path(dir)
	var existing := _read(lock_path)
	if existing.is_empty():
		return false
	if str(existing.get("owner", "")) != owner:
		return false
	return DirAccess.remove_absolute(lock_path) == OK


## 只读探测（**不写盘**，供 UI 提前提示"该文件正被占用"）。
## 返回 `{held, stale, owner, acquired_at, expires_at, age_seconds, ttl, lock_path, reason}`。
static func peek(dir: String, now: int = -1) -> Dictionary:
	var lock_path := _lock_path(dir)
	var t := _now(now)
	var existing := _read(lock_path)
	if existing.is_empty():
		return {
			"held": false, "stale": false, "owner": "", "acquired_at": 0, "expires_at": 0,
			"age_seconds": 0, "ttl": 0, "lock_path": lock_path, "reason": "空闲（无锁文件）",
		}
	var owner := str(existing.get("owner", ""))
	var acquired := int(existing.get("acquired_at", 0))
	var expires := int(existing.get("expires_at", 0))
	var ttl := int(existing.get("ttl", 0))
	var age := maxi(t - acquired, 0)
	var stale := t >= expires
	var reason := ""
	if stale:
		reason = "锁已陈旧：%s 于 %s 起持有，已 %d 秒（阈值 %d 秒），可回收" % [
			owner, _fmt_time(acquired), age, ttl]
	else:
		reason = "被 %s 占用：%s 起持有，已 %d 秒，%d 秒后到期" % [
			owner, _fmt_time(acquired), age, maxi(expires - t, 0)]
	return {
		"held": not stale, "stale": stale, "owner": owner, "acquired_at": acquired,
		"expires_at": expires, "age_seconds": age, "ttl": ttl, "lock_path": lock_path, "reason": reason,
	}


# ==================== 内部 ====================

static func _lock_path(dir: String) -> String:
	if dir.strip_edges().is_empty():
		return ""
	return dir.path_join(LOCK_FILE)


static func _now(explicit_now: int) -> int:
	if explicit_now >= 0:
		return explicit_now
	if _time_source.is_valid():
		return int(_time_source.call())
	return int(Time.get_unix_time_from_system())


static func _ensure_dir(dir: String) -> String:
	if DirAccess.dir_exists_absolute(dir):
		return ""
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return "无法创建锁目录：%s" % dir
	return ""


## 读锁记录。文件缺失 / 损坏 / 非法 ⇒ 返回空 ⇒ 视为**可回收**（锁是提示物，宁可失败放行也不永久卡死）。
static func _read(lock_path: String) -> Dictionary:
	if lock_path.is_empty() or not FileAccess.file_exists(lock_path):
		return {}
	var f := FileAccess.open(lock_path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed as Dictionary
	return {}


static func _fmt_time(unix: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix, true)
