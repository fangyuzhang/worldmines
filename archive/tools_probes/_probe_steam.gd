extends SceneTree

## 探针：GodotSteam GDExtension 在本项目（mono 4.7.2）与当前环境下的可见性。
## **只读探测，不调用 steamInitEx**（避免意外拉起 Steam 客户端）。
##
## 结论用途：决定 `core/steam_workshop.gd` 的调用写法——若单例在 headless 下不可见，
## 脚本里就绝不能出现静态 `Steam.xxx` 引用（会 Parse Error），必须走
## `Engine.get_singleton("Steam")` 动态调用。
##
## 跑法：& $GODOT --headless --path . -s tools/_probe_steam.gd

func _initialize() -> void:
	print("[steam] has_singleton(\"Steam\") = %s" % Engine.has_singleton("Steam"))
	var s: Object = Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	if s == null:
		print("[steam] 单例不可见（headless 下不注册扩展属正常——不影响 GUI 运行时的可用性）")
		quit()
		return
	var cls: String = s.get_class()
	print("[steam] 单例类 = %s" % cls)
	for m in ["steamInitEx", "steamInit", "getSubscribedItems", "getItemInstallInfo",
			"getItemState", "getAppID", "runCallbacks"]:
		print("[steam]   has_method(%s) = %s" % [m, s.has_method(m)])
	if s.has_method("getAppID"):
		print("[steam] getAppID() = %s" % str(s.call("getAppID")))
	quit()
