# test_save_coordinator.gd —— T7 存读一致与生命周期 / T8 坏档隔离【plan1.1 §10.12.4】
# Board 构造一律走 LevelLoader.load_level（真实关卡），不自造假引擎对象。
extends GutTest

const MAIN := "user://save.json"
const TEMP := "user://save_temp.json"
const BAK := "user://save.json.bak"


func before_each() -> void:
    _rm_all()
    GameSession.level_path = ""


func after_each() -> void:
    _rm_all()


func _rm_all() -> void:
    for p in [MAIN, TEMP, BAK]:
        if FileAccess.file_exists(p):
            DirAccess.remove_absolute(p)


func _get_board() -> Board:
    var levels := LevelLoader.list_levels()
    return LevelLoader.load_level(levels[0])


# T7：save → MAIN 读回字段一致且 TEMP 存在；clear 后双档消失；TEMP 残留 → 崩溃标志
func test_t7_save_load_lifecycle() -> void:
    var b := _get_board()
    assert_not_null(b)
    GameSession.level_path = "res://levels/classic_01.json"
    SaveCoordinator.save(b, 12.5, "res://levels/classic_01.json")

    assert_true(FileAccess.file_exists(MAIN), "主档应存在")
    assert_true(FileAccess.file_exists(TEMP), "TEMP 应存在（进行中对局存活标志）")
    assert_true(SaveCoordinator.has_crash_leftover(), "TEMP 残留 = 崩溃标志")

    var d: Dictionary = SaveCoordinator.load_save()
    assert_false(d.is_empty())
    assert_almost_eq(float(d["timer_seconds"]), 12.5, 0.001)
    assert_eq(d["mine_positions"].size(), 10, "雷位数量一致")
    assert_eq(d["revealed_cells"].size(), 4, "初始翻开 4 格（classic_01 事实）")
    assert_eq(d["metadata"]["level_path"], "res://levels/classic_01.json", "level_path 必写")

    SaveCoordinator.clear()
    assert_false(FileAccess.file_exists(MAIN))
    assert_false(FileAccess.file_exists(TEMP))
    assert_false(SaveCoordinator.has_crash_leftover())


# T7b：仅 TEMP 残留 → has_crash_leftover() == true（杀进程场景）
func test_t7b_temp_only_leftover() -> void:
    var f := FileAccess.open(TEMP, FileAccess.WRITE)
    f.store_string("{}")
    f.close()
    assert_true(SaveCoordinator.has_crash_leftover())
    SaveCoordinator.clear_temp()
    assert_false(SaveCoordinator.has_crash_leftover())


# T8：写坏 MAIN → quarantine() 后出现 .bak 且 MAIN 消失
func test_t8_quarantine() -> void:
    var f := FileAccess.open(MAIN, FileAccess.WRITE)
    f.store_string("不是 JSON {{{")
    f.close()
    var d: Dictionary = SaveCoordinator.load_save()
    assert_eq(d, {}, "坏档 load_save 返回空字典")
    # 声明预期报错：解析坏 JSON 会触发引擎/脚本报错，不声明会被 GUT 判 Unexpected Errors
    assert_engine_error_count(1)

    SaveCoordinator.quarantine()
    assert_true(FileAccess.file_exists(BAK), ".bak 应存在")
    assert_false(FileAccess.file_exists(MAIN), "MAIN 应消失")


# T8b：quarantine 二次执行（.bak 已存在 → 先删再改名，不崩溃）
func test_t8b_quarantine_twice() -> void:
    var f := FileAccess.open(MAIN, FileAccess.WRITE)
    f.store_string("坏档1")
    f.close()
    SaveCoordinator.quarantine()
    var f2 := FileAccess.open(MAIN, FileAccess.WRITE)
    f2.store_string("坏档2")
    f2.close()
    SaveCoordinator.quarantine()  # .bak 已存在分支
    assert_true(FileAccess.file_exists(BAK))
    assert_false(FileAccess.file_exists(MAIN))


# ==== v3.1 修复回归 ====

# v3.1/M3：主档替换走 bak 三步——二次 save 覆盖旧档后 .bak 应清理、读回为最新内容
func test_save_replaces_existing_main_via_bak() -> void:
    var b := _get_board()
    GameSession.level_path = "res://levels/classic_01.json"
    SaveCoordinator.save(b, 1.0, "res://levels/classic_01.json")
    SaveCoordinator.save(b, 2.0, "res://levels/classic_01.json")  # 第二次替换（走 bak 三步）
    assert_false(FileAccess.file_exists(BAK), "替换完成后 .bak 应清理")
    var d: Dictionary = SaveCoordinator.load_save()
    assert_almost_eq(float(d["timer_seconds"]), 2.0, 0.001, "读回应为最新档")


# v3.1/M3：MAIN 缺失（替换窗口崩溃模拟）→ load_save 回退 TEMP 兜底
func test_load_save_falls_back_to_temp() -> void:
    var b := _get_board()
    GameSession.level_path = "res://levels/classic_01.json"
    SaveCoordinator.save(b, 3.5, "res://levels/classic_01.json")
    DirAccess.remove_absolute(MAIN)  # 模拟替换窗口期 MAIN 消失
    var d: Dictionary = SaveCoordinator.load_save()
    assert_false(d.is_empty(), "MAIN 消失应回退 TEMP 恢复")
    assert_almost_eq(float(d["timer_seconds"]), 3.5, 0.001)


# v3.1/M1：字段类型漂移（键在类型错）→ load_save 返回 {} → 调用方走 quarantine，
# 而不是 restore_from_save 强类型赋值时脚本崩溃
func test_type_drift_save_rejected() -> void:
    var f := FileAccess.open(MAIN, FileAccess.WRITE)
    f.store_string(JSON.stringify({
        "revealed_cells": [], "flagged_cells": [], "timer_seconds": 0.0,
        "mine_positions": [], "seed_value": 0,
        "metadata": "not-a-dict",
    }))
    f.close()
    var d: Dictionary = SaveCoordinator.load_save()
    assert_eq(d, {}, "metadata 类型漂移应被拒收（走坏档隔离而非脚本崩溃）")


# v3.1/G1：ENDED 状态下自动存档必须是 no-op——终局档（ended=true）不可被
# 无标记常规档覆盖，否则失败局可经「恢复」复活（SL 作弊通道）
func test_ended_autosave_is_noop() -> void:
    var b := _get_board()
    GameSession.level_path = "res://levels/classic_01.json"
    SaveCoordinator.save(b, 9.0, "res://levels/classic_01.json", {}, true)  # 终局盘
    GameSession.state = GameSession.State.ENDED
    GameSession._maybe_autosave()  # 旧实现会在此用 ended=false 覆盖终局档
    var d: Dictionary = SaveCoordinator.load_save()
    assert_true(bool(d["metadata"].get("ended", false)), "终局标记必须保留")
    GameSession.state = GameSession.State.IDLE
