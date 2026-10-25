# example_mod.gd —— 内置示例规则包（mod 系统"开箱可玩"）
# 目的：mod 系统此前只有引擎与 UI，没有任何现成规则包，玩家进模组页只会看到"未找到可用模组"。
# 本类把两个示例 Def（1 线索 + 1 约束）写到 user://mods/example/defs/，供模组页加载与生成关卡。
# Def 字段格式与 ModLoader 一致（见 test_mod_loader.gd）。
class_name ExampleMod
extends RefCounted

const MOD_NAME := "example"

## 示例 Def 列表（JSON 字符串；与 ModLoader 的 IR 原子一一对应）
const DEFS := {
    "clue_example_n4.json": '{"defName": "ExampleN4", "type": "clue", "window": "n4", "aggregate": "sum", "value_range": [0, 4], "empty_value": 0}',
    "constraint_example_mirror.json": '{"defName": "ExampleMirror", "type": "constraint", "op": "symmetry_axis", "axis": "vertical"}',
}


## 写入示例规则包。返回 { ok, dir, count, reason }。已存在则覆盖（示例包无用户数据）。
static func install() -> Dictionary:
    var dir := "user://mods/%s/defs" % MOD_NAME
    if DirAccess.make_dir_recursive_absolute(dir) != OK:
        return {"ok": false, "dir": dir, "count": 0, "reason": "目录创建失败"}
    var count := 0
    for fname in DEFS:
        var f := FileAccess.open(dir.path_join(fname), FileAccess.WRITE)
        if f == null:
            return {"ok": false, "dir": dir, "count": count, "reason": "写入失败：" + fname}
        f.store_string(DEFS[fname])
        f.close()
        count += 1
    return {"ok": true, "dir": dir, "count": count, "reason": ""}


## 是否已安装（defs 目录存在且非空）。
static func is_installed() -> bool:
    var d := DirAccess.open("user://mods/%s/defs" % MOD_NAME)
    if d == null:
        return false
    d.list_dir_begin()
    var fname := d.get_next()
    var found := false
    while fname != "":
        if fname.ends_with(".json"):
            found = true
            break
        fname = d.get_next()
    d.list_dir_end()
    return found


## 卸载示例包（测试/清理用；会删除该目录下所有 json）。
static func uninstall() -> void:
    var dir := "user://mods/%s/defs" % MOD_NAME
    var d := DirAccess.open(dir)
    if d == null:
        return
    d.list_dir_begin()
    var fname := d.get_next()
    while fname != "":
        if fname.ends_with(".json"):
            d.remove(fname)
        fname = d.get_next()
    d.list_dir_end()
