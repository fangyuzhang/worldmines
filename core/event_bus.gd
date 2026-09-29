# event_bus.gd —— 事件总线（文档 23 号 §5 / §14.9）
# 职责：Mod 间解耦通信 + 只读广播。不含判负/雷位逻辑。
# 约束：事件为只读广播（Mod 不能拦截/篡改主流程事件）；handler 通过 is_valid 守卫隔离。
class_name EventBus
extends RefCounted

# 内置事件（23 号 §5）
#
# ⚠ 【2026-09-28 审计 A6：契约与实现不一致，按实标注】下列 13 个事件里，**当前只有
# MOD_LOADED / MOD_UNLOADED 真的被 emit**（`core/mod_api.gd:477,534,535`）。其余 11 个
# 虽在此声明，但产品代码走的是 **Node 信号直连**，**全仓没有任何 emit 点** ⇒
# Mod 作者若订阅 `LEVEL_STARTED` / `CELL_REVEALED` / `THEME_CHANGED` / `TICK` … **永远收不到**。
#
# 两个候选修法（**未决**，故先如实标注而不是假装已接线）：
#   (a) 在 Board / GameSession / ThemeManager 真发这些事件 —— Mod 契约才名副其实，
#       但要评估广播开销与"每格一次 emit"的热路径成本；
#   (b) 把未接线的常量从公开契约删除（或集中移到一个 `RESERVED_*` 段），避免文档误导。
# 在此之前：**Mod 侧只依赖 `MOD_LOADED` / `MOD_UNLOADED`**，其余状态请用宿主自带的 Node 信号。
const LEVEL_STARTED := &"level_started"
const CELL_REVEALED := &"cell_revealed"
const CELL_FLAGGED := &"cell_flagged"
const HINT_SHOWN := &"hint_shown"
const LEVEL_ENDED := &"level_ended"
const THEME_CHANGED := &"theme_changed"
const SETTINGS_CHANGED := &"settings_changed"
const DRAWING_STROKE := &"drawing_stroke"
const MOD_LOADED := &"mod_loaded"
const MOD_UNLOADED := &"mod_unloaded"
const SAVE_WRITTEN := &"save_written"
const SAVE_LOADED := &"save_loaded"
const TICK := &"tick"

# event(StringName) -> Array[Callable]
var _handlers: Dictionary = {}


## 订阅事件。同一 Callable 重复订阅会去重。
func on(event: StringName, cb: Callable) -> void:
	if not cb.is_valid():
		return
	var list: Array = _handlers.get(event, [])
	if list.has(cb):
		return
	list.append(cb)
	_handlers[event] = list


## 取消订阅。
func off(event: StringName, cb: Callable) -> void:
	var list: Array = _handlers.get(event, [])
	list.erase(cb)
	if list.is_empty():
		_handlers.erase(event)


## 广播事件（只读）。handler 逐个调用，is_valid 守卫；无效/失效 handler 跳过，不影响后续。
func emit(event: StringName, payload: Variant = null) -> void:
	var list: Array = _handlers.get(event, [])
	for cb in list:
		if cb.is_valid():
			cb.call(payload)


## 是否有订阅者。
func has(event: StringName) -> bool:
	return _handlers.has(event)


## 订阅者数量。
func listener_count(event: StringName) -> int:
	return _handlers.get(event, []).size()


## 列出所有有订阅者的事件（含 Mod 自定义事件，§14.9）。
func list_events() -> Array[StringName]:
	var evs: Array[StringName] = []
	for e in _handlers:
		evs.append(e)
	return evs


## 清空全部订阅。
func clear() -> void:
	_handlers.clear()
