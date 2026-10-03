# level_guard.gd —— 【清单·数据爆炸 I：输入侧异常大数】**加载期总量校验拒载**
#
# 为什么单独成文件：清单第十节要求这类**防线全局统一实现**（各功能私自处理会导致行为互相矛盾）。
# 现状盘点：玩家侧加载器（`ui/level_loader.gd`）本来就有"字节数 + 格数 + 越界"拦截，但
# **编辑器的粘贴/导入路径绕开了它** —— 一段"合法但巨大"的 JSON（声明 10 万格）能让编辑器当场卡死。
# 所以把口径收成一组**纯函数**（可单测、可被任何入口复用），凡"外部来的关卡数据"先过这道闸。
class_name LevelGuard
extends RefCounted

## 与玩家侧加载器同口径：单份关卡数据 2MB。
const MAX_BYTES := 2 * 1024 * 1024
## 单边上限（与 `core/wrap_topology.gd` / 编辑器自身上限一致）。
const MAX_SIDE := 4096
## 可编辑格数上限（与 `core/editor_doc.gd` 的自身上限同口径）。
const MAX_CELLS := 4096


## 闸门一：**先看字节数**，先于解析 —— 巨大文本连 `parse_json` 都不该跑。
static func check_text(text: String) -> Dictionary:
	if text.length() > MAX_BYTES:
		return {"ok": false, "reason": "文本太大（%.1f MB，上限 %d MB）—— 这不像一份关卡，先别导入"
			% [text.length() / 1048576.0, MAX_BYTES / 1048576]}
	return {"ok": true, "reason": ""}


## 闸门二：解析之后、灌进文档之前，检查**声明的规模**（尺寸 / 雷位 / 障碍 / 初始翻开）。
## 拒绝时给的是"人话 + 出路"，不是断言信息（清单要求：超限提示三条出路之一）。
static func check_level(lv: Dictionary) -> Dictionary:
	var size: Variant = lv.get("size", {})
	if size is Dictionary:
		var rows := int((size as Dictionary).get("rows", 0))
		var cols := int((size as Dictionary).get("cols", 0))
		if rows <= 0 or cols <= 0:
			return {"ok": false, "reason": "棋盘尺寸非法（%d×%d）" % [rows, cols]}
		if rows > MAX_SIDE or cols > MAX_SIDE:
			return {"ok": false, "reason": "棋盘太大（%d×%d，单边上限 %d）—— 把尺寸改小再导入"
				% [rows, cols, MAX_SIDE]}
		var cells := rows * cols
		if cells > MAX_CELLS:
			return {"ok": false, "reason": "格子数 %d 超过上限 %d —— 把尺寸改小再导入" % [cells, MAX_CELLS]}
	for key in ["mines", "obstacles"]:
		var arr: Variant = lv.get(key, [])
		if arr is Array and (arr as Array).size() > MAX_CELLS:
			return {"ok": false, "reason": "%s 有 %d 条，超过上限 %d（数据可疑，已拒绝）"
				% [key, (arr as Array).size(), MAX_CELLS]}
	var rev: Variant = lv.get("revealed", {})
	if rev is Dictionary and (rev as Dictionary).size() > MAX_CELLS:
		return {"ok": false, "reason": "初始翻开有 %d 格，超过上限 %d（数据可疑，已拒绝）"
			% [(rev as Dictionary).size(), MAX_CELLS]}
	return {"ok": true, "reason": ""}
