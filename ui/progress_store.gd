# progress_store.gd —— 通关进度持久化（静态工具，非 autoload）
# 数据落在 user://progress.json：{ "levels": { "<关卡路径>": {"cleared": true, "best": 12.34, "best_stars": 3, "plays": 3} } }
# 只记录"通关 + 最佳用时 + 最佳提示星级 + 尝试次数"；不存盘面、不存雷位（与存档 SaveCoordinator 完全分离）。
class_name ProgressStore
extends RefCounted

const PATH := "user://progress.json"

static var _cache: Dictionary = {}
static var _loaded: bool = false
## 进度数据版本号：任何写操作 +1。供读方（选关页通关计数缓存等）做失效判断——
## 比起「写后手动通知」，版本号让缓存方自己轮询一个整数即可，不需要接线。
static var _rev: int = 0


## 当前进度数据版本（每次 record_* / clear_all / reset_cache 后 +1）。
static func rev() -> int:
    return _rev


## 读取（首次调用时载入；文件缺失/损坏 → 空进度，不抛错）。
static func _data() -> Dictionary:
    if _loaded:
        return _cache
    _loaded = true
    _cache = {"levels": {}}
    if FileAccess.file_exists(PATH):
        var f := FileAccess.open(PATH, FileAccess.READ)
        if f != null:
            var parsed = JSON.parse_string(f.get_as_text())
            f.close()
            # 【09-28 审计修复 R3】原先只查键存在、不查类型；下面 `var levels: Dictionary = d["levels"]`
            # 是强类型赋值 ⇒ 畸形档（如 {"levels": []}，手改/旧版/写坏）会运行时报错并中断函数，
            # 导致 record_clear/is_cleared/best_time 全线失效（通关不打勾、下一关不解锁）。
            if parsed is Dictionary and (parsed as Dictionary).get("levels") is Dictionary:
                _cache = parsed
    _migrate_legacy_keys()   # 只操作 _cache，不回调 _data()，无递归
    return _cache


## 一次性键迁移（v3.3）：早期版本把「生成关卡」按**文件路径**记进度
## （user://gen_levels/<mode>_<size>_<idx>.json），而读取侧（选关页打勾/解锁、
## LevelSequence.has_next）查的是序列键 gen://<mode>/<size>/<idx>——两者永不相等，
## 那些通关记录因此永远读不到（实测存档里 4 条真实记录处于这种状态）。
## 这里把它们搬到序列键：目标键已存在时按字段合并，两边数据都不丢。
## 幂等（跑完不再有 user://gen_levels/ 键），异常也不影响其它进度。
static func _migrate_legacy_keys() -> void:
    var levels: Dictionary = _cache.get("levels", {})
    var moved := 0
    for k in levels.keys():
        var key := str(k)
        if not key.begins_with("user://gen_levels/"):
            continue
        var new_key := LevelSequence.progress_key(key)
        if new_key == key:
            continue
        var old: Dictionary = levels[key]
        var cur: Dictionary = levels.get(new_key, {})
        var merged: Dictionary = cur.duplicate()
        merged["cleared"] = bool(cur.get("cleared", false)) or bool(old.get("cleared", false))
        merged["skipped"] = bool(cur.get("skipped", false)) or bool(old.get("skipped", false))
        merged["plays"] = int(cur.get("plays", 0)) + int(old.get("plays", 0))
        var bests: Array = []
        for rec in [cur, old]:
            var b := float((rec as Dictionary).get("best", -1.0))
            if b >= 0.0:
                bests.append(b)
        merged["best"] = bests.min() if not bests.is_empty() else -1.0
        merged["best_stars"] = maxi(int(merged.get("best_stars", 0)), maxi(int(cur.get("best_stars", 0)), int(old.get("best_stars", 0))))
        levels[new_key] = merged
        levels.erase(key)
        moved += 1
    if moved > 0:
        _rev += 1   # 迁移改了键集：通关计数缓存等读方必须失效（2026-09-30 审计补）
        _flush()


static func _flush() -> void:
    var f := FileAccess.open(PATH, FileAccess.WRITE)
    if f == null:
        push_warning("进度写入失败：" + PATH)
        return
    f.store_string(JSON.stringify(_cache, "  "))
    f.close()


## 记录一次通关：cleared=true，best 取最小值（秒），best_stars 取最大值（3=未用提示）。
## 通关同时清掉「跳过」标记：跳过后回头打通，这一关就是正常通关了。
static func record_clear(level_path: String, seconds: float, stars: int = 3) -> void:
    if level_path == "":
        return
    var d := _data()
    var levels: Dictionary = d["levels"]
    var rec: Dictionary = levels.get(level_path, {"cleared": false, "best": -1.0, "plays": 0})
    rec["cleared"] = true
    rec["skipped"] = false
    rec["plays"] = int(rec.get("plays", 0)) + 1
    var best := float(rec.get("best", -1.0))
    if best < 0.0 or seconds < best:
        rec["best"] = seconds
    rec["best_stars"] = maxi(int(rec.get("best_stars", 0)), clampi(stars, 0, 3))
    levels[level_path] = rec
    _rev += 1
    _flush()


## 记录一次「跳过本关」（失败终局的选择）：**只解锁下一关，不算通关**。
## 与 cleared 分开存是刻意的：跳过若写成 cleared，通关统计与最佳用时都会失真
## （历史坑：演示预设直写 cleared，留下过永久的假「20.00 秒通关」记录）。
static func record_skip(level_path: String) -> void:
    if level_path == "":
        return
    var levels: Dictionary = _data()["levels"]
    var rec: Dictionary = levels.get(level_path, {"cleared": false, "best": -1.0, "plays": 0})
    rec["skipped"] = true
    levels[level_path] = rec
    _rev += 1
    _flush()


## 记录一次尝试（失败/退出也算），不影响 cleared。
static func record_attempt(level_path: String) -> void:
    if level_path == "":
        return
    var levels: Dictionary = _data()["levels"]
    var rec: Dictionary = levels.get(level_path, {"cleared": false, "best": -1.0, "plays": 0})
    rec["plays"] = int(rec.get("plays", 0)) + 1
    levels[level_path] = rec
    _rev += 1
    _flush()


## 全部关卡记录（**副本**）：供成就 / 掌握度雷达这类「按整表统计」的读方使用。
## 为什么要给访问器：此前只有 cleared_count() 一个聚合读口，统计方各自去摸私有 _data()，
## 一旦内部结构变了，摸私有的那些地方是**静默算错**（不报错、只是数字不对）。
static func levels() -> Dictionary:
    var src: Dictionary = _data().get("levels", {})
    var out: Dictionary = {}
    for k in src:
        if src[k] is Dictionary:
            out[str(k)] = (src[k] as Dictionary).duplicate(true)
    return out


static func is_cleared(level_path: String) -> bool:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    return bool(rec.get("cleared", false))


## 是否被「跳过」。与 cleared 互不蕴含：跳过只解锁下一关，不计入通关统计。
static func is_skipped(level_path: String) -> bool:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    return bool(rec.get("skipped", false))


## 最佳用时（秒）；未通关返回 -1.0。
static func best_time(level_path: String) -> float:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    if not bool(rec.get("cleared", false)):
        return -1.0
    return float(rec.get("best", -1.0))


## 历史最佳提示星级；未通关返回 -1。
static func best_stars(level_path: String) -> int:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    if not bool(rec.get("cleared", false)):
        return -1
    return clampi(int(rec.get("best_stars", 0)), 0, 3)


static func plays(level_path: String) -> int:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    return int(rec.get("plays", 0))


static func cleared_count() -> int:
    var n := 0
    for k in _data()["levels"]:
        if bool((_data()["levels"][k] as Dictionary).get("cleared", false)):
            n += 1
    return n


## 清空全部进度（设置页「清除进度」用）。
static func clear_all() -> void:
    _cache = {"levels": {}}
    _loaded = true
    _rev += 1
    _flush()


## 测试用：丢弃内存缓存，强制下次从磁盘重读。
static func reset_cache() -> void:
    _cache = {}
    _loaded = false
    _rev += 1
