# level_validator.gd —— 关卡结构校验（GDD 13 号 §13.4 第 2 步的结构校验子集）
#
# 纯语法、O(R·C)、零求解器依赖的结构合法性检查，用于：
#   - 关卡加载前的快速拦截（坏文件/雷格?后门/越界/重复）；
#   - 工坊上传体检流水线的「结构校验」前置；
#   - 测试门禁（levels/ 每关必须结构合法）。
#
# 当前覆盖（对齐 13.4 第 2 步）：
#   ① 尺寸/雷数合法（0 < 雷数 < R·C）
#   ② 雷位越界 / 重复
#   ③ 初始翻开格越界 / 重复
#   ④ 初始翻开格不落在雷上（「雷格 ? 后门」拦截）
# 不含：规则包哈希、L4 解数、序贯认证（那是 3~6 步，属离线体检，非结构校验）。
class_name LevelValidator
extends RefCounted


## 结构校验。返回 { "ok": bool, "reason": String }（ok=true 时 reason 为空）。
static func validate_structure(level: Dictionary) -> Dictionary:
	var size: Dictionary = level.get("size", {})
	var cols := int(size.get("cols", 0))
	var rows := int(size.get("rows", 0))
	if cols <= 0 or rows <= 0:
		return {"ok": false, "reason": "尺寸非法（%dx%d）" % [cols, rows]}
	var total_mines := int(level.get("total_mines", 0))
	if total_mines <= 0 or total_mines >= cols * rows:
		return {"ok": false, "reason": "雷数非法：%d（须 0 < 雷数 < %d）" % [total_mines, cols * rows]}

	var mine_set := {}
	for m in level.get("mines", []):
		var c := int(m.get("c", -1))
		var r := int(m.get("r", -1))
		if c < 0 or c >= cols or r < 0 or r >= rows:
			return {"ok": false, "reason": "雷位越界 (%d,%d)" % [c, r]}
		var key := Vector2i(c, r)
		if mine_set.has(key):
			return {"ok": false, "reason": "雷位重复 (%d,%d)" % [c, r]}
		mine_set[key] = true

	var seen := {}
	for rc in level.get("revealed", []):
		var c := int(rc.get("c", -1))
		var r := int(rc.get("r", -1))
		if c < 0 or c >= cols or r < 0 or r >= rows:
			return {"ok": false, "reason": "初始翻开格越界 (%d,%d)" % [c, r]}
		var key := Vector2i(c, r)
		if seen.has(key):
			return {"ok": false, "reason": "初始翻开格重复 (%d,%d)" % [c, r]}
		if mine_set.has(key):
			return {"ok": false, "reason": "初始翻开格是雷 (%d,%d)（雷格 ? 后门）" % [c, r]}
		seen[key] = true
	return {"ok": true, "reason": ""}
