# ui_mounts.gd —— Mod「纯数据 UI 挂载」的统一渲染（P4 / 开放平台实施框架 §5）
#
# 设计红线（框架 §5）：挂载物**只能是数据**——一行按钮，点击弹出 manifest 里声明的
# 说明文本（label + body）。不是任意场景、不注册回调、不触碰输入/文件/网络。
# 因此本挂载点**不需要 UI_INJECT 授权**：数据展示不构成权限面；
# 真正需要该敏感能力的是未来的「代码注入 UI」通道，那条路仍走授权弹窗。
#
# 数据链路：manifest.ui_mounts[{slot,label,body}]（ManifestParser 白名单外字段原样保留）
#   → ModAPI._collect_ui_mounts（加载时登记，非法项跳过）
#   → 本模块 append（宿主页面渲染，无挂载时不产生任何节点）
#   → 卸载时 ModAPI 自动摘除（不留孤儿）。
class_name UiMounts
extends RefCounted

## 挂载点：主菜单按钮列末尾。
const SLOT_MAIN_MENU := "main_menu.footer"
## 挂载点：选关页 Mod 页（待接——先只做主菜单，接入时用同一个 append 调用）。
const SLOT_LEVEL_SELECT := "level_select.footer"


## 把某挂载点的全部挂载项渲染进 vbox。无挂载 → 不产生任何节点（零视觉痕迹）。
## host 用于承载弹出层（传页面自身节点即可）。
static func append(vbox: VBoxContainer, slot: String, host: Node) -> void:
	if vbox == null or host == null:
		return
	for m in ModAPI.ui_mounts(slot):
		var label := str(m.get("label", ""))
		if label == "":
			continue
		var btn := Button.new()
		btn.text = label
		btn.focus_mode = Control.FOCUS_NONE
		btn.add_theme_font_size_override("font_size", 15)
		btn.custom_minimum_size = Vector2(240, 34)
		btn.set_meta("secondary", true)
		btn.tooltip_text = "来自 Mod：%s" % str(m.get("mod_id", ""))
		var body := str(m.get("body", ""))
		var owner_mod := str(m.get("mod_id", ""))
		btn.pressed.connect(func():
			var text := body if body != "" else "「%s」未提供说明文本。" % owner_mod
			UiConfirm.ask(host, text, "知道了", "关闭", func(): pass))
		vbox.add_child(btn)
		UiTheme.bind_hover(btn, 1.04)
