extends GutTest

## 存档占用锁（`core/file_lock.gd`）单测。钉住的不变量（坏一条，多会话同存就会静默互相覆盖）：
##   ① 获取后 `peek` 能看到持有者 + 时间戳；
##   ② 第二个所有者抢锁 ⇒ `ok=false` 且 reason 可读（写明谁持有）；
##   ③ 注入时钟越过 TTL ⇒ 陈旧锁可回收，新持有者拿到（**无真实等待**）；
##   ④ 释放后可再获取；非持有者不得越权释放；
##   ⑤ 测试目录（`user://` 临时子目录）在结束时被清理。
##
## 纪律：只在 `user://` 下的临时子目录建锁，绝不碰真实存档；每个用例前后各自清理。

const Lock := preload("res://core/file_lock.gd")
const TMP := "user://test_file_lock_tmp"
const TTL := 10

## 注入时钟的可变载体（lambda 通过 self 读成员变量）。
var _clock := 1000


func before_each() -> void:
	_clock = 1000
	Lock.set_time_source(func() -> int: return _clock)
	_rmrf(TMP)


func after_each() -> void:
	Lock.clear_time_source()
	_rmrf(TMP)


# ==================== ① 获取后 peek 看到持有者 ====================

func test_acquire_then_peek_sees_holder() -> void:
	var r := Lock.acquire(TMP, "owner-A", TTL)
	assert_true(bool(r["ok"]), "获取应成功：%s" % str(r.get("reason", "")))
	var p := Lock.peek(TMP)
	assert_true(bool(p["held"]), "获取后 peek 应判为占用")
	assert_false(bool(p["stale"]), "刚获取的锁不该是陈旧锁")
	assert_eq(str(p["owner"]), "owner-A", "peek 要能读出持有者")
	assert_eq(int(p["acquired_at"]), _clock, "时间戳应来自注入时钟")
	assert_eq(int(p["expires_at"]), _clock + TTL, "到期时间 = 获取时间 + 阈值")


# ==================== ② 第二个所有者冲突且有可读理由 ====================

func test_second_owner_conflicts_with_readable_reason() -> void:
	assert_true(bool(Lock.acquire(TMP, "owner-A", TTL)["ok"]), "A 应先拿到锁")
	var r := Lock.acquire(TMP, "owner-B", TTL)
	assert_false(bool(r["ok"]), "活锁在场时第二个所有者不得抢到")
	var reason := str(r.get("reason", ""))
	assert_true(reason.length() > 0, "冲突必须给可读理由（不许静默失败）")
	assert_true(reason.find("owner-A") != -1, "理由里要写明谁持有：%s" % reason)
	assert_eq(str(r.get("owner", "")), "owner-A", "冲突结果应回传当前持有者")
	# 冲突后锁仍归 A，未被 B 覆盖
	assert_eq(str(Lock.peek(TMP)["owner"]), "owner-A", "抢锁失败不得改写持有者")


# ==================== ③ 注入时钟越过阈值 ⇒ 陈旧锁可回收 ====================

func test_stale_lock_is_reclaimable_via_injected_clock() -> void:
	assert_true(bool(Lock.acquire(TMP, "owner-A", TTL)["ok"]), "A 应先拿到锁")
	_clock += TTL + 1  # 越过 TTL，无需真实等待
	var peeked := Lock.peek(TMP)
	assert_true(bool(peeked["stale"]), "越过阈值后应判为陈旧：%s" % str(peeked["reason"]))
	assert_false(bool(peeked["held"]), "陈旧锁不应算作在场占用")
	var r := Lock.acquire(TMP, "owner-B", TTL)
	assert_true(bool(r["ok"]), "陈旧锁应可被回收：%s" % str(r.get("reason", "")))
	assert_true(bool(r.get("reclaimed", false)), "回收陈旧锁应报告 reclaimed=true")
	assert_eq(str(Lock.peek(TMP)["owner"]), "owner-B", "新持有者应拿到锁")


# ==================== ④ 释放后可再获取 ====================

func test_release_then_reacquire() -> void:
	assert_true(bool(Lock.acquire(TMP, "owner-A", TTL)["ok"]), "A 应先拿到锁")
	assert_false(Lock.release(TMP, "owner-B"), "非持有者不得越权释放")
	assert_true(Lock.release(TMP, "owner-A"), "持有者应能释放自己的锁")
	assert_false(bool(Lock.peek(TMP)["held"]), "释放后不应再占用")
	assert_true(Lock.release(TMP, "owner-A") == false, "重复释放应返回 false（锁已不在）")
	assert_true(bool(Lock.acquire(TMP, "owner-B", TTL)["ok"]), "释放后应能重新获取")


# ==================== ⑤ 测试目录被清理 ====================

func test_temp_dir_is_cleaned_up() -> void:
	assert_true(bool(Lock.acquire(TMP, "owner-A", TTL)["ok"]), "应先建出锁")
	var lock_file := TMP.path_join(Lock.LOCK_FILE)
	assert_true(FileAccess.file_exists(lock_file), "锁文件应存在于临时目录")
	_rmrf(TMP)
	assert_false(FileAccess.file_exists(lock_file), "清理后锁文件应消失")
	assert_false(DirAccess.dir_exists_absolute(TMP), "清理后临时目录应消失")


# ==================== 工具 ====================

func _rmrf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var p := path.path_join(n)
		if d.current_is_dir():
			_rmrf(p)
		else:
			DirAccess.remove_absolute(p)
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)
