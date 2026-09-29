# theme_manager.gd —— 取色中枢（全工程唯一合法色源）【plan1.1 §10.7.1】
# 色板照抄 plan1.1 §8.4.1~8.4.4，任何其他文件禁止出现硬编码 RGB。
# 主题切换：300ms Tween 逐色 lerp，每步广播 theme_changed，不中断对局。
#
# 【2026-09-29】新增 **CozyStyle 五主题家族**（海盐/陶土/鼠尾草/暮紫/雾霭，见文件下方 _COZY）。
#   旧的 dark/light 与 _DARK/_LIGHT/_NUM_*/_OVERLAY_* **一字未改**：test_theme_settings.gd 对
#   dark/light 的若干 hex 做了逐字断言，覆写它们会让契约当场变红、也会让老玩家的存档主题
#   失去还原。新家族是**追加**的第 2 套体系，默认主题（"system" 的落点）指向它。
extends Node
## autoload 名：ThemeManager

signal theme_changed
## 【09-28 审计修复 R4】「一次切换**收口**」信号：`theme_changed` 在 300ms 过渡里每步都发（~10 次），
## 便宜的消费者（改个色、`queue_redraw`）跟它走没问题；但**重建页面 / 重跑 CP-SAT 查询**这类昂贵消费者
## 若也跟 `theme_changed`，一次切换就会白跑十遍（先前 `level_select` 只能自己塞 300ms 去抖）。
## `theme_settled` 只在过渡**末步**发一次；又因为 `_retarget()` 会 kill 掉上一个 tween
##（被 kill 的 tween 不再触发回调），连点/连切时**天然只发最后一次** ⇒ 无需超时去抖、也不会漏发。
signal theme_settled

## 实际生效的主题 id：内置 "dark" | "light"，或 CozyStyle 家族的 COZY_IDS 之一。
## （旧注释写"只有 dark|light"，2026-09-29 起不再成立。）
var mode: String = "cozy_salt"

## 上一次生效的主题 id（board_view 主题波浪过渡取「旧数字色」用）。
## _ready 与每次切换/换肤前更新；初始与 mode 同值。
var prev_mode: String = "cozy_salt"

var _active := {}  # 当前生效色板（插值期间为即时值）
var _target := {}  # 目标色板
var _tween: Tween
var _default_theme: Theme  # 全局兜底文本色（挂到根 Window，见 _apply_default_theme）

# Mod 皮肤覆盖（皮肤系统核心）：skin_id="" 表示内置主题；
# _skin_colors 覆盖色板键值，_skin_numbers 覆盖数字 1~8 配色。
var skin_id: String = ""
var _skin_colors := {}
var _skin_numbers: Array = []

# §8.4.1 护眼深色模式（默认）
const _DARK := {
	"bg": Color("#1E1E24"),
	"card": Color("#28282E"),
	"cell_hidden": Color("#3A3A42"),
	"cell_revealed": Color("#232328"),
	"text": Color("#E0E0E6"),
	"text_secondary": Color("#888892"),
	"accent": Color("#7CB9E8"),
	"danger": Color("#C0504D"),
	"safe": Color("#4EA96B"),
	"grid_line": Color(0, 0, 0, 0.20),
}

# §8.4.2 护眼亮色模式
const _LIGHT := {
	"bg": Color("#F4F4F0"),
	"card": Color("#FFFFFF"),
	"cell_hidden": Color("#D6D6CE"),
	"cell_revealed": Color("#EBEBE4"),
	"text": Color("#333333"),
	"text_secondary": Color("#888888"),
	"accent": Color("#2D7BB0"),
	"danger": Color("#B71C1C"),
	"safe": Color("#1E7A34"),
	"grid_line": Color(0, 0, 0, 0.10),
}

# §8.4.3 线索数字 1~8 配色（双主题）
const _NUM_DARK := [
	Color("#5FA8E8"), Color("#79C07D"), Color("#E66666"), Color("#8E9DF0"),
	Color("#C98A5B"), Color("#5BC8C8"), Color("#E0E0E6"), Color("#9494A0"),
]
const _NUM_LIGHT := [
	Color("#1A56C4"), Color("#1E7A34"), Color("#C0392B"), Color("#1F3A93"),
	Color("#8B5A2B"), Color("#0E8388"), Color("#1A1A1A"), Color("#737373"),
]

# §8.4.4 悬停遮罩 / 终局遮罩 / 雷体色
const _OVERLAY_DARK := {
	"hover_center": Color(1, 1, 1, 0.25),
	"hover_neighbor": Color(0.48, 0.72, 0.91, 0.16),
	"endgame_dim": Color(0, 0, 0, 0.55),
	"mine_body": Color("#D8D8DC"),
}
const _OVERLAY_LIGHT := {
	"hover_center": Color(0, 0, 0, 0.18),
	"hover_neighbor": Color(0, 0, 0, 0.12),
	"endgame_dim": Color(0, 0, 0, 0.35),
	"mine_body": Color("#222226"),
}


# ============ CozyStyle 五主题家族（2026-09-29 接入）============
#
# 来源：CozySudoku 逆向出的 50 角色色板（output/CozyStyle_Reusable_Assets/[04]_palettes/
#       palette_new_5themes.json），按「保留色相/饱和度、只对受门禁约束的角色数值求解明度」
#       的规则映射到本工程的色板键。逐键的推导方式与实测对比度见
#       _pv/cozy_derive_report.txt（3 条工程硬断言 + 16 条配对护栏，5 套主题全部通过）。
#
# ⚠️ 与既有 _DARK/_LIGHT 的关系：**纯追加**，一字未改。原因是 test_theme_settings.gd
#    对 dark/light 的若干 hex 做了逐字断言（#1E1E24 / #3A3A42 / #C0504D / #5FA8E8…），
#    直接覆写旧色板会让那些契约当场变红，也会让老玩家的存档主题失去还原。
#
# CozyStyle 是**粉彩低对比**体系（实测多数角色对 GlobalBg 只有 1.0~2.7:1），照字面搬会
# 直接违反本工程的三条 WCAG 硬断言，故受约束角色（text / danger_text / board_grid /
# accent / safe / mine_body）的**明度是求解出来的**，色相与饱和度才是 CozyStyle 原值。

## 全部主题 id（顺序即设置页下拉与皮肤浏览器的展示顺序；前两项恒为跟随系统/旧内置）。
## 【2026-09-30 开放性】const → static var：Mod / 皮肤包可经 register_theme() 追加自定义
## 主题（unregister_theme() 反注册）。static 的原因：测试与工具常以**类身份**访问
## （preload 后直接 .THEME_IDS），实例 var 在类级不可见会直接 parse error；static var
## 类级/实例级都能读，注册表随类共享（本工程 ThemeManager 只有一个 autoload 实例）。
## 内置 14 项不变；消费方（下拉/皮肤浏览器）全部动态读取本数组，天然感知新增。
## 仅 count 契约测试从 == 放宽到 >= 14。
static var THEME_IDS: Array = ["system", "dark", "light",
	"cozy_salt", "cozy_terracotta", "cozy_sage", "cozy_dusk", "cozy_haze",
	"cozy_blossom", "cozy_lime", "cozy_peach", "cozy_mist", "cozy_oat",
	"cozy_prism"]
## CozyStyle 家族（需要「是否新体系」判定的地方用这个）。
## ⚠️ 不含 cozy_prism：棱镜玻璃是「半透明玻璃」体系，在「不透明配对可读性 /
## 键集一致 / board_mat 不透明」三条 CozyStyle 契约上**结构性不成立**（它故意是半透明），
## 故单独走玻璃护栏（见 test_theme_manager.gd 的棱镜玻璃段）。它仍在 THEME_IDS 里，
## 下拉可选、渲染按 board_mat().a>0 走圆角瓦片路径，行为不受影响。
const COZY_IDS: Array = ["cozy_salt", "cozy_terracotta", "cozy_sage", "cozy_dusk", "cozy_haze",
	"cozy_blossom", "cozy_lime", "cozy_peach", "cozy_mist", "cozy_oat"]
## 默认主题（SettingsManager.theme_mode == "system" 时落到这里）
const DEFAULT_COZY: String = "cozy_salt"

## ==================== 【2026-09-30 开放性】Mod 注册主题 ====================
## Mod（gdscript 代码）与皮肤包（skin.json 的 theme 字段，经 SkinService）都可以
## 注册全新的主题 id。注册表是**运行期**的（不落盘）：每次启动由 SkinService 扫描
## skin.json 重放注册，与 Mod 的 on_load 钩子同一生命周期。
var _custom: Dictionary = {}          # id -> 完整色板 Dictionary（键值同 _COZY 约定）
var _custom_nums: Dictionary = {}     # id -> [Color × 8]（可选；缺省走旧双主题数字色）

## pet_c() 派生色缓存（dark/light 等无 pet_* 主题的 24 步二分结果）。键含代际号，
## 色板任何变动点 +1 即整体失效——比逐键失效简单且不会漏。
var _pet_cache: Dictionary = {}
var _pet_gen: int = 0

## ==================== 【2026-09-30 分层主题过渡】 ====================
## 换肤不再「全部属性一口气 lerp」，也不再走棋盘的圆形波浪（已移除）——
## 学习 chain-lab.html 的 CSS 思路：**不同属性按不同节奏过渡，全程重叠连贯**。
## 单个 tween_method 驱动全局进度 p ∈ [0,1]（TRANS_CUBIC EASE_OUT，~0.48s，
## 对齐网页 .4s + 缓出手感），三段窗口把键分为三层：
##   · 几何层 GEO   p ∈ [0.00, 0.32]：瓦片圆角/缝宽、垫板圆角/影尺寸（「先圆角渐变」）
##   · 材质层 MAT   p ∈ [0.24, 0.60]：瓦片描边/内高光、垫板色/白边/影色（「再切阴影」）
##   · 配色层 COLOR p ∈ [0.50, 1.00]：其余全部 Color（bg/格/文字/数字…「最后整体渐变」）
##   · 布尔/字符串（glass/bg_gradient/flag_style/pop_duration）：首步吸附。
## 窗口重叠 ~0.08 保证阶段衔接无跳变（连贯的中间过渡状态）。
const STAGE_GEO := Vector2(0.00, 0.32)
const STAGE_MAT := Vector2(0.24, 0.60)
const STAGE_COLOR := Vector2(0.50, 1.00)
const STAGE_DURATION := 0.48

## 过渡全局进度（1.0 = 静止/已完成）。number() 的数字色插值窗口也读它。
var _phase_t: float = 1.0
## 过渡起点快照（_retarget 时抓 _active），_staged_step 按 p 从 _from→_target 混合。
var _from: Dictionary = {}
## 数字色过渡起点（prev_mode 的 8 色表快照；配色段把 number(n) 从它 lerp 到新表）。
var _nums_from: Array = []

## 形态键的 getter 缺省值：键集**变窄**方向（如棱镜 → cozy）的目标色板里没有这些键，
## 必须把它们补进有效目标，几何/材质段才有真实的渐变终点（否则憋到收口瞬间跳变）。
## 数值与各 getter 的缺省参数逐一对齐（tile_gap_frac 0.064 / tile_radius_frac 0.106 /
## mat_radius 18 / 影尺寸 0 = 无影 …）。
const _FORM_DEFAULTS := {
	"tile_gap_frac": 0.064, "tile_radius_frac": 0.106, "tile_border_w": 0,
	"tile_border": Color(0, 0, 0, 0), "tile_border_open": Color(0, 0, 0, 0),
	"tile_inset": Color(0, 0, 0, 0), "tile_inset_open": Color(0, 0, 0, 0),
	"mat_radius": 18.0, "mat_border_w": 0, "mat_border": Color(0, 0, 0, 0),
	"mat_shadow_color": Color(0, 0, 0, 0), "mat_shadow_size": 0.0,
	"mat_shadow_offset": Vector2.ZERO,
}


## 为缺形态键的色板补 getter 缺省值（_retarget 的有效目标 / 测试夹具共用）。
func _inject_form_defaults(d: Dictionary) -> void:
	for k in _FORM_DEFAULTS:
		if not d.has(k):
			d[k] = _FORM_DEFAULTS[k]

## 皮肤 palette 允许覆盖到**任意底版**的键（白名单）：pet_*（伙伴猫）+ 形态维度。
## 其余未知键仍只覆盖 base 中已有的键（防皮肤包损坏把色板写崩）。
const _OVERLAYABLE_FORM_KEYS: Array = [
	"tile_gap_frac", "tile_radius_frac", "tile_border_width",
	"tile_inset", "tile_inset_open", "pop_duration", "num_glow",
	"flag_style", "use_bg_gradient", "corner_detail", "board_mat",
	"mat_border", "mat_border_w", "mat_radius",
	"mat_shadow_color", "mat_shadow_size", "mat_shadow_offset",
]


func _is_overlayable_key(k: String) -> bool:
	return k.begins_with("pet_") or _OVERLAYABLE_FORM_KEYS.has(k)


## 注册一个自定义主题。palette 值接受 Color 或 hex 字符串；至少要给出
## bg / cell_hidden / text / accent 四个核心键（其余键缺省时取色接口落回深色兜底）。
## nums 可选：8 个数字色（Color 或 hex）。返回 { ok, reason }。
func register_theme(id: String, palette: Dictionary, nums: Array = [], label: String = "") -> Dictionary:
	id = id.strip_edges()
	if id.is_empty() or id == "system":
		return {"ok": false, "reason": "非法主题 id"}
	for c in id:
		if not (c == "_" or (c >= "a" and c <= "z") or (c >= "0" and c <= "9")):
			return {"ok": false, "reason": "主题 id 只允许小写字母/数字/下划线"}
	if THEME_IDS.has(id):
		return {"ok": false, "reason": "主题 id 已存在"}
	var pal := {}
	for k in palette:
		var v: Variant = palette[k]
		if v is Color:
			pal[str(k)] = v
		elif v is String:
			pal[str(k)] = Color.from_string(v, Color(0, 0, 0, 0))
	for core in ["bg", "cell_hidden", "text", "accent"]:
		if not pal.has(core):
			return {"ok": false, "reason": "色板缺少核心键 " + core}
	var parsed_nums: Array = []
	for v in nums:
		if v is Color:
			parsed_nums.append(v)
		elif v is String:
			parsed_nums.append(Color.from_string(v, Color.WHITE))
	_custom[id] = pal
	if parsed_nums.size() == 8:
		_custom_nums[id] = parsed_nums
	THEME_IDS.append(id)
	THEME_LABELS[id] = label if label != "" else id
	return {"ok": true}


## 反注册（Mod 卸载 / 测试清理）。当前正用该主题时回退默认 CozyStyle。
func unregister_theme(id: String) -> Dictionary:
	if not _custom.has(id):
		return {"ok": false, "reason": "不是已注册的自定义主题"}
	_custom.erase(id)
	_custom_nums.erase(id)
	THEME_IDS.erase(id)
	THEME_LABELS.erase(id)
	if mode == id:
		prev_mode = mode
		mode = DEFAULT_COZY
		_retarget()
	elif prev_mode == id:
		prev_mode = DEFAULT_COZY
	return {"ok": true}


## CozyStyle 广义家族判定（含棱镜玻璃与 Mod 自定义主题）：走圆角瓦片 / board_mat
## 分支的地方用这个，**不要散写 _COZY.has(mode)**——那会把未来注册的自定义主题
## 错当成 dark/light 走旧双主题兜底。
func is_cozy_family(id: String = "") -> bool:
	var m := id if id != "" else mode
	return _COZY.has(m) or _custom.has(m)


## 棱镜旗三块糖果面（唯一事实源 = prism 数字表前 3 色）。board_view 不得再写死 hex，
## 否则改棱镜数字色必造成旗面漂移（2026-09-30 审计 A 项）。
func flag_prism_colors() -> Array:
	var arr: Array = _COZY_NUM.get("cozy_prism", [])
	if arr.size() >= 3:
		return [arr[0], arr[1], arr[2]]
	return [Color("#9BDBFF"), Color("#8FE7B4"), Color("#FF9BA8")]

## id → 中文名（设置页 / 皮肤浏览器共用；避免两处各写一份显示名）。
## 【2026-09-30 开放性】const → static var（同 THEME_IDS：类级可访问 + 注册共享）。
static var THEME_LABELS := {
	"system": "跟随系统",
	"dark": "深色（旧）",
	"light": "亮色（旧）",
	"cozy_salt": "海盐",
	"cozy_terracotta": "陶土",
	"cozy_sage": "鼠尾草",
	"cozy_dusk": "暮紫",
	"cozy_haze": "雾霭",
	"cozy_blossom": "樱花粉",
	"cozy_lime": "青柠",
	"cozy_peach": "蜜桃杏",
	"cozy_mist": "薄雾蓝",
	"cozy_oat": "燕麦奶油",
	"cozy_prism": "棱镜玻璃",
}

## CozyStyle 五套色板。在 _DARK/_LIGHT 的 14 键（10 主色 + 4 遮罩）之上，
## 本体系另有 4 个键：3 个**配对字色**（accent_text / danger_text / safe_text）+
## 1 个**棋盘垫子**（board_mat，CozyStyle 的 BoardBg 角色）——
## CozyStyle 本身就是「配对色」体系（每个底色都有专属字色），原工程把 text() 当
## accent 底上的字色，在浅色下本来就只有 ~2:1，补齐配对是这次改造的顺带修复。
const _COZY := {
	"cozy_salt": {
		"bg": Color("#b7c9d4"),
		"card": Color("#cbf5fc"),
		"cell_hidden": Color("#ccdee6"),
		"cell_revealed": Color("#b7c9d4"),
		"text": Color("#444d5b"),
		"text_secondary": Color("#5b6471"),
		"accent": Color("#3471a1"),
		"accent_text": Color("#edfafd"),
		"danger": Color("#c92a16"),
		"danger_text": Color("#992719"),
		"safe": Color("#1f5c40"),
		"grid_line": Color(0.443137, 0.52549, 0.65098, 0.34),
		"board_grid": Color(0.156863, 0.192157, 0.25098, 0.62),
		"board_mat": Color("#526685"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.203922, 0.443137, 0.631373, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#4e535b"),
		"pet_fur": Color("#7b889d"),
		"pet_fur_2": Color("#64748d"),
		"pet_patch": Color("#a9aeb5"),
		"pet_ink": Color("#353d4a"),
		"pet_eye": Color("#dee0e1"),
		"pet_pupil": Color("#596373"),
		"pet_nose": Color("#b04c71"),
		"pet_leaf": Color("#43af7d"),
		"pet_leaf_2": Color("#329d6c"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#1f5c40"),
	},
	"cozy_terracotta": {
		"bg": Color("#d3c1b2"),
		"card": Color("#f9cbba"),
		"cell_hidden": Color("#ebdecd"),
		"cell_revealed": Color("#d3c1b2"),
		"text": Color("#564842"),
		"text_secondary": Color("#665a55"),
		"accent": Color("#9a5b32"),
		"accent_text": Color("#fdf7ec"),
		"danger": Color("#c33016"),
		"danger_text": Color("#932b18"),
		"safe": Color("#1e5a3e"),
		"grid_line": Color(0.631373, 0.494118, 0.466667, 0.34),
		"board_grid": Color(0.25098, 0.184314, 0.172549, 0.62),
		"board_mat": Color("#7d5c56"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.603922, 0.356863, 0.196078, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#58504d"),
		"pet_fur": Color("#97807c"),
		"pet_fur_2": Color("#866b66"),
		"pet_patch": Color("#b1aaa8"),
		"pet_ink": Color("#453735"),
		"pet_eye": Color("#dedcdc"),
		"pet_pupil": Color("#6e5d5a"),
		"pet_nose": Color("#ae4a6f"),
		"pet_leaf": Color("#42ad7b"),
		"pet_leaf_2": Color("#319b6a"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#1e5a3e"),
	},
	"cozy_sage": {
		"bg": Color("#bbd4c8"),
		"card": Color("#c3faee"),
		"cell_hidden": Color("#cee4d8"),
		"cell_revealed": Color("#bbd4c8"),
		"text": Color("#445454"),
		"text_secondary": Color("#5c6c6b"),
		"accent": Color("#2e7f67"),
		"accent_text": Color("#ffffff"),
		"danger": Color("#d42c18"),
		"danger_text": Color("#a32a1b"),
		"safe": Color("#216244"),
		"grid_line": Color(0.454902, 0.592157, 0.623529, 0.34),
		"board_grid": Color(0.152941, 0.207843, 0.219608, 0.62),
		"board_mat": Color("#516f77"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.180392, 0.498039, 0.403922, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#515a5a"),
		"pet_fur": Color("#7b9197"),
		"pet_fur_2": Color("#637d83"),
		"pet_patch": Color("#aeb6b7"),
		"pet_ink": Color("#364448"),
		"pet_eye": Color("#e7e8e9"),
		"pet_pupil": Color("#5a6a6e"),
		"pet_nose": Color("#ac5e4a"),
		"pet_leaf": Color("#45b782"),
		"pet_leaf_2": Color("#34a471"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#216244"),
	},
	"cozy_dusk": {
		"bg": Color("#c2bad6"),
		"card": Color("#eedffc"),
		"cell_hidden": Color("#d5cfe8"),
		"cell_revealed": Color("#c2bad6"),
		"text": Color("#4d4357"),
		"text_secondary": Color("#645a6d"),
		"accent": Color("#7f4bc2"),
		"accent_text": Color("#fdfaed"),
		"danger": Color("#be2815"),
		"danger_text": Color("#8f2517"),
		"safe": Color("#1d563c"),
		"grid_line": Color(0.592157, 0.458824, 0.658824, 0.34),
		"board_grid": Color(0.215686, 0.152941, 0.25098, 0.62),
		"board_mat": Color("#745385"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.498039, 0.294118, 0.760784, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#514b56"),
		"pet_fur": Color("#8f789b"),
		"pet_fur_2": Color("#7e628b"),
		"pet_patch": Color("#aba3af"),
		"pet_ink": Color("#3f3146"),
		"pet_eye": Color("#d7d5d8"),
		"pet_pupil": Color("#685670"),
		"pet_nose": Color("#a6476a"),
		"pet_leaf": Color("#40a778"),
		"pet_leaf_2": Color("#2f9567"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#1d563c"),
	},
	"cozy_haze": {
		"bg": Color("#bdd4d8"),
		"card": Color("#fef3f8"),
		"cell_hidden": Color("#d1e6e6"),
		"cell_revealed": Color("#bdd4d8"),
		"text": Color("#4a545c"),
		"text_secondary": Color("#626b73"),
		"accent": Color("#367b94"),
		"accent_text": Color("#ffffff"),
		"danger": Color("#d52d18"),
		"danger_text": Color("#a52a1b"),
		"safe": Color("#216345"),
		"grid_line": Color(0.454902, 0.529412, 0.643137, 0.34),
		"board_grid": Color(0.168627, 0.203922, 0.262745, 0.62),
		"board_mat": Color("#596d8b"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.211765, 0.482353, 0.580392, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#555a5f"),
		"pet_fur": Color("#848fa1"),
		"pet_fur_2": Color("#6a7b92"),
		"pet_patch": Color("#b2b6bb"),
		"pet_ink": Color("#3b4350"),
		"pet_eye": Color("#e9eaea"),
		"pet_pupil": Color("#5f6a79"),
		"pet_nose": Color("#b65477"),
		"pet_leaf": Color("#46b884"),
		"pet_leaf_2": Color("#34a572"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#216345"),
	},
	"cozy_blossom": {
		# —— 樱花粉（2026-09-29 借鉴 CozySudoku 的樱花主题色感：粉底 + 奶油格 + 玫木垫）——
		# 仅取**色彩感受**（高调粉彩 + 深玫垫子的层叠关系），所有色值均按本工程
		# WCAG 门禁重新解算（_pv/palette_gate.py），未复制任何素材/文件。
		"bg": Color("#efccd9"),
		"card": Color("#f9e3e9"),
		"cell_hidden": Color("#ffeae5"),
		"cell_revealed": Color("#efccd9"),
		"text": Color("#543d4a"),
		"text_secondary": Color("#6d5461"),
		"accent": Color("#a34f6e"),
		"accent_text": Color("#fff0f4"),
		"danger": Color("#c22a15"),
		"danger_text": Color("#8f2517"),
		"safe": Color("#1d563c"),
		"grid_line": Color(0.66, 0.42, 0.53, 0.34),
		"board_grid": Color(0.251, 0.125, 0.184, 0.62),
		"board_mat": Color("#985779"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.64, 0.31, 0.43, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#5c4550"),
		"pet_fur": Color("#9a7f8e"),
		"pet_fur_2": Color("#876a7a"),
		"pet_patch": Color("#c3aab6"),
		"pet_ink": Color("#46303c"),
		"pet_eye": Color("#efe2e7"),
		"pet_pupil": Color("#6d5260"),
		"pet_nose": Color("#8f4e3d"),
		"pet_leaf": Color("#45b782"),
		"pet_leaf_2": Color("#34a471"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#1d563c"),
	},
	"cozy_lime": {
		# —— 青柠（2026-09-29 借鉴 CozySudoku 的青柠鼠尾草主题色感：柠绿底 + 石灰垫）——
		# 同上：只借色彩感受，色值按本工程门禁重新解算（_pv/palette_gate.py）。
		"bg": Color("#cbd6b6"),
		"card": Color("#eef7d8"),
		"cell_hidden": Color("#d9e4bd"),
		"cell_revealed": Color("#cbd6b6"),
		"text": Color("#3f4a33"),
		"text_secondary": Color("#58634a"),
		"accent": Color("#55702f"),
		"accent_text": Color("#f7fbee"),
		"danger": Color("#bc2b14"),
		"danger_text": Color("#8a2615"),
		"safe": Color("#1c5439"),
		"grid_line": Color(0.42, 0.49, 0.31, 0.34),
		"board_grid": Color(0.196, 0.227, 0.125, 0.62),
		"board_mat": Color("#617148"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.33, 0.44, 0.18, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#4c5344"),
		"pet_fur": Color("#8b9482"),
		"pet_fur_2": Color("#757f6c"),
		"pet_patch": Color("#b6bcaa"),
		"pet_ink": Color("#333b2c"),
		"pet_eye": Color("#e8ebe2"),
		"pet_pupil": Color("#5c6554"),
		"pet_nose": Color("#a44685"),
		"pet_leaf": Color("#3fae77"),
		"pet_leaf_2": Color("#2e9b66"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		# `safe_text` 与 `safe` 同值：安全色是"深青绿"，描边与提示文字可以共用一个值
		"safe_text": Color("#1c5439"),
	},
	"cozy_peach": {
		# —— 蜜桃杏（2026-09-29 CozySudoku 借鉴系列第三批：杏果暖底 + 陶玫垫）——
		# 与 blossom/lime 同一工作流：仅取色彩感受，全部色值按本工程 WCAG 门禁
		# 重新解算（_pv/solve3.py，全门禁 PASS 后入库）。
		"bg": Color("#f2ddcb"),
		"card": Color("#fdeedd"),
		"cell_hidden": Color("#f9d6b0"),
		"cell_revealed": Color("#f2ddcb"),
		"text": Color("#54402f"),
		"text_secondary": Color("#937052"),
		"accent": Color("#a35a32"),
		"accent_text": Color("#fbf6f2"),
		"danger": Color("#c22a15"),
		"danger_text": Color("#b72814"),
		"safe": Color("#1d563c"),
		"grid_line": Color(0.690, 0.416, 0.388, 0.34),
		"board_grid": Color(0.330, 0.182, 0.167, 0.62),
		"board_mat": Color("#b06a63"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.639, 0.353, 0.196, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#88726f"),
		"pet_fur": Color("#a98d7c"),
		"pet_fur_2": Color("#9f806d"),
		"pet_patch": Color("#c6b4a9"),
		"pet_ink": Color("#4e3e33"),
		"pet_eye": Color("#dacec6"),
		"pet_pupil": Color("#685245"),
		"pet_nose": Color("#a44691"),
		"pet_leaf": Color("#45b782"),
		"pet_leaf_2": Color("#3da374"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		"safe_text": Color("#1d563c"),
	},
	"cozy_mist": {
		# —— 薄雾蓝（同批：雾蓝底 + 石板垫；叶色随深底解成浅薄荷，护栏同绿）——
		"bg": Color("#b9c9cd"),
		"card": Color("#e2eeec"),
		"cell_hidden": Color("#d3e0dd"),
		"cell_revealed": Color("#b9c9cd"),
		"text": Color("#3d4a54"),
		"text_secondary": Color("#657b8c"),
		"accent": Color("#3f6d8e"),
		"accent_text": Color("#e8f0f5"),
		"danger": Color("#c22a15"),
		"danger_text": Color("#982110"),
		"safe": Color("#1d563c"),
		"grid_line": Color(0.306, 0.384, 0.439, 0.34),
		"board_grid": Color(0.182, 0.228, 0.261, 0.62),
		"board_mat": Color("#4e6270"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.247, 0.427, 0.557, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#4d575e"),
		"pet_fur": Color("#6c808b"),
		"pet_fur_2": Color("#62747e"),
		"pet_patch": Color("#91a1aa"),
		"pet_ink": Color("#282f33"),
		"pet_eye": Color("#aab7bd"),
		"pet_pupil": Color("#3b464c"),
		"pet_nose": Color("#d1a094"),
		"pet_leaf": Color("#eaf7f1"),
		"pet_leaf_2": Color("#bae5d1"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		"safe_text": Color("#1d563c"),
	},
	"cozy_oat": {
		# —— 燕麦奶油（同批：燕麦米底 + 奶油格 + 亚麻灰垫）——
		"bg": Color("#ded4c6"),
		"card": Color("#f5eee1"),
		"cell_hidden": Color("#ece2d3"),
		"cell_revealed": Color("#ded4c6"),
		"text": Color("#4f4331"),
		"text_secondary": Color("#8f7959"),
		"accent": Color("#7c6a45"),
		"accent_text": Color("#f7f5f0"),
		"danger": Color("#c22a15"),
		"danger_text": Color("#aa2512"),
		"safe": Color("#1d563c"),
		"grid_line": Color(0.494, 0.451, 0.376, 0.34),
		"board_grid": Color(0.252, 0.230, 0.192, 0.62),
		"board_mat": Color("#7e7360"),
		"hover_center": Color(1.0, 1.0, 1.0, 0.34),
		"hover_neighbor": Color(0.486, 0.416, 0.271, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#6e675a"),
		"pet_fur": Color("#8f8571"),
		"pet_fur_2": Color("#827967"),
		"pet_patch": Color("#afa89a"),
		"pet_ink": Color("#3a362e"),
		"pet_eye": Color("#c5bfb5"),
		"pet_pupil": Color("#514c40"),
		"pet_nose": Color("#9e3f2e"),
		"pet_leaf": Color("#45b782"),
		"pet_leaf_2": Color("#3da374"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		"safe_text": Color("#1d563c"),
	},
	"cozy_prism": {
		# —— 基础角色（棱镜玻璃：深蓝底 + 玻璃面板 + 半透明白格）——
		"bg": Color("#141834"),
		"card": Color(0.106, 0.133, 0.267, 0.66),          # 玻璃面板（深蓝半透）
		"cell_hidden": Color(1.0, 1.0, 1.0, 0.10),         # 乳白毛玻璃
		"cell_revealed": Color(0.024, 0.039, 0.102, 0.44), # 清透压暗（数字压暗底上最清楚）
		"text": Color("#eaf2ff"),
		"text_secondary": Color("#9fb0d0"),
		"accent": Color("#4cc9f0"),
		"accent_text": Color("#06243a"),
		"danger": Color("#ff5d73"),
		"danger_text": Color("#ffd0d8"),
		"safe": Color("#3ddc97"),
		"grid_line": Color(1.0, 1.0, 1.0, 0.10),
		"board_grid": Color(1.0, 1.0, 1.0, 0.12),
		# —— 三层构造 · 中层「淡灰垫板」（网页 token 原值，见 chain-lab.html [data-theme=prism]）——
		# 网页：--mat:rgba(255,255,255,.05)（半透明白 → 缝里透出**淡灰**）、
		#       --mat-bd:1px solid rgba(255,255,255,.14)（玻璃面板白边）、
		#       box-shadow:0 30px 70px -30px rgba(0,0,0,.6)（大柔影 = 高度）。
		# 【2026-09-30 修正】旧值 Color(0.031,0.055,0.118,0.55) 是深蓝压暗层——把网页
		# 「白玻璃面板」做成了「深色板」，三层构造塌成两层（用户放大脑对照片实锤）。
		"board_mat": Color(1.0, 1.0, 1.0, 0.05),
		"mat_border": Color(1.0, 1.0, 1.0, 0.14),
		"mat_border_w": 1,
		"mat_radius": 26.0,
		"mat_shadow_color": Color(0.0, 0.0, 0.0, 0.60),
		"mat_shadow_size": 26.0,
		"mat_shadow_offset": Vector2(0, 14),
		"hover_center": Color(1.0, 1.0, 1.0, 0.20),
		"hover_neighbor": Color(0.36, 0.55, 1.0, 0.16),
		"endgame_dim": Color(0.0, 0.0, 0.0, 0.45),
		"mine_body": Color("#cfd8ef"),
		"pet_fur": Color("#8a93b8"),
		"pet_fur_2": Color("#6f78a0"),
		"pet_patch": Color("#aab2cf"),
		"pet_ink": Color("#2a2f45"),
		"pet_eye": Color("#dfe6f5"),
		"pet_pupil": Color("#586079"),
		"pet_nose": Color("#FF9DB0"),
		"pet_leaf": Color("#46b884"),
		"pet_leaf_2": Color("#34a572"),
		"pet_shadow": Color(0.0, 0.0, 0.0, 0.16),
		"safe_text": Color("#3ddc97"),
		# —— 形态维度（仅棱镜使用；其余主题缺省走旧常量/透明，零回归）——
		"tile_gap_frac": 0.07,
		"tile_radius_frac": 0.28,
		"tile_border": Color(1.0, 1.0, 1.0, 0.18),         # 未翻开格玻璃边
		"tile_border_open": Color(1.0, 1.0, 1.0, 0.09),    # 翻开格玻璃边
		"tile_border_w": 1,
		"tile_inset": Color(1.0, 1.0, 1.0, 0.22),          # 内顶高光（未翻开）
		"tile_inset_open": Color(1.0, 1.0, 1.0, 0.10),     # 内顶高光（翻开）
		"glass": true,
		"bg_gradient": true,                                 # 棋盘背景走烘焙渐变贴图
		"pop_duration": 0.42,
		"num_glow": Color(1.0, 1.0, 1.0, 0.42),            # 数字辉光（近似 CSS text-shadow）
		"flag_style": "prism",
	},
}

## CozyStyle 各主题的线索数字 1~8。色相**不随主题旋转**（「1蓝2绿3红4紫5琥珀6青」
## 是扫雷玩家的跨主题肌肉记忆），主题族性只由饱和度档位携带；7/8 为中性色且显式
## 给定不同明度（否则两者会收敛到肉眼不可分的相邻色）。
const _COZY_NUM := {
	"cozy_salt": [
		Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#68399f"), Color("#6f4a1c"),
		Color("#215960"), Color("#373e43"), Color("#4d5257")
	],
	"cozy_terracotta": [
		Color("#215284"), Color("#1d5b37"), Color("#912d22"), Color("#66389c"), Color("#6d481c"),
		Color("#20575e"), Color("#443c37"), Color("#554f4c")
	],
	"cozy_sage": [
		Color("#2c5987"), Color("#27623f"), Color("#95392f"), Color("#6c429c"), Color("#735026"),
		Color("#295e64"), Color("#384340"), Color("#505956")
	],
	"cozy_dusk": [
		Color("#234e7a"), Color("#1e5636"), Color("#872e24"), Color("#61378f"), Color("#67451d"),
		Color("#215359"), Color("#3c3743"), Color("#4e4a54")
	],
	"cozy_haze": [
		Color("#2d5a88"), Color("#276340"), Color("#963a2f"), Color("#6d439d"), Color("#745127"),
		Color("#2a5f65"), Color("#384043"), Color("#52595c")
	],
	# 樱花粉/青柠：色相沿用「1蓝2绿3红4紫5琥珀6青」肌肉记忆，明度按各自
	# cell_revealed 重新解算（_pv/palette_gate.py 全绿后才入库）。
	"cozy_blossom": [
		Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#7c3d8f"), Color("#6f4a1c"),
		Color("#215960"), Color("#4a3d45"), Color("#5f4f58")
	],
	"cozy_lime": [
		Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#68399f"), Color("#6f4a1c"),
		Color("#215960"), Color("#3a4136"), Color("#505750")
	],
	# 蜜桃杏/薄雾蓝/燕麦奶油：数字沿用海盐标准 8 色（STD_NUMS），三套 bg 都比
	# cell_revealed 门禁更浅或同档，_pv/solve3.py 已按各自 revealed 复验 ≥4.5。
	"cozy_peach": [
		Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#68399f"), Color("#6f4a1c"),
		Color("#215960"), Color("#373e43"), Color("#4d5257")
	],
	"cozy_mist": [
		Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#68399f"), Color("#6f4a1c"),
		Color("#215960"), Color("#373e43"), Color("#4d5257")
	],
	"cozy_oat": [
		Color("#225485"), Color("#1e5c38"), Color("#942e23"), Color("#68399f"), Color("#6f4a1c"),
		Color("#215960"), Color("#373e43"), Color("#4d5257")
	],
	"cozy_prism": [
		Color("#9BDBFF"), Color("#8FE7B4"), Color("#FF9BA8"), Color("#C7AEFF"),
		Color("#FFCE85"), Color("#3FE0CC"), Color("#FFFFFF"), Color("#B7C2D8")
	],
}






func _ready() -> void:
	mode = _settings_mode()
	prev_mode = mode
	_target = _palette_for(mode)
	_active = _target.duplicate()
	_apply_clear_color()
	_apply_default_theme()
	if SettingsManager != null:
		SettingsManager.settings_changed.connect(_on_settings)


## 尽早装配字体回退链。
##
## `UiFonts.ui()` 是**惰性**装配的（第一次调用时才 `load()` 并设 `Font.fallbacks`）。
## 本 autoload 排在第 5 位，前面还有 `RNGService` / `ModAPI` / `DebugMenu` 三个，
## 其中 `DebugMenu` 是**场景型** autoload；它若先建出带中文的 Label 并按
## 「Nerko 且无回退」塑形一次，那一帧就会闪豆腐块。提前到 `_init()` 里装配最省事。
##
## 注：这**不是**正确性的依赖项 —— `project.godot [gui] theme/custom_font` 已经填了
## 中文覆盖完整的文源圆体，这里没装配好也只会退化成「中文走文源」，不会画不出来。
func _init() -> void:
	UiFonts.ui()
	UiFonts.digit()


func _settings_mode() -> String:
	var want := DEFAULT_COZY
	if SettingsManager != null and SettingsManager.theme_mode != null:
		want = SettingsManager.theme_mode
	if THEME_IDS.has(want) and want != "system":
		return want
	# "system"：Godot 4.7 无可靠系统暗色检测接口 → 按文档降级（§8.4.6）。
	# 2026-09-29 起降级目标由「深色」改为 **CozyStyle 默认主题**：粉彩家族成了主视觉，
	# 新装用户第一眼就该看到它，而不是回到旧的护眼深色。
	return DEFAULT_COZY


## id → 显示名（设置页 / 皮肤浏览器共用一份，避免两处各写一份显示名而漂移）。
func theme_label(id: String) -> String:
	return str(THEME_LABELS.get(id, id))


## 是否属于 CozyStyle 家族（需要按「新体系」分支的地方用这个，别散写 begin_with("cozy")）。
func is_cozy(id: String = "") -> bool:
	var m := id if id != "" else mode
	return COZY_IDS.has(m)


## 指定主题 id 的数字 1~8 配色（数字色过渡的 from/to 两端都经它取表）。
## 口径与 number() 一致：皮肤覆盖优先，其次 CozyStyle 8 色表，最后旧双主题。
func numbers_for(m: String) -> Array:
	if _skin_numbers.size() >= 8:
		return _skin_numbers
	if _COZY_NUM.has(m):
		return _COZY_NUM[m]
	if _custom_nums.has(m):
		return _custom_nums[m]
	return _NUM_DARK if m == "dark" else _NUM_LIGHT


func _palette_for(m: String) -> Dictionary:
	# 【2026-09-30 开放性】Mod/皮肤注册的自定义主题：整张色板即 base（键集自由，
	# 缺键由取色接口的 _DARK 兜底）。
	var pal: Dictionary
	if _custom.has(m):
		pal = (_custom[m] as Dictionary).duplicate()
	else:
		# CozyStyle 家族：色板表自带 4 个遮罩键（不像 dark/light 那样与 _OVERLAY_* 分开），
		# 因为五套主题的遮罩强度都是逐主题算出来的，合在一张表里读起来才完整。
		var cozy: bool = _COZY.has(m)
		if cozy:
			pal = (_COZY[m] as Dictionary).duplicate()
		else:
			pal = (_DARK if m == "dark" else _LIGHT).duplicate()
			var overlay := _OVERLAY_DARK if m == "dark" else _OVERLAY_LIGHT
			for k in overlay:
				pal[k] = overlay[k]
	# 皮肤覆盖：pal 已有的键直接覆盖；pet_*（伙伴猫）与形态维度键（白名单）允许
	# 覆盖到**任意底版**——这是「深/亮底版换猫色、给旧主题上圆角瓦片」的合法通道。
	# 其余未知键仍静默忽略（防皮肤包损坏写崩色板）。
	for k in _skin_colors:
		if pal.has(k) or _is_overlayable_key(k):
			pal[k] = _skin_colors[k]
	return pal


func _on_settings() -> void:
	var want := _settings_mode()
	if want == mode:
		return
	prev_mode = mode
	mode = want
	_retarget()


## 应用皮肤（id 非空则覆盖色板与数字色）；base_mode 同时设定内置底版。
## 切换同样走 300ms 平滑过渡，不中断对局。
func apply_skin(new_id: String, colors: Dictionary, numbers: Array, base_mode: String = "") -> void:
	skin_id = new_id
	_skin_colors = colors
	_skin_numbers = numbers
	if _is_theme_id(base_mode):
		prev_mode = mode
		mode = base_mode
	_retarget()


## 清除皮肤，回到内置主题；base_mode 可同时切换内置底版。
func clear_skin(base_mode: String = "") -> void:
	skin_id = ""
	_skin_colors = {}
	_skin_numbers = []
	if _is_theme_id(base_mode):
		prev_mode = mode
		mode = base_mode
	_retarget()


## base_mode 是否是一个**可用的具体主题 id**（"system" 与空串不算——它们只是"用默认"的意思）。
func _is_theme_id(v: String) -> bool:
	return v != "" and v != "system" and THEME_IDS.has(v)


func _retarget() -> void:
	_target = _palette_for(mode)
	_inject_form_defaults(_target)   # 键集变窄方向：给几何/材质段补渐变终点
	_pet_gen += 1         # 皮肤应用/清除也会换色板 → 派生色缓存失效
	# 分层过渡：抓起点快照（几何/材质/配色三段都从它出发，不会二次插值）。
	_from = _active.duplicate()
	_inject_form_defaults(_from)     # 起点同理（cozy → 棱镜 时起点缺形态键）
	var nf: Array = numbers_for(prev_mode)
	_nums_from = (nf.duplicate() if nf.size() == 8 else [])
	_phase_t = 0.0
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	# 单 tween_method 驱动全局进度 p（缓出 = 网页 cubic-bezier(.2,.7,.2,1) 的手感）；
	# 每步按三段窗口重算 _active 并广播 theme_changed（棋盘每帧重绘 = 连贯中间态）。
	_tween.tween_method(_staged_step, 0.0, 1.0, STAGE_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_callback(_apply_final)


## 全局进度 p → 段内进度 [0,1]（窗口外饱和到 0/1；窗口重叠 ⇒ 阶段衔接无跳变）。
func _sub_progress(p: float, window: Vector2) -> float:
	if p <= window.x:
		return 0.0
	if p >= window.y:
		return 1.0
	return (p - window.x) / (window.y - window.x)


## 键的三层归属（见 STAGE_GEO/MAT/COLOR 注释）。返回 "geo" / "mat" / "color"；
## 不在表里的键按类型兜底：Color → color，其余（float/int/Vector2）→ geo。
func _key_stage(k: String) -> String:
	if k == "tile_radius_frac" or k == "tile_gap_frac" or k == "tile_border_w" \
			or k == "mat_radius" or k == "mat_border_w" or k == "mat_shadow_size":
		return "geo"
	if k == "tile_border" or k == "tile_border_open" or k == "tile_inset" \
			or k == "tile_inset_open" or k == "board_mat" or k == "mat_border" \
			or k == "mat_shadow_color" or k == "mat_shadow_offset":
		return "mat"
	return "color"


## 单值混合：Color→lerp / float→lerpf / int→四舍五入 / Vector2→lerp；
## k>=1 取目标（终态精确），k<=0 取起点。
func _mix_value(fv: Variant, tv: Variant, k: float) -> Variant:
	if k >= 1.0:
		return tv
	if k <= 0.0:
		return fv
	if fv is Color and tv is Color:
		return (fv as Color).lerp(tv as Color, k)
	if fv is Vector2 and tv is Vector2:
		return (fv as Vector2).lerp(tv as Vector2, k)
	if fv is float and tv is float:
		return lerpf(fv, tv, k)
	if fv is int and tv is int:
		return roundi(lerpf(float(fv), float(tv), k))
	return tv if k > 0.0 else fv


## 分层过渡的单步：按全局进度 p 重算 _active（只在各自窗口内推进的键），
## 末尾广播 theme_changed —— 棋盘每步重绘，中间态天然连贯。
func _staged_step(p: float) -> void:
	_phase_t = p
	var pg := _sub_progress(p, STAGE_GEO)
	var pm := _sub_progress(p, STAGE_MAT)
	var pc := _sub_progress(p, STAGE_COLOR)
	for k in _target:
		var tv: Variant = _target[k]
		if not (tv is Color or tv is float or tv is int or tv is Vector2):
			# 布尔/字符串（glass / bg_gradient / flag_style / pop_duration…）：
			# 无「渐变」语义，首步吸附目标值（与旧 _lerp_step 的非 Color 分支同口径）。
			_active[k] = tv
			continue
		var fv: Variant = _from.get(k, tv)   # 跨家族键集变宽：缺起点直接取目标
		match _key_stage(str(k)):
			"geo":
				_active[k] = _mix_value(fv, tv, pg)
			"mat":
				_active[k] = _mix_value(fv, tv, pm)
			_:
				_active[k] = _mix_value(fv, tv, pc)
	# 键集变窄（如棱镜 → cozy）：布尔/字符串键在目标里不存在时必须**立即移除**，
	# 否则 is_glass()/use_bg_gradient()/flag_style() 在整个过渡期读到旧主题的残留值
	#（背景淡化分支也因此永远等不到翻转信号）。配色键的残留无害（无人读取）。
	for sk in ["glass", "bg_gradient", "use_bg_gradient", "flag_style"]:
		if not _target.has(sk) and _active.has(sk):
			_active.erase(sk)
	_apply_clear_color()   # 底色跟随配色段渐变，避免"卡片在过渡、底色却已经跳完"
	_pet_gen += 1          # 色板在变 → 伙伴派生色缓存随代失效
	theme_changed.emit()


func _apply_final() -> void:
	_active = _target.duplicate()
	_phase_t = 1.0
	_pet_gen += 1
	_apply_clear_color()
	_apply_default_theme()
	theme_changed.emit()
	theme_settled.emit()   # R4：末步收口（昂贵重建只跟这一拍）


## 页面底色接线。
## 背景：`bg` 原本是个「只定义、不消费」的孤儿键（全工程 0 处调用），也没有任何地方
## 调用过 RenderingServer.set_default_clear_color —— 于是各页面露出来的其实是 Godot
## 的默认清屏色 #4C4C4C（对局页再叠一层 endgame_dim 变成 #222222），五套粉彩主题
## 换来换去只有卡片和文字在动、底色纹丝不动。
## 这里把 bg 接到全局清屏色上：一处接线覆盖**全部**页面（各页面场景的根都是裸
## Control，本来就没有背景节点，不需要逐个改 .tscn，也就不会与后续美术改动打架）。
func _apply_clear_color() -> void:
	RenderingServer.set_default_clear_color(bg())


## 需要显式下发字体的控件类型（见 `_apply_default_theme` 里那段说明）。
## 只列**带 `font` 主题条目**的类型：TextEdit/CodeEdit 走 `font` 之外的条目，不在此列。
const _FONT_TYPES: Array = [
	"Label", "RichTextLabel", "LinkButton", "TooltipLabel",
	"Button", "OptionButton", "MenuButton", "CheckBox", "CheckButton",
	"LineEdit", "PopupMenu", "TabBar", "ItemList", "Tree",
]


## 【2026-09-29 新增】全局兜底文本色。
##
## 缘起：截图验收时发现选关页大标题「选择关卡」是**白字压粉彩底**（≈1.5:1），
## 几乎看不见。追下去是工程级问题：ui/ 下共有 63 处 `Label.new()`，但只有约 28 处
## 写了 font_color override —— 剩下的全靠**引擎默认主题**的白色字。旧的深色主题
## 恰好是白字，所以这个洞一直没人发现；一旦换成粉彩浅底，这些标签会成片消失。
##
## 逐个补 override 是治标的（下一次有人新加 Label 又会漏）。这里改为挂一个
## **运行时 Theme 到根 Window**：Godot 的 Theme 是链式回退的 —— 只覆盖我们定义过的
## 条目，没定义的（按钮 stylebox、Slider 纹理…）继续走引擎默认主题，所以是纯增量。
## 只覆盖「纯文本」类控件；按钮在本工程里都是显式着色的，不去动以免覆盖选中态字色。
func _apply_default_theme() -> void:
	if _default_theme == null:
		_default_theme = Theme.new()
	# ---- 字体角色（2026-09-29 新增，见 ui/ui_fonts.gd）----
	# CSS 的 `font-family` 是一张**列表**（逐字回退），Godot 是「主字体 + Font.fallbacks」。
	# 组装在 UiFonts 里，这里只负责把它下发到主题。
	#
	# ★ 机制结论（2026-09-29 探针 v4/v5/v8 逐例实测，见 `_pv/font_probe*_out.txt`）：
	#   Godot 4 的主题继承**只在 Control / Window 祖先之间传递** —— 路径上夹一个普通
	#   `Node`（或 `CanvasLayer`，如 `addons/debug_menu`）就**整条断掉**，
	#   `font` 与 `font_color` **一起断**。解析顺序：
	#       自身 theme → 最近的 Control/Window 祖先 theme → ThemeDB 项目主题 → ThemeDB 默认主题
	#   而 ThemeDB 那一层的 `font` 条目就是 `project.godot [gui] theme/custom_font`。
	#
	#   真机链路完好：`run/main_scene` 与 `change_scene_to_file` 都把 Control 场景根
	#   直接挂到 root 下，所以这里 `root.theme = _default_theme` **确实生效**。
	#   实证（v8）：在 `custom_font` 已换回**文源圆体**的前提下，真实 level_select 的
	#   **103/103** 个 Label 依旧全部解析到 NerkoOne —— 此时 Nerko 只可能来自 root.theme。
	#   对照（同一次运行）：同一份场景挂在普通 Node 下 ⇒ 103/103 解析到文源圆体（断链）。
	#
	#   ⚠️ 曾经把这条记成「`Theme.default_font` 不生效」+「custom_font 优先级高于节点链」
	#   ——**是误判**。当时的验收工具（`tools/_cozy_shot.gd`）把场景挂在**普通 Node** 下，
	#   链路本来就是断的，`root.theme` 根本轮不到，于是「改了没反应」被归因成"优先级低"。
	#   工具已修（宿主改为直挂 root 的 Control）；`test/ui/test_theme_surface_contrast.gd`
	#   里留了防回归断言。
	#
	#   为什么仍要按类型 `set_font("font", type, ...)`：`Theme.default_font` 只是
	#   **本 theme 内**「该类型没有 font 条目」时的回退，覆盖不完全；逐类型下发是双保险，
	#   多写的类型只是多一条用不到的条目，无害。
	#
	# ⚠️ 与 `project.godot [gui] theme/custom_font` 的分工（**别搞混**）：
	#   那一项 = **引擎级兜底**，只服务「断链」的节点（CanvasLayer 子树的 addon、
	#   独立 Window、引擎内部控件）。所以它必须填**中文覆盖完整**的字体 ——
	#   2026-09-29 一度把它填成纯拉丁的 Nerko One，那种写法下断链节点上的中文
	#   （例如 DebugMenu）会**整段画不出来**。界面主力字体走 root.theme（本函数）。
	#
	# ⚠️ 故意**不设** `default_font_size`：那会覆盖引擎默认的 16，
	# 凡是没显式设字号的地方会一起变，属于超出「换字体」范围的改动。
	var want_font: Font = UiFonts.ui()
	if want_font != null:
		if _default_theme.default_font != want_font:
			_default_theme.default_font = want_font
		for ft: String in _FONT_TYPES:
			# 【2026-09-29 卡顿修复】字体运行期恒定：仅条目缺失/不一致时才 set。
			# Theme.set_font 不查等值、无条件置脏 → 原实现每步 14 次全树主题重传播。
			if _default_theme.get_font("font", ft) != want_font:
				_default_theme.set_font("font", ft, want_font)
	var t: Color = text()
	_default_theme.set_color("font_color", "Label", t)
	_default_theme.set_color("font_color", "RichTextLabel", t)
	_default_theme.set_color("default_color", "RichTextLabel", t)
	_default_theme.set_color("font_color", "LinkButton", accent())
	_default_theme.set_color("font_hover_color", "LinkButton", accent_text())
	_default_theme.set_color("font_color", "TooltipLabel", text())
	var root: Window = null
	if is_inside_tree():
		root = get_tree().root
	if root != null and root.theme != _default_theme:
		root.theme = _default_theme


# ============ 取色接口（全工程唯一合法色源） ============

func bg() -> Color:
	return _active.get("bg", _DARK.bg)

func card() -> Color:
	return _active.get("card", _DARK.card)

func cell_hidden() -> Color:
	return _active.get("cell_hidden", _DARK.cell_hidden)

func cell_revealed() -> Color:
	return _active.get("cell_revealed", _DARK.cell_revealed)

func text() -> Color:
	return _active.get("text", _DARK.text)

func text_secondary() -> Color:
	return _active.get("text_secondary", _DARK.text_secondary)

func accent() -> Color:
	return _active.get("accent", _DARK.accent)

func danger() -> Color:
	return _active.get("danger", _DARK.danger)


## 危险色的**文字**版本（2026-09-25 无障碍审计）：原 danger(#C0504D) 作 18px 正文压在
## 深色底上只有 ≈3.55:1，达不到 WCAG AA 的 4.5:1。文字场景一律用这个（提亮后 ≈6:1）；
## 图形填充（旗子 / 危险格 / 雷 / 引爆高亮）继续用 danger()——那里门槛是 3:1，原标题色够用。
func danger_text() -> Color:
	# CozyStyle 家族：danger_text 是**表中已解算好的独立键**（同一色相下压明度到 ≥4.6:1），
	# 因为那些主题的底是粉彩浅色，"提亮"只会越提越糊 —— 与 light 分支同理，故不能再套
	# lightened(0.30) 的通用公式。
	if is_cozy_family():
		return _active.get("danger_text", danger())
	# 分主题（2026-09-26 补的 WCAG 测试抓出的 bug）：dark 底上提亮 0.30 ≈6:1 ✓；
	# 但 light 底是**浅色**，提亮是反向操作（越提越贴近底色），实测只有 3.51:1 ❌——
	# 浅底直接用原 danger（#B71C1C 压 #F4F4F0 ≈5.9:1）即达标。
	return danger().lightened(0.30) if mode == "dark" else danger()


## 【2026-09-29 新增】accent 底上的**文字**色。
##
## 缘起：原工程在 accent 背景按钮上直接写 `font_color = text()`。深色主题下侥幸能用
## （accent #7CB9E8 偏亮），但浅色主题 accent #2D7BB0 压 #333333 只有 ≈2.0:1 —— 既存缺陷。
## CozyStyle 是「配对色」体系（每个底色都有专属字色，如 NumBtn 配 NumBtnNum、
## NumBtnSel 配 NumBtnNumSel），本次接入顺手把这条纪律补齐：凡 accent 当底，字色走本接口。
func accent_text() -> Color:
	return _active.get("accent_text", text())


## 【2026-09-29 新增】safe 当底时的字色。CozyStyle 家族里 safe 已是深青绿，两者同值；
## 独立成键是为了让未来某个主题能把"安全底"做成浅色而不用改调用点。
func safe_text() -> Color:
	return _active.get("safe_text", safe())


## WCAG 相对亮度 / 对比度。放在 ThemeManager 而不是测试里，是因为调用点也需要它
## （见 text_on）—— 这类公式一旦有两份实现就必然会漂移。
static func _lin(u: float) -> float:
	return u / 12.92 if u <= 0.04045 else pow((u + 0.055) / 1.055, 2.4)


static func contrast_ratio(a: Color, b: Color) -> float:
	var la: float = 0.2126 * _lin(a.r) + 0.7152 * _lin(a.g) + 0.0722 * _lin(a.b)
	var lb: float = 0.2126 * _lin(b.r) + 0.7152 * _lin(b.g) + 0.0722 * _lin(b.b)
	var hi: float = max(la, lb)
	var lo: float = min(la, lb)
	return (hi + 0.05) / (lo + 0.05)


## 【2026-09-29 新增】任意底色上的**保证可读**的前景色。
##
## 缘起：工程里大量选中态/强调态把底色从 card() 换成 accent 系
## （`accent().darkened(0.5)`、`safe().darkened(0.55)`…），但字色仍然固定写 text()。
## 旧的两套主题（深/浅）各自"看着还行"，所以一直没暴露；接入五套粉彩之后同一个淡化
## 系数在五个色相上会给出完全不同的明度，固定 text() 必然有几个主题糊掉。
##
## 与其在几十个调用点各手动挑一次颜色（下一个人改配色时又会重新踩），不如把选择权
## 交给**实测对比度**：按优先级在候选前景色里挑第一个达标的，全都不达标就挑最亮的那个。
## 候选顺序即语义优先级 —— theme 自己的配对字色 > 正文色 > 纯白 > 近黑。
func text_on(base: Color, min_ratio: float = 4.5) -> Color:
	var cands: Array[Color] = [accent_text(), text(), Color.WHITE, Color("#101418")]
	var best: Color = cands[0]
	var best_ratio := -1.0
	for c in cands:
		var r: float = contrast_ratio(c, base)
		if r >= min_ratio:
			return c
		if r > best_ratio:
			best_ratio = r
			best = c
	return best


## 棋盘格线专用色（2026-09-25 无障碍审计）。
##
## 通用 `grid_line()` 是 0.20 alpha 的柔和描边，服务卡片边框；但棋盘的**相邻同色格之间
## 只靠这条线分隔** —— 0.20 压在深色底上只有 ≈1.2:1（WCAG 非文本对比要求 ≥3:1），
## 低视力玩家在一个 9×9 灰盘上看不出格子边界（审计确认）。
##
## 关键点：深色底上**不能靠加深**来提对比（黑线再黑也只到 1.3:1），必须换**浅色线**。
## 此函数只被棋盘格线使用，卡片边框仍走 grid_line，整体视觉风格不大改。
func board_grid() -> Color:
	# alpha 值经实测校准（2026-09-26）：0.34/0.42 在 **alpha 混合后**压 cell_hidden
	# 只有 2.75/2.86:1（<3 ❌）—— 旧注释的对比数字按线色直接算、没算混合，是错的。
	# 提到 0.42/0.48 后混合对比 ≈3.3/3.4:1 ✓（新补的 WCAG 测试按混合口径抓出）。
	#
	# CozyStyle 家族（2026-09-29）：线色与 alpha **都在表里解算好了** —— 保留该主题
	# BoardBg 的色相/饱和度、解出线色明度，令"浅砖之间的深缝"混合后 ≥3.5:1。
	# 注意这不是"换了个半透明色"那么简单：鼠尾草原色 #688F98 即便 α=1.0 也只有 2.63:1，
	# 必须连明度一起解才能过 3:1。
	if is_cozy_family():
		return _active.get("board_grid", Color(0, 0, 0, 0.48))
	return Color(1, 1, 1, 0.42) if mode == "dark" else Color(0, 0, 0, 0.48)


## 【2026-09-29 新增】棋盘「垫子」色 —— 格阵下面那块面板（CozyStyle 的 BoardBg 角色）。
##
## 为什么需要它：本工程的 cell_revealed 取的就是 GlobalBg，而 board_view 是全屏 Control、
## 根本没有棋盘背景节点 ⇒ **已翻开的格与页面底色完全同色**，棋盘的边界只剩 1px 格线在
## 暗示。CozyStyle 的 9×9 格阵之所以读起来是"一个物件"，靠的就是它有块专属面板色。
##
## 数值说明：原角色值对 GlobalBg 只有 2.47:1（海盐 #657DA0），低于本工程对非文本相邻色
## 的 3:1 口径 ⇒ 保留色相/饱和度、只解明度，到 3.4:1（留 0.4 余量）。
## dark/light 返回全透明 = **不画垫子**，旧主题观感零变化。
func board_mat() -> Color:
	if is_cozy_family():
		return _active.get("board_mat", Color(0, 0, 0, 0))
	return Color(0, 0, 0, 0)


## 【2026-09-29 新增】动物伙伴（占位猫）专用取色。
##
## 为什么 CozyStyle 的 50 个角色里一个都用不上：那 50 个全是 **UI 角色**
## （按钮、格子、数字、边框、状态…），整套体系里**没有任何一个"生物/角色"色**。
## 直接拿 BoardBg 当猫毛会得到一块和棋盘同色的色斑，猫会消失。
##
## 所以 pet_* 是**新解算的一族**（见 _pv/derive_cozy.py 的 solve_side + P1..P8 护栏）：
## 色相借自**该主题自己的**角色（毛 ← BoardBg 色相、鼻 ← 暖色带中离毛色相最远的点、
## 叶 ← 工程既有的 safe 绿），明度则解到"刚好压过门槛"的那一档 —— 这正是
## CozyStyle 低对比的习惯，不是随手挑的漂亮色。
##
## 键名：fur / fur_2 / patch / ink / eye / pupil / nose / leaf / leaf_2 / shadow
## （调用方传短键，此处补 "pet_" 前缀）。
##
## 旧主题（dark / light）没有这一族 —— 就地派生一族而不是全落 text()：
## 全落 text() 会把猫压成一块**纯剪影**（连眼睛、鼻子、草地上不了色，因为都同色），
## 而伙伴是要能看出"是只猫"的。派生值直接复用手边已有的角色，观感不如 CozyStyle 的
## 专用解算，但保住了最低限度的可读性。这两套主题的 hex 被 test_theme_settings.gd
## 逐字钉着、不能顺手改 ⇒ 派生是这里唯一可行的做法。
func pet_c(key: String) -> Color:
	# 【2026-09-30 开放性】皮肤/Mod 直改：任意底版下，皮肤 palette 的 pet_* 键经
	# _palette_for 白名单注入 _target/_active。**_skin_colors 原表必须最先查**——
	# apply_skin 走 300ms 过渡，_active 要等首步才长出/更新 pet_* 键；若先查 _active，
	# 换肤后的 300ms 里会返回旧毛色（过渡中回退、断言/首帧都不对）。显式意图压一切。
	if _skin_colors.has("pet_" + key):
		return _skin_colors["pet_" + key]
	if _active.has("pet_" + key):
		return _active["pet_" + key]
	# 派生结果代际缓存：dark/light 没有 pet_* 族 ⇒ 旧实现每次都 24 步二分，
	# 而伙伴 _draw 每帧约查 20 个色键 ⇒ 每帧几百次对比度运算白烧。代际号在色板
	# 任何变动点（过渡步/收口/换皮肤）+1，缓存随代失效。
	var ckey := "%d/%s" % [_pet_gen, key]
	if _pet_cache.has(ckey):
		return _pet_cache[ckey]
	# 旧主题（dark / light）没有 pet_* 族（它们的 hex 被 test_theme_settings.gd 逐字钉着、
	# 不能为伙伴顺手加键）⇒ 就地派生。派生只做两件事：**选对方向** + **解够对比度**。
	#
	# 为什么不能像第一版那样写死系数（ink = bg.darkened(0.35) 那一类）：那等于把"够不够
	# 分得开"交给运气。实测亮色主题的 bg 本来就接近白，bg.darkened(0.35) 比毛色**更亮**
	# （1.33:1，整只猫糊成一块剪影）；dark 主题的鼻子借 danger 也只有 1.33:1；
	# 亮色主题的口鼻斑 lightened(0.35) 只有 1.20:1。现在改成"以配对护栏为目标解明度"，
	# 与 _pv/derive_cozy.py 给 CozyStyle 解明度是同一套做法 ⇒ dark / light 受**同一套**
	# P1..P8 约束（守卫见 test_companion_pet.gd，7 套主题一个门槛表）。
	var fur := text_secondary()
	var page := bg()
	var out := Color.WHITE
	match key:
		"fur":
			out = fur
		"fur_2":
			out = fur.darkened(0.18)
		# 口鼻斑：朝**页面底色**推（浅底变亮、深底变暗），解得 ⊥毛 ≥1.6（护栏 1.4）。
		"patch":
			out = _pet_solve(fur, page, fur, 1.6)
		# 描边：朝**背离页面**的那一端推 —— 它同时要压住毛色和页面底色。深色主题下这给出
		# 一条近白描边，这不是取巧：bg #1E1E24 的亮度已接近 0，没有更暗的地方可去，
		# 深色底上的描边本来就只能往亮走（CozyStyle 那套是浅底，才用深墨）。
		"ink":
			out = _pet_solve(fur, _pet_extreme(page), fur, 3.2)
		"eye":
			out = Color.WHITE
		# 虹膜：起点是毛色压暗一档（多数主题下已够线 ⇒ 解出的 t≈0，即"不动"），
		# 不够才继续朝黑推，解得 ⊥眼白 ≥6.0（护栏 4.5）。
		"pupil":
			out = _pet_solve(fur.darkened(0.35), Color.BLACK, Color.WHITE, 6.0)
		# 鼻子：色相必须留在暖色（红鼻子是解剖事实），只解明度 —— 朝背离毛色的那一侧推。
		"nose":
			out = _pet_solve(danger(), _pet_away(danger(), fur), fur, 1.7)
		"leaf":
			out = safe()
		# 两色叶：同色系推深一档（护栏 1.2）。
		"leaf_2":
			out = _pet_solve(safe(), Color.BLACK, safe(), 1.35)
		"shadow":
			out = Color(0, 0, 0, 0.16)
		_:
			out = text()
	_pet_cache[ckey] = out
	return out


## 背离 ref 的那一端（比 ref 暗就往黑走，比 ref 亮就往白走）。
## 用于"只许改明度、不许动色相"的角色（鼻子）。
func _pet_away(base: Color, ref: Color) -> Color:
	return Color.BLACK if base.get_luminance() <= ref.get_luminance() else Color.WHITE


## 页面底色的**对立极端**：底色偏亮 ⇒ 描边往黑走，底色偏暗 ⇒ 往白走。
func _pet_extreme(page: Color) -> Color:
	return Color.WHITE if page.get_luminance() < 0.5 else Color.BLACK


## 把 from 沿 toward 推进到 ⊥ref ≥ target，返回恰好越线的那个值（二分 24 步）。
##
## 与 _pv/derive_cozy.py 的 solve_side 是同一套做法（受门禁约束的角色按目标解明度），
## 只是直接对 Color 二分 —— 更短，也不必假设 sRGB 分段公式的形状。toward 比 ref 更极端时
## 对比度沿 t 单调不减，故二分成立。
##
## ⚠️ 可行性判断必须拿 **ref** 比，不能拿 from 比：toward 本身对 ref 都不够时才是真的无解
##    （此时返回 toward，尽力而为）。第一版写成对比 from，于是"起点已经够线、只需保持不动"
##    被误判成无解而直接跳到纯黑（虹膜曾因此整块变黑）。
func _pet_solve(from: Color, toward: Color, ref: Color, target: float) -> Color:
	if contrast_ratio(toward, ref) <= target:
		return toward
	var lo := 0.0
	var hi := 1.0
	for _i in 24:
		var mid := (lo + hi) * 0.5
		if contrast_ratio(from.lerp(toward, mid), ref) >= target:
			hi = mid
		else:
			lo = mid
	return from.lerp(toward, hi)

## 提示「必安全」高亮色（§8.4 扩展：提示系统用色）
func safe() -> Color:
	return _active.get("safe", _DARK.safe)

func grid_line() -> Color:
	return _active.get("grid_line", _DARK.grid_line)

## 当前 mode 的数字 8 色表（number() 的取值事实源）。
func _num_table() -> Array:
	if _COZY_NUM.has(mode):
		return _COZY_NUM[mode]
	if _custom_nums.has(mode):
		return _custom_nums[mode]
	return _NUM_DARK if mode == "dark" else _NUM_LIGHT


## §8.4.3 线索数字配色；n ∈ 1..8（0 = 空白不绘制，不在此处理）
func number(n: int) -> Color:
	if _skin_numbers.size() >= 8 and n >= 1 and n <= 8:
		return _skin_numbers[n - 1]
	if n < 1 or n > 8:
		return text()
	var arr: Array = _num_table()
	# 【2026-09-30 分层过渡】数字色随**配色段**渐变（STAGE_COLOR 窗口）：
	# 起点 = prev_mode 的数字表（_retarget 快照），棋盘数字不再生硬跳变。
	# （旧圆形波浪时代数字插值在 board_view._tw_num 里，波浪已移除、职责上收到此。）
	if _phase_t < 1.0 and _nums_from.size() == 8:
		var pc := _sub_progress(_phase_t, STAGE_COLOR)
		return (_nums_from[n - 1] as Color).lerp(arr[n - 1], pc)
	return arr[n - 1]

func mine_body() -> Color:
	return _active.get("mine_body", _OVERLAY_DARK.mine_body)

func hover_center_overlay() -> Color:
	return _active.get("hover_center", _OVERLAY_DARK.hover_center)

func hover_neighbor_overlay() -> Color:
	return _active.get("hover_neighbor", _OVERLAY_DARK.hover_neighbor)

func endgame_dim() -> Color:
	return _active.get("endgame_dim", _OVERLAY_DARK.endgame_dim)


## ============ 形态维度（棱镜玻璃主题专用；其余主题缺省 → 走旧常量/透明，零回归）============
##
## 这些键不是颜色，而是**几何 / 动效 / 材质**参数。放在 _COZY 表里与颜色平级，是为了
## 让皮肤覆盖（apply_skin）也能一并改它们，且读取路径与颜色完全一致。
## 所有 getter 的缺省值都对齐改造前的硬编码常量（TILE_GAP_FRAC / TILE_RADIUS_FRAC / POP_WD）
## 或"无效果"（透明 / 0 / false / 空串），故对 8 套旧主题是完全恒等的。

## 瓦片缝宽 / 圆角（占格边长比例）。BoardView 原硬编码 TILE_GAP_FRAC=0.064 / TILE_RADIUS_FRAC=0.106。
func tile_gap_frac() -> float:
	return float(_active.get("tile_gap_frac", 0.064))

func tile_radius_frac() -> float:
	return float(_active.get("tile_radius_frac", 0.106))

## 瓦片描边（玻璃边缘）。缺省透明 + 宽 0 ⇒ 不画描边（旧主题原样）。
func tile_border() -> Color:
	return (_active.get("tile_border", Color(0.0, 0.0, 0.0, 0.0)) as Color)

func tile_border_open() -> Color:
	return (_active.get("tile_border_open", tile_border()) as Color)

func tile_border_width() -> int:
	return int(_active.get("tile_border_w", 0))

## 内顶高光（近似 CSS inset 0 1px 0）。缺省透明 ⇒ 不画（旧主题原样）。
func tile_inset() -> Color:
	return (_active.get("tile_inset", Color(0.0, 0.0, 0.0, 0.0)) as Color)

func tile_inset_open() -> Color:
	return (_active.get("tile_inset_open", tile_inset()) as Color)

## 是否玻璃主题（启用烘焙渐变背景 + 半透玻璃瓦片）。
func is_glass() -> bool:
	return bool(_active.get("glass", false))

## 棋盘背景是否走烘焙渐变贴图（棱镜的彩色光晕背景）。
func use_bg_gradient() -> bool:
	return bool(_active.get("bg_gradient", false))

## 单格 pop 时长（秒）。缺省 0.20 = 旧常量 POP_WD。
func pop_duration() -> float:
	return float(_active.get("pop_duration", 0.20))

## 数字辉光色（近似 CSS text-shadow）。缺省透明 ⇒ 不发光（旧主题原样）。
func num_glow() -> Color:
	return (_active.get("num_glow", Color(0.0, 0.0, 0.0, 0.0)) as Color)

## 旗形标识（"" = 默认三角旗）。棱镜用 "prism" 小棱镜图形。
func flag_style() -> String:
	return str(_active.get("flag_style", ""))


## ============ 垫板形态键（2026-09-30 三层构造 · 仅玻璃主题声明，其余走缺省）============
##
## 网页版每个主题的棋盘都是三层：内层瓦片 → 中层垫板（.mat：半透面板 + 白边 +
## 大柔影显高度）→ 外层页面背景（垫板区域带 backdrop blur = 透镜感）。
## 棱镜把这些维度全部 token 化（见 _COZY["cozy_prism"] 的 mat_* 键）；
## 非 glass 主题缺省值让 _mat_stylebox 走旧路径，逐像素不变。
func mat_border() -> Color:
	return (_active.get("mat_border", Color(0.0, 0.0, 0.0, 0.0)) as Color)

func mat_border_w() -> int:
	# 编辑器缓存戳（2026-09-30）：script_patch 保存触发就地重载。
	return int(_active.get("mat_border_w", 0))

func mat_radius() -> float:
	return float(_active.get("mat_radius", 18.0))

func mat_shadow_color() -> Color:
	return (_active.get("mat_shadow_color", Color(0.0, 0.0, 0.0, 0.0)) as Color)

func mat_shadow_size() -> float:
	return float(_active.get("mat_shadow_size", 0.0))

func mat_shadow_offset() -> Vector2:
	var v: Variant = _active.get("mat_shadow_offset", Vector2.ZERO)
	return v if v is Vector2 else Vector2.ZERO


# ============ 软阴影（2026-09-29 用户反馈修复）============
#
# 起因（用户原话）：「鼠标放上去弹一下那种效果……有个阴影。阴影没有做好很好的适配，
# 有些突兀。」
#
# 改动前：UiTheme 用**一份固定的纯黑 α**（常态 0.10 / 悬停 0.22）服务全部七套主题。
# 实拍量测（`_pv/hover_b/`，逐行亮度剖面，0..255 编码值口径，见 `_measure.txt`）：
#   · 同一份 α0.22 压在粉彩底（L≈198）上掉 **43.4/255**，压在深色底（L≈30）上只掉
#     **7.1/255** —— 相差 6 倍。于是粉彩主题上是一圈**脱色的脏灰**，深色主题上几乎
#     看不见（等于白画）。这就是"没有做好适配"的本体：**一套 α 服务七套底色**。
#   · 常态→悬停是**瞬时换 stylebox**（α0.10→0.22、size 8→12 一帧到位），而 scale 是
#     0.2s 缓动 —— 影先跳、按钮后长，观感就是"弹一下"里夹着一记突兀的加深。
#     （实测跳变 2.2×，绝对差 23.8/255。）
#
# 修法两条：
#   ① **影色随主题走**（不再纯黑）：CozyStyle 主题取该主题自己的深色调（board_mat 的
#      色相/饱和度，明度已解算过）—— 冷底得冷影、暖底得暖影，不再是脱色的灰。
#      dark / light 的底本身中性，没有专属深色调，仍用纯黑。
#   ② **α 由目标压暗量反解**，不写死：目标是**绝对**亮度差（0..255），七套主题因此
#      看起来"浮起程度"接近，而不是粉彩主题独重。
#
# ⚠️ 为什么反解 α 是可算的：Godot 2D 的 canvas 混合发生在**编码值空间**（不是线性空间）。
#    实测确认：bg `#b7c9d4` 叠纯黑 α0.10 后加权亮度 = 178.4，与 `0.9×198.0 + 0.1×0`
#    逐位吻合。故 观感亮度差 == α · (lum(bg) − lum(tint))，直接解出 α 即可。
#    （这也是为什么不能用 WCAG 的线性亮度：那套口径下"深色底最多只能掉 0.012"，
#     反解会得到 α→1 的荒谬值 —— 阴影本来就不是对比度问题，是**明度微差**问题。）

## 常态影的目标压暗量（0..255）。取值依据：改动前实测 19.6 明显过重（粉彩底上已经是
## 一圈脏灰），按"看得见、但读起来是层次而不是污渍"重定。
const SHADOW_DROP_NORMAL := 7.0
## 悬停影的目标压暗量。刻意只比常态深 1.86 倍（改动前是 2.2 倍、绝对差 23.8）——
## 「抬起一档」的提示由描边换 accent + 底色提亮 0.06 + scale 1.03 三条共同承担，
## 阴影只负责补一点点，跳变才不会被看出来。
const SHADOW_DROP_HOVER := 13.0
## 大面板（棋盘垫子）的目标压暗量。面积越大越需要多一点影才"托得住"，
## 小控件套这个值会显得脏，故单独一档。
const SHADOW_DROP_MAT := 14.0
## α 钳制范围。
##
## 上限 0.42：避免近黑主题反解出 0.7+ 那种硬边黑影（那不是柔影，是一圈黑边）。
## 下限 0.02：只要不是 0 就行，**不要**往上抬 —— 第一版取 0.05，结果只在最亮的
## `light`（底 L=243.7，反解出 α=0.029）上触发，把压暗量从 7 顶到 12.2，
## 恰好顶出契约带（4~10）被测试当场抓住。这条下限原本是想防"深底算出 0"，
## 但深底方向是 **span 小 ⇒ α 大**，撞的是上限，下限根本不该承担那个职责。
const SHADOW_ALPHA_MIN := 0.02
const SHADOW_ALPHA_MAX := 0.42


## 影色（不含 α）：CozyStyle 取该主题自己的深色调，dark/light 取纯黑。
## 【2026-09-30 三层构造】玻璃主题（棱镜）的垫板改成了**半透明白**（网页 token），
## 影色不能再取它的色相——白影落在深底上是「光」不是「影」。玻璃固定用一套
## 深蓝调（旧玻璃垫板色，非纯黑：shadow() 的近黑底收敛分支需要 tint 亮度 > 0）。
func shadow_tint() -> Color:
	if is_glass():
		return Color(0.031, 0.055, 0.118, 1.0)
	if is_cozy_family():
		var m := board_mat()
		if m.a > 0.0:
			return Color(m.r, m.g, m.b, 1.0)
	return Color(0, 0, 0)


## 直接可用的 shadow_color：目标压暗量 / 底与影的亮度跨度 ⇒ α。
##
## base = 影**落上去的那块底**（一般是 bg()；压在卡片上时传 card()）。
## drop 省略时用常态档；`ThemeManager.SHADOW_DROP_HOVER` 传进来就是悬停档。
func shadow(base: Color, drop: float = SHADOW_DROP_NORMAL) -> Color:
	var tint := shadow_tint()
	# 近黑底（如棱镜玻璃 bg L≈25）上，主题深色调与底几乎同亮（span≈11），α 顶到
	# 0.42 上限也只能压暗 ~4.7/255 —— 影等于白画，且常态/悬停被钳成同一个值，
	# 「抬起一档」的提示彻底丢失。此时把影色按比例向纯黑收敛：sdr_lum 对通道是
	# 线性的，令 span 恰好 = drop/α上限（该档位在不触上限时的最大可达跨度）；
	# 若底暗到连纯黑都凑不出（base - need < 0），k=0 落纯黑，交给 α 上限兜底。
	# 其他主题 span 富余，此分支不触发，行为零变化。
	var span := sdr_lum(base) - sdr_lum(tint)
	var need := drop / SHADOW_ALPHA_MAX
	if span < need and sdr_lum(tint) > 0.0:
		var k: float = clampf((sdr_lum(base) - need) / sdr_lum(tint), 0.0, 1.0)
		tint = Color(tint.r * k, tint.g * k, tint.b * k, 1.0)
		span = sdr_lum(base) - sdr_lum(tint)
	if span <= 1.0:
		# 底已经和影同亮（近黑主题 + 纯黑影）：反解会除爆，退回"亮度差的固定比例"。
		span = maxf(1.0, sdr_lum(base) * 0.25)
	var a := clampf(drop / span, SHADOW_ALPHA_MIN, SHADOW_ALPHA_MAX)
	return Color(tint.r, tint.g, tint.b, a)


## 影落在 base 上之后的实际观感亮度差（0..255 口径）。测试与工具用它验证
## 「七套主题的压暗量落在同一窄带」。
##
## ⚠️ 这里**手算闭式**而不是调 `Color.blend()`：
##    `Color.blend()` 的语义是「把**参数**盖在 self 上」（实现取的是参数的 α），
##    写成 `shadow(base).blend(base)` 会把底盖回影上 ⇒ 恒等于 base ⇒ 压暗量恒为 0。
##    第一版就是这么写的，测试直接报「七套主题压暗量全 0」。
##    又因为混合在编码值空间是线性的（见本节开头），闭式就是精确值，没必要再调 API。
func shadow_drop(base: Color, drop: float = SHADOW_DROP_NORMAL) -> float:
	var s := shadow(base, drop)
	return s.a * (sdr_lum(base) - sdr_lum(Color(s.r, s.g, s.b, 1.0)))


## 编码值空间的加权亮度（0..255）。**不要**拿它当 WCAG 亮度用 —— 那套是线性化的，
## 见 `_lin` / `contrast_ratio`。本函数只服务"阴影压暗了多少"这类观感量。
static func sdr_lum(c: Color) -> float:
	return 255.0 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
