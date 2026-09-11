# test_game_session_logic.gd —— T9 状态机 / T10 计时门控 / T11 重开归零【plan1.1 §10.12.4】
# 直接调 _tick，禁 sleep；headless 可跑。
extends GutTest


func before_each() -> void:
    SaveCoordinator.clear()
    GameSession.state = GameSession.State.IDLE
    GameSession.board = null
    GameSession.level_path = ""
    GameSession.timer_started = false
    GameSession.elapsed = 0.0


func after_each() -> void:
    GameSession.state = GameSession.State.IDLE
    SaveCoordinator.clear()


func _first_level() -> String:
    return LevelLoader.list_levels()[0]


# T9：状态机矩阵（非法转换被拒且不崩溃）
func test_t9_state_machine() -> void:
    # IDLE + start_level 失败 → IDLE
    assert_false(GameSession.start_level("res://levels/classic_99.json"))
    assert_eq(GameSession.state, GameSession.State.IDLE)
    # 声明预期报错（LevelLoader 解析/加载失败各一条），否则 GUT 判 Unexpected Errors
    assert_push_error_count(2)

    # IDLE + start_level 成功 → PLAYING
    assert_true(GameSession.start_level(_first_level()))
    assert_eq(GameSession.state, GameSession.State.PLAYING)

    # PLAYING + pause → PAUSED；PAUSED + resume → PLAYING
    GameSession.set_paused(true)
    assert_eq(GameSession.state, GameSession.State.PAUSED)
    GameSession.set_paused(false)
    assert_eq(GameSession.state, GameSession.State.PLAYING)

    # ENDED + pause（非法）→ 拒绝且不崩溃
    GameSession.state = GameSession.State.ENDED
    GameSession.set_paused(true)
    assert_eq(GameSession.state, GameSession.State.ENDED)

    # IDLE + resume（非法）→ 拒绝且不崩溃
    GameSession.state = GameSession.State.IDLE
    GameSession.set_paused(false)
    assert_eq(GameSession.state, GameSession.State.IDLE)


# T10：计时门控（PLAYING 累计、PAUSED/ENDED 不累计）
func test_t10_timer_gating() -> void:
    assert_true(GameSession.start_level(_first_level()))
    # 未翻格 → 不计
    GameSession._tick(0.5)
    assert_almost_eq(GameSession.elapsed, 0.0, 0.001, "未起表不累计")
    # 起表 → 累计
    GameSession.timer_started = true
    var before: float = GameSession.elapsed
    GameSession._tick(0.5)
    assert_gt(GameSession.elapsed, before + 0.4, "PLAYING 应累计")
    # PAUSED → 不计
    GameSession.set_paused(true)
    before = GameSession.elapsed
    GameSession._tick(0.5)
    assert_almost_eq(GameSession.elapsed, before, 0.001, "PAUSED 不累计")
    # ENDED → 不计
    GameSession.state = GameSession.State.PLAYING
    GameSession._tick(0.1)
    GameSession.state = GameSession.State.ENDED
    before = GameSession.elapsed
    GameSession._tick(0.5)
    assert_almost_eq(GameSession.elapsed, before, 0.001, "ENDED 不累计")


# T11：restart 后 elapsed == 0、state == PLAYING、timer 归零
func test_t11_restart_resets() -> void:
    assert_true(GameSession.start_level(_first_level()))
    GameSession.timer_started = true
    GameSession._tick(3.0)
    assert_gt(GameSession.elapsed, 2.0)

    GameSession.restart()
    assert_eq(GameSession.state, GameSession.State.PLAYING)
    assert_almost_eq(GameSession.elapsed, 0.0, 0.001)
    assert_false(GameSession.timer_started)
    assert_not_null(GameSession.board)


# T11b：restore_from_save 状态恢复（盘面精确一致的核心路径）
func test_t11b_restore_from_save() -> void:
    assert_true(GameSession.start_level(_first_level()))
    # 预设 elapsed：reveal 内的首次自动存档（无防抖）将写入 42.0
    GameSession.elapsed = 42.0
    # 翻开一格（选安全格；GDScript 无标签循环，用 found 标志）
    var revealed_one: Vector2i = Vector2i(-1, -1)
    var found := false
    var size := GameSession.board.grid.size()
    for r in size.y:
        if found:
            break
        for c in size.x:
            var cell := GameSession.board.grid.get_cell(Vector2i(c, r))
            if cell.state == Cell.State.HIDDEN and not cell.is_mine:
                GameSession.reveal(Vector2i(c, r))
                revealed_one = Vector2i(c, r)
                found = true
                break
    assert_true(found, "应找到可翻开的安全格")
    assert_eq(GameSession.board.grid.get_cell(revealed_one).state, Cell.State.REVEALED)
    assert_true(FileAccess.file_exists("user://save.json"), "reveal 应触发首次自动存档")

    # 模拟杀进程后的恢复
    GameSession.state = GameSession.State.IDLE
    GameSession.board = null
    GameSession.elapsed = 0.0
    assert_true(GameSession.restore_from_save())
    assert_eq(GameSession.state, GameSession.State.PLAYING)
    assert_almost_eq(GameSession.elapsed, 42.0, 0.001)
    assert_eq(GameSession.level_path, _first_level())
    # 翻开的格子在恢复后仍是 REVEALED
    assert_eq(GameSession.board.grid.get_cell(revealed_one).state, Cell.State.REVEALED)


# T11c：restore 失败路径（无档 → false）
func test_t11c_restore_no_save_fails() -> void:
    assert_false(GameSession.restore_from_save())
    assert_eq(GameSession.state, GameSession.State.IDLE)
