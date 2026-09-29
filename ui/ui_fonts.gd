# ui_fonts.gd —— 字体角色 + 回退链（Godot 对 CSS font-family 列表的等价物）
#
# 为什么需要单独一层：CSS 的 `font-family: "Nerko One", "文源圆体", sans-serif`
# 是**逐字回退** —— 拉丁字符命中第一款，遇到第一款没有的汉字就换下一款。
# Godot 里一个 Font 资源只有一套字形，缺字直接画空白/豆腐块，
# 等价机制是 `Font.fallbacks`（有序数组）。
#
# ★ 最容易搞反的一条：`fallbacks` **只在主字体缺字时**才会被用上。
#   所以「想让拉丁走 Nerko、中文走文源」必须把 **Nerko 放主位、文源放 fallbacks**。
#   反过来写（主=文源、fallback=Nerko）等于什么都没做 ——
#   文源圆体自带完整拉丁字形，永远不会轮到 Nerko。
#   本工程在 2026-09-29 之前就是这个状态：全工程只挂了一个文源圆体，
#   原作那几款「更好看」的拉丁字体一款都没进来。
#
# 原作的角色分配（见 CozySudoku 分析报告 §2.3，Construct 3 / WebView2）：
#   Nerko One                     —— **界面主力**（UI 里几乎全部拉丁文本走它）
#   Potta One                     —— 标题（日系圆体）
#   Gen Jyuu Gothic Monospace Heavy —— **棋盘数字**（等宽；9 个数字宽度必须一致）
#   Russo One / Bagel Fat One     —— 备用
#   中文一律回落文源圆体（WenYuan Rounded SC，OFL，简体覆盖好）
#
# 授权：四款拉丁字体与源柔ゴシック均为 SIL OFL 1.1，本工程用的是
# **Google Fonts / 上游原件**，不是从游戏安装目录提取的字节。
# 详见 output/CozyStyle_Reusable_Assets/[03]_licenses/ 与 [05]_manifest/。
class_name UiFonts

## 界面主力：拉丁 + 数字走 Nerko One，中文回落文源圆体
##
## ⚠️ 它**不是** `project.godot [gui] theme/custom_font` 该填的值 —— 那一项是
## **引擎级兜底**（喂 `ThemeDB.fallback_font` 与引擎默认主题），只服务主题链**断掉**的
## 节点（普通 `Node` / `CanvasLayer` 子树的 addon / 独立 Window）。
## 链断后节点拿不到 root.theme，只能拿到那一项；若在那里填纯拉丁的 Nerko One，
## 这些节点上的中文会**整段画不出来**（2026-09-29 实测：DebugMenu 就是 CanvasLayer）。
## ⇒ 那一项必须填**中文覆盖完整**的字体（现为文源圆体）；本字体走
## `ThemeManager._apply_default_theme()` 下发到 `root.theme`。
const P_UI := "res://assets/fonts/NerkoOne-Regular.ttf"
## 数字主力：源柔ゴシック等宽 Heavy。**等宽是硬需求** —— 比例字体下
## `Font.get_string_size("1")=20.5px` / `"8"=37.0px`（字号 56 实测），
## 差 45%，计时器会随秒数跳动、棋盘上每个数字的光学中心也不一致。
const P_DIGIT := "res://assets/fonts/GenJyuuGothic-Monospace-Heavy.ttf"
## 中文兜底
const P_CJK := "res://assets/fonts/WenYuanRoundedSCVF.ttf"

static var _cache: Dictionary = {}


static func _load(path: String) -> Font:
	if not ResourceLoader.exists(path):
		push_warning("[UiFonts] 缺字体资源：%s（回落到默认字体）" % path)
		return null
	return load(path) as Font


## 组一条 CSS 味的回退链：primary 命中优先，缺字才去 fallbacks 里按序找。
##
## 注意这是**就地修改** primary 指向的 FontFile 资源（fallbacks 是 Font 上的属性，
## 不是 FontVariation 专有）。该资源在工程内共享，所以只需设一次；
## 也正因为它共享，别在这里做任何与「本次调用」相关的状态。
static func _chain(primary: String, fb: String) -> Font:
	var a := _load(primary)
	if a == null:
		return _load(fb)
	var b := _load(fb)
	if b != null and b != a:
		var fa: Array[Font] = []
		fa.append(b)
		a.fallbacks = fa
	return a


## ⚠️ 不能叫 `_get` —— `Object` 有一个虚函数 `_get(property: StringName) -> Variant`
## 专供动态属性访问，同名会被判「签名与父类不符」而直接解析失败（--check-only 抓到过）。
static func _role_font(role: String) -> Font:
	if not _cache.has(role):
		match role:
			"ui":
				_cache[role] = _chain(P_UI, P_CJK)
			"digit":
				_cache[role] = _chain(P_DIGIT, P_CJK)
			_:
				_cache[role] = _load(P_CJK)
	return _cache[role]


## 界面通用字体（拉丁/数字 = Nerko One，中文 = 文源圆体）
static func ui() -> Font:
	return _role_font("ui")


## 数字专用字体（等宽；棋盘数字、计时器、计数器）
static func digit() -> Font:
	return _role_font("digit")


## 纯中文兜底
static func cjk() -> Font:
	return _role_font("cjk")


## 给一个 Font 补上中文回退（用于外部自建 FontVariation 的场景）。
## 幂等：已有同样的 fallback 就不重复追加。
static func with_cjk(f: Font) -> Font:
	if f == null:
		return null
	var cjk := cjk()
	if cjk == null or cjk == f:
		return f
	var cur := f.fallbacks
	for x in cur:
		if x == cjk:
			return f
	var nxt: Array[Font] = []
	nxt.append_array(cur)
	nxt.append(cjk)
	f.fallbacks = nxt
	return f


# ---------------------------------------------------------------- 自省（供测试用）

## 取「主字体」的资源路径。FontVariation 会先解开 base_font。
##
## 为什么要解一层：`project.godot [gui] theme/custom_font` 接受任意 Font，
## 换字体时既可能直接指向 FontFile，也可能指向包了回退链的 FontVariation，
## 断言不该因为实现形式不同而红。
static func primary_path(f: Font) -> String:
	if f == null:
		return ""
	var base := f
	if f is FontVariation and (f as FontVariation).base_font != null:
		base = (f as FontVariation).base_font
	return base.resource_path


## 回退链里是否含某个资源（沿 Font.fallbacks 递归一层）
static func has_fallback(f: Font, path: String) -> bool:
	if f == null:
		return false
	for x in f.get_fallbacks():
		if x == null:
			continue
		if x.resource_path == path:
			return true
		if primary_path(x) == path:
			return true
	return false


## 这个 Font（含其 `fallbacks` 链）到底画不画得出某个字符。
##
## ⚠️ 必须自己递归：`Font.has_char()` 是**单字体**判定 —— `FontVariation` 只会把问题
## 转发给 `base_font`，**不会**去问 `fallbacks`。直接 `f.has_char("翻")` 会把
## 「靠回退能画」误判成「画不出来」，于是「中文会不会消失」这类断言全是假的。
##
## `depth` 限深防环（`fallbacks` 理论上可以配成环）。
static func can_render(f: Font, ch: String, depth: int = 0) -> bool:
	if f == null or ch.is_empty() or depth > 4:
		return false
	if f.has_char(ch.unicode_at(0)):
		return true
	for x in f.get_fallbacks():
		if can_render(x, ch, depth + 1):
			return true
	return false
