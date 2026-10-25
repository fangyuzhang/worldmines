# progress_store.gd —— 通关进度持久化（静态工具，非 autoload）
# 数据落在 user://progress.json：{ "levels": { "<关卡路径>": {"cleared": true, "best": 12.34, "plays": 3} } }
# 只记录"通关 + 最佳用时 + 尝试次数"；不存盘面、不存雷位（与存档 SaveCoordinator 完全分离）。
class_name ProgressStore
extends RefCounted

const PATH := "user://progress.json"

static var _cache: Dictionary = {}
static var _loaded: bool = false


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
            if parsed is Dictionary and (parsed as Dictionary).has("levels"):
                _cache = parsed
    return _cache


static func _flush() -> void:
    var f := FileAccess.open(PATH, FileAccess.WRITE)
    if f == null:
        push_warning("进度写入失败：" + PATH)
        return
    f.store_string(JSON.stringify(_cache, "  "))
    f.close()


## 记录一次通关：cleared=true，best 取最小值（秒）。
static func record_clear(level_path: String, seconds: float) -> void:
    if level_path == "":
        return
    var d := _data()
    var levels: Dictionary = d["levels"]
    var rec: Dictionary = levels.get(level_path, {"cleared": false, "best": -1.0, "plays": 0})
    rec["cleared"] = true
    rec["plays"] = int(rec.get("plays", 0)) + 1
    var best := float(rec.get("best", -1.0))
    if best < 0.0 or seconds < best:
        rec["best"] = seconds
    levels[level_path] = rec
    _flush()


## 记录一次尝试（失败/退出也算），不影响 cleared。
static func record_attempt(level_path: String) -> void:
    if level_path == "":
        return
    var levels: Dictionary = _data()["levels"]
    var rec: Dictionary = levels.get(level_path, {"cleared": false, "best": -1.0, "plays": 0})
    rec["plays"] = int(rec.get("plays", 0)) + 1
    levels[level_path] = rec
    _flush()


static func is_cleared(level_path: String) -> bool:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    return bool(rec.get("cleared", false))


## 最佳用时（秒）；未通关返回 -1.0。
static func best_time(level_path: String) -> float:
    var rec: Dictionary = _data()["levels"].get(level_path, {})
    if not bool(rec.get("cleared", false)):
        return -1.0
    return float(rec.get("best", -1.0))


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
    _flush()


## 测试用：丢弃内存缓存，强制下次从磁盘重读。
static func reset_cache() -> void:
    _cache = {}
    _loaded = false
