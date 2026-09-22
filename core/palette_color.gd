# palette_color.gd —— 色码 → 颜色 的派生化（Tametsi `setColors(code, dark)` 的等价物）
#
# 为什么需要：此前关卡 palette 里的颜色是**逐关手写的 RGB 数组**，后果有两个：
#   ① 全库 57 个带 palette 的关卡，七个基础键各只有一种取值（tile 恒 #7f7f7f、
#      revealed 恒 #333333、background 恒 #140023…）—— 也就是所有盘「看起来一个颜色」；
#   ② 手写只能写一个档位，实测 9 色命名里 `_DARK` 档全库只被写了 4 次且各出现 1 次。
#      Tametsi 是给一个色码 + 一个明暗开关就自动出三色，所以它的同一色码在
#      「未翻开 / 已翻开 / 已完成变暗」三种底上都成立；我们手写就写不出来。
#
# 本模块把这个关系变成函数：**输入 9 色之一的色码 + 档位，输出颜色**。
# 于是关卡只需要写「这关是 BLUE」或「这组是 ORANGE」，三档明度自动派生且对比度有保证。
#
# 三档的用途分工（这是本模块唯一的强制约定）：
#   · accent（`derive`，保持原饱和度）—— 小面积强调：分组色、数字、旗子
#   · field （`wash`，饱和度压到 ~28%）—— 大面积铺底：瓦片底、翻开底
#     为什么必须分开：整盘 200+ 格都铺 #EA33EA 这种高饱和色，几分钟就看瞎；
#     但同一色相降饱和之后铺满整盘是舒服的，且仍然一眼可辨"这是粉的那盘"。
#
# 纯函数：static + RefCounted，不引用引擎 / UI / autoload，不做随机（散列必须稳定）。
class_name PaletteColor
extends RefCounted

## 三档名单（顺序 = 由亮到暗；UI/测试按此序枚举）。
const TIER_ORDER: Array[String] = ["standard", "dark", "darker"]

## ==== 三档的推导口径（v2，2026-09-22）====
## 旧口径是「明度单轴乘系数」（V × 1.0 / 0.72 / 0.52）。对着对标作品的常量池逐色
## 换算成 HSV 之后，真实规律是**双轴**的，单轴乘法只是它的一个粗糙近似：
##
##   dark   = 饱和度 ↑ + 明度小幅 ↓   —— 是「加深」而不是「变暗」。
##            实测对标：RED S .83→.90／GREEN .74→.91／PINK .78→.88，ΔV 仅 −0.09~−0.26
##            （VIOLET 甚至 ΔV=0，只靠色相微调）。
##   darker = 饱和度腰斩 + 明度**收敛到同一条窄带**（实测 0.345~0.420，带宽仅 0.075）
##            + 色相朝棋盘底色靠一点点 —— 相当于给整盘打一盏统一环境光。
##
## 为什么必须双轴：单轴乘法下三档只有亮度差、饱和度纹丝不动，看着像「同一张贴纸调暗了
## 三遍」；而且降幅随基色明度漂移（越亮的色掉得越多），深色相被压得发脏。
## 三个系数的取值都对着上面那两组实测值反解，不是拍脑袋：
##   · DARK_SAT_GAIN 1.10 ← 实测各色饱和度增益 1.045~1.218 的中位
##   · DARK_VALUE_DROP 0.16 ← 实测 ΔV 中位（VIOLET 那个 0 是离群值，不参与）
##   · DARKER_SAT 0.58 / DARKER_VALUE 0.385 ← 实测八色饱和度与明度的均值
##   · DARKER_HUE_PULL 0.06 ← 复现实测色相偏移量：GREEN 98.5→110.6、ORANGE 31.1→24.8、
##     BLUE 206.4→210.0 等六色都能对上（偏移量与「到底色色相的最短弧」成正比）
const DARK_SAT_GAIN := 1.10
const DARK_VALUE_DROP := 0.16
const DARKER_SAT := 0.58
const DARKER_VALUE := 0.385
## darker 档向底色靠拢的比例（0 = 不动色相，1 = 完全变成底色色相）。
const DARKER_HUE_PULL := 0.06

## 那盏「环境光」——darker 档朝它靠拢的底色（棋盘背景）。
const AMBIENT := Color8(20, 0, 35)

## 九色基色板 —— 取值直接沿用关卡 JSON 里**已经在用的**色值，不重新发明一套色板，
## 这样把某个关卡从「手写 RGB」改成「写色码」时，standard 档的输出与原来逐位相同（零视觉变化）。
const BASE := {
	"RED": Color8(216, 40, 37),
	"ORANGE": Color8(234, 139, 37),
	"YELLOW": Color8(218, 210, 0),
	"GREEN": Color8(112, 214, 55),
	"BLUE": Color8(82, 179, 255),
	"INDIGO": Color8(69, 69, 234),
	"VIOLET": Color8(144, 0, 234),
	"PINK": Color8(234, 51, 234),
	"GREY": Color8(138, 144, 153),
}
## 散列兜底时的取色顺序（固定，保证同一色码在任何机器/任何次运行都得到同一个色）。
const ORDER: Array[String] = ["RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "INDIGO", "VIOLET", "PINK", "GREY"]

## 大面积铺底的饱和度系数（见文件头「accent / field」的分工说明）。
const FIELD_SAT := 0.28
## 棋盘背景的明度系数（比 darker 再低一档，让瓦片浮起来）。
const BG_V := 0.13
## 背景的饱和度系数（背景也不该太艳）。
const BG_SAT := 0.50
## 可见文字对比度的下界（测试门禁用；由 text_on 的"取最大"构造保证 ≥ 4.29）。
const MIN_TEXT_RATIO := 4.0

const TRANSPARENT := Color(0, 0, 0, 0)


## 判断一个字符串是不是色码（能解析成颜色）。给关卡校验与 mod 作者用。
static func is_color_code(v: Variant) -> bool:
	return v is String and (v as String) != ""


## 色码 → 基色名。两级策略：
##   ① 显式色名（BLUE / PINK_DARK / ORANGE_DARKER）→ 去档位后缀后即基色；
##   ② 未登记的名字（RING_0 / mod 自定义名）→ 按**名字稳定散列**分配到九色之一。
## 必须是稳定散列而非随机：分组色是玩家用来记"这个色 = 这条约束"的锚点，
## 同一关每次打开颜色变了，学到的映射就废了。（Tametsi 的 colorFactor 随机只用于
## 每格底色的不可见微扰，不用于分组语义色。）
static func resolve_code(code: String) -> String:
	var key := _strip_tier_suffix(code)
	if BASE.has(key):
		return key
	return ORDER[_stable_hash(code) % ORDER.size()]


## 该色码是否写了显式色名（false = 走散列兜底）。给"建议显式写色名"的检查用。
static func has_explicit_name(code: String) -> bool:
	return BASE.has(_strip_tier_suffix(code))


## 色码是否是带档位后缀的形式（PINK_DARK）。带后缀时档位即由名字给出。
static func tier_of_name(code: String) -> String:
	var c := code.to_upper()
	if c.ends_with("_DARKER"):
		return "darker"
	if c.ends_with("_DARK"):
		return "dark"
	return "standard"


## accent 色：保持推导后的饱和度（小面积强调用）。
static func derive(code: String, tier: String = "standard") -> Color:
	return tiered(BASE[resolve_code(code)], tier)


## field 色：在**该档位**的基础上再降饱和（大面积铺底用）。见文件头 accent / field 分工。
## 注意顺序：先按档位推导（拿到这档该有的明暗/色相），再压饱和度 —— 反过来先把饱和度
## 压到 0.28 再推 dark 档，饱和度增益就失去了作用面。
static func wash(code: String, tier: String = "standard") -> Color:
	var c := tiered(BASE[resolve_code(code)], tier)
	return Color.from_hsv(c.h, clampf(c.s * FIELD_SAT, 0.0, 1.0), c.v, c.a)


## 三档推导的唯一出口（纯函数）：standard 原样返回，dark / darker 走双轴。
## 公开出来是为了让「调色板的人」与「渲染的人」共用同一个口径，也便于单测直接钉死。
static func tiered(base: Color, tier: String) -> Color:
	match tier:
		"dark":
			return Color.from_hsv(base.h, clampf(base.s * DARK_SAT_GAIN, 0.0, 1.0),
					clampf(base.v - DARK_VALUE_DROP, 0.0, 1.0), base.a)
		"darker":
			return Color.from_hsv(hue_toward(base.h, AMBIENT.h, DARKER_HUE_PULL),
					clampf(base.s * DARKER_SAT, 0.0, 1.0), DARKER_VALUE, base.a)
		_:
			return base


## 色相沿最短弧从 from_h 向 to_h 走 f 的比例（f=0 原样，f=1 完全到达）。
## 必须走最短弧：色相是环，350° 与 10° 只差 20° 而不是 340°。
static func hue_toward(from_h: float, to_h: float, f: float) -> float:
	var d := fposmod(to_h - from_h + 180.0, 360.0) - 180.0
	return fposmod(from_h + d * f, 360.0)


## 棋盘背景色：低饱和 + 低明度。
static func background(code: String) -> Color:
	var c: Color = BASE[resolve_code(code)]
	return Color.from_hsv(c.h, clampf(c.s * BG_SAT, 0.0, 1.0), BG_V, 1.0)


## 压在该色之上的可读文字色。
##
## 实现要点：**在「白」与「近黑」两个候选里取实际对比度更大的那个**，而不是拿亮度阈值猜。
## 阈值法的漏洞是实测出来的：三档 wash 里有一批中间亮度（BLUE/darker 等），
## 阈值判定会选出对比度只有 2.7~3.9 的文字色，压在数字上一样糊。
##
## 取最大值的做法有**可证的下界**：两个候选的对比度曲线在 L ≈ 0.195 处相交，
## 该点比值 = 1.05 / (0.195 + 0.05) ≈ 4.29 ⇒ 任何底色都能拿到 ≥ 4.29 的对比度，
## 稳过 WCAG AA 正文阈值 4.5 的邻域（数字是加粗大字，4.5 不是硬线）。测试按 ≥ 4.0 钉住。
static func text_on(bg: Color) -> Color:
	var light := Color8(255, 255, 255)
	var dark := Color8(18, 20, 26)
	return light if contrast_ratio(bg, light) >= contrast_ratio(bg, dark) else dark


## WCAG 相对亮度（**自己线性化，不用 Color.get_luminance()**）。
##
## 为什么不用内置：Godot 4.7 的 `Color.get_luminance()` 返回的是
## `0.2126r + 0.7152g + 0.0722b` 直接作用在 **sRGB 原始分量**上的值，**不做线性化**。
## 拿它算 WCAG 对比度会系统性偏低（实测灰度 L=0.32 时算出 2.88，而真正的 WCAG 值应是 7.87），
## 于是 `text_on` 会在中间亮度上选错文字色 —— 这正是"对比度最差 2.73"那个 bug 的根因。
static func relative_luminance(c: Color) -> float:
	return 0.2126 * _srgb_to_linear(c.r) + 0.7152 * _srgb_to_linear(c.g) + 0.0722 * _srgb_to_linear(c.b)


## 两个颜色的 WCAG 对比度（1..21）。供测试做门禁与 text_on 选色，不直接用于渲染。
static func contrast_ratio(a: Color, b: Color) -> float:
	var la := relative_luminance(a)
	var lb := relative_luminance(b)
	return (maxf(la, lb) + 0.05) / (minf(la, lb) + 0.05)


## `palette.theme = <色码>` 时，某个 palette 键该取什么颜色。
## 返回**透明**表示"这个键不归主题派生管"（调用方据此回退主题色/默认值）。
##
## 键 → 派生口径（每条都要能说出为什么）：
##   tile            = field standard  未翻开是最大面积，用降饱和底色
##   revealed        = field dark      翻开必须与未翻开**明确分层**，取更深一档
##   tile_border     = field darker    轮廓要比两种底色都深才看得见缝
##   tile_highlight  = 高亮线保持中性白（它是"线"不是"面"，不该被主题染色）
##   flagged_tile    = accent standard 插旗是状态强调，要跳出来 → 用高饱和
##   revealed_text   = text_on(field dark) 白/黑由底色亮度决定，不再写死 #ffffff
##   background      = background       比 darker 更低一档，让瓦片浮起来
static func theme_color(code: String, key: StringName) -> Color:
	match str(key):
		"tile":
			return wash(code, "standard")
		"revealed":
			return wash(code, "dark")
		"tile_border":
			return wash(code, "darker")
		"flagged_tile":
			return derive(code, "standard")
		"revealed_text":
			return text_on(wash(code, "dark"))
		"background":
			return background(code)
		_:
			return TRANSPARENT


## 解析 palette 里的一项取值 → 颜色。两种合法形式：
##   · RGB 数组 [r, g, b]（0..255）—— 兼容既有 57 个关卡的手写口径
##   · 色码字符串 "BLUE" / "PINK_DARK" / "RING_2" —— 走派生
## 非法输入 → 透明（调用方回退），绝不抛错、绝不臆造颜色。
static func parse(v: Variant) -> Color:
	if v is Array:
		var a: Array = v
		if a.size() < 3:
			return TRANSPARENT
		return Color8(_clamp8(a[0]), _clamp8(a[1]), _clamp8(a[2]))
	if v is String:
		var s: String = v
		if s == "":
			return TRANSPARENT
		# 带档位后缀的名字（PINK_DARK）按名字给档位；否则 standard
		return derive(s, tier_of_name(s))
	return TRANSPARENT


# ---- 内部 ----

static func _strip_tier_suffix(code: String) -> String:
	var c := code.to_upper()
	if c.ends_with("_DARKER"):
		return c.substr(0, c.length() - 7)
	if c.ends_with("_DARK"):
		return c.substr(0, c.length() - 5)
	return c


## 平台无关的稳定散列（不能依赖 String.hash() 的实现细节）。
static func _stable_hash(s: String) -> int:
	var h := 0
	for i in s.length():
		h = (h * 31 + s.unicode_at(i)) & 0x7FFFFFFF
	return h


## sRGB 分量 → 线性光（WCAG 规定的分段函数，阈值 0.04045 / 12.92）。
static func _srgb_to_linear(v: float) -> float:
	var x := clampf(v, 0.0, 1.0)
	if x <= 0.04045:
		return x / 12.92
	return pow((x + 0.055) / 1.055, 2.4)


static func _clamp8(v: Variant) -> int:
	return clampi(int(v), 0, 255)
