# level_loader.gd —— 关卡 JSON → Board 构造【plan1.1 §10.7.3】
# 字段名以实际 JSON 为准（Step 0 第 1 项核对结论）：
#   name / size{rows,cols} / total_mines / mines[{r,c}] / revealed[{r,c,value?|interval?}]
# loader 不做规则层工作（判重、线索计算都在引擎内）。
class_name LevelLoader
extends RefCounted


## 扫描 res://levels/ 下所有 *.json 关卡（经典 + 变体）。经典优先、其余按文件名升序。
static func list_levels() -> Array[String]:
    var out: Array[String] = []
    var dir := DirAccess.open("res://levels")
    if dir == null:
        push_error("levels 目录不存在")
        return out
    var classic: Array[String] = []
    var others: Array[String] = []
    dir.list_dir_begin()
    var fname: String = dir.get_next()
    while fname != "":
        if fname.ends_with(".json"):
            if fname.begins_with("classic_"):
                classic.append(fname)
            else:
                others.append(fname)
        fname = dir.get_next()
    dir.list_dir_end()
    classic.sort()
    others.sort()
    for n in classic + others:
        out.append("res://levels/" + n)
    return out


## 扫描已加载 mod 的关卡目录 user://mods/*/levels/*.json。
static func list_mod_levels() -> Array[String]:
    var out: Array[String] = []
    for mod_name in ModService.loaded_mods:
        var dir_path := "user://mods/%s/levels" % mod_name
        var dir := DirAccess.open(dir_path)
        if dir == null:
            continue
        dir.list_dir_begin()
        var fname := dir.get_next()
        while fname != "":
            if not dir.current_is_dir() and fname.ends_with(".json"):
                out.append(dir_path.path_join(fname))
            fname = dir.get_next()
        dir.list_dir_end()
    out.sort()
    return out


## 关卡变体中文名（无 variant 字段视为经典；支持混合码 "布局+线索"）。
static func get_variant_name(path: String) -> String:
    var d: Variant = _parse_file(path)
    if d is Dictionary and d.has("variant"):
        var code: String = str(d["variant"])
        var def := VariantRegistry.resolve(code)
        if not def.is_empty():
            return str(def["name"])
    return "经典"


## 关卡显示名：JSON 有 name 字段用之；否则文件名去后缀（§8.5 关卡条目）。
static func get_level_name(path: String) -> String:
    var d: Variant = _parse_file(path)
    if d is Dictionary and d.has("name") and str(d["name"]) != "":
        return str(d["name"])
    return path.get_file().get_basename()


## 关卡变体类别（供选关页分组浏览）。返回：
##   "经典" / "布局型" / "线索型" / "一布局一线索" / "线索混合" / "双布局"
static func classify_variant(path: String) -> String:
    var d: Variant = _parse_file(path)
    if not (d is Dictionary):
        return "经典"
    var code: String = str(d.get("variant", ""))
    if code == "":
        return "经典"
    var def := VariantRegistry.resolve(code)
    if def.is_empty():
        return "经典"
    if int(def.get("clue2", -1)) >= 0:
        return "线索混合"
    if int(def.get("constraint2", -1)) >= 0:
        return "双布局"
    if int(def.get("constraint", -1)) >= 0:
        if code.contains("+"):
            return "一布局一线索"
        return "布局型"
    return "线索型"


static func _parse_file(path: String) -> Variant:
    if not FileAccess.file_exists(path):
        return null
    var text := FileAccess.get_file_as_string(path)
    return JSON.parse_string(text)


## 加载关卡 → 返回就绪 Board；任一校验失败 → push_error + null。
static func load_level(path: String) -> Board:
    var parsed: Variant = _parse_file(path)
    if not (parsed is Dictionary):
        push_error("关卡解析失败: " + path)
        return null
    var d: Dictionary = parsed
    return _validate_and_build(d, path)


static func _validate_and_build(d: Dictionary, path: String) -> Board:
    # 结构字段
    if not (d.has("size") and d["size"] is Dictionary):
        push_error("关卡缺 size: " + path)
        return null
    var rows: int = int(d["size"].get("rows", 0))
    var cols: int = int(d["size"].get("cols", 0))
    if rows <= 0 or cols <= 0:
        push_error("关卡尺寸非法: " + path)
        return null
    var total_mines: int = int(d.get("total_mines", -1))
    if total_mines <= 0 or total_mines >= rows * cols:
        push_error("关卡雷数非法: " + path)
        return null

    # 雷位：界内、无重复
    var mines: Array = d.get("mines", [])
    if mines.size() != total_mines:
        push_error("雷位数与 total_mines 不符: " + path)
        return null
    var mine_keys := {}
    for m in mines:
        if not (m is Dictionary) or not m.has("r") or not m.has("c"):
            push_error("雷位缺坐标: " + path)
            return null
        var mr: int = int(m["r"])
        var mc: int = int(m["c"])
        if mr < 0 or mr >= rows or mc < 0 or mc >= cols:
            push_error("雷位越界: " + path)
            return null
        var mkey := Vector2i(mc, mr)
        if mine_keys.has(mkey):
            push_error("雷位重复: " + path)
            return null
        mine_keys[mkey] = true

    # 初始翻开格：界内、非雷、无重复
    var revealed: Array = d.get("revealed", [])
    var rkeys := {}
    for rv in revealed:
        if not (rv is Dictionary) or not rv.has("r") or not rv.has("c"):
            push_error("初始翻开格缺坐标: " + path)
            return null
        var rr: int = int(rv["r"])
        var cc: int = int(rv["c"])
        if rr < 0 or rr >= rows or cc < 0 or cc >= cols:
            push_error("初始翻开格越界: " + path)
            return null
        var rkey := Vector2i(cc, rr)
        if mine_keys.has(rkey):
            push_error("初始翻开格是雷: " + path)
            return null
        if rkeys.has(rkey):
            push_error("初始翻开格重复: " + path)
            return null
        rkeys[rkey] = true

    # 构造（引擎 API = Board.new() + load_level(dict)，Step 0 第 2 项核对结论）
    var board := Board.new()
    board.load_level(d)
    if board.grid == null or board.total_mines != total_mines:
        push_error("引擎构造棋盘失败: " + path)
        return null
    return board
