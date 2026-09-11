# test_level_loader.gd —— T4 扫描排序 / T5 全量载入 / T6 异常路径【plan1.1 §10.12.4】
# 事实基线（Step 0 核对）：levels/ 实际 10 关（文档写 13，以代码为准）。
extends GutTest


# T4：list_levels() 非空、经典优先、变体随后（P1 后 levels/ 含变体关卡）
func test_t4_list_sorted() -> void:
    var levels := LevelLoader.list_levels()
    assert_gt(levels.size(), 10, "关卡列表应含经典 + 变体")
    # 经典关卡全部排在最前，其后才是变体关卡
    var seen_non_classic := false
    for p in levels:
        var is_classic: bool = p.get_file().begins_with("classic_")
        if is_classic:
            assert_false(seen_non_classic, "经典关卡应排最前: " + p)
        else:
            seen_non_classic = true


# T5：全部关卡 load_level 成功且结构一致（P1 后不再假定 10 雷 / 5x5）
func test_t5_all_levels_load() -> void:
    var levels := LevelLoader.list_levels()
    for p in levels:
        var b: Board = LevelLoader.load_level(p)
        assert_not_null(b, "载入失败: " + p)
        if b == null:
            continue
        assert_not_null(b.grid, "grid 未构造: " + p)
        var data := _load_json(p)
        var rows: int = int(data["size"]["rows"])
        var cols: int = int(data["size"]["cols"])
        assert_eq(b.grid.size(), Vector2i(cols, rows), "棋盘尺寸: " + p)
        assert_eq(b.total_mines, int(data["total_mines"]), "雷数: " + p)
        assert_eq(b.get_mine_positions().size(), b.total_mines, "雷位数量: " + p)
        # 初始态非 LOST（PLAYING 或 WON 均可；WON = 开局即全翻开，可玩但过易）
        assert_true(b.state != Board.GameState.LOST, "初始态非 LOST: " + p)


func _load_json(path: String) -> Dictionary:
    var f := FileAccess.open(path, FileAccess.READ)
    var d: Variant = JSON.parse_string(f.get_as_text())
    f.close()
    return d if d is Dictionary else {}


# T6：不存在路径返回 null（不崩溃）
func test_t6_missing_path_null() -> void:
    var b: Board = LevelLoader.load_level("res://levels/classic_99.json")
    assert_null(b)
    # 显式声明「本次调用预期会 push_error 一条」。
    # 不声明的话 GUT 会把预期内的报错判成 Unexpected Errors → 测试假失败；
    # 声明后既消费掉错误，又顺带验证了「确实报了且只报了一条」。
    assert_push_error_count(1)


# 附加：显示名规则（JSON name 字段 / 文件名回退）
func test_level_display_name() -> void:
    var levels := LevelLoader.list_levels()
    assert_gt(levels.size(), 0)
    var name := LevelLoader.get_level_name(levels[0])
    assert_eq(name, "classic_01", "JSON name 字段 = 文件名")
