# theme_marks.gd —— 关卡「主题配色」的唯一规则源（2026-09-24）
#
# 与 tools/texture_marks.gd 同范式：一张表 + 一个 resolve/apply 出口，
# 生成器与门禁都从这里读，避免「改了生成器忘了门禁」或反之。
#
# ## 为什么需要它
#
# 实测（2026-09-24 盘点）：**生成器重跑会把 theme 悄悄丢掉**。
#   · 五个生成器写 palette 时用的是**手写 RGB 底盘**（PALETTE_BASE / PALETTE / COLORS），
#     不带 theme；而 theme 是渲染侧「整盘配色」的顶层开关（PaletteColor.theme_color）。
#   · 后果：凡被任何一次重跑碰过的关卡，主题都会退化成同一套灰紫底盘 ——
#     实测 s6/s7/z2 **整族缺失**、s2 混着 BLUE/GREEN/PINK 三种值（重跑时机不同导致）。
#   · 这和 texture 当年丢过一次是同一个病：**展示数据的规则散落在各生成器里**。
#
# ## 两条硬要求（写错等于白写）
#
#   ① 写 theme 的**同时必须删掉七个手写基础键**。取值优先级是「显式键 > theme 派生」
#      （ui/board_view.gd 的 resolve_palette_color），留着 tile/background/... 这些键，
#      theme 会被逐键短路，整盘配色一点都不会变。
#   ② **必须保留 groups 与 texture**：前者是规则语义色（分色雷数计数器的数据源），
#      后者是识别徽记，都不属于「底盘」。
extends RefCounted

## 变体 → 主题色码（10 色板，色相尽量拉开、让变体一眼可辨）。
## 这套映射是**线上既成事实**（盘点所得），本模块只是把它固化下来。
##
## z3（四象）原先沿用 z2 的 GREY —— 9 个变体占满九色，后加的 z3 无位可放，
## 结果两个不同变体在玩家眼里同色。2026-09-24 给 PaletteColor 补了第 10 色 CYAN 后分开。
const BY_VARIANT := {
	"s1": "RED",      # 局部禁形
	"s2": "BLUE",     # 重心
	"s3": "VIOLET",   # 无环
	"s4": "ORANGE",   # 洋葱
	"s5": "YELLOW",   # 行列凸
	"s6": "PINK",     # 度偶数
	"s7": "GREEN",    # 分量数 K
	"z2": "GREY",     # 相邻行锁
	"z3": "CYAN",     # 四象（与 z2 的灰区分开）
	"dt": "INDIGO",   # 骨牌边界
}

## 生成器 kind → 主题色码（纯形状关：没有变体，按形状族给一个稳定的色系）。
## 键同时收各生成器的 kind 命名（它们并不统一，见 texture_marks.gd 的同类说明）。
const BY_KIND := {
	# 参数化形状族
	"holed_grid": "ORANGE",
	"hex": "BLUE",
	# 风格族
	"grid": "VIOLET",
	"t488": "GREY",
	# 几何族
	"tri_grid": "GREEN",
	"trihex": "YELLOW",
	"t31212": "ORANGE",
	"ring": "YELLOW",
	# 多边形 / 等轴 / 手写 mask
	"poly_set": "PINK",
	"iso_cubes": "GREY",
	"mask": "VIOLET",
	# 虫洞族（tools/gen_wormhole_levels.gd）：深蓝紫 —— 「管子/隧道」的稳定色相，
	# 与其它族不撞色。不给它登记 = 生成器写出的 palette 过不了全库 theme 门禁。
	"wormhole": "INDIGO",
	# 折叠族（tools/gen_fold_levels.gd）：青 —— 「折纸/折痕」的清冷色相，与虫洞的深蓝紫分开。
	"fold": "CYAN",
}

## 纯风格族（同一 kind 有多关）的**逐关轮转**色表。
##
## 为什么需要它：风格族有 24 关，若只按 BY_KIND 取族级单色（hex→BLUE / grid→VIOLET /
## t488→GREY），24 关就只剩 3 种颜色 —— 而这一族的卖点恰恰是「每关看起来全新」。
## 用法：同 kind 的第 i 关取 STYLE_ROTATE[i % 9]，索引由生成器按 SPECS 顺序给出。
##
## **放在这里而不是各生成器里**（2026-09-24 交叉验证）：原先它在
## gen_style_shape_levels.gd 里自成一个常量，等于绕开本模块又立了第二套「形状 → 颜色」
## 规则源 —— 本文件声称是唯一事实源，那就必须真的是。
const STYLE_ROTATE: Array[String] = [
	"RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "INDIGO", "VIOLET", "PINK", "GREY"]


## 纯风格关的轮转主题色：kind 必须登记在 BY_KIND 才给色（未登记 = 不给，保持原样）。
## index 是「该关在生成器 SPECS 里的序号」—— 同一批 SPECS 稳定 ⇒ 结果幂等。
static func resolve_indexed(kind: String, index: int) -> String:
	if not BY_KIND.has(kind) or STYLE_ROTATE.is_empty():
		return ""
	return STYLE_ROTATE[abs(index) % STYLE_ROTATE.size()]


## 会**短路** theme 派生的七个手写基础键（写 theme 前必须从 palette 里删掉）。
## 与 ui/board_view.gd 的 resolve_palette_color 一一对应：这七个键各自都有「显式优先」分支。
const SHORTCUT_KEYS: Array[String] = [
	"background", "tile", "tile_border", "tile_highlight",
	"flagged_tile", "revealed", "revealed_text",
]


## 解析一关应带的主题色码；"" = 不给主题（保持生成器原样，用于普通矩形关）。
## explicit：SPEC 里显式声明的 theme（优先，允许单关覆盖族级规则）。
## variant：该关的 global_rules[0]（空串 = 纯形状关）。
## kind：生成器的 kind（或产物的 topology.style）。
static func resolve(explicit: String, variant: String, kind: String) -> String:
	if explicit != "":
		return explicit
	if BY_VARIANT.has(variant):
		return str(BY_VARIANT[variant])
	if BY_KIND.has(kind):
		return str(BY_KIND[kind])
	return ""


## 把生成器产出的 palette 规整成「theme 驱动」形态，返回**新的**字典（不改入参）。
##   · 删掉 SHORTCUT_KEYS（否则 theme 被逐键短路）
##   · 写入解析出的 theme
##   · 原样保留 groups / texture / 以及任何其它自定义键
## 解析不出主题（resolve 返回 ""）时**逐字返回入参**——普通矩形关的 palette 不该被动。
static func apply(palette: Dictionary, explicit: String, variant: String, kind: String) -> Dictionary:
	var th := resolve(explicit, variant, kind)
	if th == "":
		return palette
	var out := {"theme": th}
	for k in palette:
		var key := str(k)
		if key == "theme" or SHORTCUT_KEYS.has(key):
			continue
		out[key] = palette[k]
	return out


## 判断一个 palette 是否是「theme 驱动」形态（门禁用：有 theme 就不该残留短路键）。
static func is_theme_driven(palette: Dictionary) -> bool:
	if str(palette.get("theme", "")) == "":
		return false
	for k in SHORTCUT_KEYS:
		if palette.has(k):
			return false
	return true


## 本模块声明的全部主题色码（门禁核对用：必须都是 PaletteColor 九色之一）。
static func declared_values() -> Array:
	var out: Array = []
	for v in BY_VARIANT.values():
		out.append(str(v))
	for v in BY_KIND.values():
		out.append(str(v))
	for v in STYLE_ROTATE:
		out.append(str(v))
	return out
