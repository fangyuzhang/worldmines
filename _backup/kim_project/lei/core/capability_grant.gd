# capability_grant.gd —— 能力授权层（文档 23 号 §14.14）
# 敏感能力首次使用时弹窗授权，用户可随时撤销，授权记录持久化（宿主负责落盘）。
# 把"平台一刀切禁止"改成"用户自己决定"；永久不授予的仍由 Capability.NEVER_GRANTED 守住。
class_name CapabilityGrant
extends RefCounted


## 敏感能力集（需运行时授权才可用；其余能力走 manifest 声明即可）。
const SENSITIVE: Array[StringName] = [
	Capability.UI_INJECT,
	Capability.NET_WORKSHOP,
	Capability.DEBUG_CMD,
]


# capability(StringName) -> bool（用户是否已授权）
var _grants: Dictionary = {}


## 某能力是否需要运行时授权。
static func is_sensitive(cap: StringName) -> bool:
	return SENSITIVE.has(cap)


## 用户授权。
func grant(cap: StringName) -> void:
	_grants[cap] = true


## 用户拒绝/撤销。
func revoke(cap: StringName) -> void:
	_grants[cap] = false


## 某能力当前是否可用：非敏感能力默认 true；敏感能力需显式授权。
func is_granted(cap: StringName) -> bool:
	if not is_sensitive(cap):
		return true
	return _grants.get(cap, false)


## 是否处于"待授权"状态（敏感且尚未授权/拒绝）。
func is_pending(cap: StringName) -> bool:
	return is_sensitive(cap) and not _grants.has(cap)


## 导出授权记录（持久化用）。
func snapshot() -> Dictionary:
	return _grants.duplicate(true)


## 恢复授权记录。
func restore(snapshot: Dictionary) -> void:
	_grants.clear()
	for k in snapshot:
		_grants[StringName(str(k))] = bool(snapshot[k])


## 清空。
func clear() -> void:
	_grants.clear()
