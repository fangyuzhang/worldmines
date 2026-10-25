# expression_func.gd —— 表达式函数注册表（文档 23 号 §14.5）
# 零代码 DSL 的函数库可扩展：Mod 可注册领域函数（ExpressionFuncPlugin）。
# is_symbolizable 决定该函数参与的表达式能否进官方验证：
#   true（纯组合子）→ 可静态校验、进官方验证；false（黑盒，如任意代码/随机/时间）→ 自动降级工坊 🧩。
class_name ExpressionFuncRegistry
extends RefCounted


# name(String) -> { callable: Callable, symbolizable: bool }
var _funcs: Dictionary = {}


## 注册一个表达式函数。返回是否成功（空名/无效 callable/已存在则失败）。
func register(name: String, callable: Callable, symbolizable: bool = false) -> bool:
	if name == "" or not callable.is_valid() or _funcs.has(name):
		return false
	_funcs[name] = {"callable": callable, "symbolizable": symbolizable}
	return true


## 调用函数。未注册返回 null。命名 invoke 以免覆盖 Object.call()。
func invoke(name: String, args: Array = []) -> Variant:
	if not _funcs.has(name):
		return null
	return _funcs[name]["callable"].callv(args)


## 是否存在。
func has(name: String) -> bool:
	return _funcs.has(name)


## 是否可符号化（决定能否进官方验证）。
func is_symbolizable(name: String) -> bool:
	if not _funcs.has(name):
		return false
	return bool(_funcs[name]["symbolizable"])


## 列出全部函数（含 symbolizable 标记）。
func list() -> Array:
	var out: Array = []
	for name in _funcs:
		out.append({"name": name, "symbolizable": _funcs[name]["symbolizable"]})
	return out


## 清空。
func clear() -> void:
	_funcs.clear()
