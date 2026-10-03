extends RefCounted

## 编辑 / 试玩两态的**统一状态机**（文档「七」W2：禁止各功能自己判断）。
##
## 【要解决的问题】编辑器画布原来**恒显雷**（`ui/editor_canvas.gd:_draw` 直接取 `doc.mine_set()`），
## 各功能各自决定要不要显示"作弊信息"，没有单一权威 ⇒ 一旦以后加了热力图/推理链回放，
## 每个功能都得自己再判一次"现在是不是试玩态"，迟早有人判漏（把雷泄进试玩视图）。
##
## 【口径】唯一真源：`mode`（编辑 / 试玩）+ `cheats_on`（编辑态下的用户开关）。
## 对外只暴露一个 `is_cheat_visible()`：
##   * 编辑态 → 看 `cheats_on`（默认 **开**：关掉雷就没法编辑了，这不是"默认隐藏"能接受的）；
##   * 试玩态 → **恒 false**（无论开关怎么设）。
## 消费方（画布/热力图/回放）一律只问这一句，不得自己拼 `mode == ...`。
##
## 【坑】不写 `class_name`（headless 新全局类不在缓存里会让整份脚本解析失败，见仓库坑表 #26）。

const MODE_EDIT := "edit"
const MODE_PLAY := "play"

## 当前态：编辑 / 试玩。
var mode: String = MODE_EDIT
## 编辑态下用户是否要看"作弊信息"（雷位 / 将来的热力图、推理链）。
var cheats_on: bool = true


## 切态。未知识别串一律当编辑态（**fail-safe**：宁可真编辑，也不要静默进"试玩"却还在显雷）。
func set_mode(p_mode: String) -> void:
	mode = MODE_PLAY if p_mode == MODE_PLAY else MODE_EDIT


func is_play() -> bool:
	return mode == MODE_PLAY


## 唯一的"作弊信息该不该显示"判据。
func is_cheat_visible() -> bool:
	if mode == MODE_PLAY:
		return false
	return cheats_on


## 编辑态下开关（试玩态调用不报错，但返回值仍被强制隐藏）。
func toggle_cheats() -> void:
	cheats_on = not cheats_on


func set_cheats(on: bool) -> void:
	cheats_on = on


## 状态栏/按钮文案用：当前实际生效的显隐。
func cheat_label() -> String:
	if mode == MODE_PLAY:
		return "试玩态：作弊信息强制隐藏"
	return "显雷/线索：开" if cheats_on else "显雷/线索：关"
