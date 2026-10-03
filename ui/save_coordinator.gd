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
    var starred: Array[Vector2i] = []
    if board != null and board.grid != null:
        # 遍历用 all_positions()（v2.9.3 修复）：AdjacencyGrid.size() 是包围盒、坐标不连续，
        # 直接按 size 双重循环会把洞格的 get_cell()==null 当 Cell 用 → 空引用错误
        #（异形关卡自动存档必崩）。矩形棋盘下两者等价。与 board.get_stats() 同模式。
        for pos in board.grid.all_positions():
            var cell := board.grid.get_cell(pos)
            if cell == null:
                continue
            match cell.state:
                Cell.State.REVEALED:
                    revealed.append(pos)
                Cell.State.FLAGGED:
                    flagged.append(pos)
            # 终极模式星号格（值隐藏的线索格）：不入档则恢复后线索值直接暴露（星号语义丢失）
            if cell.starred:
                starred.append(pos)
        mines = board.get_mine_positions()
    sd.revealed_cells = revealed
    sd.flagged_cells = flagged
    sd.timer_seconds = elapsed
    sd.mine_positions = mines
    sd.seed_value = 0  # 仅元数据，恢复不依赖
    var meta := {}
    meta["level_path"] = level_path
    meta["ended"] = ended
    # 终极模式星号 / 演绎确证雷集（T3 合规：只进 metadata，顶层 6 字段锁死）。
    # proven_mines 不入档 → 恢复后「只剩 1 格却推不动」的假卡死防护失效（见 board.gd 头注释）。
    if not starred.is_empty():
        meta["starred"] = _pairs(starred)
    if board != null and not board.proven_mines.is_empty():
        meta["proven_mines"] = _pairs(board.proven_mines.keys())
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

    # ⑤ 原子替换主档（bak 三步：MAIN→.bak → TEMP→MAIN → 删 .bak）。
    # 旧实现 remove(MAIN)→rename(TEMP) 存在丢失窗口：两步之间崩溃 = MAIN 消失且 TEMP
    # 未改名；Windows 上 rename 被杀毒/索引器短暂占用失败同样如此——每步检查 Error。
    var bak := MAIN + ".bak"
    if FileAccess.file_exists(bak):
        DirAccess.remove_absolute(bak)
    if FileAccess.file_exists(MAIN):
        if DirAccess.rename_absolute(MAIN, bak) != OK:
            push_error("存档替换失败：MAIN 无法改名（可能被占用），保留旧档")
            DirAccess.remove_absolute(TEMP)
            return
    if DirAccess.rename_absolute(TEMP, MAIN) != OK:
        push_error("存档替换失败：TEMP 无法改名为 MAIN，回滚旧档")
        if FileAccess.file_exists(bak):
            DirAccess.rename_absolute(bak, MAIN)
        return
    if FileAccess.file_exists(bak):
        DirAccess.remove_absolute(bak)

    # ⑥ 重写 TEMP（「进行中对局」存活标志，供崩溃检测）
    var f2 := FileAccess.open(TEMP, FileAccess.WRITE)
    if f2 != null:
        f2.store_string(json)
        f2.close()


static func _fields_ok(d: Dictionary) -> bool:
    for k in _FIELDS:
        if not d.has(k):
            return false
    # 类型校验：JSON 手改/损坏可能产生「键在类型错」的档——restore_from_save 的强类型
    # 赋值（var meta: Dictionary = d["metadata"]）会脚本崩溃而非走 quarantine 坏档隔离，
    # 此处统一拦截 → load_save 返回 {} → 调用方按坏档隔离处理。
    if not (d["metadata"] is Dictionary):
        return false
    for k in ["revealed_cells", "flagged_cells", "mine_positions"]:
        if not (d[k] is Array):
            return false
    return true


## 读主档 → Dictionary；无档/解析失败/字段类型错返回 {}（调用方按坏档隔离处理）。
## MAIN 缺失/损坏时回退读 TEMP：bak 三步把 MAIN 消失窗口缩到最小，TEMP（第 ⑥ 步）
## 总保留最近一次成功写盘的内容，作为最后兜底。
static func load_save() -> Dictionary:
    var d := _parse_json_file(MAIN)
    if d.is_empty() and FileAccess.file_exists(TEMP):
        var fallback := _parse_json_file(TEMP)
        if not fallback.is_empty() and _fields_ok(fallback):
            return fallback
    return d


static func _parse_json_file(path: String) -> Dictionary:
    if not FileAccess.file_exists(path):
        return {}
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    if parsed is Dictionary and _fields_ok(parsed):
        return parsed
    return {}


## Vector2i 数组 → [row, col] 对（save_data.gd 序列化约定）。
static func _pairs(arr: Array) -> Array:
    var out: Array = []
    for v in arr:
        out.append([v.y, v.x])
    return out


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


# ============ 绘画草稿按关卡持久化（v3.3） ============
#
# 草稿独立于对局存档（save.json 是单槽，通关/换关即被覆盖）：
# 按 level_path 哈希落 user://drawings/<md5>.json → 通关后重进本关草稿仍在。
# 清除时机：玩家手动清空绘画（空数据 = 删除）、重开关卡（GameSession.restart）。
# 「绘画草稿存入存档」关闭时不读不写（进入即全新开始）。

const DRAWING_DIR := "user://drawings"


static func _drawing_path(level_path: String) -> String:
    return DRAWING_DIR + "/" + level_path.md5_text() + ".json"


static func save_drawing(level_path: String, data: Dictionary) -> void:
    if level_path == "":
        return
    var strokes_v: Variant = data.get("strokes", [])
    if data.is_empty() or not (strokes_v is Array) or (strokes_v as Array).is_empty():
        clear_drawing(level_path)  # 空草稿 = 清除（玩家手动清空绘画）
        return
    DirAccess.make_dir_recursive_absolute(DRAWING_DIR)
    var f := FileAccess.open(_drawing_path(level_path), FileAccess.WRITE)
    if f == null:
        push_error("绘画草稿写入失败: " + level_path)
        return
    f.store_string(JSON.stringify(data))
    f.close()


static func load_drawing(level_path: String) -> Dictionary:
    if level_path == "":
        return {}
    var p := _drawing_path(level_path)
    if not FileAccess.file_exists(p):
        return {}
    var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
    return v if v is Dictionary else {}


static func clear_drawing(level_path: String) -> void:
    if level_path == "":
        return
    var p := _drawing_path(level_path)
    if FileAccess.file_exists(p):
        DirAccess.remove_absolute(p)


## 清空全部按关绘画草稿（v3.3：关闭「绘画草稿存入存档」开关时调用）。
static func clear_all_drawings() -> void:
    var dir := DirAccess.open(DRAWING_DIR)
    if dir == null:
        return  # 目录不存在 = 本来就没有草稿
    dir.list_dir_begin()
    var fname := dir.get_next()
    while fname != "":
        if not dir.current_is_dir() and fname.ends_with(".json"):
            dir.remove(fname)
        fname = dir.get_next()
    dir.list_dir_end()


# ============ 历史快照：全局磁盘配额 + 内容哈希去重（v3.4 / 数据爆炸 F） ============
#
# 快照 = 整份关卡 JSON 的历史副本，独立于存档主流程（MAIN/TEMP/.bak 的语义一律不动）。
# 三条硬约束：
#   1) 内容哈希去重：JSON 规范化（键排序）后取 md5，**文件名即哈希** ⇒ 相同内容再存 =
#      命中已有文件、不再落盘（挂机反复保存不会堆一堆相同快照）。
#   2) 全局配额：整个 user://snapshots 目录的字节总量超限 → 按写入序号从旧到新删。
#      配额是**全局**的，不按关卡分份。
#   3) 绝不碰主流程文件：本子系统只读写 SNAPSHOT_DIR 内的 *.json；MAIN/TEMP/.bak 不在该目录，
#      物理上不可能被误删（clear_snapshots 也只删目录内文件）。

const SNAPSHOT_DIR := "user://snapshots"
## 全局配额依据：单份对局存档（revealed/flagged/mine_positions/metadata）通常 < 50KB；
## 快照存整份关卡 JSON（多为几 KB~几十 KB，大关卡也 < 200KB）。取 8 MiB ≈
## 可留 ~160 份 50KB / 数百份小关卡，足以覆盖"最近少量历史 + 崩溃回滚"，
## 又给 user:// 一个明确上限（不是每关卡一份，故不会随关卡数线性膨胀）。
const SNAPSHOT_QUOTA_BYTES := 8 * 1024 * 1024
## 可注入配额（单测把配额调小以验证淘汰逻辑，避免真写 8 MiB）。
static var snapshot_quota_bytes: int = SNAPSHOT_QUOTA_BYTES


## 写一份快照；返回落盘路径（内容去重命中 = 返回已有路径）。写入失败返回 ""。
## 只操作 SNAPSHOT_DIR 内的文件，不触碰 MAIN/TEMP/.bak。
static func write_snapshot(data: Dictionary) -> String:
    return write_snapshot_to(SNAPSHOT_DIR, data)


## write_snapshot 的可指定目录版本（单测隔离用）。
static func write_snapshot_to(dir_path: String, data: Dictionary) -> String:
    # 键排序保证「内容相同、键序不同」得到同一哈希 ⇒ 跨机器/跨次调用去重结果一致。
    var json := JSON.stringify(data, "", true)
    var hash := json.md5_text()
    var existing := _find_snapshot_by_hash(dir_path, hash)
    if existing != "":
        return existing  # 内容完全相同 → 不重复落盘
    DirAccess.make_dir_recursive_absolute(dir_path)
    var path := "%s/%010d_%s.json" % [dir_path, _next_snapshot_seq(dir_path), hash]
    var f := FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        push_error("快照写入失败: " + path)
        return ""
    f.store_string(json)
    f.close()
    prune_snapshots(dir_path)
    return path


## 全局配额淘汰：总量超限时从最旧（序号最小）开始删，至少保留最新一份。
## 返回删除的份数。只删目录内的快照文件。
static func prune_snapshots(dir_path: String = SNAPSHOT_DIR) -> int:
    var files := list_snapshots(dir_path)  # 已按文件名（= 写入序号）升序，最旧在前
    var total := snapshot_total_bytes(dir_path)
    var removed := 0
    var i := 0
    # 条件 `i < files.size() - 1` + `files.size() - removed > 1` 双重保证最新一份永不被删。
    while total > snapshot_quota_bytes and files.size() - removed > 1 and i < files.size() - 1:
        var p: String = files[i]
        var sz := _file_size(p)
        if DirAccess.remove_absolute(p) == OK:
            total -= sz
            removed += 1
        i += 1
    return removed


## 目录内快照路径，按写入序号（文件名前缀）升序 = 最旧 → 最新。
static func list_snapshots(dir_path: String = SNAPSHOT_DIR) -> PackedStringArray:
    var out := PackedStringArray()
    var dir := DirAccess.open(dir_path)
    if dir == null:
        return out
    dir.list_dir_begin()
    var fname := dir.get_next()
    while fname != "":
        if not dir.current_is_dir() and fname.ends_with(".json"):
            out.append(dir_path + "/" + fname)
        fname = dir.get_next()
    dir.list_dir_end()
    out.sort()  # 文件名前缀为零填充序号 ⇒ 字典序 = 写入序
    return out


## 目录内快照字节总量（配额判据）。
static func snapshot_total_bytes(dir_path: String = SNAPSHOT_DIR) -> int:
    var total := 0
    for p in list_snapshots(dir_path):
        total += _file_size(p)
    return total


## 清空目录内全部快照（只删 SNAPSHOT_DIR 内的 *.json，不影响主档）。
static func clear_snapshots(dir_path: String = SNAPSHOT_DIR) -> void:
    for p in list_snapshots(dir_path):
        DirAccess.remove_absolute(p)


static func _file_size(path: String) -> int:
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return 0
    var n := f.get_length()
    f.close()
    return n


## 文件名 `<010 位序号>_<md5>.json`；命中同哈希文件即返回其路径（= 去重）。
static func _find_snapshot_by_hash(dir_path: String, hash: String) -> String:
    for p in list_snapshots(dir_path):
        var base := p.get_file().get_basename()
        var us := base.find("_")
        if us >= 0 and base.substr(us + 1) == hash:
            return p
    return ""


## 下一个写入序号 = 目录内最大序号 + 1（跨次运行仍单调，保证"最旧"可判定）。
static func _next_snapshot_seq(dir_path: String) -> int:
    var max_seq := 0
    for p in list_snapshots(dir_path):
        var base := p.get_file().get_basename()
        var us := base.find("_")
        if us > 0:
            max_seq = maxi(max_seq, int(base.substr(0, us)))
    return max_seq + 1
