# steam_workshop.gd —— Steam 创意工坊·读取侧（开放平台实施框架 §2 / P1）
#
# 职责：把玩家在工坊**订阅**的 Mod 同步成本地已安装 Mod（user://mods/workshop_<fileid>/），
# 之后的加载/游玩完全走既有链路（scan_mods / load_mod / 代码 Mod 信任确认 / 崩溃熔断）——
# Steam 只是「下载缓存 + 分发渠道」，断连/退订不影响已装 Mod，也不进 levels_lib 官方索引（天然分池）。
#
# 环境要求：Steam 客户端运行 + appid 可用（steam_appid.txt 或经 Steam 启动）。
# 缺任一 → init 失败，所有入口**安全降级**（返回失败字典、不崩不弹错、UI 按钮置灰）。
#
# 调用写法刻意用 Engine.get_singleton 动态调用：GodotSteam 是可选依赖，
# 缺插件时必须能整体降级——脚本里不允许出现静态 `Steam.` 引用（缺失即 Parse Error）。
class_name SteamWorkshop
extends RefCounted

## 工坊安装副本的目录名前缀（与手动导入的 Mod 区分，便于 UI/统计识别来源）。
const WORKSHOP_PREFIX := "workshop_"
const MODS_DIR := "user://mods"

var _steam: Object = null
var _inited := false
var _last_error := ""


## Steam 单例（装了 GodotSteam 扩展才有）。不代表已初始化。
static func singleton() -> Object:
	return Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null


## 插件是否在场（可据此决定 UI 是否显示工坊入口）。
static func plugin_present() -> bool:
	var s := singleton()
	return s != null and s.has_method("steamInitEx")


func is_available() -> bool:
	return _inited


func last_error() -> String:
	return _last_error


## 初始化 Steam（幂等）。返回 { ok, reason }。
## **失败是正常情况**（编辑器里没经 Steam 启动 / 无 appid / 无客户端），调用方据此降级。
func init() -> Dictionary:
	if _inited:
		return {"ok": true, "reason": ""}
	var s := singleton()
	if s == null:
		_last_error = "未安装 GodotSteam 扩展"
		return {"ok": false, "reason": _last_error}
	if not s.has_method("steamInitEx"):
		_last_error = "GodotSteam 缺 steamInitEx（版本过旧？）"
		return {"ok": false, "reason": _last_error}
	var r: Variant = s.call("steamInitEx")
	if not (r is Dictionary):
		_last_error = "steamInitEx 返回异常"
		return {"ok": false, "reason": _last_error}
	var d: Dictionary = r
	var status := int(d.get("status", -1))
	if status != 0:
		_last_error = str(d.get("verbal", "Steam 初始化失败（status=%d）" % status))
		return {"ok": false, "reason": _last_error}
	_steam = s
	_inited = true
	return {"ok": true, "reason": ""}


## 枚举订阅项并同步到本地（**幂等**：已装的不动——保护玩家进度与已生成关卡）。
## api：ModAPI 实例（传 Object 以避免 core 内互相引用；调用 install_from_dir）。
## 返回 { ok, reason, synced: Array, skipped: Array, errors: Array }。
func poll_subscriptions(api: Object) -> Dictionary:
	var out := {"ok": true, "reason": "", "synced": [], "skipped": [], "errors": []}
	if not _inited:
		out["ok"] = false
		out["reason"] = "Steam 未初始化：%s" % _last_error
		return out
	if api == null or not api.has_method("install_from_dir"):
		out["ok"] = false
		out["reason"] = "缺 ModAPI 引用"
		return out
	var subs: Variant = _steam.call("getSubscribedItems")
	if not (subs is Array):
		out["ok"] = false
		out["reason"] = "getSubscribedItems 返回异常"
		return out
	for fid in (subs as Array):
		var key := str(fid)
		var info: Variant = _steam.call("getItemInstallInfo", fid)
		if not (info is Dictionary) or not bool((info as Dictionary).get("ret", false)):
			(out["errors"] as Array).append("%s：安装信息不可用（可能未下载完）" % key)
			continue
		var folder := str((info as Dictionary).get("folder", ""))
		if folder == "" or not DirAccess.dir_exists_absolute(folder):
			(out["errors"] as Array).append("%s：工坊安装目录不存在" % key)
			continue
		var dst_name := WORKSHOP_PREFIX + key
		if DirAccess.dir_exists_absolute("%s/%s" % [MODS_DIR, dst_name]):
			(out["skipped"] as Array).append(dst_name)
			continue
		var r: Dictionary = api.call("install_from_dir", folder, dst_name)
		if bool(r.get("ok", false)):
			(out["synced"] as Array).append(dst_name)
		else:
			(out["errors"] as Array).append("%s：%s" % [key, str(r.get("reason", "同步失败"))])
	return out


## 该本地 Mod 目录名是否来自工坊订阅（UI 标记来源用）。
static func is_workshop_mod(dir_name: String) -> bool:
	return dir_name.begins_with(WORKSHOP_PREFIX)


## 创意工坊上传提示语（产品要求：未集成时明确告知，别让用户以为已经发布）。
const UPLOAD_HINT := "已生成本地 workshop 包，请手动上传。"


## 【预留接口】把本地 workshop 包发布到创意工坊。
##
## 当前**不实际联网、不集成 Steamworks**（产品硬要求），因此本函数**永远返回 ok=false**：
##   * 插件不在（编辑器里没经 Steam 启动 / 无 appid / 无客户端）⇒ code = "no_steam"；
##   * 插件在 ⇒ code = "not_implemented"。
## 为什么"插件在"也必须返回失败：**假成功比没功能更坏**——用户会以为东西已经发出去了，
## 而失败信息至少告诉他要手动上传。
## 为什么入参直接是 zip 路径：将来接 Steamworks 时只改本函数，编辑器侧（生成包的地方）不用动。
static func publish_pack(zip_path: String, title: String = "", description: String = "") -> Dictionary:
	var present := plugin_present()
	return {
		"ok": false,
		"code": "not_implemented" if present else "no_steam",
		"reason": UPLOAD_HINT,
		"path": zip_path,
		"title": title,
		"description": description,
		"plugin_present": present,
	}
