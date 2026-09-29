# companion_pet.gd —— 动物伙伴「占位猫」：程序化图元 + 真机同构的 6 轨道状态机
#
# ══════════════════════════════════════════════════════════════════════════════
# 这是什么
#   棋盘右侧停靠区里的猫。骨骼层级 / 动画表 / 轨道状态机**逐项对齐**真实工程的
#   CozyCat Spine 骨架（数据见 ui/companion_rig.gd），但**形象是程序化图元画的**——
#   不用原作的任何图集/网格，规避直接复用素材的法律风险。
#
# 为什么要"占位"
#   真资源需要 Spine 4.3 编辑器重新绑骨、K 帧、出 .atlas（规格书 §5 明说了）。
#   在拿到真资源之前，先把**接口面**做扎实：
#     · 骨骼名/层级 = 真实的（换真资源时换的是数据，不是代码结构）
#     · 动画名/时长/末帧事件 = 真实的（换的是采样器，不是调度逻辑）
#     · 6 轨道 + 加权随机 + end/complete 事件 = 真实的（换资源时**一行都不用改**）
#     · 鼠标视线跟随链（FaceControl → FaceAll → Eye/Nose）= 真实的（见 CONSTRAINTS）
#   所以"后期换成别的动画"= 换 ui/companion_rig.gd 的三张表 + 把 _draw_* 换成 Spine 网格绘制。
#
# 与真实工程的三处**有意简化**（都写在对应代码处）
#   ① 关键帧用线性插值，真机是贝塞尔 —— 时长/振幅/节奏一致，缓入缓出被抹平；
#   ② 变形网格用刚性图元代替 —— 皮肤不跟着骨骼拉伸，而是整块跟着代表骨骼走（"纸偶"观感）；
#   ③ 眼睛的遮挡用「把虹膜夹进眼球椭圆内」代替真机的 clipping mask —— 视觉效果等价
#      （真机就是靠 EyeRMask 裁剪眼球，让虹膜在球内滑动）。
#
# ⚠️ 绝不用 RNGService：它是关卡生成/变体选择的**种子化流**，本工程有 golden 种回归测试
#    （tools/_golden_*.jsonl）。宠物纯装饰，每帧抽一次会打乱那条流。这里用私有 RNG。
# ══════════════════════════════════════════════════════════════════════════════
extends Control

const RIG := preload("res://ui/companion_rig.gd")

# ==================== 停靠尺寸与行为常量 ====================

## 停靠区设计宽（px）。board_view 用 PET_W + 2×PET_EDGE 计算要从棋盘让出多少宽度。
const DESIGN_W := 192.0
## 停靠留白（px）：右侧与 HUD 侧列、底部与工具栏各留这么多。
const EDGE := 12.0

## 鼠标视线跟随的收敛速度（每秒）。规格书原文：「每帧以 C3.lerp 让 Chest / FaceControl
## 缓慢跟随鼠标 X」——C3 即"每秒收敛 3 倍"，这里取同量级。
const GAZE_SPEED := 3.2
## 视线写进 FaceControl 的最大本地平移（rig 单位）。选 88 的依据：经约束链
## FaceAll(×0.3) → EyeCL/EyeCR(×0.5) 衰减后约 13 rig 单位，而眼球内可滑动的余量
## 是 (眼白半长 59 − 虹膜半长 33) ≈ 26 ⇒ 只用掉一半，眼球不会贴边。
const GAZE_TX := 88.0
## 视线写进 Chest 的最大旋转（度）。Chest 是 Head 的祖先 ⇒ 整只头跟着偏，形成"转头"。
const GAZE_CHEST_DEG := 3.4

## 外部事件触发的点击反应冷却（ms）：连点不会把 IdleClick 反复打断成抽搐。
const CLICK_COOLDOWN_MS := 900
## 一格翻开/插旗触发的反应强度下限：连续快速开格时只保留一次完整反应。
const REACT_MIN_GAP_MS := 140

## 描边宽度（rig 单位）。随停靠尺寸缩放 ⇒ 小尺寸下不会糊成黑边。
const INK_W := 5.5
## 椭圆/弧线的分段数。40 段在 192px 宽下已经看不出多边形。
const SEG := 40

## 图元绘制顺序（**照真实工程的插槽顺序**，见 companion_rig.gd::SLOTS）：
## 植物 → 尾 → 身 → 腿 → 胸 → 外耳 → 头 → 胡须 → 眼 → 嘴/鼻 → 内耳。
## 注意两处照抄来的前后关系，不是笔误：
##   ① 外耳画在头**之前**（真机 BC_Ear_R 槽位 09、Bc_Head 槽位 11）⇒ 外耳被头压住一半；
##   ② 内耳画在头**之后**（槽位 26/27）⇒ 露在外面。
## 测试会断言这张表覆盖了 PARTS 里除纯功能骨骼外的每一个键。
const DRAW_ORDER: Array = [
	# 环境植物（真机里叶链挂在 root 下，不受身体影响）
	"Leaf1_1", "Leaf1_2", "Leaf1_3", "Leaf1_4", "Leaf1_5",
	"Leaf2_1", "Leaf2_2", "Leaf2_3",
	"Leaf1_6", "Leaf1_7", "Leaf1_8", "Leaf1_9",
	# 尾巴（6 节链，画在身体后面）
	"Tail1", "Tail2", "Tail3", "Tail4", "Tail5", "Tail6",
	# 躯干 → 腿 → 胸（腿的根部要被身体压住才不露缝）
	"Body", "LegR2", "LegR5", "Chest", "HeadTail",
	# 外耳 → 头
	"EarR1", "EarL1", "Head",
	# 胡须 → 眼 → 嘴/鼻
	"BeardR1", "BeardL1",
	"EyeR", "EyeCR", "EyeCLR", "EyeL", "EyeCL", "EyeCLL",
	"Mouth2", "Mouth1", "Nose",
	# 内耳（画在头之后）
	"EarR2", "EarL2",
]

## 占位图元表：bone → 图元规格。
## **这张表就是"换真资源时整段删掉"的那部分** —— 真资源的形状来自 .atlas 图集 + 网格权重，
## 代码的其余部分（骨架求值 / 动画采样 / 状态机 / 视线链 / 停靠）一行都不用动。
##   k  : blob 椭圆 / ear 三角耳 / earin 内耳 / leg 腿 / chain 尾节 / leaf 叶 / whisker 胡须
##        / eye 眼白 / iris 虹膜 / shine 高光 / muzzle 口鼻斑 / mouth 嘴线
##   ox : 沿骨轴的圆心偏移（rig 单位）；rx 沿骨轴半长；ry 垂直骨轴半长
##   c  : 色键（ThemeManager.pet_c 的 pet_<键>）
const PARTS := {
	# ---------------- 躯干 ----------------
	# 尺寸口径 = 真机的部位贴图尺寸（BC_Body 488×428 / Bc_Head 386×262 / BC_Leg 143×243 /
	# BC_Tail 302×84 / BC_Ear 121×138），但**以骨骼长度为准摆位**（贴图本身没有位置信息，
	# 真机的位置藏在网格顶点里）。
	#
	# 躯干两块的分工（2026-09-29 按截图逐轮校准，两处都是"看起来不对"才改的）：
	#   Body  —— **主体块**，必须从地面一路长到下巴。骨架给的位置是：Body 骨在 root y=15、
	#            Chest 骨 422、Head 骨 696.4，而头块（ox 270）的下沿在 766。
	#            所以 Body 的 ox+rx 必须够到 ~800，否则中间会露出一整圈背景（第二版就是
	#            "头和身子断开"，第三版把 Chest 拉长去补，结果得到一根"台灯颈"）。
	#   Chest —— **肩/遮盖块**，只负责盖住腿根（它画在 LegR2/LegR5 之后）。压在 Body 里面，
	#            所以不需要描边也不需要够到头部。
	"Body": {"k": "blob", "ox": 400.0, "rx": 400.0, "ry": 285.0, "c": "fur"},
	# ⚠️ Chest / HeadTail **不描边**（ink=false）。躯干是几块同色椭圆叠出来的：若各自描边，
	# 描边会在重叠区互相压出一道横跨身体的深色弧（第一版截图里那道"颈缝"）。改成
	# Body = 填充 + 描边、Chest/HeadTail = 只填充，后画的填充正好把 Body 描边在重叠区**盖掉**
	# ⇒ 剩下的描边就是躯干并集的外轮廓。不需要算并集，靠绘制顺序即可。
	"Chest": {"k": "blob", "ox": 108.0, "rx": 170.0, "ry": 170.0, "c": "fur", "ink": false},
	"Head": {"k": "blob", "ox": 270.0, "rx": 200.0, "ry": 190.0, "c": "fur"},
	"HeadTail": {"k": "blob", "ox": 0.0, "rx": 62.0, "ry": 62.0, "c": "fur", "ink": false},
	# ---------------- 面部 ----------------
	"Nose": {"k": "muzzle"},
	"Mouth1": {"k": "mouth", "r": 30.0, "w": 30.0},
	"Mouth2": {"k": "mouth", "r": 12.0, "w": 34.0},
	# ox 内收 150：真机的胡须骨骼位于头轮廓**之外**（Head 局部 y=∓330，而头贴图半宽只有 193），
	# 靠网格顶点把胡须拉回嘴边。占位图元没有网格，直接按 ox 把起点收回到嘴边。
	"BeardR1": {"k": "whisker", "len": 200.0, "ox": -150.0},
	"BeardL1": {"k": "whisker", "len": 200.0, "ox": -150.0},
	# ---------------- 眼 ----------------
	# 虹膜取 44×42（眼白 59×55）：留一圈 ~15 单位的浅色眼白。占位阶段最容易画错成
	# "白底 + 小黑点"（= 一副眼镜）；让深色虹膜占满大部分眼球才读得出是猫眼。
	"EyeR": {"k": "eye", "rx": 59.0, "ry": 55.0},
	"EyeL": {"k": "eye", "rx": 59.0, "ry": 55.0},
	"EyeCR": {"k": "iris", "rx": 47.0, "ry": 44.0},
	"EyeCL": {"k": "iris", "rx": 47.0, "ry": 44.0},
	# ox/oy 是 **rig 空间**偏移（见 _draw_shine）：两眼一致的光源方向，左上。
	"EyeCLR": {"k": "shine", "r": 11.0, "ox": -13.0, "oy": 15.0},
	"EyeCLL": {"k": "shine", "r": 11.0, "ox": -13.0, "oy": 15.0},
	# ---------------- 耳（外耳在头后、内耳在头前） ----------------
	# ⚠️ EarR2/EarL2 在真机里**没有 l 字段**（bone 只有 {"x": 200}），且 origin 落在
	# **外耳的尖端**上 —— 真机靠内耳网格的顶点把它拉回耳内。占位阶段没有网格顶点，
	# 于是在 _draw_ear 里改成「用**外耳的变换** + 沿骨轴内收 inset」画一个缩小的同形，
	# 做的是同一件事。（第一版直接用自己的 k 画，结果内耳退化成一个戳在头顶的小尖刺。）
	"EarR1": {"k": "ear", "f": 0.92, "w": 60.0},
	"EarL1": {"k": "ear", "f": 0.92, "w": 60.0},
	"EarR2": {"k": "earin", "f": 0.58, "w": 34.0, "inset": 0.42},
	"EarL2": {"k": "earin", "f": 0.58, "w": 34.0, "inset": 0.42},
	# ---------------- 腿（rx 取到爪落地的长度） ----------------
	"LegR2": {"k": "leg", "rx": 176.0, "ry": 56.0},
	"LegR5": {"k": "leg", "rx": 176.0, "ry": 56.0},
	# ---------------- 尾（半径按 84/2 = 42 起步，逐节收细） ----------------
	"Tail1": {"k": "chain", "r": 45.0},
	"Tail2": {"k": "chain", "r": 42.0},
	"Tail3": {"k": "chain", "r": 39.0},
	"Tail4": {"k": "chain", "r": 35.0},
	"Tail5": {"k": "chain", "r": 31.0},
	"Tail6": {"k": "chain", "r": 27.0},
	# ---------------- 环境植物 ----------------
	# 真机的叶簇是「窄长草叶」（BC_Plant_Leaf01 174×395），故宽度取窄、两色交替制造层次。
	"Leaf1_1": {"k": "leaf", "w": 52.0, "c": "leaf"},
	"Leaf1_2": {"k": "leaf", "w": 42.0, "c": "leaf_2"},
	"Leaf1_3": {"k": "leaf", "w": 38.0, "c": "leaf"},
	"Leaf1_4": {"k": "leaf", "w": 36.0, "c": "leaf_2"},
	"Leaf1_5": {"k": "leaf", "w": 33.0, "c": "leaf"},
	"Leaf2_1": {"k": "leaf", "w": 44.0, "c": "leaf_2"},
	"Leaf2_2": {"k": "leaf", "w": 37.0, "c": "leaf"},
	"Leaf2_3": {"k": "leaf", "w": 35.0, "c": "leaf_2"},
	"Leaf1_6": {"k": "leaf", "w": 46.0, "c": "leaf"},
	"Leaf1_7": {"k": "leaf", "w": 35.0, "c": "leaf_2"},
	"Leaf1_8": {"k": "leaf", "w": 33.0, "c": "leaf"},
	"Leaf1_9": {"k": "leaf", "w": 34.0, "c": "leaf_2"},
}

## 描边宽度（px，按停靠尺寸等比缩放）。
const INK_PX := 2.0

# ==================== 骨骼运行时 ====================

var _n := 0
var _parent := PackedInt32Array()
var _bx := PackedFloat32Array()      ## 局部 rest 平移 x
var _by := PackedFloat32Array()      ## 局部 rest 平移 y
var _br := PackedFloat32Array()      ## 局部 rest 旋转（弧度）
var _bs := PackedVector2Array()      ## 局部 rest 缩放
var _bl := PackedFloat32Array()      ## 骨骼长度（绘制参考）
var _names := PackedStringArray()
var _idx := {}                       ## 骨骼名 → 下标
var _local: Array[Transform2D] = []
var _world: Array[Transform2D] = []

## 本帧的**局部增量**（动画 + 视线 + 约束都往这里写；最终 local = rest ⊕ off）
var _off_p := PackedVector2Array()
var _off_r := PackedFloat32Array()
var _off_s := PackedVector2Array()

## 动画预编译表：动画名 → Array[{i: 骨骼下标, ch: 通道名, t: 关键帧时间, v: 关键帧值}]
var _anim_cache := {}

# ==================== 状态机 ====================

var _track_anim := PackedStringArray()
var _track_t := PackedFloat32Array()

## 私有 RNG（绝不用 RNGService，理由见文件头）
var _rng := RandomNumberGenerator.new()
## 测试可注入固定种子；负数 = 随机种子
var rng_seed: int = -1:
	set(v):
		rng_seed = v
		if v >= 0:
			_rng.seed = v

## 视线当前值（-1..1，0 = 居中）与目标值
var _gaze := 0.0
var _gaze_target := 0.0
## 视线链的两根源骨下标（-1 = 本骨架里没有，该支路跳过）。
## 在 _build_skeleton() 里按 RIG.GAZE_ROT_BONES / GAZE_TX_BONES 解析一次 —— 见 _apply_gaze。
var _gaze_rot_i := -1
var _gaze_tx_i := -1
## 鼠标位置（控件本地坐标）
var _pointer := Vector2.ZERO

var _click_until_ms := -100000
var _react_last_ms := -100000

## 主题色解析器：默认走 ThemeManager；测试可替换成纯函数（headless 下不依赖 autoload）。
var color_of: Callable = Callable()

## 是否冻结动画（暂停菜单弹出时用；仍会重绘）
var frozen := false


func _ready() -> void:
	# 伙伴是**纯装饰**：不吃任何输入。点它由 board_view 用 hit_test 命中后转发 ——
	# 这样矩形控件的空白角落不会吞掉棋盘的点击（MOUSE_FILTER_IGNORE 直接放行）。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("themed")
	_build_skeleton()
	_precompile_anims()
	if color_of.is_null():
		color_of = func(k: String) -> Color: return ThemeManager.pet_c(k)
	if rng_seed < 0:
		_rng.randomize()
	else:
		_rng.seed = rng_seed
	_startup_tracks()
	ThemeManager.theme_changed.connect(queue_redraw)
	set_process(true)



## 骨架建立：一次性。
## 只走一遍正向遍历即可（真实工程保证"父必在子之前"），不需要拓扑排序。
func _build_skeleton() -> void:
	_n = RIG.BONES.size()
	_parent.resize(_n)
	_bx.resize(_n); _by.resize(_n); _br.resize(_n)
	_bs.resize(_n); _bl.resize(_n)
	_names.resize(_n)
	_local.resize(_n); _world.resize(_n)
	_off_p.resize(_n); _off_r.resize(_n); _off_s.resize(_n)
	for i in _n:
		var b: Dictionary = RIG.BONES[i]
		# ⚠️ 必须用**下标赋值**而不是 append：上面已经把 _names resize 到 _n，
		# append 会把数组撑成 2n、前 n 个全是空串，于是所有 _names[i] 查表都拿到 ""。
		_names[i] = str(b["n"])
		_idx[str(b["n"])] = i
		var p := -1
		if str(b["p"]) != "":
			p = int(_idx[str(b["p"])])
			# 父必须已经出现过 —— 真实工程的数组顺序保证这一点；破坏了就是数据坏了，
			# 与其在后面用错误的变换画一整帧，不如当场报错。
			assert(p < i, "companion_rig.BONES 顺序被破坏：%s 的父 %s 排在其后" % [b["n"], b["p"]])
		_parent[i] = p
		_bx[i] = float(b.get("x", 0.0))
		_by[i] = float(b.get("y", 0.0))
		_br[i] = deg_to_rad(float(b.get("r", 0.0)))
		var s: Variant = b.get("s", null)
		_bs[i] = Vector2(float(s[0]), float(s[1])) if s is Array else Vector2.ONE
		_bl[i] = float(b.get("l", 0.0))
	# 视线链的两根源骨：**按候选表解析一次**（换动物时名字会变，见 _apply_gaze 的说明）
	_gaze_rot_i = _pick_bone(RIG.GAZE_ROT_BONES)
	_gaze_tx_i = _pick_bone(RIG.GAZE_TX_BONES)


## 候选表里第一根**本骨架确实存在**的骨骼下标（都没有 -> -1）。
func _pick_bone(cands: Array) -> int:
	for n in cands:
		if _idx.has(str(n)):
			return int(_idx[str(n)])
	return -1


## 动画预编译：把 RIG.ANIMS 的嵌套字典摊平成"骨骼下标 + PackedFloat32Array"，
## 免得每帧在几百个通道里做字典查找 + Array 拆包。
func _precompile_anims() -> void:
	for name in RIG.ANIMS.keys():
		var a: Dictionary = RIG.ANIMS[name]
		var chans: Array = []
		var bones: Dictionary = a.get("bones", {})
		for bn in bones.keys():
			if not _idx.has(bn):
				continue      # 动画引用了本骨架没有的骨骼 → 跳过（换资源时常见，静默忽略最稳）
			var i := int(_idx[bn])
			for ch in (bones[bn] as Dictionary).keys():
				var pairs: Array = bones[bn][ch]
				var ts := PackedFloat32Array(); ts.resize(pairs.size())
				var vs := PackedFloat32Array(); vs.resize(pairs.size())
				for k in pairs.size():
					ts[k] = float((pairs[k] as Array)[0])
					vs[k] = float((pairs[k] as Array)[1])
				chans.append({"i": i, "ch": str(ch), "t": ts, "v": vs})
		_anim_cache[name] = chans


## 启动姿态：照规格书的加权随机表为每条轨道各抽一段开场动画。
## 点击轨道（track 5）留空 —— 它只在被点/被操作时才播。
func _startup_tracks() -> void:
	_track_anim.resize(RIG.TRACKS.size())
	_track_t.resize(RIG.TRACKS.size())
	for ti in RIG.TRACKS.size():
		var tr: Dictionary = RIG.TRACKS[ti]
		if str(tr.get("id", "")) == "click":
			_track_anim[ti] = ""
			_track_t[ti] = 0.0
			continue
		_set_track(ti, RIG.pick_weighted(tr["anims"], _rand1000()))


func _set_track(ti: int, name: String) -> void:
	_track_anim[ti] = name
	_track_t[ti] = 0.0


func _rand1000() -> int:
	return _rng.randi_range(0, 999)


# ==================== 每帧 ====================

func _process(delta: float) -> void:
	if frozen:
		return
	_advance_tracks(delta)
	_update_gaze(delta)
	_pose()
	queue_redraw()


## 6 轨道推进。语义逐条对齐规格书 §0：
##   loop=true  → 播到时长末帧即回绕，并在回绕点触发事件（idle / tail / plants）
##   loop=false 且有事件 → 播到末帧触发事件后立刻换下一段（ear / eye）
##   loop=false 且无事件 → 一次性，播完**清空**（click）
##   loop=true  且无事件 → 永不切换（plants）
func _advance_tracks(dt: float) -> void:
	for ti in RIG.TRACKS.size():
		var tr: Dictionary = RIG.TRACKS[ti]
		var an := _track_anim[ti]
		if an == "":
			continue
		var d: float = RIG.anim_duration(an)
		if d <= 0.0:
			_set_track(ti, "")
			continue
		_track_t[ti] += dt
		if _track_t[ti] < d:
			continue
		var want := str(tr.get("on", ""))
		if bool(tr.get("loop", false)):
			_track_t[ti] = fmod(_track_t[ti], d)
			if want != "":
				_fire(want, tr, ti, an)
		elif want != "":
			_track_t[ti] = d          # 停在末帧（姿态 = 归位）直到选出下一段
			_fire(want, tr, ti, an)
		else:
			_set_track(ti, "")        # 点击反应：播完清空


## 末帧事件。`want` 是规格书原样声明的依赖事件名（end / complete）。
##
## ⚠️ 反查修正：规格书写「尾巴用 complete 事件」，但真实工程的 events 段只定义了 **end** 一个
##    事件，且 Tail1/Tail2 的末帧事件也是 end（t=3.0，见 _pv/cat_anim_probe.txt 的汇总表）。
##    严格按 complete 判定的话尾巴会永久停摆。故这里把 "complete" 当成 end 的同义写法：
##    判定实际以「动画到达末帧」为准，事件名只作声明与自检。
func _fire(want: String, tr: Dictionary, ti: int, an: String) -> void:
	if want != "end" and want != "complete":
		return      # 未声明依赖事件的轨道（plants）不切换
	var next: String = RIG.pick_weighted(tr["anims"], _rand1000())
	if next == "":
		return      # 权重表异常时宁可留在原动画，也绝不切到空
	_set_track(ti, next)


## 鼠标视线：目标值 = 鼠标相对控件中心的横向偏移（归一化到 -1..1，带死区）。
## 这里读的是**屏幕鼠标**而不是"悬停在伙伴上"，所以鼠标在棋盘上移动时猫也会看过去 ——
## 规格书说的就是"跟随鼠标 X"，不是"被悬停时才看"。
func _update_gaze(delta: float) -> void:
	_pointer = get_local_mouse_position()
	var half: float = maxf(size.x * 0.5, 1.0)
	var t: float = clampf((_pointer.x - size.x * 0.5) / half, -1.0, 1.0)
	# 死区：正中央 ±12% 视为"看正前方"，避免鼠标微动就让眼睛抖
	if absf(t) < 0.12:
		t = 0.0
	else:
		t = signf(t) * (absf(t) - 0.12) / 0.88
	_gaze_target = clampf(t, -1.0, 1.0)
	# C3.lerp：帧率无关的指数收敛（用 1-exp(-k·dt) 而不是 k·dt 直乘，
	# 后者在低帧率下会过冲、在 30fps 与 144fps 上手感不同）
	_gaze = lerpf(_gaze, _gaze_target, 1.0 - exp(-GAZE_SPEED * delta))


## 姿态求值：清增量 → 动画 → 视线 → 约束 → 组世界变换。
func _pose() -> void:
	for i in _n:
		_off_p[i] = Vector2.ZERO
		_off_r[i] = 0.0
		_off_s[i] = Vector2.ONE
	for ti in RIG.TRACKS.size():
		var an := _track_anim[ti]
		if an == "":
			continue
		_apply_anim(an, _track_t[ti])
	_apply_gaze()
	_apply_constraints()
	_compose()


## 采样一段动画的全部通道并**累加**进增量表（多轨道叠加 = Spine 的多 track 行为）。
func _apply_anim(name: String, t: float) -> void:
	var chans: Array = _anim_cache.get(name, [])
	for c in chans:
		var v := _sample(c, t)
		var i := int(c["i"])
		var ch := str(c["ch"])
		match ch:
			"rot": _off_r[i] += deg_to_rad(v)
			"tx": _off_p[i].x += v
			"ty": _off_p[i].y += v
			"sx": _off_s[i].x *= v
			"sy": _off_s[i].y *= v
			"shx", "shy": pass   # 切变只在真实工程里的耳朵上有（幅度 5°），占位阶段并入旋转即可


## 相邻关键帧线性插值（真实工程是贝塞尔；本文件头已声明这是有意简化）。
## 关键帧数 ≤ 30，直接线性扫描比建索引更快也更好读。
func _sample(c: Dictionary, t: float) -> float:
	var ts: PackedFloat32Array = c["t"]
	var vs: PackedFloat32Array = c["v"]
	if ts.size() == 0:
		return 0.0
	if t <= ts[0]:
		return vs[0]
	if t >= ts[ts.size() - 1]:
		return vs[vs.size() - 1]
	for k in ts.size() - 1:
		if t <= ts[k + 1]:
			var span: float = ts[k + 1] - ts[k]
			if span <= 0.0:
				return vs[k + 1]
			var f: float = (t - ts[k]) / span
			return lerpf(vs[k], vs[k + 1], f)
	return vs[vs.size() - 1]


## 视线：写 Chest 的旋转 + FaceControl 的平移（规格书 §0 那句 C3.lerp 的落点）。
## 为什么写这两处就够：CONSTRAINTS 里 FaceControl → FaceAll(0.3) → EyeL/EyeR(0.5) → Nose(0.75)
## 是一条**已经存在**的传导链，写源头即可；Chest 在 Head 的祖先链上，写它就等于"转头"。
## 视线链求值：把 gaze 的**旋转**写进 GAZE_ROT_BONES 里第一根存在的骨、**平移**写进
## GAZE_TX_BONES 里第一根存在的骨，再由 CONSTRAINTS 级联到 FaceAll/EyeL/EyeR/Nose。
##
## ⚠️ 这两个下标**不能写死骨骼名**：不同动物的命名不同（黑猫有专门的 FaceControl，
## 规格书里的小老虎/小黑熊只有 FaceAll）。写死的话换骨架后平移支路静默失效 ——
## 不报错、不崩溃，只是"眼睛几乎不跟着鼠标动了"（实测 −93%，见 companion_rig.gd 的说明）。
## 下标在 _build_skeleton() 里解析一次并缓存；取不到就是 -1，该支路跳过。
func _apply_gaze() -> void:
	if _gaze_rot_i >= 0:
		_off_r[_gaze_rot_i] += deg_to_rad(_gaze * GAZE_CHEST_DEG)
	if _gaze_tx_i >= 0:
		_off_p[_gaze_tx_i] += Vector2(_gaze * GAZE_TX, 0.0)


## 约束求值：把源骨骼本帧的**局部增量**按 mixX/mixY 加权叠加到目标骨骼上。
## CONSTRAINTS 的顺序保证"源排在目标之前"（测试里有断言），故一遍正向遍历即可 ——
## FaceAll 叠加完 FaceControl 的增量后，EyeL/EyeR 再叠加 FaceAll 的**累计**增量，
## 于是眼睛拿到的偏移 = 0.3 × 0.5 = 15% 的头转量，与真实工程的级联效果一致。
func _apply_constraints() -> void:
	for c in RIG.CONSTRAINTS:
		var src := str(c["src"])
		if not _idx.has(src):
			continue
		var si := int(_idx[src])
		var mx := float(c.get("mx", 1.0))
		var my := float(c.get("my", c.get("mx", 1.0)))
		for bn in (c["b"] as Array):
			if not _idx.has(bn):
				continue
			var di := int(_idx[str(bn)])
			_off_p[di] += Vector2(_off_p[si].x * mx, _off_p[si].y * my)
			_off_r[di] += _off_r[si] * mx


## 组变换：local = rest ⊕ off（先缩放→再旋转→再平移，与 Spine 的骨骼局部变换同序），
## world = parent.world × local。
func _compose() -> void:
	for i in _n:
		var sc := Vector2(_bs[i].x * _off_s[i].x, _bs[i].y * _off_s[i].y)
		var ang := _br[i] + _off_r[i]
		var pos := Vector2(_bx[i], _by[i]) + _off_p[i]
		_local[i] = Transform2D(ang, sc, 0.0, pos)
		var p := _parent[i]
		_world[i] = _local[i] if p < 0 else (_world[p] * _local[i])


# ==================== 对外接口 ====================

## 由棋盘把「翻开了一格 / 插了一面旗」转发进来。
## 对应真实工程的 track 5（点击反应 IdleClick）：一次性、播完清空。
func react(strength: float = 1.0) -> void:
	_react_impl(strength)


func trigger_click() -> void:
	_react_impl(1.0)


func _react_impl(strength: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _react_last_ms < REACT_MIN_GAP_MS:
		return
	_react_last_ms = now
	if now - _click_until_ms < CLICK_COOLDOWN_MS:
		return
	var ti := RIG.track_index("click")
	if ti < 0:
		return
	var tr: Dictionary = RIG.TRACKS[ti]
	var pick: String = RIG.pick_weighted(tr["anims"], _rand1000())
	if pick == "":
		return
	_set_track(ti, pick)
	_click_until_ms = now


## 命中测试：只在**猫的轮廓**内算命中，矩形停靠区的空白角落一律放行给棋盘。
##
## 口径与 `_draw_part` 一一对应（同一张 PARTS 表、同一套 _world 变换）。为什么不用几个
## 硬编码椭圆：那种写法会在"改了比例 / 换了姿势 / 换了动画"之后悄悄失准，而且**不会报错**
## —— 只是某天发现猫的耳朵点不动。这里多花三十行，换命中区永远跟着画出来的形状走。
##
## 环境植物（Leaf*）不计入：它们是布景，点草不该触发猫的反应。
func hit_test(global_pos: Vector2) -> bool:
	if not is_inside_tree() or size.x <= 0.0 or _n == 0:
		return false
	var q: Vector2 = _screen_xf().affine_inverse() * (global_pos - global_position)
	for bn in DRAW_ORDER:
		var key := str(bn)
		if key.begins_with("Leaf"):
			continue
		if not _idx.has(key) or not PARTS.has(key):
			continue
		if _touch(int(_idx[key]), PARTS[key], q):
			return true
	return false


## 单个图元的命中：所有形状一律化成「该骨骼局部空间里的一个椭圆」来判 ——
## 圆角三角（耳）/ 水滴（叶）/ 胶囊（腿、尾节）都用外接椭圆近似，误差只出现在形状的
## 凹角处，而那里点不中不会有观感问题（真机也是矩形包围盒命中，没比这更严）。
func _touch(i: int, spec: Dictionary, q: Vector2) -> bool:
	var l: Vector2 = _world[i].affine_inverse() * q
	match str(spec["k"]):
		"blob", "muzzle":
			return _in_ellipse(l, Vector2(float(spec.get("ox", 0.0)), 0.0),
					Vector2(float(spec.get("rx", 0.0)), float(spec.get("ry", 0.0))))
		"eye", "iris":
			return _in_ellipse(l, Vector2.ZERO, Vector2(float(spec["rx"]), float(spec["ry"])))
		"shine":
			var sr := float(spec["r"])
			return _in_ellipse(l, Vector2.ZERO, Vector2(sr, sr))
		"ear", "earin":
			var el := maxf(_bl[i], 1.0) * float(spec.get("f", 0.9))
			return _in_ellipse(l, Vector2(el * 0.45, 0.0), Vector2(el * 0.60, float(spec["w"])))
		"leaf":
			var ll := maxf(_bl[i], 1.0) * 1.15
			return _in_ellipse(l, Vector2(ll * 0.5, 0.0), Vector2(ll * 0.55, float(spec["w"])))
		"leg":
			var lrx := float(spec["rx"])
			return _in_ellipse(l, Vector2(lrx * 0.5, 0.0),
					Vector2(lrx * 0.55, float(spec["ry"]) * 0.95))
		"chain":
			var cr := float(spec["r"])
			var nxt := _next_bone(i)
			var to := Vector2(cr * 2.0, 0.0)
			if nxt >= 0:
				to = _in_local(i, _world[nxt].origin)
			return _in_ellipse(l, to * 0.5, Vector2(maxf(to.length() * 0.55, 1.0), cr))
		"whisker":
			var wl := float(spec["len"])
			return _in_ellipse(l, Vector2(float(spec.get("ox", 0.0)) + wl * 0.5, 0.0),
					Vector2(wl * 0.55, 34.0))
		"mouth":
			return _in_ellipse(l, Vector2(0.0, -18.0), Vector2(float(spec["w"]) * 1.1, 30.0))
	return false


static func _in_ellipse(u: Vector2, c: Vector2, r: Vector2) -> bool:
	var dx: float = (u.x - c.x) / maxf(r.x, 0.0001)
	var dy: float = (u.y - c.y) / maxf(r.y, 0.0001)
	return dx * dx + dy * dy <= 1.0


## 当前每条轨道的状态（调试 / 测试 / 截图自检用）。
func track_state() -> Array:
	var out: Array = []
	for ti in RIG.TRACKS.size():
		var tr: Dictionary = RIG.TRACKS[ti]
		out.append({
			"id": str(tr["id"]),
			"anim": _track_anim[ti],
			"t": _track_t[ti],
			"dur": RIG.anim_duration(_track_anim[ti]),
			"loop": bool(tr.get("loop", false)),
		})
	return out


## 一帧的骨骼世界变换（Spine 空间）。测试用它钉住"层级确实生效"。
func bone_world(name: String) -> Transform2D:
	if not _idx.has(name):
		return Transform2D()
	return _world[int(_idx[name])]


## 测试缝：把全部增量清零并重组变换 ⇒ 得到**纯净的 rest 姿态**。
##
## 为什么必须有这个入口：hit_test / bone_world 的正确性只能在"姿态已知"的前提下断言，
## 而伙伴每帧都在按开机时间采样动画、按鼠标位置算视线 —— 不冻结姿态的话，同一段断言会
## 随鼠标停在哪儿而间歇性变红（测试自己的抖动源）。这里复用 _pose() 的清理口径，
## 而不是让测试去手搓一份"只清一半"的副本。
func _clear_all_offsets_for_test() -> void:
	for i in _n:
		_off_p[i] = Vector2.ZERO
		_off_r[i] = 0.0
		_off_s[i] = Vector2.ONE
	_gaze = 0.0
	_gaze_target = 0.0
	_compose()


# ==================== 绘制：程序化图元 ====================
#
# 坐标系：先算 rig 空间（Spine，y 向上）的变换，最后乘一个"翻到屏幕"的仿射（见 _screen_xf）：
#   F 的 x 轴 = (sc, 0)、y 轴 = (0, -sc)，sc = min(控件宽/bbox.w, 控件高/bbox.h)，
#   原点把 bbox 中心放到控件中心。
# 于是**所有图元都在 rig 单位下描述**（与骨骼长度同尺度，好核对），y 翻转只发生一次。
# 这么做避开了"角度要取反、左右要镜像"那一类到处漏改的坑 —— 翻转作用在**点**上，
# 旋转/缩放/切变全部自动跟着翻对。
# 注意 sc 是**等比**的：父容器给的比例不对时只会留白，不会把猫拉扁。


func _draw() -> void:
	if _n == 0 or size.x <= 0.0:
		return
	var sc := _screen_xf()
	var col := {}      # 本帧色缓存：避免每个图元都过一次 Callable
	_draw_shadow(sc, col)
	for bn in DRAW_ORDER:
		if not _idx.has(bn) or not PARTS.has(bn):
			continue
		_draw_part(sc, int(_idx[bn]), PARTS[bn], col)


## 停靠区**设计**尺寸：宽 DESIGN_W、高由骨架 bbox 的长宽比决定。
## board_view 用它来预留空间；尺寸比例一旦不符，猫会被拉扁 —— 所以这里给出唯一口径，
## 并且 _screen_xf 还会再兜一层（见下）。
static func design_size() -> Vector2:
	var w := maxf(float(RIG.SKELETON["w"]), 1.0)
	var h := maxf(float(RIG.SKELETON["h"]), 1.0)
	return Vector2(DESIGN_W, DESIGN_W * h / w)


## rig 空间 → 控件像素空间。
##
## 缩放取 min(w 向, h 向)：父容器给的比例若与骨架 bbox 不符（不同关卡/不同窗口尺寸下
## 难免），猫只会**留白**而不会被拉变形。原点取控件中心 —— 于是"停靠区变大变小"只是
## 整体缩放，构图不漂。bbox 长宽比 1.2845 时两条路等价，等价性有测试守着。
func _screen_xf() -> Transform2D:
	var w: float = maxf(float(RIG.SKELETON["w"]), 1.0)
	var h: float = maxf(float(RIG.SKELETON["h"]), 1.0)
	var sc: float = minf(size.x / w, size.y / h)
	var x0 := float(RIG.SKELETON["x"])
	var y0 := float(RIG.SKELETON["y"])
	# 目标：rig 空间里 bbox 的中心 → 控件中心；且 y 轴翻向（Spine y 向上，屏幕 y 向下）。
	var tx: float = size.x * 0.5 - sc * (x0 + w * 0.5)
	var ty: float = size.y * 0.5 + sc * (y0 + h * 0.5)
	return Transform2D(Vector2(sc, 0.0), Vector2(0.0, -sc), Vector2(tx, ty))


## 描边宽度（px）：随停靠尺寸等比，小尺寸下不会糊成一块黑边。
func _ink_w() -> float:
	return INK_PX * size.x / DESIGN_W


func _c(col: Dictionary, key: String) -> Color:
	if not col.has(key):
		col[key] = color_of.call(key)
	return col[key]


func _draw_part(sc: Transform2D, i: int, spec: Dictionary, col: Dictionary) -> void:
	var xf: Transform2D = sc * _world[i]
	match str(spec["k"]):
		"blob":
			var blob := _ellipse(Vector2(float(spec.get("ox", 0.0)), 0.0),
					float(spec["rx"]), float(spec["ry"]), xf)
			# ink=false 的躯干块（Chest / HeadTail）：只填充，把先画的 Body 描边在重叠区盖掉，
			# 于是三块同色椭圆读成一整块 —— 理由见 PARTS 里 Chest 上方的注释。
			if bool(spec.get("ink", true)):
				_draw_filled(blob, _c(col, str(spec["c"])), _c(col, "ink"), _ink_w())
			else:
				_draw_filled(blob, _c(col, str(spec["c"])))
		"leg", "chain":
			_draw_limb(sc, xf, i, spec, col)
		"ear", "earin":
			_draw_ear(sc, i, spec, col)
		"leaf":
			_draw_leaf(xf, i, spec, col)
		"whisker":
			_draw_whisker(xf, spec, col)
		"eye":
			# 眼白只用 0.7 倍描边：192px 停靠宽下整只眼才 ~14px，2.0px 的黑圈会占掉直径的
			# 14%，戴眼镜观感（第一版实测）。其余图元仍用满宽。
			_draw_filled(_ellipse(Vector2.ZERO, float(spec["rx"]), float(spec["ry"]), xf),
					_c(col, "eye"), _c(col, "ink"), _ink_w() * 0.7)
		"iris":
			_draw_iris(sc, i, spec, col)
		"shine":
			_draw_shine(sc, i, spec, col)
		"muzzle":
			_draw_muzzle(xf, col)
		"mouth":
			_draw_mouth(xf, spec, col)
		_:
			pass


## 椭圆 → 屏幕多边形。off 在局部 rig 空间，xf 是该骨骼的 rig→屏幕变换。
func _ellipse(off: Vector2, rx: float, ry: float, xf: Transform2D) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(SEG)
	for k in SEG:
		var a: float = TAU * float(k) / float(SEG)
		out[k] = xf * (off + Vector2(cos(a) * rx, sin(a) * ry))
	return out


## 填充 + 描边。描边走 draw_polyline 的 antialiased 档（给多边形本身加边不会有 AA）。
func _draw_filled(pts: PackedVector2Array, fill: Color,
		ink: Color = Color(0, 0, 0, 0), w: float = 0.0) -> void:
	if pts.size() < 3:
		return
	draw_colored_polygon(pts, fill)
	if ink.a > 0.0 and w > 0.0:
		var loop := pts.duplicate()
		loop.append(pts[0])
		draw_polyline(loop, ink, w, true)


# ---------------- 分图元 ----------------

## 尾节 / 腿。
## 尾（chain）：**整条链一次成笔**（见 _draw_chain；逐节画会变成一串珠子）。
## 腿（leg）：沿 LegR2 的骨轴一根圆柱 + 末端一个爪圆 —— 真机的腿是 143×243 的皮肤网格，
##           这里用"柱 + 爪"两段近似；LegR1 完全落在身体blob内，故不单独绘制。
func _draw_limb(sc: Transform2D, xf: Transform2D, i: int, spec: Dictionary, col: Dictionary) -> void:
	var ink := _c(col, "ink")
	if str(spec["k"]) == "chain":
		# 只在链根出笔；其余节按 PARTS 留着是为了比例数据与命中测试（见 _chain_points）。
		if _is_chain_root(i):
			_draw_chain(sc, i, col)
		return
	var rx := float(spec["rx"])
	var ry := float(spec["ry"])
	_draw_filled(_capsule(xf, Vector2(-ry * 0.30, 0.0), Vector2(rx, 0.0), ry * 0.92, ry * 0.80),
			_c(col, "fur"), ink, _ink_w() * 0.85)
	# 爪：末端一个横向椭圆 + 一道趾缝
	var paw := Vector2(rx - ry * 0.34, 0.0)
	_draw_filled(_ellipse(paw, ry * 0.80, ry * 0.64, xf), _c(col, "fur_2"), ink, _ink_w() * 0.7)
	draw_polyline(PackedVector2Array([
		xf * Vector2(paw.x + ry * 0.05, 0.0),
		xf * Vector2(paw.x + ry * 0.52, 0.0)]), ink, _ink_w() * 0.7, true)


## 是否尾链的**根**（父骨骼不属于本链）。只有根负责整条链的绘制。
func _is_chain_root(i: int) -> bool:
	var p := _parent[i]
	if p < 0:
		return true
	var pn := _names[p]
	if not PARTS.has(pn):
		return true
	return str((PARTS[pn] as Dictionary).get("k", "")) != "chain"


## 沿「第一个子骨骼」往下收齐整条链的（rig 空间位置, 半径）。末尾补一个**尖端**点：
## 真机的尾末节长 100（BC_Tail 是一整条锥形网格），只连到末节起点会留下一个平头断口。
## guard 是防数据出环：链式跟随一旦被写成环会死循环，而这是"换资源时导入错表"最可能的形态。
func _chain_points(i: int) -> Array:
	var pts: Array = []
	var cur := i
	var guard := 0
	while cur >= 0 and guard < 32:
		var nm := _names[cur]
		if not PARTS.has(nm):
			break
		var spec: Dictionary = PARTS[nm]
		if str(spec.get("k", "")) != "chain":
			break
		pts.append({"p": _world[cur].origin, "r": float(spec.get("r", 20.0))})
		cur = _next_bone(cur)
		guard += 1
	if pts.is_empty():
		return pts
	# 尖端：从末节起点沿末节骨轴再走一个骨长，半径收到 30%。
	# ⚠️ 链末节常常**没有 l 字段**（Tail6 只有 {"x": 110.26}），直接拿它会退化成 1 单位，
	# 尾巴就断成一个平头。末节无 l 时回退到父节的骨长。
	var last := -1
	cur = i
	guard = 0
	while cur >= 0 and guard < 32:
		last = cur
		cur = _next_bone(cur)
		guard += 1
	var tl: float = _bl[last]
	if tl <= 0.0 and _parent[last] >= 0:
		tl = _bl[_parent[last]]
	var tip_r: float = float((pts[pts.size() - 1] as Dictionary)["r"]) * 0.30
	pts.append({"p": _world[last] * Vector2(maxf(tl, 40.0), 0.0), "r": tip_r})
	return pts


## 尾：把整条链画成**一条锥形缎带** —— 拼接全部节点的骨架线，两侧各偏移半径，
## 然后**一次填充 + 一圈描边**。
##
## 为什么不能逐节画胶囊：每支胶囊自带一圈描边，相邻两节的描边在重叠区互相压出来，
## 整条尾巴变成"一串珠子"（第一版就是，截图里一眼假）。改成一次成笔后重叠区只剩一次
## 描边。法线取「前一点→后一点」的方向（而不是相邻两点），拐弯处才不会出现折角缺口。
func _draw_chain(sc: Transform2D, i: int, col: Dictionary) -> void:
	var pts := _chain_points(i)
	if pts.size() < 2:
		return
	var n := pts.size()
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for k in n:
		var p: Vector2 = (pts[k] as Dictionary)["p"]
		var prev: Vector2 = (pts[maxi(k - 1, 0)] as Dictionary)["p"]
		var next: Vector2 = (pts[mini(k + 1, n - 1)] as Dictionary)["p"]
		var d := next - prev
		if d.length() < 0.001:
			d = Vector2(1.0, 0.0)
		var nor := Vector2(-d.y, d.x).normalized()
		var r: float = (pts[k] as Dictionary)["r"]
		left.append(p + nor * r)
		right.append(p - nor * r)
	var poly := PackedVector2Array()
	for v in left:
		poly.append(sc * v)
	for k in range(right.size() - 1, -1, -1):
		poly.append(sc * right[k])
	_draw_filled(poly, _c(col, "fur"), _c(col, "ink"), _ink_w() * 0.85)


## 胶囊多边形：局部 a → b，半径 ra → rb（锥形 + 两端半圆）。
func _capsule(xf: Transform2D, a: Vector2, b: Vector2, ra: float, rb: float) -> PackedVector2Array:
	var d := b - a
	var l := d.length()
	if l < 0.001:
		return _ellipse(a, ra, ra, xf)
	var dir := d / l
	var nor := Vector2(-dir.y, dir.x)
	var out := PackedVector2Array()
	out.append(xf * (a + nor * ra))
	out.append(xf * (b + nor * rb))
	for k in 9:
		var th: float = PI * (float(k) + 1.0) / 9.0
		out.append(xf * (b + dir * (sin(th) * rb) + nor * (cos(th) * rb)))
	for k in 9:
		var th: float = PI * (float(k) + 1.0) / 9.0
		out.append(xf * (a - dir * (sin(th) * ra) - nor * (cos(th) * ra)))
	return out


## 耳朵：沿骨轴的圆角三角（外耳 = fur，内耳 = fur_2 且更小）。
##
## 内耳的两个坑（都在上面 PARTS 的注释里）：
##   ① 它的骨骼 origin 在外耳的**尖端**上；
##   ② 它**没有 l 字段** ⇒ `_bl[i] == 0`，按自己算长度会退化成 0.58 单位的小尖刺。
## 所以内耳一律改用**外耳的变换与骨长**，再沿骨轴按 inset 内收成一个缩小的同形。
func _draw_ear(sc: Transform2D, i: int, spec: Dictionary, col: Dictionary) -> void:
	var outer := str(spec["k"]) == "ear"
	var par := _parent[i]
	var host: int = i if (outer or par < 0) else par
	var t: Transform2D = sc * _world[host]
	var ln: float = maxf(_bl[host], 1.0) * float(spec.get("f", 0.9))
	var w := float(spec["w"])
	var ox: float = 0.0 if outer else ln * float(spec.get("inset", 0.4))
	var pts := PackedVector2Array([
		t * Vector2(ox, -w),
		t * Vector2(ox + ln * 0.55, -w * 0.55),
		t * Vector2(ox + ln * 0.88, -w * 0.22),
		t * Vector2(ox + ln, 0.0),
		t * Vector2(ox + ln * 0.88, w * 0.22),
		t * Vector2(ox + ln * 0.55, w * 0.55),
		t * Vector2(ox, w),
		t * Vector2(ox - ln * 0.08, 0.0),
	])
	_draw_filled(pts, _c(col, "fur" if outer else "fur_2"), _c(col, "ink"),
			_ink_w() * (1.0 if outer else 0.7))


## 叶：沿骨轴的水滴形（两端收尖、40% 处最宽）+ 一条主叶脉。
func _draw_leaf(xf: Transform2D, i: int, spec: Dictionary, col: Dictionary) -> void:
	var ln: float = maxf(_bl[i], 1.0) * 1.15
	var w := float(spec["w"])
	var pts := PackedVector2Array()
	for k in 13:
		var f: float = float(k) / 12.0
		pts.append(xf * Vector2(ln * f, -w * sin(PI * f) * (1.0 - 0.32 * f)))
	for k in 13:
		var f: float = 1.0 - float(k) / 12.0
		pts.append(xf * Vector2(ln * f, w * sin(PI * f) * (1.0 - 0.32 * f)))
	_draw_filled(pts, _c(col, str(spec["c"])), _c(col, "ink"), _ink_w() * 0.55)
	draw_polyline(PackedVector2Array([
		xf * Vector2(ln * 0.10, 0.0),
		xf * Vector2(ln * 0.84, 0.0)]), _c(col, "ink"), _ink_w() * 0.4, true)


## 胡须：从骨骼起点（按 ox 内收，因为真机的胡须骨骼在头轮廓外、靠网格顶点伸回来）
## 向外三根，整体向下垂一点。
## ⚠️ 下垂方向必须看骨骼局部 **y 轴**在屏幕上的指向（xf.y.y），不是 x 轴 ——
## 写成 xf.x.y 的话左右两根胡须会一根朝上一根朝下（第一版就是）。
func _draw_whisker(xf: Transform2D, spec: Dictionary, col: Dictionary) -> void:
	var ln := float(spec["len"])
	var dy := 1.0 if xf.y.y > 0.0 else -1.0
	var base := Vector2(float(spec.get("ox", 0.0)), 0.0)
	var ink := _c(col, "ink")
	for k in 3:
		var a: float = deg_to_rad(-19.0 + 19.0 * float(k))
		var d := Vector2(cos(a), sin(a)) * ln
		draw_polyline(PackedVector2Array([
			xf * base,
			xf * (base + d * 0.55 + Vector2(0.0, dy * 20.0)),
			xf * (base + d + Vector2(0.0, dy * 34.0)),
		]), ink, _ink_w() * 0.55, true)


## 虹膜：**夹进父骨骼（眼白）的椭圆内** —— 这是真机 EyeRMask/EyeLMask 的等价做法。
## 真机用 clipping attachment 让眼球在眼窝里滑动、越界处被裁掉；这里改成把虹膜的圆心
## 夹回眼白椭圆内，观感等价且不需要图集。
##
## ⚠️ 两条都在这里踩过（都表现为"两只眼不对称得像斜视"）：
##   ① `local` 取的是**动画增量**（now − rest），不是虹膜骨骼在眼骨坐标系里的绝对位置。
##      真机里 EyeCR 位于 EyeR 局部 (−55, 4)、EyeCL 位于 EyeL 局部 (+55, 4) —— 那是
##      **绑定用的骨骼位置**（骨骼贴在眼球外沿用网格顶点把虹膜拉回中心）。照它摆的话虹膜会
##      偏到眼球边缘：眼白半长 59、虹膜半长 47，余量只剩 12，于是虹膜偏 12 就是"一边贴边
##      一边空 24"。取增量后静息态虹膜正中，只有动画真的推了它才滑。
##   ② 本函数是唯一**自己在 rig 空间拼变换**的图元（其余图元把 `sc * _world[i]` 交给 _ellipse），
##      所以必须自己乘 `sc`。第一版漏了 → 虹膜连同瞳孔被画到屏幕外的 rig 坐标上，
##      效果是"白眼球 + 小黑点"，看着像一副眼镜。改这里时别再把 sc 丢了。
func _draw_iris(sc: Transform2D, i: int, spec: Dictionary, col: Dictionary) -> void:
	var eb := _parent[i]
	if eb < 0 or not PARTS.has(_names[eb]):
		return
	var es: Dictionary = PARTS[_names[eb]]
	var erx := float(es.get("rx", 0.0))
	var ery := float(es.get("ry", 0.0))
	if erx <= 0.0 or ery <= 0.0:
		return
	var irx := float(spec["rx"])
	var iry := float(spec["ry"])
	var rest := Vector2(_bx[i], _by[i])      # 虹膜在眼骨坐标系里的 rest 位置
	var now := _world[eb].affine_inverse() * _world[i].origin
	var local := now - rest
	var lim := Vector2(maxf(erx - irx - 2.0, 0.0), maxf(ery - iry - 2.0, 0.0))
	# 用"从中心指向外"的方向乘夹回来的长度：直接分轴 clamp 会让虹膜贴住方角，
	# 按向量长度夹则始终落在眼白椭圆内部的同心位置。
	if local.x > lim.x or local.y > lim.y:
		var f: float = minf(lim.x / maxf(absf(local.x), 0.001), lim.y / maxf(absf(local.y), 0.001))
		local = local * minf(f, 1.0)
	var xf := sc * Transform2D(_world[i].get_rotation(),
			_world[eb] * Vector2(clampf(local.x, -erx, erx), clampf(local.y, -ery, ery)))
	_draw_filled(_ellipse(Vector2.ZERO, irx, iry, xf), _c(col, "pupil"))
	# 瞳孔：虹膜内更小一圈的竖椭圆（猫是竖瞳；比"一个纯色圆"更像眼睛）
	_draw_filled(_ellipse(Vector2.ZERO, irx * 0.34, iry * 0.62, xf), _c(col, "ink"))


## 高光：一个小的浅色圆。
## ⚠️ 偏移走 **rig 空间的绝对方向**（ox 向右、oy 向上），不跟着虹膜骨骼的朝向走 ——
##    EyeCLR 与 EyeCLL 在真机里的局部坐标并不互为镜像（EyeCLL 挂了 r=90，算到 root 是
##    (−52,−49)，而 EyeCLR 是 (+39,+60)），照骨骼画会让两只眼的高光一个在左上、一个在右下。
##    高光是**光源方向**，本来就该两眼一致，所以这里绕开骨骼朝向。
func _draw_shine(sc: Transform2D, i: int, spec: Dictionary, col: Dictionary) -> void:
	if _parent[i] < 0:
		return
	var c: Vector2 = _world[_parent[i]].origin + Vector2(
			float(spec.get("ox", -13.0)), float(spec.get("oy", 15.0)))
	var r := float(spec["r"])
	# ⚠️ 必须写成 `sc * Transform2D(0, c)`（= 位置经 sc、半径也经 sc 缩放），
	#    不能写成 `Transform2D(0, sc * c)`：后者只把圆心搬到屏幕坐标、**丢掉了缩放**，
	#    于是高光按 rig 半径（11）当**像素**画出来 —— 一只 22px 的白团直接盖住整只眼球
	#    （实测就是这个：虹膜明明画了，却被高光糊掉，"两眼全白"）。
	_draw_filled(_ellipse(Vector2.ZERO, r, r, sc * Transform2D(0.0, c)), _c(col, "eye"))


## 口鼻：鼻骨处的浅色椭圆（脸中轴的亮块，脸的立体感全靠它）+ 一颗圆角三角鼻。
## 尺寸 74×84（rig 单位）：头块宽 380 ⇒ 口鼻斑约占头宽 20%。原先取 88×98（23%）在
## 192px 停靠宽下会盖掉半张脸，眼睛被挤成两个小点（实测截图确认）。
func _draw_muzzle(xf: Transform2D, col: Dictionary) -> void:
	_draw_filled(_ellipse(Vector2(-10.0, -4.0), 74.0, 84.0, xf), _c(col, "patch"))
	var n := PackedVector2Array([
		xf * Vector2(-54.0, 32.0),
		xf * Vector2(46.0, 32.0),
		xf * Vector2(34.0, 2.0),
		xf * Vector2(-4.0, -34.0),
		xf * Vector2(-42.0, 2.0),
	])
	_draw_filled(n, _c(col, "nose"), _c(col, "ink"), _ink_w() * 0.8)


## 嘴：人中一竖 + 左右各一段下垂弧（"ω"）。上唇由 Mouth1 驱动、下巴线由 Mouth2 驱动 ——
## 这两个骨骼在 Idle1 里被逐帧平移（Mouth2 的 y 有 24.45 的位移），于是嘴会跟着呼吸开合。
func _draw_mouth(xf: Transform2D, spec: Dictionary, col: Dictionary) -> void:
	var w := float(spec["w"])
	var drop := float(spec["r"])
	var ink := _c(col, "ink")
	var lw := _ink_w() * 0.8
	draw_polyline(PackedVector2Array([
		xf * Vector2(0.0, -4.0),
		xf * Vector2(0.0, -32.0)]), ink, lw, true)
	for s in [-1.0, 1.0]:
		draw_polyline(PackedVector2Array([
			xf * Vector2(0.0, -32.0),
			xf * Vector2(s * w * 0.58, -32.0 - drop * 0.52),
			xf * Vector2(s * w, -32.0 - drop * 0.06),
		]), ink, lw, true)


## 脚下投影：两层不同 alpha 的椭圆近似"软投影"（_draw 里没有渐变填充）。
## 有了它伙伴才是"站在页面上"，而不是"浮在页面上"。
func _draw_shadow(sc: Transform2D, col: Dictionary) -> void:
	var sh := _c(col, "shadow")
	if sh.a <= 0.0:
		return
	var cx := float(RIG.SKELETON["x"]) + float(RIG.SKELETON["w"]) * 0.52
	_draw_filled(_ellipse(Vector2(cx, 46.0), 690.0, 54.0, sc),
			Color(sh.r, sh.g, sh.b, sh.a * 0.70))
	_draw_filled(_ellipse(Vector2(cx, 50.0), 470.0, 38.0, sc),
			Color(sh.r, sh.g, sh.b, sh.a * 1.20))


## 取骨骼 i 的第一个子骨骼（尾巴链 / 腿的末端要用）。
func _next_bone(i: int) -> int:
	for k in _n:
		if _parent[k] == i:
			return k
	return -1


## 世界点 p（rig 空间）在骨骼 i 的局部空间里的坐标。
func _in_local(i: int, p: Vector2) -> Vector2:
	return _world[i].affine_inverse() * p
