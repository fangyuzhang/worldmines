# theme_token.gd —— 主题变量可扩展（文档 23 号 §14.10）
# 皮肤可覆盖的键不再固定：Mod 用 declare_token 声明新 token，任何皮肤包（包括没听说过这个 Mod 的）
# 都能覆盖它 —— 跨 Mod 自发适配。
class_name ThemeTokenRegistry
extends RefCounted


# token(StringName) -> { default: Variant, override: Variant }（override 为 null 表示未覆盖）
var _tokens: Dictionary = {}


## 声明一个新主题 token（带默认值）。返回是否成功（空名/已存在则失败）。
func declare_token(token: StringName, default_value: Variant) -> bool:
	if token == &"" or _tokens.has(token):
		return false
	_tokens[token] = {"default": default_value, "override": null}
	return true


## 读 token 当前值：有覆盖用覆盖，否则用默认；未声明返回 null。
func token(token: StringName) -> Variant:
	if not _tokens.has(token):
		return null
	var entry: Dictionary = _tokens[token]
	if entry["override"] != null:
		return entry["override"]
	return entry["default"]


## 设置覆盖（皮肤包调用）。token 未声明时自动以 null 为默认声明。
func set_override(token: StringName, value: Variant) -> void:
	if not _tokens.has(token):
		_tokens[token] = {"default": null, "override": value}
	else:
		_tokens[token]["override"] = value


## 清除覆盖（回退到默认）。
func clear_override(token: StringName) -> void:
	if _tokens.has(token):
		_tokens[token]["override"] = null


## 是否已声明。
func has_token(token: StringName) -> bool:
	return _tokens.has(token)


## 列出全部已声明 token 名。
func list_tokens() -> Array[StringName]:
	var out: Array[StringName] = []
	for t in _tokens:
		out.append(t)
	return out


## 导出默认值表（供皮肤面板/文档展示）。
func defaults() -> Dictionary:
	var out: Dictionary = {}
	for t in _tokens:
		out[t] = _tokens[t]["default"]
	return out


## 是否被覆盖。
func is_overridden(token: StringName) -> bool:
	return _tokens.has(token) and _tokens[token]["override"] != null


## 清空全部。
func clear() -> void:
	_tokens.clear()
