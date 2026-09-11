# save_coordinator.gd —— 三段式存档 + 崩溃残留检测 + 坏档隔离【plan1.1 §10.7.4】
# 读档直接读 mine_positions 恢复，禁止「存 seed + 重放生成」（判负基准纯净性）。
# TEMP = 「进行中对局」存活标志（§10.10.3），不是单纯的写入中转。
class_name SaveCoordinator
extends RefCounted

const MAIN := "user://save.json"
const TEMP := "user://save_temp.json"

const _FIELDS := ["revealed_cells", "flagged_cells", "timer_seconds", "mine_positions", "seed_value", "metadata"]


## 组装 SaveData 并三段式写入。
## 字段与序：Step 0 第 4 项核对的 save_data.gd 实际为准（禁止新增/改名）。
## metadata.level_path 必写（不写则恢复后按 R 重开会因 level_path 为空而崩溃）。
## 〔偏离〕level_path 由调用方传入（文档骨架为 static 内读 GameSession；
## static 上下文引用 autoload 在 --check-only 独立解析下报 Identifier not found，故参数化）。
## ended=true 表示这是「终局盘」快照（失败后落盘），恢复时必须拒绝，
## 否则失败局连同已引爆的雷被读回并判为 PLAYING，形成 SL 复活作弊。
static func save(board: Board, elapsed: float, level_path: String = "", drawing: Dictionary = {}, ended: bool = false) -> void:
    var sd := SaveData.new()
    var revealed: Array[Vector2i] = []
    var flagged: Array[Vector2i] = []
    var mines: Array[Vector2i] = []
    if board != null and board.grid != null:
        var size := board.grid.size()  # Vector2i(cols, rows)
        for r in size.y:
            for c in size.x:
                var cell := board.grid.get_cell(Vector2i(c, r))
                match cell.state:
                    Cell.State.REVEALED:
                        revealed.append(Vector2i(c, r))
                    Cell.State.FLAGGED:
                        flagged.append(Vector2i(c, r))
        mines = board.get_mine_positions()
    sd.revealed_cells = revealed
    sd.flagged_cells = flagged
    sd.timer_seconds = elapsed
    sd.mine_positions = mines
    sd.seed_value = 0  # 仅元数据，恢复不依赖
    var meta := {}
    meta["level_path"] = level_path
    meta["ended"] = ended
    if not drawing.is_empty():
        meta["drawing"] = drawing  # 绘画数据（独立于游戏状态，恢复时一并还原）
    sd.metadata = meta

    var json := JSON.stringify(sd.to_dict())

    # ③ 写 TEMP
    var f := FileAccess.open(TEMP, FileAccess.WRITE)
    if f == null:
        push_error("存档写 TEMP 失败")
        return
    f.store_string(json)
    f.close()

    # ④ 回读校验
    var back: Variant = JSON.parse_string(FileAccess.get_file_as_string(TEMP))
    if not (back is Dictionary) or not _fields_ok(back):
        # 校验失败 → 删 TEMP 并放弃本次存档（不破坏既有 MAIN）
        DirAccess.remove_absolute(TEMP)
        return

    # ⑤ 原子替换主档
    if FileAccess.file_exists(MAIN):
        DirAccess.remove_absolute(MAIN)
    DirAccess.rename_absolute(TEMP, MAIN)

    # ⑥ 重写 TEMP（「进行中对局」存活标志，供崩溃检测）
    var f2 := FileAccess.open(TEMP, FileAccess.WRITE)
    if f2 != null:
        f2.store_string(json)
        f2.close()


static func _fields_ok(d: Dictionary) -> bool:
    for k in _FIELDS:
        if not d.has(k):
            return false
    return true


## 读主档 → Dictionary；无档/解析失败返回 {}。
static func load_save() -> Dictionary:
    if not FileAccess.file_exists(MAIN):
        return {}
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MAIN))
    if parsed is Dictionary:
        return parsed
    return {}


## TEMP 残留 = 上次在对局中异常终止。
static func has_crash_leftover() -> bool:
    return FileAccess.file_exists(TEMP)


## 删 MAIN + TEMP（主动结束对局 / 放弃恢复）。
static func clear() -> void:
    if FileAccess.file_exists(MAIN):
        DirAccess.remove_absolute(MAIN)
    if FileAccess.file_exists(TEMP):
        DirAccess.remove_absolute(TEMP)


## 仅删 TEMP（终局 / 恢复成功后）。
static func clear_temp() -> void:
    if FileAccess.file_exists(TEMP):
        DirAccess.remove_absolute(TEMP)


## 坏档隔离：MAIN 存在但解析失败/关键字段缺失时调用。
## MAIN → MAIN.bak（.bak 已存在则先删），再清 TEMP。调用方显示 toast 并留在主菜单。
static func quarantine() -> void:
    if FileAccess.file_exists(MAIN):
        var bak := MAIN + ".bak"
        if FileAccess.file_exists(bak):
            DirAccess.remove_absolute(bak)
        DirAccess.rename_absolute(MAIN, bak)
    clear_temp()
