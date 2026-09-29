extends GutTest

## 主题化「容器底板」契约（2026-09-29）
##
## 起因：设置面板的内容区底板一直在吃 Godot 引擎默认的 `TabContainer/panel` 样式盒
## （不透明、近黑，bg_color ≈ Color(0.1,0.1,0.1,0.6)），它铺在浅色 `card()` 卡片之上 ⇒
## 正文被压到**实测 1.67:1**（`#444d5b` 压 `#607174`），整页设置项几乎读不出来。
## 口径见 `_pv/probe_skin_contrast.py`（取样框整块落在元素内部，不是压在边界上）。
##
## 为什么这类缺陷能活很久：
##   · 它不是"没上色"，而是"上了色的容器**里面**叠了一块没上色的底板"；
##   · 静态检查、既有单测、代码评审都只看"有没有设 font_color"，看不出叠层；
##   · CozyStyle 之前的主视觉是深色主题 —— 深色底 + 白字毫无异常，缺陷被深色主题藏住了；
##   · 它不是"错"，它是"引擎默认值"，看起来像是设计选择。
##
## 断言方式刻意选**渲染后的对比度**，而不是"某属性 == 某值"：
## 底板怎么实现都行，只要它与正文的对比度达标。这样以后换实现不会被测试绊住，
## 而"又叠了一块深色底板"这种回归一定会被抓住。

## WCAG 2.x：正文 AA = 4.5:1。与 _pv/analyze_ui_probe.py、test_theme_manager.gd 同口径。
const AA_BODY := 4.5

const PANEL := "res://ui/settings_panel.tscn"

var _saved: Dictionary = {}


func before_all() -> void:
	# 本文件会直接改 autoload ThemeManager（绕开 300ms tween），结束必须还原
	_saved = {
		"mode": ThemeManager.mode,
		"target": ThemeManager._target,
		"active": ThemeManager._active,
	}


func after_all() -> void:
	if not _saved.is_empty():
		ThemeManager.mode = _saved["mode"]
		ThemeManager._target = _saved["target"]
		ThemeManager._active = _saved["active"]


# ============================ 字体角色是否真下发到控件 ============================

func test_ui_font_role_actually_reaches_plain_labels() -> void:
	## 全局 UI 字体（Nerko One 打头 + 中文回退文源圆体）必须真的下发到普通控件。
	##
	## ★ 机制（2026-09-29 二次更正，探针 v8 逐例实测，见 `_pv/font_probe8_out.txt`）：
	##   Godot 4 的主题继承**只在 Control / Window 祖先之间传递** —— 路径上夹一个普通
	##   `Node` 就**整条断掉**，`font` 与 `font_color` 一起断；断链后落到引擎默认主题，
	##   也就是 `project.godot [gui] theme/custom_font`。
	##   （曾经记成「custom_font 优先级高于节点主题链」是误判，见下。）
	##
	## ⚠️ 这条断言以前是**假绿**，别再改回去：
	##   旧版把控件 `add_child_autofree()` 挂在 `self` 下 —— 而 `extends GutTest` = `Node`，
	##   于是**从测试自己这儿就把链切断了**，控件取到的一直是 `custom_font`。
	##   当时 `custom_font` 恰好也是 Nerko One，所以「主字体 == Nerko」照样通过，
	##   让人误以为「root.theme 里存着 Nerko」这件事验证过了 —— **其实一次都没验证到**。
	##   把 `custom_font` 换回中文底（文源圆体）后它立刻变红，才暴露出来。
	##
	##   所以必须**自建一条与真机同形的链**：Control 直接挂到 root Window 下
	##   （`run/main_scene` 挂的就是 `ui/level_select.tscn`，其根是 Control；
	##   `change_scene_to_file` 同理）。
	_diag_font_chain()

	var host := Control.new()
	host.name = "ChainHost"
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_tree().root.add_child(host)
	autofree(host)

	for t: String in ["Label", "Button", "RichTextLabel"]:
		var c: Control = null
		match t:
			"Label":
				c = Label.new()
			"Button":
				c = Button.new()
			_:
				c = RichTextLabel.new()
		host.add_child(c)
		var f: Font = c.get_theme_font("font", t)
		print("[diag] %s：链路内控件取到=%s" % [t, _describe(f)])
		assert_eq(UiFonts.primary_path(f), UiFonts.P_UI,
			"%s 的主字体应是 Nerko One（实得 %s）" % [t, _describe(f)])
		assert_true(UiFonts.has_fallback(f, UiFonts.P_CJK),
			"%s 必须带中文回退链（否则中文变豆腐块）：%s" % [t, _describe(f)])
	# 棋盘数字走另一条（等宽）字体，别被全局字体顺手改掉
	var bv := preload("res://ui/board_view.tscn").instantiate()
	host.add_child(bv)
	await wait_process_frames(1)
	assert_eq(UiFonts.primary_path(bv._board_font()), UiFonts.P_DIGIT,
		"棋盘数字必须仍是等宽数字字体")


func test_engine_fallback_font_can_render_chinese() -> void:
	## 断链安全网：`project.godot [gui] theme/custom_font` 是**引擎级兜底**，
	## 只服务主题链**断掉**的节点 —— 普通 `Node` 子树、`CanvasLayer` 子树
	## （本工程的 `addons/debug_menu` 就是 CanvasLayer autoload）、独立 Window、
	## 引擎内部控件。这些地方只能拿到它，拿不到 root.theme。
	##
	## ⚠️ 2026-09-29 踩过：一度把这一项改成纯拉丁的 Nerko One。后果不是"中文变豆腐块"，
	## 而是**整段画不出来** —— 实测棋盘页底部那两行首局引导提示在该条带上
	## 42,900 像素里**一个字形像素都没有**（`UiToast` 只 override 了 font_color，
	## 字体本身没得替）。所以这里把「引擎兜底字体必须能画中文」钉成断言：
	## 以后无论谁改 custom_font（含换成 FontVariation 包一层回退链的写法），都跑得过。
	var fb: Font = ThemeDB.fallback_font
	assert_not_null(fb, "引擎兜底字体不该为空（custom_font 指向的字体没加载成功？）")
	assert_true(UiFonts.can_render(fb, "翻"),
		"引擎兜底字体必须能画中文，实得 %s —— 断链节点上的中文会整段消失" % _describe(fb))
	assert_true(UiFonts.can_render(fb, "A"), "引擎兜底字体也得能画拉丁字母")
	assert_true(UiFonts.can_render(fb, "8"), "引擎兜底字体也得能画数字")

	# 断链形态（祖先里有普通 Node）取到的那一个也必须能画中文。
	# 注意这里**不断言它是哪个字体** —— 那是引擎行为；我们要守的是"中文别消失"。
	var plain := Node.new()
	plain.name = "SeveredHost"
	get_tree().root.add_child(plain)
	autofree(plain)
	var ctl := Control.new()
	plain.add_child(ctl)
	var lb := Label.new()
	lb.text = "选择关卡"
	ctl.add_child(lb)
	var f: Font = lb.get_theme_font("font", "Label")
	print("[diag] 断链控件取到=%s" % _describe(f))
	assert_true(UiFonts.can_render(f, "翻"),
		"断链控件也必须能画中文（实得 %s）" % _describe(f))


# ============================ 工具 ============================

## 把字体描述成「主字体路径 (类型) [+N 条回退]」，一眼看出回退链在不在。
## 类型也要打：`FontFile` 与 `FontVariation` 是区分「吃到哪一层主题」的关键身份
## （本工程两种形式都用过，只打路径会看不出差别）。
func _describe(f: Font) -> String:
	if f == null:
		return "<null>"
	return "%s (%s) fallbacks=%d can('翻')=%s" % [
		UiFonts.primary_path(f), f.get_class(), f.get_fallbacks().size(),
		str(UiFonts.can_render(f, "翻"))]


## 一次性诊断：把字体从「存进主题」到「控件取到」的四环事实打出来。
## 这几条在红灯时能直接指出卡在哪一环，省掉一轮盲改。
func _diag_font_chain() -> void:
	var dt: Theme = ThemeManager._default_theme
	print("[diag] project gui/theme/custom_font = %s"
		% str(ProjectSettings.get_setting("gui/theme/custom_font", "<none>")))
	print("[diag] ThemeDB.fallback_font    = %s" % _describe(ThemeDB.fallback_font))
	print("[diag] UiFonts.ui()             = %s" % _describe(UiFonts.ui()))
	print("[diag] UiFonts.digit()          = %s" % _describe(UiFonts.digit()))
	print("[diag] root.theme 已挂 = %s ; default_theme 非空 = %s"
		% [str(get_tree().root.theme == dt), str(dt != null)])
	if dt != null:
		print("[diag] theme 里存着 Label 字体 = %s" % _describe(dt.get_font("font", "Label")))
	print("[diag] 测试节点自身的祖先链（GutTest 是 Node ⇒ 本测试树里主题链是断的，"
		+ "所以下面专门另建一条 Control<-root 的链来测）")

func _use(m: String) -> void:
	ThemeManager.mode = m
	ThemeManager._target = ThemeManager._palette_for(m)
	ThemeManager._active = ThemeManager._target.duplicate()


func _theme_ids() -> Array:
	return ThemeManager.THEME_IDS.filter(func(x): return str(x) != "system")


func _settle(n: int = 10) -> void:
	for i in n:
		await get_tree().process_frame


func _find_first(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var hit := _find_first(c, cls)
		if hit != null:
			return hit
	return null


func _lin(u: float) -> float:
	return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)


func _lum(c: Color) -> float:
	return 0.2126 * _lin(c.r) + 0.7152 * _lin(c.g) + 0.0722 * _lin(c.b)


func _contrast(a: Color, b: Color) -> float:
	var la := _lum(a)
	var lb := _lum(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


func _hex(c: Color) -> String:
	return "#%02x%02x%02x" % [int(round(c.r * 255)), int(round(c.g * 255)), int(round(c.b * 255))]


func _mount_panel():
	var sp = load(PANEL).instantiate()
	add_child_autofree(sp)
	await _settle(12)
	return sp


# ============================ 断言 ============================

func test_settings_content_panel_is_themed_on_every_theme() -> void:
	## 逐主题（含 dark / light / 五套 CozyStyle）检查：
	##   ① TabContainer 必须有 `panel` 样式盒**覆盖**（没有覆盖 = 又吃引擎默认深色底板）；
	##   ② 底板色必须与正文色 ≥4.5:1。
	## 遍历全部主题是关键 —— 只测 CozyStyle 就无法证明 dark/light 没被改坏，
	## 只测 dark 就完全测不出这个缺陷（深色底下白字本来就是达标的）。
	var sp = await _mount_panel()
	var tabs := _find_first(sp, "TabContainer")
	assert_not_null(tabs, "设置面板里应有 TabContainer（结构变了？本测试要同步改）")

	var checked := 0
	for m: String in _theme_ids():
		_use(m)
		sp._apply_theme()   # 直接改 mode 不会发 theme_changed，手工刷一次
		assert_true(tabs.has_theme_stylebox_override("panel"),
			"%s：TabContainer 没有 `panel` 样式盒覆盖 ⇒ 内容区会退回引擎默认的深色底板" % m)
		var sb: StyleBox = tabs.get_theme_stylebox("panel")
		assert_not_null(sb, "%s：取不到 panel 样式盒" % m)

		var bg: Color = ThemeManager.card() if not (sb is StyleBoxFlat) else (sb as StyleBoxFlat).bg_color
		var fg: Color = ThemeManager.text()
		var r := _contrast(fg, bg)
		assert_gte(r, AA_BODY,
			"%s：内容区底板%s 压正文%s 只有 %.2f:1（需 ≥%.1f）"
			% [m, _hex(bg), _hex(fg), r, AA_BODY])
		checked += 1
	assert_eq(checked, _theme_ids().size(),
		"应逐主题检查（实得 %d / %d）" % [checked, _theme_ids().size()])


func test_content_panel_matches_the_outer_card() -> void:
	## 内容区底板必须**与外层 PanelContainer 同色** —— 否则会看到两条不同色的分层，
	## 那正是"引擎默认底板叠在卡片上"的可见征兆（也是本次缺陷的外观表现）。
	## 同色还能保证外层 10px 圆角不会被内层方角切掉。
	var sp = await _mount_panel()
	var tabs := _find_first(sp, "TabContainer")
	assert_not_null(tabs, "设置面板里应有 TabContainer")

	var checked := 0
	for m: String in _theme_ids():
		_use(m)
		sp._apply_theme()
		var inner: StyleBox = tabs.get_theme_stylebox("panel")
		assert_true(inner is StyleBoxFlat, "%s：内容区底板应为 StyleBoxFlat（便于取色）" % m)
		var outer: StyleBox = sp._panel.get_theme_stylebox("panel")
		assert_true(outer is StyleBoxFlat, "%s：外层卡片底板应为 StyleBoxFlat" % m)
		assert_eq((inner as StyleBoxFlat).bg_color, (outer as StyleBoxFlat).bg_color,
			"%s：内容区底板与外层卡片必须同色（否则出现两条分层）" % m)
		checked += 1
	assert_eq(checked, _theme_ids().size(), "应逐主题检查（实得 %d）" % checked)


func test_tab_strip_fonts_are_themed() -> void:
	## 页签条的字色也必须接管：选中/未选中/悬停三态在浅色底上靠引擎默认同样发灰，
	## 而"选中态看不出选的是哪个"是最典型的可用性缺陷（玩家找不到自己在哪一页）。
	var sp = await _mount_panel()
	var tabs := _find_first(sp, "TabContainer")
	assert_not_null(tabs, "设置面板里应有 TabContainer")

	for m: String in _theme_ids():
		_use(m)
		sp._apply_theme()
		for key: String in ["font_selected_color", "font_unselected_color", "font_hovered_color"]:
			assert_true(tabs.has_theme_color_override(key),
				"%s：页签条缺少 `%s` 覆盖 ⇒ 该态会退回引擎默认色" % [m, key])
		# 选中态字色压在内容区底板上必须达标（未选中态压在页面底色上同理）
		var sel: Color = tabs.get_theme_color("font_selected_color")
		var r := _contrast(sel, ThemeManager.card())
		assert_gte(r, AA_BODY,
			"%s：选中页签字色%s 压卡片底%s 只有 %.2f:1" % [m, _hex(sel), _hex(ThemeManager.card()), r])


# ============================ 悬停阴影的**主题适配** ============================
#
# 起因（用户 2026-09-29）：「鼠标放上去弹一下……有个阴影。阴影没有做好很好的适配，
# 有些突兀。」改动前的实现是**两个写死的纯黑常量**（常态 α0.10 / 悬停 α0.22），
# 服务全部七套底色。实拍量测（`_pv/hover_b/`，逐行亮度剖面）：
#   粉彩底（L≈198）上 α0.22 掉 **43.4/255**；深色底（L≈30）上只掉 **7.1/255** —— 差 6 倍。
#   ⇒ 粉彩主题得到一圈脱色的脏灰，深色主题几乎看不见（等于白画）。
#
# 这条契约守的就是"别再退回去"：**七套主题的压暗量必须落在同一个窄带里**。
# 断言口径刻意选「渲染后的压暗量」而不是「α == 某值」——
# 未来换实现（比如换成 FontVariation 式的多层影）照样能过，但"一套 α 打天下"必红。
#
# ⚠️ 亮度口径是 **0..255 编码值加权和**（`ThemeManager.sdr_lum`），不是 WCAG 线性亮度。
#    原因是 Godot 2D 的 canvas 混合发生在编码值空间：实测 bg `#b7c9d4` 叠纯黑 α0.10
#    后 = 178.4，与「0.9×198.0 + 0.1×0」逐位吻合。用 WCAG 线性亮度反解会得到
#    "深色底最多只能掉 0.012" ⇒ α→1 的荒谬值。阴影是**明度微差**问题，不是对比度问题。

## 压暗量的合理区间（0..255）。下界保证"画得出来"，上界保证"不像污渍"。
const DROP_NORMAL_MIN := 4.0
const DROP_NORMAL_MAX := 10.0
const DROP_HOVER_MIN := 9.0
const DROP_HOVER_MAX := 17.0
## 悬停/常态的跳变上限。换 stylebox 是**瞬时**的，跨度大了就是"影先跳、按钮后长"。
const DROP_RATIO_MAX := 2.0


func test_hover_shadow_depth_is_adapted_per_theme() -> void:
	# ⚠️ 只测**内置**主题：Mod/皮肤注册的自定义主题色板自由，压暗量带宽不归本契约管。
	var _band_ids: Array = ["dark", "light"] + (ThemeManager.COZY_IDS as Array) + ["cozy_prism"]
	var rows: Array[String] = []
	for m: String in _band_ids:
		_use(str(m))
		var base: Color = ThemeManager.bg()
		var dn: float = ThemeManager.shadow_drop(base)
		var dh: float = ThemeManager.shadow_drop(base, ThemeManager.SHADOW_DROP_HOVER)
		rows.append("%s: 常态 %.1f / 悬停 %.1f" % [m, dn, dh])
		assert_between(dn, DROP_NORMAL_MIN, DROP_NORMAL_MAX,
			"%s：常态影压暗量 %.1f 越界（应 %.0f~%.0f）—— 太小等于没画，太大就是脏灰"
			% [m, dn, DROP_NORMAL_MIN, DROP_NORMAL_MAX])
		assert_between(dh, DROP_HOVER_MIN, DROP_HOVER_MAX,
			"%s：悬停影压暗量 %.1f 越界（应 %.0f~%.0f）" % [m, dh, DROP_HOVER_MIN, DROP_HOVER_MAX])
		assert_gt(dh, dn, "%s：悬停影必须比常态更深（否则「抬起」这个提示丢了）" % m)
		assert_lte(dh / maxf(0.01, dn), DROP_RATIO_MAX,
			"%s：悬停/常态影深跳变 %.2f 倍超上限 %.1f —— 换 stylebox 是瞬时的，会「弹一下」" % [
				m, dh / maxf(0.01, dn), DROP_RATIO_MAX])
	print("[diag] 阴影压暗量（0..255）：" + " | ".join(rows))

	# 影色必须随主题走：CozyStyle 用该主题自己的深色调（带色相），不再是脱色的纯黑。
	# 【2026-09-30】玻璃主题（棱镜）的垫板是半透明白（三层构造），影色不能取它的
	# 色相——白影在深底上是光不是影 ⇒ 玻璃固定用一套深蓝调（见 shadow_tint 玻璃分支）。
	# ⚠️ 只断言**内置**主题（dark/light/COZY_IDS/棱镜）：Mod/皮肤注册的自定义主题
	# 影色自由，不该被本契约锁死（user://skins 装了皮肤包时会多出 id）。
	var _shadow_ids: Array = ["dark", "light"] + (ThemeManager.COZY_IDS as Array) + ["cozy_prism"]
	for m: String in _shadow_ids:
		_use(str(m))
		var tint: Color = ThemeManager.shadow_tint()
		if ThemeManager.is_glass():
			assert_ne(tint, Color(0, 0, 0),
				"%s：玻璃主题影色应是非纯黑的深调（近黑底收敛分支需要 tint 亮度>0）" % m)
			assert_lt(tint.r + tint.g + tint.b, 0.5,
				"%s：玻璃主题影色应是深色调（白影=光）" % m)
		elif str(m).begins_with("cozy_"):
			assert_ne(tint, Color(0, 0, 0),
				"%s：CozyStyle 的影色应是该主题自己的深色调（board_mat 的色相），不是纯黑" % m)
			assert_eq(tint, Color(ThemeManager.board_mat().r, ThemeManager.board_mat().g,
				ThemeManager.board_mat().b, 1.0),
				"%s：影色应等于 board_mat 去 α 后的值" % m)
		else:
			assert_eq(tint, Color(0, 0, 0),
				"%s：dark/light 底本身中性，影色仍用纯黑" % m)


func test_button_hover_and_focus_share_one_shadow() -> void:
	## hover 有影、focus 没影（改动前的真实状态）⇒ 用 Tab 移焦点会看到阴影"啪"地出现。
	## 同一个"悬停/聚焦"语义不该有两种观感，这条把它们钉成同一档。
	var b := Button.new()
	add_child_autofree(b)
	UiTheme.style_button(b)
	for key: String in ["normal", "hover", "focus", "pressed"]:
		assert_true(b.has_theme_stylebox_override(key), "style_button 应覆盖 %s 态" % key)
	var hover_sb := b.get_theme_stylebox("hover") as StyleBoxFlat
	var focus_sb := b.get_theme_stylebox("focus") as StyleBoxFlat
	assert_not_null(hover_sb, "hover 态应是 StyleBoxFlat")
	assert_not_null(focus_sb, "focus 态应是 StyleBoxFlat")
	assert_gt(hover_sb.shadow_color.a, 0.0, "hover 态必须带阴影")
	assert_eq(focus_sb.shadow_color, hover_sb.shadow_color,
		"focus 与 hover 的阴影必须同档（否则 Tab 移焦点时阴影会突然出现/消失）")
	assert_eq(focus_sb.shadow_size, hover_sb.shadow_size, "focus 与 hover 的影范围必须同档")
	# normal 与 hover 的**范围**跨度也要收敛：瞬时换 stylebox，跨度大就是跳变
	assert_lte(UiTheme.HOVER_SHADOW_SIZE - UiTheme.NORMAL_SHADOW_SIZE, 4,
		"常态→悬停的阴影模糊半径跨度应 ≤4px（实得 %d）"
		% (UiTheme.HOVER_SHADOW_SIZE - UiTheme.NORMAL_SHADOW_SIZE))
