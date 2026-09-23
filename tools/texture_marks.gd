# texture_marks.gd —— 关卡「纹理徽记」的唯一规则源（2026-09-23 审计续）
#
# 徽记（palette.texture）是玩家侧的第二条识别通道。登记表共 16 个值，分两套
#（渲染侧的唯一登记表 = ui/board_view.gd 的 TEXTURE_MARKS）：
#   · 变体轴 9 个：forbid / anchor / spore / strata / chain / parity / block / trail / pip
#     —— 标「这盘是哪个变体」
#   · 形状族 7 个：comb / weave / halo / petal / cube / octa / ring
#     —— 标「这盘是什么拓扑」
#
# 为什么要有这个模块：这条规则此前**散在四处**——
#   ① gen_shape_levels 的 SPEC 手写（只覆盖 art_*/ani_*，holed_/hex_ 漏了）；
#   ② 其余四个生成器根本不写（重跑即丢，iso_cubes 实测丢过 5 行）；
#   ③ 一次性补丁脚本按族硬编码（commit 64f87c8，55 关）；
#   ④ 门禁只能按名字抽查，抄不进规则。
# 规则一散，新增一族或一批关必然漏。
#
# 现在它是一张表：**新增形状族/变体，只在这里加一行**——生成器（写盘前调用 resolve）
# 与门禁（test_all_shape_products_match_texture_marks 逐关校验）都从同一处读，
# 不会出现「改了生成器忘了门禁」或反之。
#
# 优先级：explicit（SPEC 显式声明）> variant（global_rules[0]）> kind（生成器 kind）。
# 返回 "" = 无徽记（普通矩形关，以及没有专属徽记的变体如 z3/z4/z5）。
extends RefCounted

## 变体轴 → 徽记（10 个，与 TEXTURE_MARKS 的变体套一一对应）。
## z1/z4/z5 仍没有专属徽记——它们不带值（借用形状族的除外，保持原样）。
## z3 原也在此列，2026-09-24 补上 `quad`（四象限田字）：它是**库内实有 6 关的变体**，
## 没有徽记就等于六关共用形状族的 weave，识别通道缺一环。
const BY_VARIANT := {
	"s1": "forbid",
	"s2": "anchor",
	"s3": "spore",
	"s4": "strata",
	"s5": "chain",
	"s6": "parity",
	"s7": "block",
	"z2": "trail",
	"z3": "quad",
	"dt": "pip",
}

## 生成器 kind → 徽记（7 个形状族）。
## 键**同时收各生成器的 kind 命名**（它们并不统一：style 用 grid、shape 用 holed_grid），
## 调用方传自己的 kind 即可；新增生成器时在这里补它的 kind 名，不必改调用点。
const BY_KIND := {
	# —— 参数化形状族 ——
	"holed_grid": "strata",   # 挖洞方格（gen_shape_levels 的 holed_*）
	"hex": "comb",            # 蜂窝（gen_shape_levels 的 hex_* 与 gen_style 的 sty_hex_*）
	# —— 风格/复刻族（gen_style_shape_levels）——
	"grid": "weave",          # 方格风格（sty_sq_*）
	"t488": "octa",           # 4.8.8 截角方形（sty_t488_*）
	# —— 多边形/环状几何族（gen_geo_levels）——
	"tri_grid": "weave",
	"trihex": "weave",
	"t31212": "weave",
	"ring": "ring",
	"poly_set": "petal",      # 多边形镶嵌（daisy_chain）
	# —— 等轴族 ——
	"iso_cubes": "cube",
	# —— 手写 mask 图案族 ——
	"mask": "halo",
}


## 解析一关应带的徽记；"" = 无徽记。
## explicit：SPEC 里显式声明的 texture（优先，允许单关覆盖族级规则）。
## variant：该关的 global_rules[0]（空串 = 纯形状关）。
## kind：生成器的 kind（或产物的 topology.style——同族两者同名时都可用）。
static func resolve(explicit: String, variant: String, kind: String) -> String:
	if explicit != "":
		return explicit
	if BY_VARIANT.has(variant):
		return str(BY_VARIANT[variant])
	if BY_KIND.has(kind):
		return str(BY_KIND[kind])
	return ""


## 本模块声明的全部徽记值（供门禁核对：必须全部登记在渲染侧 TEXTURE_MARKS 里）。
static func declared_values() -> Array:
	var out: Array = []
	for v in BY_VARIANT.values():
		out.append(str(v))
	for v in BY_KIND.values():
		out.append(str(v))
	return out


## 某变体是否有专属徽记（供报告/门禁判断「缺值是缺陷还是本就没有」）。
static func variant_has_mark(variant: String) -> bool:
	return BY_VARIANT.has(variant)
