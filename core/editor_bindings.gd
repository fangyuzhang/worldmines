extends RefCounted

## 编辑器键位绑定表（文档「二」：**第一天就定好存储格式**）。
##
## 【为什么要独立成表 + 独立段】
## 原来编辑器的快捷键**硬编码**在 `ui/level_editor.gd:_unhandled_key_input` 里（只有 Ctrl+Z/Y/S/C/V），
## 既没有"有哪些动作"的清单，也没有可读写的持久化格式。界面自定义（重绑）可以后做，
## 但**存储格式必须现在就定**，否则将来一改就是"旧 cfg 全部失效"。
##
## 【为什么新建本文件而不改 `ui/settings_manager.gd`】
## 那是**游戏侧**的设置（玩家键位 `[keys]` 段 + 22 项），编辑器是**开发工具**，两套键位
## 互不相干：编辑器把 Tab 当"秒切"，游戏侧 Tab 毫无意义。混进同一个 cfg 只会互相污染。
##
## 【格式】独立段 `[editor_keys]`，一行一个动作：值 = 描述串（如 `"ctrl+z"` / `"space"` / `"alt+click"`）。
## 描述串语法：`ctrl+alt+shift+<键>`，键 token = 单个字母 / 数字 / space / tab / enter / escape /
## backspace / delete / f1..f12 / click（鼠标左键）。**全小写**，便于人工阅读与手改。
##
## 【坑】本文件**不写 `class_name`**：headless 下新全局类不在 `.godot` 缓存里，一旦别的脚本按类名
## 引用就会整份解析失败（见 `ui/level_editor.gd` 顶部与 `ui/tutorial_overlay.gd:12` 记的同一个坑）。
## 用 `preload("res://core/editor_bindings.gd")`。

const PATH := "user://editor_bindings.cfg"
const SECTION := "editor_keys"

## 实际读写路径（成员而非常量：测试要指到临时文件，别去动玩家真实的 cfg）。
var path := PATH

## 动作 → 缺省描述串。**这张表是唯一真源**：UI 提示、事件匹配、存读都读它。
const DEFAULTS := {
	# —— 文档「一、基础操作」——
	"pan_mode": "space",
	# —— 文档「二」：Tab 编辑↔试玩秒切 ——
	"playtest_toggle": "tab",
	# —— 面板焦点切换改 Ctrl+Tab（Tab 已被秒切占用）——
	"panel_focus": "ctrl+tab",
	# —— 显示 ——
	"grid_toggle": "g",
	"symmetry_cycle": "ctrl+g",
	"cheat_toggle": "h",
	# —— 工具（字母助记）——
	# 【2026-10-03 键位语义对齐文档】M/S 让给**格型**（文档：M=放雷、S=强制安全格=初始已翻开），
	# 平移工具 / 区域选择改到不冲突的 P / L。功能一个不删，只调键位（旧 cfg 见 LEGACY_KEYS 迁移）。
	"tool_brush": "b",
	"tool_erase": "e",
	"tool_pan": "p",
	"tool_select": "l",
	# —— 格型直选（文档「画笔颜色」）——
	"kind_mine": "m",
	"kind_safe": "s",
	# —— 数字快选 1~9：①~⑦ 工具（按 EditorCanvas.Tool 顺序）、⑧⑨ 最常用的两个格型 ——
	"digit_1": "1",
	"digit_2": "2",
	"digit_3": "3",
	"digit_4": "4",
	"digit_5": "5",
	"digit_6": "6",
	"digit_7": "7",
	"digit_8": "8",
	"digit_9": "9",
	# —— 编辑动作 ——
	"undo": "ctrl+z",
	"redo": "ctrl+y",
	"copy": "ctrl+c",
	"cut": "ctrl+x",
	"paste": "ctrl+v",
	"duplicate": "ctrl+d",
	"save": "ctrl+s",
	# 【2026-10-03】R / Ctrl+R 让给**选区编辑**（文档：R=选区旋转、Ctrl+R=镜像），
	# 随机布雷 / 重置视图移到不冲突的 Ctrl+N / Ctrl+0。功能一个不丢（左栏按钮同样可用）。
	"rotate_selection": "r",
	"mirror_selection": "ctrl+r",
	"random_mines": "ctrl+n",
	"reset_view": "ctrl+0",
	"eyedropper": "alt+click",
	"help": "f1",
}

## 动作 → 人话名（tooltip / 将来的"改键"界面用；不含 key 名，key 名走 `describe`）。
const LABELS := {
	"pan_mode": "按住空格：临时平移",
	"playtest_toggle": "编辑 ↔ 试玩（秒切）",
	"panel_focus": "下一块面板",
	"grid_toggle": "网格线开关",
	"symmetry_cycle": "对称模式循环（关→竖轴→横轴→四象）",
	"cheat_toggle": "显雷/隐藏（仅编辑态）",
	"tool_brush": "画笔",
	"tool_erase": "橡皮",
	"tool_pan": "平移工具",
	"tool_select": "区域选择",
	"kind_mine": "画笔格型：地雷",
	"kind_safe": "画笔格型：强制安全格",
	"digit_1": "① 画笔",
	"digit_2": "② 橡皮",
	"digit_3": "③ 矩形填充",
	"digit_4": "④ 区域选择",
	"digit_5": "⑤ 平移",
	"digit_6": "⑥ 直线",
	"digit_7": "⑦ 油漆桶",
	"digit_8": "⑧ 地雷格型",
	"digit_9": "⑨ 障碍格型",
	"undo": "撤销",
	"redo": "重做",
	"copy": "复制选区",
	"cut": "剪切选区",
	"paste": "粘贴到选区",
	"duplicate": "原地复制一份（右下偏移）",
	"save": "保存",
	"rotate_selection": "选区旋转 90°（格型守恒）",
	"mirror_selection": "选区镜像（默认左右翻转）",
	"random_mines": "随机布雷",
	"reset_view": "重置视图（缩放/平移归位）",
	"eyedropper": "Alt+点击：吸取该格格型",
	"help": "上下文帮助",
}

## 【兼容处理 2026-10-03】旧 cfg 里 `tool_pan=m` 的**明确迁移**（文档语义调整的配套）。
##
## 为什么必须显式迁移：文档把 M/S 改成格型（m→kind_mine、s→kind_safe）、把 R/Ctrl+R 改成选区编辑
##（r→rotate_selection、ctrl+r→mirror_selection）。若旧 cfg 里仍写着 `tool_pan=m`，而 `kind_mine`
## 的**新缺省**恰好也是 `m`，就会出现"两个动作抢同一个键"（谁在 DEFAULTS 里靠前谁赢）——
## 用户会觉得"我的改键被吃了"。故读回时把**旧值**改写成对应动作的**新缺省**（注：用户把 tool_pan
## 手改成 m 在新方案里本就非法，因为 m 已被 kind_mine 占用）。
const LEGACY_KEYS := {
	"tool_pan": {"m": "p"},
	"tool_select": {"s": "l"},
	"random_mines": {"r": "ctrl+n"},
	"reset_view": {"ctrl+r": "ctrl+0"},
}

## 键 token → Godot 键码（只列**非字母数字**的；字母/数字走 unicode）。
const SPECIAL_KEYS := {
	"space": KEY_SPACE,
	"tab": KEY_TAB,
	"enter": KEY_ENTER,
	"escape": KEY_ESCAPE,
	"backspace": KEY_BACKSPACE,
	"delete": KEY_DELETE,
	"insert": KEY_INSERT,
	"home": KEY_HOME,
	"end": KEY_END,
	"f1": KEY_F1, "f2": KEY_F2, "f3": KEY_F3, "f4": KEY_F4,
	"f5": KEY_F5, "f6": KEY_F6, "f7": KEY_F7, "f8": KEY_F8,
	"f9": KEY_F9, "f10": KEY_F10, "f11": KEY_F11, "f12": KEY_F12,
}
## 反向表（键码 → token），用于 `describe`。
const _CODE_TO_TOKEN := {
	KEY_SPACE: "space", KEY_TAB: "tab", KEY_ENTER: "enter", KEY_ESCAPE: "escape",
	KEY_BACKSPACE: "backspace", KEY_DELETE: "delete", KEY_INSERT: "insert",
	KEY_HOME: "home", KEY_END: "end",
}

## 当前绑定（action → 描述串）。未加载时为空 ⇒ `key_for` 回退 `DEFAULTS`。
var bindings: Dictionary = {}


# ==================== 描述串解析 / 生成（纯函数，可单测） ====================

## 描述串 → {ctrl, alt, shift, meta, key(int), mouse(String), ok(bool)}。
## 解析失败（空串 / 未知 token）返回 ok=false（调用方回退缺省）。
static func parse(desc: String) -> Dictionary:
	var out := {"ctrl": false, "alt": false, "shift": false, "meta": false,
		"key": 0, "mouse": "", "ok": false}
	var s := desc.strip_edges().to_lower()
	if s == "":
		return out
	var parts := s.split("+")
	for i in parts.size():
		var tok := parts[i].strip_edges()
		if tok == "":
			return out
		if i < parts.size() - 1:
			match tok:
				"ctrl", "control": out["ctrl"] = true
				"alt": out["alt"] = true
				"shift": out["shift"] = true
				"meta", "cmd", "super": out["meta"] = true
				_: return out
			continue
		# 最后一个 token = 键本体
		if tok == "click":
			out["mouse"] = "left"
			out["ok"] = true
			return out
		if SPECIAL_KEYS.has(tok):
			out["key"] = int(SPECIAL_KEYS[tok])
			out["ok"] = true
			return out
		if tok.length() == 1:
			var ch := tok.to_upper()
			out["key"] = ch.unicode_at(0)
			out["ok"] = true
			return out
		return out
	return out


## 键码 → 描述串里的 token（`describe` 与回写共用）。
static func token_of(code: int) -> String:
	if _CODE_TO_TOKEN.has(code):
		return str(_CODE_TO_TOKEN[code])
	if code >= KEY_A and code <= KEY_Z:
		return char(code).to_lower()
	if code >= KEY_0 and code <= KEY_9:
		return char(code)
	if code >= KEY_F1 and code <= KEY_F12:
		return "f%d" % (code - KEY_F1 + 1)
	return ""


## 描述串 → 人话（"Ctrl+Z" / "空格" / "Alt+点击"）。空/非法返回"（未设）"。
static func describe(desc: String) -> String:
	var p := parse(desc)
	if not bool(p["ok"]):
		return "（未设）"
	var bits: Array[String] = []
	if bool(p["ctrl"]):
		bits.append("Ctrl")
	if bool(p["alt"]):
		bits.append("Alt")
	if bool(p["shift"]):
		bits.append("Shift")
	if bool(p["meta"]):
		bits.append("Cmd")
	if str(p["mouse"]) != "":
		bits.append("点击")
	else:
		var code := int(p["key"])
		match code:
			KEY_SPACE: bits.append("空格")
			KEY_TAB: bits.append("Tab")
			KEY_ENTER: bits.append("回车")
			KEY_ESCAPE: bits.append("Esc")
			KEY_BACKSPACE: bits.append("退格")
			KEY_DELETE: bits.append("Delete")
			KEY_F1: bits.append("F1")
			KEY_F2: bits.append("F2")
			_:
				var t := token_of(code)
				bits.append(t.to_upper() if t.length() == 1 and not t.is_valid_int() else t)
	if bits.is_empty():
		return "（未设）"
	return "+".join(bits)


# ==================== 读写 ====================

## 从 `[editor_keys]` 段读回。缺段/缺键/脏值一律回退 `DEFAULTS`（**不抛错**）。
func load_cfg() -> void:
	bindings = {}
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return          # 文件不存在 ⇒ 全缺省
	if not cfg.has_section(SECTION):
		return
	for a in DEFAULTS.keys():
		# 必须先查 has_section_key：`get_value(..., null)` 会被引擎当成"没给默认值"并**打 ERROR 日志**
		#（本仓 CI 会把 SCRIPT ERROR 判红）。
		if not cfg.has_section_key(SECTION, str(a)):
			continue
		var raw := str(cfg.get_value(SECTION, str(a), ""))
		if bool(parse(raw)["ok"]):
			bindings[str(a)] = raw
		# 脏值（未知 token / 类型不对）静默忽略 ⇒ `key_for` 回退缺省
	_migrate_legacy()


## 旧版键位 → 新版键位（见 `LEGACY_KEYS`）。幂等：新值不在迁移表里，跑几次结果一样。
func _migrate_legacy() -> void:
	for a in LEGACY_KEYS.keys():
		var moves: Dictionary = LEGACY_KEYS[a]
		var cur := str(bindings.get(str(a), DEFAULTS.get(str(a), "")))
		if moves.has(cur):
			bindings[str(a)] = str(moves[cur])


## 写回。**只写当前表里的动作**（未知/被删除的动作不落盘，避免 cfg 无限膨胀）。
func save() -> void:
	var cfg := ConfigFile.new()
	# 先加载已有文件再覆盖本段：ConfigFile 不做"读-改-写"也能新建写入，
	# 但保留其它段（若有）是更稳的做法（将来编辑器加别的段不会互相清掉）。
	cfg.load(path)
	for a in DEFAULTS.keys():
		cfg.set_value(SECTION, str(a), key_for(str(a)))
	cfg.save(path)


# ==================== 查询 / 匹配 ====================

## 动作当前键位（玩家覆盖优先，否则缺省）。
func key_for(action: String) -> String:
	return str(bindings.get(action, DEFAULTS.get(action, "")))


## 人话：动作名 + 当前键（tooltip 用）。
func hint(action: String) -> String:
	var label := str(LABELS.get(action, action))
	return "%s（%s）" % [label, describe(key_for(action))]


## 某个键事件命中的动作（无则 ""）。修饰键必须**完全相等**（否则 `g` 会抢 `ctrl+g`）。
func action_for_event(event: InputEventKey) -> String:
	if event == null or event.echo:
		return ""
	var code := event.keycode
	if code == 0:
		code = event.physical_keycode
	for a in DEFAULTS.keys():
		var p := parse(key_for(str(a)))
		if not bool(p["ok"]) or str(p["mouse"]) != "":
			continue
		if int(p["key"]) != code:
			continue
		if bool(p["ctrl"]) != event.ctrl_pressed:
			continue
		if bool(p["alt"]) != event.alt_pressed:
			continue
		if bool(p["shift"]) != event.shift_pressed:
			continue
		return str(a)
	return ""


## 鼠标事件是否命中该动作（目前只有 `alt+click`）。
func matches_mouse(action: String, event: InputEventMouseButton) -> bool:
	if event == null:
		return false
	var p := parse(key_for(action))
	if not bool(p["ok"]) or str(p["mouse"]) == "":
		return false
	if bool(p["ctrl"]) != event.ctrl_pressed:
		return false
	if bool(p["alt"]) != event.alt_pressed:
		return false
	if bool(p["shift"]) != event.shift_pressed:
		return false
	return event.button_index == MOUSE_BUTTON_LEFT
