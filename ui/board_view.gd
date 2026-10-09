# board_view.gd —— 棋盘渲染 + 拾取 + 键盘 + 涟漪动效 + scale-to-fit【plan1.1 §10.7.6】
# 渲染只 queue_redraw() 交给 Godot 调度，禁手写脏矩形。
# 判负引爆格高亮从 GameSession.exploded_pos 取；终局揭晓绘制雷位允许调
# get_mine_positions()（渲染，非判负逻辑；红线 2 的例外条款）。
# 全部色值经 ThemeManager；无 48px 硬编码（全文件跟随 cell_px）。
#
# 几何抽象（T4）：所有「格坐标 → 像素」的换算集中到 _cell_center / _cell_rect / _cell_polygon
# 三个函数里，另加纯函数 _unit_px()（每晶格单位的像素数）。矩形关卡（RectGrid 或 style=="custom"
# 的邻接表）走原路径，逐像素等价；蜂窝（style=="hex"）走六边形几何（常量见下）。渲染之外的
# 动效状态机（wave / pop / ripple）与它们的时间常量**一律未动**，只吃传进去的矩形。
extends Control

## 伙伴骨架数据（只取 ASPECT 与 DESIGN_W/EDGE 做停靠尺寸换算）。纯数据脚本、不引用任何
## autoload，故这里的 preload 不会给 board_view 添运行时依赖。
const RIGDATA := preload("res://ui/companion_rig.gd")
## 试玩期「检查进度」的判据（文档 §7）。**preload 而不是引用全局类名**：
## 本文件被 headless 工具链加载，依赖全局类缓存会多一个解析期风险点。
const PROGRESS_CHECK := preload("res://core/progress_check.gd")
## 伙伴本体脚本，**当类型注解用**（Godot 4 允许把 const preload 的脚本作类型）：
## 于是 _pet.react() / _pet.frozen / _pet.hit_test() 都有静态检查，而不是先转 Control
## 再靠 `call("react")` 这种一改签名就静默失效的动态调用。
## 也不必给 companion_pet.gd 注册 class_name —— 那会多一个全局名字，与工具链/CI 的类名
## 扫描打架（RIPPLE_RINGS 就是为此才不注册的）。
const PetScript := preload("res://ui/companion_pet.gd")

# ============ 蜂窝（六边形）几何常量 ============
# 数值来源 = 原版游戏字节码（T4 已确证），**照用勿改**：
#   格心（晶格单位，(x,y) = 格坐标）：cx = 0.75*(x+y)、cy = (√3/4)*(x−y)
#   六边形外接半径 R = 0.475；相邻格心距 = √3/2 ≈ 0.866；内切半径 = (√3/2)R ≈ 0.4114。
#   ⇒ 两格内切半径和 ≈ 0.823 < 0.866，相邻格之间天然留 ~5% 缝——这是原版 0.95 收缩的复刻，
#     蜂窝盘看着「格与格分得开」正是它，**不要改成无缝**。
const HEX_R := 0.475                      # 六边形外接半径（晶格单位）
const HEX_SQ3 := 1.7320508075688772       # √3
const HEX_CX := 0.75                      # 格心 x 系数：cx = HEX_CX*(x+y)
const HEX_CY := HEX_SQ3 / 4.0             # 格心 y 系数：cy = HEX_CY*(x−y) = 0.4330127…
const HEX_SPACING := HEX_SQ3 / 2.0        # 相邻格心距 = √3/2 = 0.8660254…
const HEX_INRADIUS := HEX_SPACING * HEX_R # 内切半径 = (√3/2)R = 0.4113620…
## 六边形半高 = (√3/2)R：平顶六边形的**上下是水平边**，故这两条边到格心的距离就是内切半径
## （= HEX_INRADIUS，同一个数）。layout 的视觉包围盒上下各外扩这么多：只有外扩 R 就会把
## 最上/最下两排六边形切掉半个高度（首跑实测就是这么暴露的）。
const HEX_HALF_H := HEX_INRADIUS
const HEX_SQ_HALF := HEX_R / (1.0 + 1.0 / HEX_SQ3)  # 内接正方形半边长 = 0.3011379…
## 为什么内接正方形半边长是 0.3011 而不是「内切半径 0.4114」：
## 这个六边形是**平顶**的（顶点在左右，上下是水平边），左右两侧的斜边向内收。
## 半边长取 0.4114 时，正方形四角 (0.4114, 0.4114) 落在六边形**外面**（该处斜边只在 x ≤ 0.2375），
## 越过边长最多 0.174 晶格单位，而相邻格心仅相距 0.866 ⇒ 相邻格的正方形互相重叠约 1% 格面积，
## 整盘会糊成方阵的观感。取真正内接的正方形（0.3011）后正方形完全落在六边形内：
## 「六边形填充 ∪ 内接正方形填充 = 恰好六边形」，且与邻格零重叠（test_shape_style.gd 逐项断言）。
## 内接正方形仍以格心为中心，故数字/旗子/问号与各类覆盖层的**居中口径**与矩形路径完全一致。
const MIN_CELL_PX := 24                   # cell_px 下限（与矩形路径原公式的 24 同值同义）

## HUD 侧列保留宽度（2026-09-28 HUD 两列改造）：**必须与 ui/hud.gd:SIDE_COL_RESERVE 同值**，
## 由 test_ui_rework_contract.gd 的一致性断言守住——两处独立声明，改一处忘另一处就是
## 「棋盘被按钮盖住」或「无谓留白」两个 bug 之一。
## 为什么不用 preload 引用 hud 的常量：board_view 会被 headless 工具链间接加载，
## 不给编译期依赖再添一环（纯值复制 + 测试守卫在这里更稳）。
const HUD_SIDE_RESERVE := 104.0

## ── 动物伙伴「占位猫」的停靠区（2026-09-29 建，在棋盘**右侧**）────
## 2026-09-30 一度计划换到左侧（对齐 CozySudoku「猫在左」），但只落了 _apply_layout 的一半
## （avail_left 右移），_pet_dock_rect 仍量右侧 ⇒ 让位白扣、条带恒 0、伙伴消失。
## 2026-10-01 按契约（test_pet_dock_sits_between_board_and_hud_column）与实测判定**维持右侧**。
## 三条值与 ui/companion_pet.gd 的 DESIGN_W / EDGE 是**两处独立声明**（沿用 HUD_SIDE_RESERVE
## 的先例：board_view 会被 headless 工具链间接加载，不给编译期依赖再添一环），
## 由 test_companion_pet.gd 的一致性断言守住——改一处忘另一处就是「猫被棋盘压住」。
##
## 为什么是 192（而不是"越大越好"）——PET_W 只影响两件事，两件都已量化
## （_pv/pet_size_sweep.py，1280×720，179 关）：
##   ① 条带够宽的关卡能显示**满尺寸**猫的关数：168→147 / **192→144** / 216→143 / 240→127
##      / 264→16（**断崖**：棋盘定位后右侧条带的天花板就是 ~242，越过它满尺寸关数崩掉）；
##   ② 必须让位的那 31 关里格子缩多少 = PET_RESERVE / 1024：192→−21.1% / 240→−25.8%
##      / 288→−30.5%（线性，每 +24px 猫宽多付 ~2.3%）。
## 192 与 216 在①上只差 1 关，而②要多付 2.3% ⇒ 取 192。要继续调大请先重跑那张表。
const PET_W := 192.0
const PET_EDGE := 12.0
## 停靠区可用宽低于此值就**不显示**伙伴。取 ≈ 0.77×PET_W：再小就比三个格子还窄，看不出是猫；
## 与其塞一只被压扁/被盖住的，不如没有（伙伴是装饰，不是信息）。
## 注意它**不是**让位阈值以外的第二个阈值：条带 ∈ [PET_MIN_W, PET_W) 时会显示一只
## 按条带宽度等比缩小的猫（不触发让位），实测有 4 关落在这个区间。
const PET_MIN_W := 148.0
## 额外让位宽度 = PET_W + 2×PET_EDGE。让位后**棋盘右边缘到 HUD 右列保留线**之间
## **恒有 ≥ PET_RESERVE** 的条带（推导见 _apply_layout 的 avail_w：宽度受限的盘恰好
## = PET_RESERVE，与实测 179 关的 216 一致）。故绝不会有"让位了还放不下"。
## 2026-09-30 曾把伙伴换到**左侧**（对齐 CozySudoku「猫在左」），但停靠区一直在棋盘
## **右侧**（_pet_dock_rect 与 test_pet_dock_sits_between_board_and_hud_column 都是右侧口径），
## 换边只落了 avail_left 右移那一半 ⇒ 让位白扣 216px 而条带仍为 0。数值不变。
const PET_RESERVE := 216.0

# ============ 自定义多边形（数据驱动，T-D2）几何常量与口径 ============
# 数据来源：关卡 JSON 的 custom_shapes（level_loader 在 load_level 后挂到 board 的 meta 上；
# core/Board/GridInterface 一行不改）：bbox = [minX,minY,maxX,maxY]（**原版世界坐标**，只用于
# 核对尺寸——格心已归一化到 0 起）、unit = 一个「格」的世界尺寸（正六边形外径 2R）、
# cells = [{x,y,center:[cx,cy],poly:[[dx,dy],…],hl:[i,…],taper:[b,b],group}, …]。
# 坐标口径（三段线性映射，全部围绕 _custom_scale()）：
#   世界坐标 → 屏幕 ：screen = board_origin + world * scale，scale = unit_px / unit
#   棋盘坐标 → 屏幕 ：board_pt = world / unit ⇒ screen = board_origin + board_pt * unit_px
#     （与矩形分支「1 棋盘单位 = 1 格 = cell_px 像素」同构：1 棋盘单位 = 1 格世界尺寸）
#   格心 / 格轮廓   ：格心 = board_origin + center * scale；顶点 = board_origin + poly * scale
# 与 hex_layout_for() 的对照（同构，只差「视觉包围盒」的来源）：
#   · 两者都按**视觉包围盒**（既不是 grid.size() 方阵包围盒，也不是格心包围盒）scale-to-fit
#     + 居中，并用同样的 24px 下限；
#   · 蜂窝的视觉跨度由六边形公式推出（hex_visual_span = 格心跨度 + 左右 2R / 上下 2×半高）；
#   · 自定义盘的五/六边形混排、朝向各异，公式化外扩不成立 ⇒ 直接实测量「全部格心 + 全部顶点」
#     的并集包围盒（custom_visual_bounds）。
#   · 反例：bbox 字段只圈住格心，比视觉包围盒每边小约一格半径 ⇒ 按它分配会把最外圈格子切掉
#    （与蜂窝盘当初误用 grid.size() 的错同源）。
const CUSTOM_CELL_FRAC := 2.0 * HEX_SQ_HALF  # cell_px = CUSTOM_CELL_FRAC × unit_px
## 为什么沿用蜂窝的 0.6023（= 2×内接正方形半边长）：cell_px 是本文件字号/旗子/雷体/描边的
## **密度旋钮**，取同一比例 ⇒ 自定义盘与蜂窝盘的文字视觉密度一致。自定义盘没有「内接正方形」
## 这种几何量，这个比例只是密度约定，不是几何量。
const CUSTOM_HL_W := 3.5                  # 高亮折线线宽（原版 ≈ 轮廓的 3~4 倍；轮廓固定 1.0）
const CUSTOM_HL_TAPER_W := 1.0            # taper 端收细后的线宽（= 轮廓线宽）
const CUSTOM_HL_TAPER_STEPS := 4          # taper 段的细分段数（分段变宽折线，见 _draw_hl_polyline）

## cell_px：scale-to-fit 动态格尺寸（§8.4.7 公式；下限 24px）
## 蜂窝路径下 = 内接正方形边长（像素），沿用 cell_px 是为了让既有「全部尺寸跟随 cell_px」的
## 绘制代码（字号 scale、旗子、提示描边…）零改动地跟着蜂窝盘一起缩放。
var cell_px: int = 48
## 棋盘绘制原点（恒居中）。矩形路径 = 格 (0,0) 的左上角；蜂窝路径 = 晶格原点（格心 = origin + 晶格坐标×unit）。
var board_origin: Vector2 = Vector2.ZERO
## 棋盘的**视觉包围盒**（屏幕像素）。三条布局路径都在 _apply_layout 里从各自的纯函数
## 取 vis_rect 写入（矩形路径当场构造），唯一消费者是 _pet_dock_rect。
##
## ⚠️ 为什么不能拿 board_origin 当左边缘：board_origin 是「坐标系原点」而不是「实绘左上角」——
##    自定义盘的世界坐标**不必从 0 起**（girih_02 的最小顶点是负的，origin 比实绘左边缘靠右
##    近 50px），蜂窝盘的 origin 也要再向外扩 R 才到实绘边缘。2026-09-29 第一版就是这么错的，
##    症状是 girih_02 的停靠条带被算窄 49px、伙伴莫名消失。
var board_vis_rect: Rect2 = Rect2()
## 蜂窝路径的「每晶格单位像素数」（由 _layout() 按六边形实际跨度 scale-to-fit 算出）。
## 只经 _unit_px() 读取；矩形路径不使用。
var _hex_unit_px: float = 48.0
## 自定义多边形路径的「每棋盘单位像素数」（= scale × unit；由 _layout() 按视觉包围盒 scale-to-fit
## 算出）。只经 _unit_px() / _custom_scale() 读取；矩形与蜂窝路径不使用。
var _custom_unit_px: float = 48.0
## 自定义盘查表缓存：Vector2i → {center, poly(世界绝对顶点), rel, hl, taper, apothem}。
## 按 board 实例 id 失效（换关/重开/读档都是新 Board ⇒ 自动重建，不跨关卡残留）。
var _custom_cells: Dictionary = {}
var _custom_cache_key: int = 0
## 连接透镜开关（**不可能几何盘专属**；见 supports_lens 的判据）与它的几何缓存。
##   · `_lens_on`   —— 玩家点了右列「透镜」后整盘常驻；关闭时只在悬停格上出现（悬停即问）。
##   · `_impl_seams` / `_impl_ghosts` —— 见 _impossible_pairs()：把「真相邻」与
##     「看着碰上、其实不算相邻」两批位置算一次、存起来（键 = board 实例 id，换关自动失效）。
var _lens_on := false
var _impl_key: int = 0
var _impl_seams: Array = []
var _impl_ghosts: Array = []
## 静态折叠视图开关 + 配对缓存（**折叠盘专属**；见 supports_fold 的判据）。
##   · `_fold_flat`  —— false = 「折起来」观感（远侧压暗、折痕上的记号指向近侧）；
##     true = 「摊平看」：把每对 a↔b 的镜像虚线画出来，顺着线就能数清叠了几层。默认折起来。
##   · `_fold_audit_cache` —— 见 _fold_audit()：按 board 实例 id 缓存整份折叠审计
##     （配对表 + 摞 + 最厚层数；换关自动失效）。一次算好，绘制/悬停/测试都读它。
var _fold_flat := false
var _fold_key: int = 0
var _fold_audit_cache: Dictionary = {}
var _fold_pairs_cache: Array = []
## 鼠标悬停格（-1,-1 = 无）
var hover_pos: Vector2i = Vector2i(-1, -1)

## 开格波浪参数（§8.4.5；0 间隙棋盘：波浪的本质是**相位差**，不是位移）。
##   WS 每环延迟秒 · WD 单格时长秒 · GLOW 网格线高亮上限 · WP 颜色脉冲权重
##   SHRINK 填充收缩幅度 · COVER 波及范围比例 · MAX_RINGS 扩散层数上限
##   DELAY_CAP 错峰上限秒 · TAIL_MULT 末环长尾倍率 · LINE_GAIN 高亮线宽增益
const WAVE_WS := 0.040        # 每环延迟（秒）：环 0/1 同时开始，环 2 起逐环错开
const WAVE_WD := 0.30         # 单格时长（秒）：waveE = sin(PI*t/WD)，唯一能精确回到 0
const WAVE_GLOW := 0.85       # 网格线混向高亮色的强度上限（本方案主通道）
const WAVE_WP := 0.75         # 颜色脉冲权重：峰值 alpha = WP * WAVE_PULSE_MAX
const WAVE_SHRINK := 0.04     # 填充原地收缩幅度（0 间隙下禁位移/放大）
const WAVE_COVER := 0.24      # 波及格数上限 = 总格数 × COVER（连续参数，跨环按 frac 衰减）
const WAVE_MAX_RINGS := 4     # 扩散层数上限（安全 + 收尾时长可控）
const WAVE_PULSE_MAX := 0.55  # 颜色脉冲相对 WP 的系数
## 错峰延迟上限（秒）：末环起播最多比环 0 晚这么久（`_ring_delay_sec` 逐环 min 封顶）。
## 为什么要显式封顶：环延迟随环序线性增长 (ring-1)*WS，泛洪范围一大（大盘 / 掀开整片）
## 最后一环就会等到几百毫秒才起播，观感从「一圈推开」变成「拖沓」。
## 封顶后超出的环共享同一启动时刻——波前在末环「追上」并一起收束，总时长因此有硬上限
## ＝ WAVE_DELAY_CAP + WAVE_WD * WAVE_TAIL_MULT（见 total_ms 计算）。
const WAVE_DELAY_CAP := 0.12
## 末环渐慢长尾倍率：只有**最后一环**的波形时长放大到 WAVE_WD 的该倍率。
## 目的：波前推到最外圈时不再「整环同时亮灭」地硬切，而是慢慢收束（渐慢长尾）。
## 内部环时长不变 → 既有节奏、既有测试都不受影响。
const WAVE_TAIL_MULT := 1.5
## 波浪高亮描边相对静止网格线的线宽增益：线宽 = 1.0 + GAIN*g ∈ [1.0, 1.6]。
## 只作用于被波浪波及、且该帧确有强度（g>0）的格——g=0 时精确回 1.0（非波浪帧零变化）。
const WAVE_LINE_GAIN := 0.6

## 单格翻开 pop 参数（动效规范两件套之「单格 pop」，与 0 格波浪并存）。
##   POP_WD 单格时长秒 · POP_SCALE_MIN 起始收缩比
## 规范初值：p = clamp((now-t0)/0.20, 0, 1)；e = sin(PI*p/2)（单调缓出）；
##           scale = 0.86 + 0.14*e；color = lerp(未翻开色, 已翻开色, e)。
## ⚠️ 关键约束（否则会压到邻格）：本项目格子间隙 = 0（cell_px 即格宽、网格线居中于格缝）。
## 规范原式的过冲项 `+ 0.10 * sin(PI*p)` 峰值可达 1.07 —— 零间隙下必然越线压住邻格。
## 故**砍掉过冲项**：scale 严格落在 [0.86, 1.0]，只收缩、永不超过 1.0。
const POP_WD := 0.20           # 单格 pop 时长（秒）：0.20s 内 scale 0.86→1.0、颜色插值完毕
const POP_SCALE_MIN := 0.86    # 起始收缩比例（0.86 收缩起 → 1.0 归位；上界恒为 1.0）

# 用 preload 而非全局类名：新增脚本的全局类缓存未必在加载本场景前刷新，
# 直接用 `RippleRings` 会解析失败（单元测试首跑已复现）。纯静态方法，preload 等价。
const RIPPLE_RINGS := preload("res://core/ripple_rings.gd")

## 开格波浪：同一时间最多一条（新波浪覆盖旧波浪，天然防叠加）。
## 每条记录 = { pos 环0起点, t0 触发时刻ms, ring_of{格->环}, amp_of{格->振幅},
##              total_rings 最后一环, ring_sizes 各环格数, ring_delays 各环起播延迟,
##              cells / target 供渐隐校验 }
var _ripples: Array = []
## 波浪触发源（v3.4 起）：Board.flood_planned 的**权威计划**——origin / cells / zero_flood。
## 此前在 UI 侧攒 cell_state_changed 做「同帧唯一格数 >= 2」的启发式判泛洪，已删除：
## 那个启发式会把 chord（逐目标展开）与终极模式揭星误报成 0 格泛洪（core 侧新增本信号即为取代它）。
## 波浪逐帧缓存（Vector2i -> {"s": 填充缩放, "g": 波浪强度 0..1}）。
## 原实现对每个格子 O(1) 扫描整个涟漪队列（连锁翻开时可达数十条），
## 大盘下变成 O(格子数 × 涟漪数)/帧。改为每帧只算一次几何，绘制时查表。
var _ripple_cache: Dictionary = {}
var _ripple_cache_ms: int = -1

## 单格 pop 登记表：Vector2i -> 该格本次翻开的起始时刻(ms)。
## 每次收到该格翻开事件就登记一次（泛洪时每格各一次，与波浪并存）。
## pop 结束（超过 POP_WD）后由 _cull_pops 从表中移除 → 不会无限增长。
var _pops: Dictionary = {}
## pop 逐帧缓存（Vector2i -> {"s": 缩放, "e": 缓出进度 0..1}）。
## 与 _ripple_cache 同范式：按 ms 重建、绘制只查表。两套缓存独立，互不覆盖。
var _pop_cache: Dictionary = {}
var _pop_cache_ms: int = -1

## 棋盘垫子样式缓存（2026-09-29 CozyStyle）。见 _mat_stylebox()：颜色没变就复用同一个
## StyleBoxFlat，避免波浪动效期间逐帧 new。
## `_mat_sb_shadow` 是第二个缓存键：影色自 2026-09-29 起也随主题走了（见 _mat_stylebox），
## 只比垫子色的话，两套主题垫子色撞上时会把上一套的影色一起带过去。
var _mat_sb: StyleBoxFlat = null
var _mat_sb_color := Color(0, 0, 0, 0)
var _mat_sb_shadow := Color(0, 0, 0, 0)
## 玻璃垫板缓存（2026-09-30 三层构造）：棱镜的 mat_* 六个形态键拼成一个字符串键，
## 任一变化（含皮肤/Mod 覆盖、主题过渡 lerp 吸附）都触发重建。
## _gmat_shadow_sb 只出影不出面板（bg 全透明）；_gmat_fill_sb 只出面不出影——
## 分开的原因见 _draw_board_mat：CSS 的 box-shadow 不画在元素半透背景之下，
## StyleBoxFlat 的影却画在整块 rect 后面，半透白面板会被自己的黑影衬成深色板。
var _gmat_sb: StyleBoxFlat = null
var _gmat_key := ""
var _gmat_shadow_sb: StyleBoxFlat = null
var _gmat_fill_sb: StyleBoxFlat = null
var _prism_bg_tex: Texture2D = null   # 棱镜玻璃烘焙渐变背景（懒加载）

## 背景交叉淡化（2026-09-30 分层过渡的配套）：网页 body{transition:background .4s}
## 的等价物。use_bg_gradient 翻转（棱镜 ↔ 其余主题）时，烘焙贴图在新底色上 α 淡入/淡出
##（清屏色由 ThemeManager 同步渐变），避免背景整层硬切跳变。-1 = 无淡化在途。
var _bg_grad_last: int = -1
var _bg_fade_t0: int = -1
const BG_FADE_MS := 480.0

## 提示高亮（一步直推）：结论格描边 + 依据格描边（推理文字见 HintPanel 浮动窗口）
var _hint_steps: Array = []
var _hint_until_ms: int = -1
const HINT_TTL_MS := 6000

## 无猜模式「猜测被拒」反馈：以前 GameSession 发了 guess_rejected 但没有任何订阅者，
## 玩家点下去只有一声音效、格子纹丝不动，看起来就像卡死。现给出视觉反馈 + 节流文案。
var _reject_pos: Vector2i = Vector2i(-1, -1)
var _reject_until_ms: int = -1
var _reject_toast_ms: int = -100000
const REJECT_FLASH_MS := 550
const REJECT_TOAST_THROTTLE_MS := 3000

## 【2026-09-30】旧「换肤圆形波浪」系统（圆形扩散逐格换色）已按用户要求整体移除：
## 主题切换改由 ThemeManager 的**分层过渡**承担（几何→材质→配色三段重叠窗口，
## 见 theme_manager.gd 的 STAGE_* 注释），棋盘只响应 theme_changed 逐帧重绘。
## 翻开动效的 _ripples/_pops（开格涟漪）与本节无关，保持不动。


func _ready() -> void:
	add_to_group("themed")
	# 变体纹理的呼吸节拍（低频 Timer，不是 _process —— 理由见 _sync_tex_timer 上方注释）
	_tex_timer = Timer.new()
	_tex_timer.wait_time = TEX_PULSE_STEP_S
	_tex_timer.timeout.connect(_on_tex_pulse)
	add_child(_tex_timer)
	# 触摸长按判定（一次性；见 TOUCH_LONG_PRESS_MS 处注释）
	_touch_timer = Timer.new()
	_touch_timer.one_shot = true
	_touch_timer.wait_time = float(TOUCH_LONG_PRESS_MS) / 1000.0
	_touch_timer.timeout.connect(_on_touch_long_press)
	add_child(_touch_timer)
	if not ThemeManager.theme_changed.is_connected(queue_redraw):
		ThemeManager.theme_changed.connect(queue_redraw)
	GameSession.session_started.connect(_on_session_started)
	if not GameSession.hint_ready.is_connected(_on_hint_ready):
		GameSession.hint_ready.connect(_on_hint_ready)
	if not GameSession.guess_rejected.is_connected(_on_guess_rejected):
		GameSession.guess_rejected.connect(_on_guess_rejected)
	# 终局冻结伙伴（暂停那一路在 _toggle_pause 里，开局那一路在 _on_session_started 里）——
	# 三个入口各管一段状态迁移，覆盖 PLAYING → PAUSED → PLAYING 与 PLAYING → WON/LOST。
	if not GameSession.game_ended.is_connected(_on_game_ended_for_pet):
		GameSession.game_ended.connect(_on_game_ended_for_pet)
	# 试玩期「检查进度」（文档 §7）：HUD 发信号，本视图负责标/清（判据在 core/progress_check.gd）
	if not GameSession.progress_check_requested.is_connected(_on_progress_check_requested):
		GameSession.progress_check_requested.connect(_on_progress_check_requested)
	# 鼠标移出棋盘：不再有 MouseMotion 事件，悬停高亮会永远定格在最后一格
	mouse_exited.connect(_on_mouse_exited)
	# 绘画层（棋盘之上、HUD 之下）+ 底栏工具栏
	_drawing = load("res://ui/drawing_layer.tscn").instantiate()
	add_child(_drawing)
	# 笔迹改用棋盘坐标存储：窗口缩放 / 换分辨率读档时笔记自动跟着格子走。
	# 闭包读的是当前字段值，故 _layout() 改变 cell_px / board_origin 后无需重新注入。
	# 换算本身仍是「棋盘坐标 → 屏幕」的线性映射（绘画层代码零改动），只是蜂窝盘要换成晶格仿射映射，
	# 否则笔记会整片错位（蜂窝的格心间距与矩形不同）。
	_drawing.set_board_transform(_board_pt_to_screen, _screen_pt_to_board)
	# 动物伙伴（占位猫）：纯装饰，跟在绘画层之后、HUD 之前（见 _setup_pet）。
	_setup_pet()
	var hud: Control = load("res://ui/hud.tscn").instantiate()
	add_child(hud)
	_toolbar = load("res://ui/drawing_toolbar.tscn").instantiate()
	add_child(_toolbar)
	_toolbar.setup(_drawing)
	_game_over = load("res://ui/game_over.tscn").instantiate()
	add_child(_game_over)
	_pause_menu = load("res://ui/pause_menu.tscn").instantiate()
	add_child(_pause_menu)
	_pause_menu.hide()  # Window 默认 visible=true，不显式隐藏会一进局就盖住棋盘
	# 提示浮动窗口（推理文字；可拖拽/缩放/调字体）
	_hint_panel = HintPanel.new()
	add_child(_hint_panel)
	# 绘画数据采集回调交给 GameSession（依赖倒置：autoload 不持有 UI 节点类型）。
	# 闭包读 board_view 自己的 _drawing 字段，取实时值；绘画层仅 _ready 创建一次，无需重复注册。
	GameSession.set_drawing_provider(func(): return _drawing.get_save_data())
	# v3.2/v3.3 存档内容自动保存：一笔画完/擦除/清空（changed）就落盘——
	# ① 写入按关草稿库（通关重进草稿仍在；清空绘画 = 删除草稿文件）；
	# ② 触发对局自动存档（走 1s 防抖）。关闭「绘画草稿存入存档」时两者都不触发。
	_drawing.changed.connect(func():
		if SettingsManager.drawing_in_save and GameSession.level_path != "":
			SaveCoordinator.save_drawing(GameSession.level_path, _drawing.get_save_data())
			GameSession.request_autosave())
	# 窗口尺寸变化 → 重排棋盘（格子大小/原点都依赖视口）。
	# 2026-09-25 修 bug：这个连接原先**写在 _exit_tree() 里**（且在那里还调了一次 _layout）——
	# 后果是从不生效（进入场景时没人连接，退出时才连给一个正在销毁的节点），
	# 拖动/最大化窗口后棋盘保持旧尺寸不再居中。现在连在 _ready（`_on_session_started`
	# 里已有一处 _layout 应付进场，此处只负责后续 resize）。
	get_viewport().size_changed.connect(_layout)
	# 双时序兼容：_ready 里手动调一次（恢复路径时 session 先开好、场景后进来）
	_on_session_started()


## 离开场景时注销绘画采集回调：
## autoload（GameSession）生命周期长于本场景，不注销会留下悬空的 provider 闭包，
## 之后的自动存档会在引擎层报错（见 GameSession._get_drawing 的同名注释）。
func _exit_tree() -> void:
	GameSession.set_drawing_provider(Callable())
	if get_viewport().size_changed.is_connected(_layout):
		get_viewport().size_changed.disconnect(_layout)


var _game_over: Control
var _drawing: DrawingLayer
var _toolbar: Control
var _hint_panel: HintPanel
var _pause_menu: PopupPanel
## 动物伙伴「占位猫」（ui/companion_pet.gd）。类型走 PetScript（见文件头的说明）——
## 它是纯装饰：所有对外调用都先判 null，且坏了也绝不该影响对局。
var _pet: PetScript = null


func _on_session_started() -> void:
	_connect_board()
	_ripples.clear()
	_ripple_cache.clear()
	_ripple_cache_ms = -1
	_pops.clear()
	_pop_cache.clear()
	_pop_cache_ms = -1
	_clear_hint()
	_clear_reject()
	_load_drawing()
	_layout()
	_sync_tex_timer()      # 换关：新棋盘可能带/不带 palette.texture，节拍跟着切
	queue_redraw()
	# 首次入局引导（2026-09-25 引导审计）：新玩家此前**没有任何上手提示**——
	# 「左键翻格、右键插旗」只写在教程文件里，得主动去点才发现（审计确认为「高」）。
	# 开局给一次、仅一次（持久化标记），8 秒够读完两行；之后玩家可随时点顶部「教程」。
	# headless（GUT 测试 / CI）下既不弹也不置位（2026-09-25 自查修）：测试会实例化本场景
	# 并触发本函数，若照常写盘，`seen_play_hint` 会被**测试**置成 true —— 玩家真机上的
	# 首次引导就再也不弹了。本项目已有「测试写真实 user:// 设置」的先例（settings 测试
	# 都靠手动保存/还原规避），这里用环境判断把这类污染挡在源头。
	if not SettingsManager.seen_play_hint and DisplayServer.get_name() != "headless":
		SettingsManager.set_seen_play_hint(true)
		UiToast.popup(self,
				"左键翻开隐藏格 · 右键插旗（按住右键拖过格子可连续插）\n"
				+ "点已翻开的数字格 = 一键展开邻域（数字 = 它周围 8 格的雷数）",
				false, 8.0)


## 恢复对局时载入存档中的绘画；新对局则清空
func _load_drawing() -> void:
	if _drawing == null:
		return
	# 用户关闭「绘画草稿存入存档」→ 恢复也不还原草稿（与新存档不带 drawing 字段一致）
	if SettingsManager != null and not SettingsManager.drawing_in_save:
		_drawing.clear_strokes()
		return
	var pending: Dictionary = GameSession.pending_drawing
	if pending is Dictionary and not pending.is_empty():
		_drawing.load_save_data(pending)
		# 旧版（v1 屏幕坐标）笔迹无法对齐棋盘 → 已丢弃，必须告知，不能静默消失
		if _drawing.legacy_discarded():
			UiToast.popup(self, "旧版绘画笔记无法对齐棋盘已清空；新笔记会跟随棋盘缩放")
	else:
		_drawing.clear_strokes()


# ============ 提示显示（一步直推；结论只读玩家视角，不读雷位） ============

func _on_hint_ready(steps: Array) -> void:
	_hint_steps = steps
	var now_ms := Time.get_ticks_msec()
	_hint_until_ms = now_ms + HINT_TTL_MS if not steps.is_empty() else -1
	if _hint_panel != null:
		_hint_panel.show_hint(steps)
	queue_redraw()
	# 【09-28 审计修复 R2】必须唤醒帧回调：`_process` 在无动效时会 `set_process(false)`，而提示高亮的
	# TTL 到期清理**发生在 _process 里** ⇒ 不唤醒就永不过期（静止盘上点"提示"，描边一直留着；
	# 关掉"翻开动效"后连 pop/wave 都不唤醒，问题稳定复现）。`_request_frames()` 是既有的对称接口。
	_request_frames()


## 盘面一变（翻开/插旗）旧提示即失效，避免误导。
func _clear_hint() -> void:
	_hint_steps = []
	_hint_until_ms = -1
	if _hint_panel != null:
		_hint_panel.clear_hint()


## Board 是新实例，每次 start/restart/restore 都重连（§10.11-3）。
func _connect_board() -> void:
	if GameSession.board == null:
		return
	# 换了 Board（新关 / 重开 / 恢复）⇒ 分色分组与雷数全变，浮层必须重建
	_reset_group_panel()
	if not GameSession.board.cell_state_changed.is_connected(_on_cell_changed):
		GameSession.board.cell_state_changed.connect(_on_cell_changed)
	# v3.4：波浪触发改用 Board 的**权威泛洪计划**（取代旧的「同帧唯一格数 >= 2」启发式）。
	if not GameSession.board.flood_planned.is_connected(_on_flood_planned):
		GameSession.board.flood_planned.connect(_on_flood_planned)


func _on_cell_changed(pos: Vector2i) -> void:
	_clear_hint()  # 盘面变化 → 旧推理结论失效
	# 盘面一变，「哪里插错了旗」的结论立刻过期 ⇒ 红叉必须跟着消失。
	# 留着就是**主动误导**：玩家会照着已经不对的红叉继续判断（比不标更糟）。
	if not _wrong_flag_marks.is_empty():
		_wrong_flag_marks.clear()
	_group_dirty = true   # 插旗/翻开都会改变「分色剩余雷数」
	# 伙伴反应：翻开/插旗都摸它一下。真机规格书里 track 5 只挂「点击」，本工程扩成
	# 「玩家的每一个操作」—— 猫对盘面变化有反应，比只对点击有反应更像活物。
	# 泛洪时本信号会逐格连发几十次，但 companion_pet 里有两道闸（REACT_MIN_GAP_MS 去抖 +
	# CLICK_COOLDOWN_MS 冷却），最终退化成约 0.9s 一次 —— 闸就是为这个场景设的。
	if _pet != null:
		_pet.react(1.0)
	# 单格 pop：每次翻开该格都登记一次（数字格/任意单格都有反馈）。
	# 泛洪时每个被翻开的格子都会各走一次本分支 → 每格各有一次 pop，与波浪并存。
	# 注意：波浪**不在这里**触发——它只由 Board.flood_planned(zero_flood=true) 驱动（见下）。
	if GameSession.board != null and GameSession.board.grid != null:
		var cell := GameSession.board.grid.get_cell(pos)
		if cell != null and cell.state == Cell.State.REVEALED and _reveal_effects_enabled():
			_register_pop(pos)
	queue_redraw()


## v3.4：0 格泛洪的权威计划 → 以 origin 为环 0、cells 为实际翻开集合起一条波浪（按环错峰）。
##
## 为什么只认 zero_flood=true：单格翻开（数字格 / FR 的 0 / 孤立 0 格）的反馈是
## _on_cell_changed 登记的单格 pop；把它塞进环序错峰既无意义又会与 pop 打架。
## chord 逐目标展开（每个目标各发一次 zero_flood=false）同理不产生波浪。
##
## 时序承诺：本信号在逐格 cell_state_changed 全部发完后、**同一个同步调用内**发出，
## 此刻棋盘状态已是最终态。这里只做「演出」，绝不回写状态、也绝不延迟任何状态变更——
## 动画的错峰只体现在绘制层（_ripples / _ripple_cache），与 Board 的时序完全解耦。
func _on_flood_planned(origin: Vector2i, cells: Array[Vector2i], zero_flood: bool) -> void:
	if not zero_flood:
		return
	if not _reveal_effects_enabled():
		return
	_start_wave(origin, cells)


## 登记一次单格 pop（记录起始时刻）。同一格重复 emit 只保留最新一次起算时刻。
## 复用「登记表 + _process 重算 + 按 ms 缓存」范式（不引入 Tween / 节点）。
## 总闸由调用方 _on_cell_changed 把关；此处只负责登记并唤醒逐帧回调。
func _register_pop(pos: Vector2i) -> void:
	_pops[pos] = float(Time.get_ticks_msec())
	_pop_cache_ms = -1
	_request_frames()


## 无猜-专家档：翻开请求被拒绝（该格无法纯逻辑推出）。
## 必须给出可见反馈——否则玩家会认为点击无响应/游戏卡死。
func _on_guess_rejected(pos: Vector2i) -> void:
	_reject_pos = pos
	var now_ms := Time.get_ticks_msec()
	_reject_until_ms = now_ms + REJECT_FLASH_MS
	_request_frames()
	if now_ms - _reject_toast_ms > REJECT_TOAST_THROTTLE_MS:
		_reject_toast_ms = now_ms
		UiToast.popup(self, "这一格无法纯逻辑推出（无猜模式不允许猜测）", true)
	queue_redraw()


func _clear_reject() -> void:
	_reject_pos = Vector2i(-1, -1)
	_reject_until_ms = -1


func _on_mouse_exited() -> void:
	# 右键拖动插旗中移出控件：释放事件收不到（gui_input 只在控件内触发）→ 在此复位，
	# 否则 _flag_dragging 残留到下次右键按下才被重置（拖出再拖入会误插旗）
	_flag_dragging = false
	_flag_drag_last = Vector2i(-1, -1)
	if hover_pos.x < 0:
		return
	hover_pos = Vector2i(-1, -1)
	queue_redraw()


## 棋盘布局。**两遍**：先按「不让位」排一次量出右侧还剩多宽的条带；条带够就收工
## （此时棋盘一格都没变小），不够才带着 PET_RESERVE 重排一次。
##
## 为什么要两遍而不是无条件让位：实测 179 关里有 148 关**本来就放得下**伙伴
## （正方形盘受高度限制 → 横向必有富余）。无条件让位会让这 148 关的格子白缩 20%，
## 只为摆一只装饰猫 —— 不划算。两遍法的代价：那 31 关宽扁盘才真的让位，
## 且中位损失仍是 0%（数据见 _pv/pet_layout_sim.txt，含最差 12 关的逐关数字）。
func _layout() -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	var vp := get_viewport_rect().size
	_apply_layout(vp, 0.0)
	if _pet_dock_rect(vp).size.x < PET_MIN_W:
		_apply_layout(vp, PET_RESERVE)
		if _pet_dock_rect(vp).size.x < PET_MIN_W:
			# 让位也腾不出条带 ⇒ **回滚**。会走到这里的是「棋盘被 MIN_CELL_PX 撑到比可用区
			# 还宽」的极端盘（格子已无法再缩，让位只是白亏 216px），或窗口本身就极窄。
			# 有回滚这条路，_layout 才不必去猜"让位有没有用"——它自己会证明。
			_apply_layout(vp, 0.0)
	_sync_pet(vp)


## 按 reserve（伙伴让位宽度，px）排一次盘面。reserve = 0 时与改造前**逐像素等价**。
func _apply_layout(vp: Vector2, reserve: float) -> void:
	# `size`/`scale` 与 Control 自身属性同名（遮蔽告警）——局部只读使用，注解表达有意
	@warning_ignore("shadowed_variable_base_class")
	var size := GameSession.board.grid.size()  # Vector2i(cols, rows)
	var cols: int = size.x
	var rows: int = size.y
	# 边距：左右 24、上 HUD 64 + 上边距 24、下边距 24 + 底栏 64（随窗口自适应，无 48px 上限）
	# 侧列保留（2026-09-28 HUD 两列改造；2026-09-30 左列已取消）：右列（对局工具列）仍浮在
	# 棋盘右侧，棋盘必须让出这段宽度——否则右边缘约半格被按钮盖住（点不到、也看不清）。
	# 伙伴让位（2026-09-29；停靠区在棋盘**右侧**，见 _pet_dock_rect）：reserve 只扣
	# **可用宽**，avail_left 锚定不动 ⇒ 盘面在变窄的可用区里重新居中，棋盘右边缘左移，
	# 右侧条带被腾出来。⚠️ **别**把 reserve 加进 avail_left —— 那是"左边界右移、右边界
	# 不动"的算法（2026-09-30 半途换边的残留），棋盘右边缘恒 = avail_left + avail_w 不变，
	# 一格条带都腾不出（sty_sq_wide 实测条带 0 ⇒ 伙伴消失，被布局代价用例守住）。
	var avail_left: float = 24.0 + HUD_SIDE_RESERVE
	var avail_w: float = maxf(vp.x - 48.0 - 2.0 * HUD_SIDE_RESERVE - reserve, 1.0)
	var avail_h: float = vp.y - 64.0 - 64.0 - 48.0
	# 可用区域的中心。**左边缘锚定**（= 左边距 + 两侧列保留，**不含** reserve）而不是 vp.x×0.5：
	#   · reserve = 0 时下式恒等于 vp.x×0.5（128 + (vp.x−256)/2 = vp.x/2），与改造前逐像素等价；
	#   · reserve > 0 时可用宽缩短 reserve、盘面在可用区里重新居中 ⇒ 棋盘右边缘左移：
	#     宽度受限的盘（sty_sq_wide 那类宽扁盘）整宽收缩，右边缘 = avail_left + avail_w
	#     = 1152 − reserve，条带恒 = reserve = PET_RESERVE（与 vp.x、盘面几何都无关）；
	#     高度受限的盘格子不变，右边缘只左移 reserve/2。
	#     _layout 的两遍法据此判定"让位有没有用"：两次都量不到条带就回滚（见 _layout）。
	var avail_center := Vector2(avail_left + avail_w * 0.5, 64.0 + avail_h * 0.5)
	# 自定义多边形盘（数据驱动）：同样按**视觉包围盒**（所有格心 + 所有顶点的并集，不是
	# grid.size() 的 15×15 紧凑包围盒、也不是 bbox 字段的格心包围盒）做 scale-to-fit + 居中。
	if _custom_layout():
		var layout := custom_layout_for(
				custom_visual_bounds(_custom_shapes().get("cells", []) as Array),
				_custom_unit_world(), avail_w, avail_h, avail_center)
		_custom_unit_px = float(layout["unit_px"])
		cell_px = maxi(int(layout["cell_px"]), MIN_CELL_PX)
		board_origin = layout["origin"]
		board_vis_rect = layout["vis_rect"]
		queue_redraw()
		return
	# 蜂窝：按六边形**实际几何跨度**（不是 grid.size() 包围盒方阵）做 scale-to-fit。
	# 用包围盒算会按 size×size 的正方形分配空间，六边形盘的斜边留白全被浪费 ⇒ 盘明显偏小。
	if _hex_layout():
		var layout := hex_layout_for(GameSession.board.grid.all_positions(), avail_w, avail_h, avail_center)
		_hex_unit_px = float(layout["unit_px"])
		cell_px = maxi(int(layout["cell_px"]), MIN_CELL_PX)
		board_origin = layout["origin"]
		board_vis_rect = layout["vis_rect"]
		queue_redraw()
		return
	# ↓ 矩形路径：以下逐行是原实现（唯一改动 = 字面量 24 → 同值常量 MIN_CELL_PX，
	#   以及居中基准 vp.x → avail_left：reserve=0 时两者恒等）。
	cell_px = maxi(floori(min(avail_w / float(cols), avail_h / float(rows))), MIN_CELL_PX)
	var board_w: float = float(cols) * cell_px
	var board_h: float = float(rows) * cell_px
	board_origin = Vector2(avail_left + (avail_w - board_w) * 0.5, 64.0 + (avail_h - board_h) * 0.5)
	board_vis_rect = Rect2(board_origin, Vector2(board_w, board_h))
	queue_redraw()


# ============ 动物伙伴「占位猫」的停靠（2026-09-29）============
#
# 伙伴是**纯装饰**：不参与任何规则，不吃输入（companion_pet 的 mouse_filter = IGNORE），
# 点击由下面的 _pet_touched() 用轮廓命中转发。故它坏了也绝不该影响对局 ——
# 所有对外调用都先判 _pet != null。

## 创建伙伴并挂进棋盘页。挂载点在绘画层之后、HUD 之前：伙伴不压 HUD/底栏，但压在棋盘之上
## （停靠区反正与棋盘不重叠，这个顺序只是保底）。
func _setup_pet() -> void:
	_pet = PetScript.new()
	add_child(_pet)
	_sync_pet(get_viewport_rect().size)


## 伙伴停靠区：棋盘右边缘 → HUD 右列保留线之间那条竖带，纵向与棋盘可用区同高。
## 宽度可能 ≤ 0（棋盘很宽时）；调用方据 PET_MIN_W 判定要不要显示伙伴。
func _pet_dock_rect(vp: Vector2) -> Rect2:
	var avail_h: float = vp.y - 64.0 - 64.0 - 48.0
	var left: float = board_vis_rect.end.x + PET_EDGE
	var right: float = vp.x - HUD_SIDE_RESERVE - PET_EDGE
	return Rect2(Vector2(left, 64.0), Vector2(maxf(right - left, 0.0), maxf(avail_h, 0.0)))


## 把伙伴摆进停靠区：**右下角对齐** —— 与棋盘共用同一条「地面线」，读起来是「站在棋盘边上
## 的伙伴」而不是「浮在半空的图标」。宽度取停靠区宽（上限 PET_W），高度按骨架长宽比推。
##
## 高宽比必须走 companion_rig.ASPECT（= 1661.18/1293.24 = 1.2845，真机骨架包围盒实测）：
## 硬编码 0.78 之类的近似值会让猫看起来「胖了一圈」，而 companion_pet._screen_xf 是等比
## 缩放的 —— 比例不符时它只会留白，于是误差表现为「猫比预留框小」，很难反查。
func _sync_pet(vp: Vector2) -> void:
	if _pet == null:
		return
	var dock := _pet_dock_rect(vp)
	if dock.size.x < PET_MIN_W or dock.size.y <= 0.0:
		# 空间不够：直接隐藏。硬塞会得到一只被压扁、或被棋盘盖掉一半的猫 ——
		# 那比没有猫更糟（伙伴是装饰，不是信息）。
		_pet.visible = false
		_sync_pet_frozen()
		return
	var w: float = minf(dock.size.x, PET_W)
	var h: float = w / maxf(RIGDATA.ASPECT, 0.0001)
	_pet.size = Vector2(w, h)
	_pet.position = Vector2(dock.position.x, dock.position.y + dock.size.y - h)
	_pet.visible = true
	_sync_pet_frozen()


## 暂停 / 终局时冻结伙伴：它是个活物，暂停面板开着还继续眨眼会立刻出卖「这是装饰」。
## 反过来也成立 —— 终局揭晓时它还在若无其事地甩尾巴，观感上是「不关心玩家」。
func _sync_pet_frozen() -> void:
	if _pet != null:
		_pet.frozen = GameSession.state != GameSession.State.PLAYING


## GameSession.game_ended 的伙伴侧接收端（终局 → 冻结）。
func _on_game_ended_for_pet(_won: bool) -> void:
	_sync_pet_frozen()


## 点伙伴 = 摸它一下（真机规格书的 track 5 / IdleClick）。
## 用**轮廓命中**（companion_pet.hit_test）而不是控件矩形：停靠区里的空白角落必须放行，
## 否则那一片死区会把本该落到棋盘上的点击吞掉。
func _pet_touched() -> bool:
	if _pet == null or not _pet.visible:
		return false
	if not _pet.hit_test(get_global_mouse_position()):
		return false
	_pet.trigger_click()
	return true




# ============ 几何抽象（矩形 / 蜂窝两套坐标映射的唯一出口） ============

## 当前盘面是否按蜂窝（六边形）几何排布。唯一判据 = 邻接表的 style == "hex"
## （ShapeGenerator.build_hex / 落盘 topology.style 得来）。矩形关卡与旧异形拓扑恒 false
## ⇒ 本文件其余分支全部走原路径，行为零变化。
func _hex_layout() -> bool:
	if _custom_layout():
		return false   # 自定义多边形盘优先（见 _custom_layout 的优先级说明）
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return false
	var g: GridInterface = b.grid
	return g is AdjacencyGrid and (g as AdjacencyGrid).has_hex_layout()


# ============ 自定义多边形盘：判据 / 查表 / 世界→屏幕 ============

## 当前盘面是否按数据驱动的自定义多边形排布（T-D2）。判据 = board 上挂了**非空**的
## custom_shapes 字典（且含非空 cells）——level_loader 在 load_level 后注入 meta。
## 矩形/蜂窝关卡没有这条 meta ⇒ 恒 false ⇒ 本文件其余分支零变化。
## 优先级：自定义盘 > 蜂窝（_hex_layout() 因此返回 false）。两者本是互斥数据；若真同现，
## 以更具体的 custom_shapes 为准。
func _custom_layout() -> bool:
	var cs := _custom_shapes()
	if cs.is_empty():
		return false
	var cells: Variant = cs.get("cells", null)
	return cells is Array and not (cells as Array).is_empty()


## board 上挂的 custom_shapes 字典（无 meta / 值非字典 → 空字典）。
## ⚠️ 必须先 has_meta 再 get_meta(name)（**不带默认值**）：Object.get_meta(name, default) 在
## 默认值恰为 null 时不生效（引擎按「没给默认值」处理）→ key 不存在时每帧刷一条
## "Method/function failed. Returning: Variant()" 引擎错误（本轮实测：矩形/蜂窝关卡每帧每格一条）。
func _custom_shapes() -> Dictionary:
	var b: Board = GameSession.board
	if b == null or not b.has_meta("custom_shapes"):
		return {}
	var cs: Variant = b.get_meta("custom_shapes")
	return cs if cs is Dictionary else {}


## 一个「格」的世界尺寸（custom_shapes.unit = 正六边形外径 2R）。缺字段 → 0。
func _custom_unit_world() -> float:
	return float(_custom_shapes().get("unit", 0.0))


## 世界单位 → 屏幕像素的比例（px / 世界单位）= unit_px / unit。
func _custom_scale() -> float:
	return _custom_unit_px / maxf(_custom_unit_world(), 0.0001)


## 世界点 → 屏幕点（自定义盘唯一的坐标变换出口）。
func _custom_world_to_screen(w: Vector2) -> Vector2:
	return board_origin + w * _custom_scale()


## 查一格的自定义几何（缓存查表；缺格/数据不合法 → 空字典）。
func _custom_cell(pos: Vector2i) -> Dictionary:
	_ensure_custom_cache()
	return _custom_cells.get(pos, {})


## 重建查表缓存（每次换 Board 只建一次；绘制与命中测试共用同一份）。
## poly 存**世界绝对坐标**（center + 相对顶点）⇒ 绘制时每顶点只乘一个 scale。
## apothem = 相对顶点多边形对格心的内切圆半径（供数据自检与内容盒使用）。
## 缓存键 = board 实例 id：Board 每次 start/restart/restore 都是新实例（见 _connect_board），
## 而 custom_shapes 是随关卡 JSON 一次性载入的**不可变**数据 ⇒ 换 board 即换关，缓存必失效。
## （Dictionary 不是 Object，取不到实例 id，也不必取。）
func _ensure_custom_cache() -> void:
	var cs := _custom_shapes()
	if cs.is_empty():
		return
	var b: Board = GameSession.board
	if b == null:
		return
	var key: int = b.get_instance_id()
	if key == _custom_cache_key and not _custom_cells.is_empty():
		return
	_custom_cache_key = key
	_custom_cells.clear()
	for c in (cs.get("cells", []) as Array):
		if not (c is Dictionary):
			continue
		var d: Dictionary = c
		if not (d.has("x") and d.has("y") and d.has("center") and d.has("poly")):
			continue
		# 坏数据防御（2026-09-25 审计）：此前只查「键存在」，不查**类型** —— 若 MOD/手写关卡
		# 把 center 写成数字、或 poly 元素写成标量，`var ctr: Array = d["center"]` 赋值即抛错；
		# 而本函数在 _layout 路径上被 _draw 依赖 ⇒ 整帧不绘制（视觉等同卡死）。
		# 这里显式判类型，坏格跳过（宁可少画一格，也不能整盘不画）。
		var ctr_v: Variant = d["center"]
		var rel_v: Variant = d["poly"]
		if not (ctr_v is Array) or not (rel_v is Array):
			continue
		var ctr: Array = ctr_v
		var rel_arr: Array = rel_v
		if ctr.size() < 2 or rel_arr.size() < 3:
			continue
		if not (ctr[0] is float or ctr[0] is int) or not (ctr[1] is float or ctr[1] is int):
			continue
		var center := Vector2(float(ctr[0]), float(ctr[1]))
		var rel := PackedVector2Array()
		var bad_poly := false
		for v in rel_arr:
			if not (v is Array) or (v as Array).size() < 2:
				bad_poly = true
				break
			var vv: Array = v
			if not (vv[0] is float or vv[0] is int) or not (vv[1] is float or vv[1] is int):
				bad_poly = true
				break
			rel.append(Vector2(float(vv[0]), float(vv[1])))
		if bad_poly:
			continue
		var abs_poly := PackedVector2Array()
		for v in rel:
			abs_poly.append(center + v)
		_custom_cells[Vector2i(int(d["x"]), int(d["y"]))] = {
			"center": center,
			"poly": abs_poly,
			"rel": rel,
			"hl": d.get("hl", []),
			"taper": d.get("taper", []),
			"apothem": custom_apothem(rel),
			"group": str(d.get("group", "")),   # 颜色分组（Tametsi 多色分区；"" = 不属任何组）
		}


## 自定义盘的「内容盒」：以格心为中心、cell_px 见方的矩形。
## 与蜂窝路径的「内接正方形」同角色（内容定位 + 动效收缩基准），但**不用于填充**——填充由
## 多边形承担（见 _draw_cell 的 poly_filled）：矩形填充会越出多边形边线、盖住格与格之间的缝。
## 为什么不用 _cell_rect（外接矩形）：五边形外接矩形 ≈ 33×59 世界单位、且左上角不在格内
## （格心偏在矩形右侧），旗子/问号按「48px 基准坐标 × scale」从矩形左上角摆放会被顶到格角外；
## 方盒以格心为中心 ⇒ 内容居中、旗子落在格内（与蜂窝盘内接正方形的居中口径一致）。
func _custom_content_rect(pos: Vector2i) -> Rect2:
	var s := float(cell_px)
	return Rect2(_cell_center(pos) - Vector2(s, s) * 0.5, Vector2(s, s))


## 每「棋盘单位」的像素数（棋盘单位 = 1 格的坐标步长）。
## 矩形路径：1 单位 = 1 格 = cell_px（于是 _cell_center 与旧式 board_origin + (c,r)*cell_px 逐像素等价）。
## 蜂窝路径：1 单位 = 原版晶格单位（0.75 / √3÷4 的格心步长、0.475 的外接半径都以它为单位）。
## 自定义盘：1 单位 = 1 格世界尺寸（= 世界坐标 / unit，见文件头口径）。
func _unit_px() -> float:
	if _custom_layout():
		return _custom_unit_px
	return _hex_unit_px if _hex_layout() else float(cell_px)


## 格心（像素）。矩形路径 = 原格矩形中心；蜂窝路径 = 六边形格心；自定义盘 = 世界格心 × scale。
func _cell_center(pos: Vector2i) -> Vector2:
	if _custom_layout():
		var c := _custom_cell(pos)
		if c.is_empty():
			return board_origin   # 数据缺该格（不该发生）：退化为原点，绝不崩
		return _custom_world_to_screen(c["center"])
	if _hex_layout():
		return hex_center_px(pos, _hex_unit_px, board_origin)
	return board_origin + Vector2(pos.x, pos.y) * float(cell_px) + Vector2(cell_px, cell_px) * 0.5


## 格位绘制矩形（_draw_cell 与全部覆盖层共用）。
## 矩形路径 = **原实现原式**（逐像素等价）；蜂窝路径 = 以格心为中心的内接正方形（见 HEX_SQ_HALF）；
## 自定义盘 = 该格多边形的**外接矩形**（世界包围盒 × scale）。自定义盘没有「格宽×格高」可言，
## 外接矩形只有两个用途：命中测试粗筛（_pick_custom）与外部核对；
## **填充与内容定位分别由多边形和 _custom_content_rect 承担**（说明见那两个函数的注释）。
func _cell_rect(pos: Vector2i) -> Rect2:
	if _custom_layout():
		var c := _custom_cell(pos)
		if c.is_empty():
			return Rect2(_cell_center(pos), Vector2.ZERO)
		var poly: PackedVector2Array = c["poly"]
		var sc := _custom_scale()
		var lo: Vector2 = poly[0]
		var hi: Vector2 = poly[0]
		for v in poly:
			lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.y))
			hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.y))
		return Rect2(board_origin + lo * sc, (hi - lo) * sc)
	if not _hex_layout():
		return Rect2(board_origin + Vector2(pos.x, pos.y) * cell_px, Vector2(cell_px, cell_px))
	var s := 2.0 * HEX_SQ_HALF * _unit_px()
	return Rect2(_cell_center(pos) - Vector2(s, s) * 0.5, Vector2(s, s))


## 格子的多边形轮廓：蜂窝 = 6 顶点六边形；自定义盘 = 数据给的 5/6 顶点多边形（顺序即绕序）；
## 其余 = 该格矩形的 4 角（顺时针）。
func _cell_polygon(pos: Vector2i) -> PackedVector2Array:
	if _custom_layout():
		var c := _custom_cell(pos)
		if c.is_empty():
			return PackedVector2Array()
		var sc := _custom_scale()
		var out := PackedVector2Array()
		for v in (c["poly"] as PackedVector2Array):
			out.append(board_origin + v * sc)
		return out
	if _hex_layout():
		return hex_polygon_px(pos, _hex_unit_px, board_origin)
	var r := _cell_rect(pos)
	return PackedVector2Array([
		r.position,
		r.position + Vector2(r.size.x, 0.0),
		r.position + r.size,
		r.position + Vector2(0.0, r.size.y),
	])


## 覆盖层用多边形：格子轮廓按「顶点向格心收缩 inset 像素」后的形态（inset=0 = 原轮廓）。
## 用于把 hover / hint / reject / 光标 / 波浪等**颜色覆盖层**画成与格子同形——此前它们统一
## 用 _cell_rect（蜂窝的**内接正方形**），蜂窝盘上会看到「六边形格子里顶着一个方块」。
func _cell_polygon_inset(pos: Vector2i, inset: float) -> PackedVector2Array:
	var poly := _cell_polygon(pos)
	if inset <= 0.0:
		return poly
	var c := _cell_center(pos)
	var out := PackedVector2Array()
	for p in poly:
		var d: Vector2 = p - c
		var l := d.length()
		if l > 0.0:
			out.append(c + d * (maxf(0.0, l - inset) / l))
		else:
			out.append(p)
	return out


## 填充一个格子（覆盖层用）：蜂窝 = 六边形多边形；自定义盘 = 数据多边形；
## 矩形 = 圆角瓦片（CozyStyle 主题）/ 原 draw_rect（其余主题逐像素不变），见 _draw_tile。
func _draw_cell_fill(pos: Vector2i, col: Color) -> void:
	if _hex_layout() or _custom_layout():
		var poly := _cell_polygon(pos)
		if poly.size() >= 3:   # 自定义盘缺格数据 → 不画，绝不臆造形状
			draw_colored_polygon(poly, col)
		return
	_draw_tile(_cell_rect(pos), col)


## 描边一个格子（覆盖层用）：蜂窝/自定义盘 = 沿该格多边形折线（顶点向格心内缩 inset）；
## 矩形 = Cozy 走同形圆角描边 / 其余主题走原 rect.grow(-inset) 方角描边（逐像素不变）。
func _draw_cell_outline(pos: Vector2i, col: Color, width: float, inset: float = 0.0) -> void:
	if _hex_layout() or _custom_layout():
		var poly := _cell_polygon_inset(pos, inset)
		if poly.size() < 3:
			return
		var closed := poly.duplicate()
		closed.append(closed[0])   # draw_polyline 画折线，需手动闭合
		draw_polyline(closed, col, width)
		return
	_draw_tile_outline(_cell_rect(pos), col, width, inset)


# ============ 变体纹理（格子内的主题徽记） ============
## 目的：让「这一盘是哪个变体 / 哪一族形状」在**不看数字**时也能认出 —— 这是颜色之外的
## **第二条识别通道**（同色系相邻关卡、色觉障碍玩家都受益；也是「每个变体有独特外观」的落点）。
##
## 数据：`palette.texture` 的字符串值，TEXTURE_MARKS 是唯一登记表（新增标记要同时进表与测试）。
## 几何：徽记一律画在**内容盒内部**（自定义/蜂窝盘的内容盒是内接正方形，见 _custom_content_rect），
##      外半径取盒宽的 0.21 ⇒ 离多边形边界还有余量，**绝不会溢出格子**。
## 只画 HIDDEN 格：翻开格已经有数字，再叠纹理是噪声。
## **零回归**：palette 无 texture（含全部矩形经典关）⇒ 一次绘制都不发生。

const TEXTURE_MARKS: Array[String] = [
	"forbid",   # ⊘ 局部禁形（s1）
	"anchor",   # ◎ 稳固锚点（s2）
	"spore",    # ✳ 散开的孢子（s3）
	"strata",   # ☰ 岩层横纹（s4 / 挖洞族）
	"chain",    # ‖ 成排竖链（s5）
	"parity",   # ◺ 半格奇偶（s6）
	"block",    # ▦ 分块田字（s7）
	"trail",    # ⌇ 足迹折线（z2）
	"quad",     # ⊞ 四象限十字（z3；与 block 的四个小方块刻意区分）
	"pip",      # ∴ 骰点（dt）
	"comb",     # ⬡ 蜂窝轮廓（蜂窝族）
	"weave",    # ✕ 编织菱格（方格风格 / 吉里赫 / 三角族）
	"halo",     # ◇ 图案光圈（艺术图案族）
	"petal",    # ❁ 花瓣（雏菊链）
	"cube",     # ⬒ 等轴立方（等轴族）
	"octa",     # ⯃ 八角轮廓（截角方形镶嵌）
	"ring",     # ◎ 同心环（环盘族）
]


## 本关纹理标记（palette.texture）。未声明或未登记 → 空串（不画，静默降级）。
func _theme_texture() -> String:
	var t: Variant = _custom_palette().get("texture", "")
	var s := str(t) if t is String else ""
	return s if TEXTURE_MARKS.has(s) else ""


## ==== 纹理呼吸（缓慢的 alpha 脉动）====
## **刻意不用 _process 驱动**：本控件的 _process 在无动效时会 `set_process(false)`（静态棋盘
## 不逐帧醒来，见 _process 末尾的性能条款）。若把脉动挂进 _process，就等于让每一盘
## 永远每帧重绘 200+ 格 —— 为一个装饰效果付整盘帧率，不划算。
## 改用 0.2s 的低频 Timer：3 秒一个呼吸周期 = 15 帧/周期，肉眼足够平滑，重绘量只有 5fps。
const TEX_PULSE_STEP_S := 0.2
const TEX_PULSE_PERIOD_S := 3.0
## 呼吸的基准不透明度与幅度（0.20~0.40）：幅度再大就会干扰读数字。
const TEX_ALPHA_BASE := 0.30
const TEX_ALPHA_SWING := 0.10

## 每个徽记的**专属呼吸节拍**（x = 周期秒数，y = 摆动幅度）。
##
## 为什么逐标记给参数：若所有变体共用同一个 3 秒节奏，动效就只是**全局装饰**；
## 而这一层的目的是让玩家不看数字也能感到「这盘不一样」—— **节奏本身就是变体身份的一部分**，
## 与颜色、几何、徽记形状并列。
##
## 分配原则（对照各自语义，不是随机数值）：
##   · 警示类快而大 —— 局部禁形 2.2s/±0.16，急促让人警觉
##   · 稳固类慢而小 —— 重心 4.2s/±0.07、四象 3.6s/±0.10，沉稳得像锚住不动
##   · 交替类最快 —— 度偶数 2.0s/±0.17（"奇偶交替"的动感）
##   · 流动类中速 —— 足迹 2.8s、编织 3.4s，像在走 / 在织
##   · 厚重类最慢 —— 洋葱 4.6s、同心环 4.8s，层层压着
##
## 取值全部落在测试门禁的安全带内：base 0.30 ± 最大 0.17 ⇒ [0.13, 0.47] ⊂ [0.10, 0.55]。
const TEX_PULSE_BY_MARK := {
	# —— 变体轴 ——
	"forbid": Vector2(2.2, 0.16),   # 局部禁形：急促
	"anchor": Vector2(4.2, 0.07),   # 重心：几乎不动
	"spore": Vector2(2.6, 0.15),    # 无环：飘散
	"strata": Vector2(4.6, 0.09),   # 洋葱：厚重
	"chain": Vector2(3.0, 0.12),    # 行列凸：规律
	"parity": Vector2(2.0, 0.17),   # 度偶数：交替（最快）
	"block": Vector2(4.0, 0.08),    # 分量数 K：块状稳定
	"trail": Vector2(2.8, 0.13),    # 相邻行锁：行进
	"quad": Vector2(3.6, 0.10),     # 四象：对称
	"pip": Vector2(2.4, 0.12),      # 骨牌边界：轻快
	# —— 形状族 ——
	"comb": Vector2(3.2, 0.11),     # 蜂窝
	"weave": Vector2(3.4, 0.10),    # 编织
	"halo": Vector2(4.0, 0.14),     # 图案光圈：大而慢
	"petal": Vector2(3.8, 0.13),    # 花瓣
	"cube": Vector2(4.4, 0.09),     # 等轴立方：慢
	"octa": Vector2(3.6, 0.10),     # 八角
	"ring": Vector2(4.8, 0.12),     # 同心环：最慢
}
## 未登记标记 / 未指定标记时的节拍（沿用最初的统一口径）。
const TEX_PULSE_DEFAULT := Vector2(3.0, 0.10)

## ==== 触摸手势（2026-09-25 无障碍审计）====
## 此前零触摸处理，而 Godot 默认把触摸合成**左键** ⇒ 触屏永远无法插旗（丢一半操作）。
## 交互：短按 = 翻开；**长按 0.4s = 插旗**（触屏没有右键，这是移动端扫雷的通行方案），
## 长按已翻开的数字格 = 一键展开（与鼠标二次点击同口径）；拖动 = 取消长按。
const TOUCH_LONG_PRESS_MS := 400
## 触摸会**同时**合成鼠标事件（`emulate_mouse_from_touch` 必须保持开——否则触屏上所有
## 按钮失效）。故收到触摸后的这个窄窗口内，把随之而来的模拟鼠标事件吞掉，避免双触发。
const TOUCH_MOUSE_SUPPRESS_MS := 350
var _touch_timer: Timer = null
var _touch_pos := Vector2i(-1, -1)
var _touch_long_fired := false
var _last_touch_ms := -100000
## 语音可用性缓存（-1 未查 / 0 无 / 1 有；见 _speak）
var _tts_available := -1

var _tex_timer: Timer = null
## 本帧的纹理标记与颜色：由 _draw() 开头求值一次后缓存供逐格读取。
## 为什么缓存：_draw_cell_texture 每格调用一次，若每格都走 _theme_texture()
## 就是每帧 200+ 次 meta 查询 + 字典查找；且 _texture_color() 还含一次 sin。
## 5fps 下算不上瓶颈，但这条缓存是"一笔免掉"，没有理由不做。
var _tex_kind_now := ""
var _tex_col_now := Color(0, 0, 0, 0)


func _on_tex_pulse() -> void:
	# 特效可能被玩家在设置里**中途关掉**，而那一刻没有任何人回调 _sync_tex_timer
	# ⇒ 在这里自查一次：已关闭就停表，不再每 0.2s 空转重绘（重绘本身没害，但纯属白烧）。
	if not _reveal_effects_enabled():
		_sync_tex_timer()
		return
	queue_redraw()


## 按「本关是否有纹理 + 动效总闸」决定呼吸节拍是否运行（换关 / 初始化时调用）。
func _sync_tex_timer() -> void:
	if _tex_timer == null:
		return
	var want := _theme_texture() != "" and _reveal_effects_enabled()
	if want and _tex_timer.is_stopped():
		_tex_timer.start()
	elif not want and not _tex_timer.is_stopped():
		_tex_timer.stop()


## 当前呼吸相位对应的纹理不透明度（动效关闭时恒为基准值 = 完全静止）。
## `mark` 缺省 = 用统一口径（旧签名兼容：既有测试与调用点都只传前两个参数）。
func texture_alpha_at(ms: int, pulsing: bool, mark: String = "") -> float:
	if not pulsing:
		return TEX_ALPHA_BASE
	var beat: Vector2 = TEX_PULSE_BY_MARK.get(mark, TEX_PULSE_DEFAULT)
	var period := beat.x
	var swing := beat.y
	var t := fmod(float(ms) / 1000.0, period) / period
	return TEX_ALPHA_BASE + swing * sin(t * TAU)


## 徽记颜色：palette.texture_tint 可覆盖；默认取格线色并压在基准 alpha 上 —— 同色系、低调，
## 不与数字/旗子抢注意力（它只负责"这一盘是哪个变体"的潜意识提示）。
## 动效总闸开启时叠一层缓慢呼吸（见 texture_alpha_at）；显式 tint 则原样返回不带呼吸
## —— 作者显式指定的颜色不该被我们偷偷改透明度。
func _texture_color() -> Color:
	var override := _pal_color("texture_tint", Color(0, 0, 0, 0))
	if override.a > 0.0:
		return override
	var base := _pal_color("tile_border", ThemeManager.grid_line())
	# 传本关的徽记名 → 取该徽记的专属节拍（见 TEX_PULSE_BY_MARK）
	var a := texture_alpha_at(Time.get_ticks_msec(), _reveal_effects_enabled(), _tex_kind_now)
	return Color(base.r, base.g, base.b, a)


## 画一格的变体徽记。`rect` 必须是**内容盒**（调用方已按盘型算好）；
## 只对 HIDDEN 格生效，无 texture 时空操作。
func _draw_cell_texture(cell: Cell, rect: Rect2, scale: float) -> void:
	# kind / col 取 _draw() 本帧算好的缓存（本函数每格调用一次，见 _tex_kind_now 处注释）
	var kind := _tex_kind_now
	if kind == "" or cell == null or cell.state != Cell.State.HIDDEN:
		return
	var r := minf(rect.size.x, rect.size.y) * 0.21
	if r < 2.5:
		return                                   # 格子太小：宁可留白，也不要糊成一团
	var col := _tex_col_now
	var c := rect.get_center()
	var w := maxf(1.0, scale)
	match kind:
		"forbid":
			draw_arc(c, r, 0.0, TAU, 24, col, w * 1.4)
			var d := Vector2(r, r) * 0.72
			draw_line(c - d, c + d, col, w * 1.4)
		"anchor":
			draw_arc(c, r, 0.0, TAU, 24, col, w)
			draw_arc(c, r * 0.52, 0.0, TAU, 18, col, w)
			draw_circle(c, r * 0.16, col)
		"spore":
			draw_circle(c, r * 0.26, col)
			for k in 4:
				var a := TAU * float(k) / 4.0 + PI * 0.25
				var dir := Vector2(cos(a), sin(a))
				draw_line(c + dir * r * 0.5, c + dir * r, col, w)
		"strata":
			for k in 3:
				var y := c.y + (float(k) - 1.0) * r * 0.62
				draw_line(Vector2(c.x - r, y), Vector2(c.x + r, y), col, w)
		"chain":
			for k in 2:
				var x := c.x + (float(k) * 2.0 - 1.0) * r * 0.45
				draw_line(Vector2(x, c.y - r), Vector2(x, c.y + r), col, w * 1.3)
		"parity":
			draw_colored_polygon(PackedVector2Array([
					c + Vector2(-r, -r), c + Vector2(r, r), c + Vector2(-r, r)]), col)
		"block":
			for k in 4:
				var o := Vector2(float(k % 2) * 2.0 - 1.0, float(k / 2) * 2.0 - 1.0) * r * 0.5
				var s2 := Vector2(r * 0.34, r * 0.34)
				draw_rect(Rect2(c + o - s2, s2 * 2.0), col, false, w)
		"trail":
			draw_polyline(PackedVector2Array([
					c + Vector2(-r, r * 0.62), c + Vector2(-r * 0.28, -r * 0.2),
					c + Vector2(r * 0.34, r * 0.3), c + Vector2(r, -r * 0.78)]), col, w * 1.2)
		"quad":
			# 四象限（z3）：十字分割 + 中心点。
			# 注意**不能**画成四个小方块 —— 那是 s7 的 "block"，两个徽记会看不出区别。
			draw_line(Vector2(c.x - r, c.y), Vector2(c.x + r, c.y), col, w)
			draw_line(Vector2(c.x, c.y - r), Vector2(c.x, c.y + r), col, w)
			draw_circle(c, r * 0.16, col)
		"pip":
			draw_circle(c + Vector2(-r * 0.46, -r * 0.46), r * 0.26, col)
			draw_circle(c + Vector2(r * 0.46, r * 0.46), r * 0.26, col)
		"comb":
			var hp := PackedVector2Array()
			for k in 6:
				var a := TAU * float(k) / 6.0 - PI * 0.5
				hp.append(c + Vector2(cos(a), sin(a)) * r)
			hp.append(hp[0])                      # draw_polyline 不闭合，手动回起点
			draw_polyline(hp, col, w)
		"weave":
			draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, w)
			draw_line(c + Vector2(-r, r), c + Vector2(r, -r), col, w)
		"halo":
			var dia := PackedVector2Array([
					c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
			dia.append(dia[0])
			draw_polyline(dia, col, w)
		"petal":
			for k in 4:
				var a := TAU * float(k) / 4.0
				draw_circle(c + Vector2(cos(a), sin(a)) * r * 0.52, r * 0.30, col)
		"cube":
			var top := c + Vector2(0, -r)
			var mid := c + Vector2(0, -r * 0.1)
			draw_line(top, mid, col, w)
			draw_line(mid, c + Vector2(-r * 0.85, r * 0.62), col, w)
			draw_line(mid, c + Vector2(r * 0.85, r * 0.62), col, w)
			draw_line(mid, c + Vector2(0, r * 0.62), col, w)
		"octa":
			var op := PackedVector2Array()
			for k in 8:
				var a := TAU * float(k) / 8.0 - PI * 0.5
				op.append(c + Vector2(cos(a), sin(a)) * r)
			op.append(op[0])
			draw_polyline(op, col, w)
		"ring":
			draw_arc(c, r, 0.0, TAU, 24, col, w)
			draw_arc(c, r * 0.55, 0.0, TAU, 18, col, w)


# ============ 配色（自定义盘的 palette；无 palette 时逐项回退 ThemeManager） ============
# 口径：palette 只在**自定义多边形盘**上生效，且逐键回退主题色 ⇒ 矩形/蜂窝路径的取色
# 与改动前逐像素一致（这是「不得回归」的结构性保证）。

## 关卡配色表（关卡 JSON 的 palette；无 meta / 非字典 → 空字典）。
##
## ⚠️ 2026-09-22 修正：此处**不再要求自定义几何**。此前这行是 `if not _custom_layout(): return {}`，
## 而 `_custom_layout()` 要求关卡带非空 custom_shapes ⇒ 走 style 分支的关卡（hex / 挖洞方格）
## 即使声明了 palette 和 groups，取色也全部落空：实测 16 关（va_hex_* 9 + va_holed_* 7）、
## 395 个已分组格、48 条分组色声明被整条丢弃 —— 棋盘仍是主题灰，而分色雷数计数器
## 照样建出来（它的条件只看 groups 是否为空），于是色块全是透明的。
## palette 描述的是「这盘用什么颜色」，与「几何从哪来」无关，故解耦。
## 矩形关卡不写 palette 字段 ⇒ meta 为 null ⇒ 仍走主题色，行为零变化。
##
## 入口提成**静态纯函数**（下面两个）：一是单测不必起整棵场景树就能锁住「palette 会被采用」，
## 二是静态函数拿不到 `_custom_layout()`，那条耦合在结构上就加不回来了。
static func palette_of(board: Board) -> Dictionary:
	if board == null or not board.has_meta("palette"):
		return {}
	var p: Variant = board.get_meta("palette")
	return p if p is Dictionary else {}


## 从 palette 字典取某个键的颜色（纯函数，无实例状态）。
## 取值支持两种形式（见 core/palette_color.gd）：
##   · RGB 数组 [r,g,b] —— 既有 57 关的手写口径
##   · 色码字符串 "BLUE" / "PINK_DARK" —— 走派生化，自动带对比度保证
## 逐级回退：显式键 → palette.theme 派生 → 调用方给的 fallback（主题色）。
## 不抛错、不臆造：mod 关卡给了畸形 palette 也只会退回主题色。
static func resolve_palette_color(palette: Dictionary, key: String, fallback: Color) -> Color:
	if not palette.is_empty() and palette.has(key):
		var c := PaletteColor.parse(palette[key])
		if c.a > 0.0:
			return c
	var t: Variant = palette.get("theme", "")
	if t is String and (t as String) != "":
		var tc := PaletteColor.theme_color(t as String, key)
		if tc.a > 0.0:
			return tc
	return fallback


func _custom_palette() -> Dictionary:
	return palette_of(GameSession.board)


## 取 palette 中的颜色（实例侧薄封装，见上面的静态实现）。
func _pal_color(key: String, fallback: Color) -> Color:
	return resolve_palette_color(_custom_palette(), key, fallback)


## 本关的主题色码（palette.theme）。空串 = 未声明主题，全部走 fallback/显式键。
func _theme_code() -> String:
	var t: Variant = _custom_palette().get("theme", "")
	return str(t) if t is String else ""


## 未翻开格底色（palette.tile / 主题隐藏色）。
func _cell_hidden_color() -> Color:
	return _pal_color("tile", ThemeManager.cell_hidden())


## 已翻开格底色（palette.revealed / 主题已翻开色）。
func _cell_revealed_color() -> Color:
	return _pal_color("revealed", ThemeManager.cell_revealed())


## 格子轮廓线色（palette.tile_border / 主题网格线色）。
func _outline_color() -> Color:
	return _pal_color("tile_border", ThemeManager.board_grid())


## 格子底色（与 _draw_cell 的状态分支同口径；REVEALED 时含 pop 颜色插值）。
## 蜂窝/自定义盘下先由 _draw() 填多边形本体、再让 _draw_cell 填内容盒（或跳过矩形底）——
## 两处必须同色，否则会看到「多边形里嵌着一个方块」。
func _cell_base_color(pos: Vector2i, cell: Cell, pop_e: float) -> Color:
	var base := _cell_hidden_color()
	if cell.state == Cell.State.FLAGGED:
		base = _pal_color("flagged_tile", _cell_hidden_color())
	elif cell.state == Cell.State.REVEALED:
		base = _cell_revealed_color()
		if pop_e < 1.0:
			base = _cell_hidden_color().lerp(base, pop_e)
	# 分色棋盘（复刻 Tametsi 的多色分区）：格子属于某颜色分组 → 用该组色。
	# 翻开格压暗 45%：亮色底 + 白数字会糊成一片（黄 #DAD200 尤其明显）。
	var g := _custom_group(pos)
	if g != "":
		var gc := _group_color(g)
		if gc.a > 0.0:
			base = gc.darkened(0.45) if cell.state == Cell.State.REVEALED else gc
	return base


## 关卡的颜色分组数据（两种来源，2026-09-21 起）：
##   · custom_shapes.cells[].group —— 数据驱动多边形盘（如雏菊链复刻，几何与分组同一份数据）
##   · level.groups.cells{"x,y": 组名} —— **参数化形状**（蜂窝 / 挖洞方格 + 环层分色）：
##     几何仍走 style 分支（hex/方阵公式），分组单独一张轻表，避免为分色复制一份几何。
func _level_groups() -> Dictionary:
	var b: Board = GameSession.board
	if b == null or not b.has_meta("groups"):
		return {}
	var g: Variant = b.get_meta("groups")
	return g if g is Dictionary else {}


## 该格所属的颜色分组（"" = 不属于任何分组）：先查数据驱动盘，再查参数化形状的 groups 表。
func _custom_group(pos: Vector2i) -> String:
	if _custom_layout():
		var c := _custom_cell(pos)
		var g1 := str(c.get("group", ""))
		if g1 != "":
			return g1
	var cells: Variant = _level_groups().get("cells", null)
	if cells is Dictionary:
		return str((cells as Dictionary).get("%d,%d" % [pos.x, pos.y], ""))
	return ""


## 分组色（关卡 palette.groups，值可以是 RGB 数组或色码串如 "YELLOW" / "PINK_DARK"）；
## 未定义 → 透明（调用方据此回退）。
## 注意这里**不走 _pal_color**：分组色没有"主题派生"这一层（主题只负责底色/文字/轮廓），
## 未声明就是未声明，回退到棋盘底色而不是拿主题色冒充某个分组。
func _group_color(name: String) -> Color:
	if name == "":
		return Color(0, 0, 0, 0)
	var groups: Variant = _custom_palette().get("groups", null)
	if not (groups is Dictionary):
		return Color(0, 0, 0, 0)
	return PaletteColor.parse((groups as Dictionary).get(name, null))


# ============ 分色雷数计数器（左上角浮层，紧贴 HUD「雷数」下方） ============
#
# 复刻 Tametsi 的「彩色分区 + 分色雷数」：棋盘被染成若干颜色区，按颜色列出
# 「该区还剩几颗雷没被标记 / 该区共有几颗雷」。它同时承担两个作用：
#   ① 好看（单色灰盘 → 多色图案）；
#   ② **额外线索**：某色区剩余归零时，该区剩下的未知格全部安全——原版高阶推理的抓手之一。
#
# 位置沿革（2026-09-22 用户决策）：原先在**右上角**，玩家视线要在「左上读总雷数、
# 右上读分色明细」之间来回跑；现移到左上角、紧贴 HUD「雷数 N」下方——总数用大字（28px）、
# 各色明细用小字（18px）竖排连成一块，一眼看全。仍是浮层（mouse_filter=IGNORE），
# 不会挡住棋盘点击。

var _group_panel: VBoxContainer = null
var _group_rows: Dictionary = {}      # group -> {"total": int, "label": Label}
var _group_dirty := true


## 建计数器（换关时先 _reset_group_panel，下一帧由 _refresh_group_panel 重建）。
func _ensure_group_panel() -> void:
	if _group_panel != null:
		return
	# 数据驱动盘（custom_shapes）与参数化形状（level.groups）都能有分组；
	# 两者都没有 ⇒ 这关没有分色，也就不需要计数器。
	if not _custom_layout() and _level_groups().is_empty():
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	# 每组雷数 = 该组内的雷颗数（按关卡数据的分组，静态不变）
	var totals: Dictionary = {}
	for m in board.get_mine_positions():
		var g := _custom_group(m)
		if g == "":
			continue
		totals[g] = int(totals.get(g, 0)) + 1
	if totals.is_empty():
		return
	# 左上角、紧贴 HUD「雷数 N」下方（2026-09-22 用户决策：总数与分色明细合并到同一角）。
	# 左缘 24 与 HUD._box.offset_left 对齐；顶栏高 64，故从 62 起 → 视觉上与「雷数」连成一块。
	# 宽度只约束换行边界（行内容左对齐，组多也不溢出）。
	var panel := VBoxContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 24
	panel.offset_right = 240
	panel.offset_top = 62
	panel.add_theme_constant_override("separation", 6)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE        # 浮层不得吃掉棋盘点击
	add_child(panel)
	_group_panel = panel
	for g in totals:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(18, 18)
		sw.color = _group_color(str(g))
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(sw)
		var lb := Label.new()
		lb.add_theme_font_size_override("font_size", 18)
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(lb)
		panel.add_child(row)
		_group_rows[str(g)] = {"total": int(totals[g]), "label": lb}
	_group_dirty = true


## 换关：销毁旧浮层（Board 换了 ⇒ 分组与雷数全变，不能沿用旧面板）。
func _reset_group_panel() -> void:
	if _group_panel != null:
		if is_instance_valid(_group_panel):
			_group_panel.queue_free()
		_group_panel = null
	_group_rows.clear()
	_group_dirty = true


## 刷新「剩余 / 总数」：剩余 = 该组雷数 − 该组已插旗数（与总雷数计数同口径）。
func _refresh_group_panel() -> void:
	_ensure_group_panel()
	if _group_panel == null or not _group_dirty:
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var flags: Dictionary = {}
	for p in board.grid.all_positions():
		var cell: Cell = board.grid.get_cell(p)
		if cell != null and cell.state == Cell.State.FLAGGED:
			var g := _custom_group(p)
			if g != "":
				flags[g] = int(flags.get(g, 0)) + 1
	for g in _group_rows:
		var rec: Dictionary = _group_rows[g]
		var total := int(rec["total"])
		# 与顶栏**同口径**（2026-09-25 审计）：允许为负 = 该色旗标多了。
		# 原先这里 clamp 到 0，于是「多标 2 面」显示成「0 / N」——看起来像刚好标完，
		# 与顶栏的「剩余雷数 -2」互相矛盾。
		var left := total - int(flags.get(g, 0))
		var lb: Label = rec["label"]
		var txt := "%d / %d" % [left, total] if left >= 0 else "%d / %d（多了）" % [left, total]
		if lb.text != txt:
			lb.text = txt
		# 多标 = 明确的错误信号，用危险色（正常态仍用组色）
		lb.add_theme_color_override("font_color",
				ThemeManager.danger() if left < 0 else _group_color(g).lightened(0.3))
	_group_dirty = false


# ============ 蜂窝几何纯函数（static：渲染与单测共用同一份公式，可脱离场景树验证） ============

## 格心（晶格单位，与像素无关）：cx = 0.75*(x+y)、cy = (√3/4)*(x−y)。
static func hex_center_lattice(pos: Vector2i) -> Vector2:
	return Vector2(HEX_CX * float(pos.x + pos.y), HEX_CY * float(pos.x - pos.y))


## 格心（像素）= origin + 晶格坐标 × unit_px。
static func hex_center_px(pos: Vector2i, unit_px: float, origin: Vector2) -> Vector2:
	return origin + hex_center_lattice(pos) * unit_px


## 六边形 6 顶点（晶格单位，相对格心；顺序照原版：右 → 右上 → 左上 → 左 → 左下 → 右下）。
static func hex_vertex_units() -> PackedVector2Array:
	var r := HEX_R
	var h := HEX_SPACING * HEX_R   # (√3/2)R：上下两条水平边距格心的距离
	return PackedVector2Array([
		Vector2(r, 0.0),
		Vector2(r * 0.5, -h),
		Vector2(-r * 0.5, -h),
		Vector2(-r, 0.0),
		Vector2(-r * 0.5, h),
		Vector2(r * 0.5, h),
	])


## 某格的六边形顶点（像素）。shrink ≤ 1 时绕格心等比收缩——复用 wave / pop 已算好的收缩比，
## 让动效在蜂窝盘上也「看得见」（不改动那两个状态机本身）。
static func hex_polygon_px(pos: Vector2i, unit_px: float, origin: Vector2, shrink: float = 1.0) -> PackedVector2Array:
	var c := hex_center_px(pos, unit_px, origin)
	var out := PackedVector2Array()
	for v in hex_vertex_units():
		out.append(c + v * unit_px * shrink)
	return out


## 格心范围的包围盒（晶格单位）：position = 最小格心，size = 跨度。
static func hex_lattice_bounds(positions: Array) -> Rect2:
	if positions.is_empty():
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var min_c := Vector2(INF, INF)
	var max_c := Vector2(-INF, -INF)
	for p: Vector2i in positions:
		var c := hex_center_lattice(p)
		min_c = Vector2(minf(min_c.x, c.x), minf(min_c.y, c.y))
		max_c = Vector2(maxf(max_c.x, c.x), maxf(max_c.y, c.y))
	return Rect2(min_c, max_c - min_c)


## 蜂窝盘的视觉包围盒尺寸（晶格单位）= 格心跨度 + 六边形外扩（左右各 R、上下各半高 (√3/2)R）。
## 注意：**不能**用 grid.size()（= size×size 包围盒方阵）——六边形盘的 bbox 四角大半是盘外格，
## 按 bbox 分配空间会让盘明显偏小、留白全堆在四个角。
static func hex_visual_span(positions: Array) -> Vector2:
	var b := hex_lattice_bounds(positions)
	if b.size == Vector2.ZERO:
		return Vector2.ZERO
	return b.size + Vector2(2.0 * HEX_R, 2.0 * HEX_HALF_H)


## 蜂窝布局（纯函数）：在 avail_w×avail_h 的可用区域里按视觉跨度做 scale-to-fit，并居中。
## 返回 {unit_px, origin, span, cell_px, vis_rect}：
##   unit_px —— 每晶格单位像素数；origin —— 晶格原点（格心 = origin + 晶格坐标×unit）；
##   span    —— 视觉跨度（晶格单位，便于核对/报告）；cell_px —— 内接正方形边长（像素，= 渲染用的 cell_px）；
##   vis_rect —— **实绘的屏幕包围盒**（= origin + 外扩后的视觉包围盒）。
## ⚠️ origin ≠ vis_rect.position：origin 是「晶格坐标 0」落在屏幕哪里，而晶格坐标 0 未必
## 就是最左/最上的格子（异形盘的最小坐标可以不是 0）。任何要"棋盘画在哪、多宽"的调用方
## （现在就一处：伙伴停靠区）都必须用 vis_rect，用 origin 会在异形盘上偏掉半个外扩量。
static func hex_layout_for(positions: Array, avail_w: float, avail_h: float, center: Vector2) -> Dictionary:
	var span := hex_visual_span(positions)
	if span.x <= 0.0 or span.y <= 0.0:
		return {"unit_px": 0.0, "origin": center, "span": Vector2.ZERO, "cell_px": 0,
				"vis_rect": Rect2(center, Vector2.ZERO)}
	var unit := minf(avail_w / span.x, avail_h / span.y)
	var sq := 2.0 * HEX_SQ_HALF * unit
	if sq < float(MIN_CELL_PX):
		# 与矩形路径的 24px 下限同口径：窗口极小时宁可溢出，也不把格子缩成一团糊。
		sq = float(MIN_CELL_PX)
		unit = sq / (2.0 * HEX_SQ_HALF)
	# 左右/上下的外扩是对称的 ⇒ 视觉包围盒中心 == 格心跨度中点，直接拿它对准可用区中心即可。
	var bounds := hex_lattice_bounds(positions)
	var mid := bounds.position + bounds.size * 0.5
	var origin := center - mid * unit
	# 视觉包围盒的左上角 = 晶格包围盒的左上角再各向外扩（左/右 R，上/下 半高）。
	var vis_lo := origin + Vector2(bounds.position.x - HEX_R, bounds.position.y - HEX_HALF_H) * unit
	return {
		"unit_px": unit,
		"origin": origin,
		"span": span,
		"cell_px": int(round(sq)),
		"vis_rect": Rect2(vis_lo, span * unit),
	}


# ============ 自定义多边形纯函数（static：渲染与单测共用同一份公式，可脱离场景树验证） ============

## custom_shapes.bbox（原版世界坐标 [minX,minY,maxX,maxY]）→ Rect2。
## ⚠️ 两个坑，别直接拿去当布局输入：
##   ① 它只圈住**格心**：多边形从格心向外伸出一个格半径（正六边形外接半径 = unit/2），
##      故它不是视觉包围盒（见 custom_visual_bounds）；
##   ② 它是**原版世界坐标**（本关 minX/minY = 318.93/59.52），而 center/poly 已减去 minX/minY
##      归一化到 0 起 ⇒ 本函数返回的 position 与 center 不在同一坐标系，**只有 size 可跨帧比较**；
##      归一化帧下的格心包围盒恒为 Rect2(0, 0, size)。
static func custom_bbox_rect(bbox: Array) -> Rect2:
	if bbox.size() < 4:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	var lo := Vector2(float(bbox[0]), float(bbox[1]))
	var hi := Vector2(float(bbox[2]), float(bbox[3]))
	return Rect2(lo, hi - lo)


## 全部（格心 + 多边形顶点）的并集包围盒（世界坐标）= 真正的**视觉包围盒**。
## 这是自定义盘版的 hex_visual_span()：五/六边形混排、每格形状与朝向都不同，公式化外扩不成立，
## 只能实测。cells 是 JSON 原始数组（[{center:[x,y], poly:[[dx,dy],…]}, …]），便于单测构造。
static func custom_visual_bounds(cells: Array) -> Rect2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in cells:
		if not (c is Dictionary):
			continue
		var d: Dictionary = c
		if not (d.has("center") and d.has("poly")):
			continue
		# 类型校验（2026-09-25 审计）：与 _rebuild_custom_cells 同源问题 —— 此前
		# `var ctr: Array = d["center"]` 与 `for v in (d["poly"] as Array)` 在坏数据上
		# 直接抛错，而本函数被 _layout 调用 ⇒ 整帧不绘制。坏格跳过即可。
		var ctr_v: Variant = d["center"]
		var poly_v: Variant = d["poly"]
		if not (ctr_v is Array) or not (poly_v is Array):
			continue
		var ctr: Array = ctr_v
		if ctr.size() < 2:
			continue
		if not (ctr[0] is float or ctr[0] is int) or not (ctr[1] is float or ctr[1] is int):
			continue
		var center := Vector2(float(ctr[0]), float(ctr[1]))
		lo = Vector2(minf(lo.x, center.x), minf(lo.y, center.y))
		hi = Vector2(maxf(hi.x, center.x), maxf(hi.y, center.y))
		for v in (poly_v as Array):
			if not (v is Array) or (v as Array).size() < 2:
				continue
			var vv: Array = v
			if not (vv[0] is float or vv[0] is int) or not (vv[1] is float or vv[1] is int):
				continue
			var pt := center + Vector2(float(vv[0]), float(vv[1]))
			lo = Vector2(minf(lo.x, pt.x), minf(lo.y, pt.y))
			hi = Vector2(maxf(hi.x, pt.x), maxf(hi.y, pt.y))
	if lo.x > hi.x or lo.y > hi.y:
		return Rect2(Vector2.ZERO, Vector2.ZERO)
	return Rect2(lo, hi - lo)


## 自定义盘布局（纯函数）：在 avail_w×avail_h 的可用区域里按**视觉包围盒** scale-to-fit 并居中。
## 返回 {scale, unit_px, origin, span, cell_px, vis_rect}：
##   scale   —— px / 世界单位（世界 → 屏幕的唯一比例）；
##   unit_px —— px / 棋盘单位（= scale × unit，绘画层换算用的比例）；
##   origin  —— 世界原点在屏幕上的位置（世界点 w ↦ origin + w × scale）；
##   span    —— 视觉跨度（世界单位，便于核对/报告）；cell_px —— 内容/字号密度基准；
##   vis_rect —— **实绘的屏幕包围盒**。
## ⚠️ origin ≠ vis_rect.position：世界坐标**不必从 0 起** —— girih_02 的格心/顶点最小值是
## **负数**（实测 min_x·scale ≈ −49px），此时 origin 比实绘左边缘靠右近 50px。
## 要"棋盘画在哪、多宽"就用 vis_rect（唯一调用方：伙伴停靠区）。
## 与 hex_layout_for 逐条对照：贴合口径（等比缩放 + 某一维恰好贴满）、居中口径（视觉包围盒
## 中心对准可用区中心）、以及同样的 MIN_CELL_PX 下限（窗口极小时宁可溢出，也不把格子缩成糊）。
static func custom_layout_for(bounds: Rect2, unit: float, avail_w: float, avail_h: float, center: Vector2) -> Dictionary:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or unit <= 0.0:
		return {"scale": 0.0, "unit_px": 0.0, "origin": center, "span": Vector2.ZERO, "cell_px": 0,
				"vis_rect": Rect2(center, Vector2.ZERO)}
	var scale: float = minf(avail_w / bounds.size.x, avail_h / bounds.size.y)
	var unit_px: float = scale * unit
	var cell: float = CUSTOM_CELL_FRAC * unit_px
	if cell < float(MIN_CELL_PX):
		cell = float(MIN_CELL_PX)
		unit_px = cell / CUSTOM_CELL_FRAC
		scale = unit_px / unit
	var mid := bounds.position + bounds.size * 0.5
	var origin := center - mid * scale
	return {
		"scale": scale,
		"unit_px": unit_px,
		"origin": origin,
		"span": bounds.size,
		"cell_px": int(round(cell)),
		"vis_rect": Rect2(origin + bounds.position * scale, bounds.size * scale),
	}


## 相对顶点多边形（n ≥ 3）对**格心（原点）**的内切圆半径 = 原点到各边（线段）的最小距离。
## 用途：① 内容盒尺寸的自检；② 数据自检（格心必须落在自格内 ⇒ 该值 > 0）。
static func custom_apothem(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var best := INF
	for i in poly.size():
		var a: Vector2 = poly[i]
		var b: Vector2 = poly[(i + 1) % poly.size()]
		best = minf(best, Geometry2D.get_closest_point_to_segment(Vector2.ZERO, a, b).length())
	return best if best < INF else 0.0


## 多边形绕格心等比缩放（shrink>1 也合法，虽然翻开动效只用 ≤1）：波浪/pop 已算好的收缩比
## 直接喂进来，与 hex_polygon_px(..., shrink) 同语义（那两个动效状态机一行未改）。
static func scale_polygon_about(poly: PackedVector2Array, c: Vector2, shrink: float) -> PackedVector2Array:
	if is_equal_approx(shrink, 1.0):
		return poly
	var out := PackedVector2Array()
	for p in poly:
		out.append(c + (p - c) * shrink)
	return out


## 高亮折线的**屏幕**顶点序列：按 hl 的索引顺序取 poly（世界绝对顶点）再乘 scale + origin。
## 开放折线（不闭合、不补首点）；索引越界或 hl < 2 项 → 返回空数组（= 整格不画，绝不画错线）。
## 抽成 static 的唯一目的：单测能断言「画出来的顺序 == 数据给的顺序」——顺序错 = 图案错，
## 这是本任务的视觉核心，不能只靠肉眼看截图。
static func custom_hl_points(poly: PackedVector2Array, hl: Array, scale: float, origin: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if poly.size() < 3 or hl.size() < 2:
		return out
	for i in hl:
		var idx := int(i)
		if idx < 0 or idx >= poly.size():
			return PackedVector2Array()
		out.append(origin + poly[idx] * scale)
	return out


## 点是否落在该格多边形内（自定义盘命中测试的精确判据；< 3 顶点恒 false）。
static func custom_point_in_cell(pt: Vector2, poly: PackedVector2Array) -> bool:
	if poly.size() < 3:
		return false
	return Geometry2D.is_point_in_polygon(pt, poly)


## 棋盘坐标（单位 = 格，可为小数）→ 屏幕（绘画层注入的两个换算之一）。
## 矩形 = 旧式线性映射（逐像素不变）；蜂窝 = 晶格仿射映射；
## 自定义盘 = 「棋盘坐标 = 世界坐标 / unit」，故 screen = origin + board_pt × unit_px（线性）。
func _board_pt_to_screen(p: Vector2) -> Vector2:
	if _custom_layout():
		return board_origin + p * _custom_unit_px
	if _hex_layout():
		return board_origin + Vector2(HEX_CX * (p.x + p.y), HEX_CY * (p.x - p.y)) * _unit_px()
	return board_origin + p * cell_px


## 屏幕 → 棋盘坐标（_board_pt_to_screen 的逆；两者必须互补，否则笔记会漂）。
func _screen_pt_to_board(p: Vector2) -> Vector2:
	if _custom_layout():
		return (p - board_origin) / maxf(_custom_unit_px, 0.0001)
	if _hex_layout():
		var v := (p - board_origin) / maxf(_unit_px(), 0.0001)
		var s := v.x / HEX_CX            # = x + y
		var d := v.y / HEX_CY            # = x − y
		return Vector2((s + d) * 0.5, (s - d) * 0.5)
	return (p - board_origin) / float(maxi(cell_px, 1))


func _process(_delta: float) -> void:
	var now_ms := Time.get_ticks_msec()
	var dirty := false
	# 分色雷数计数器（仅自定义盘存在；内部有脏标记，不变时直接返回）
	_refresh_group_panel()
	# 总开关关闭：立刻丢弃在途波浪/单格 pop 与缓存 → 下一次重绘即静止态
	#（无收缩、无高亮残留；pop 清掉后该格 scale 回 1.0、颜色走状态色）。
	if not _reveal_effects_enabled() and (not _ripples.is_empty() or not _pops.is_empty()):
		_clear_wave_state()
		dirty = true
	if _hint_until_ms > 0 and now_ms >= _hint_until_ms:
		# 高亮描边到期只清高亮；推理文字窗口保留（盘面变化时才清）
		_hint_steps = []
		_hint_until_ms = -1
		dirty = true
	if _reject_until_ms > 0 and now_ms >= _reject_until_ms:
		_reject_pos = Vector2i(-1, -1)
		_reject_until_ms = -1
		dirty = true
	# 波浪存在期间持续重绘；队列清空即停止（§8.4.5 性能条款）
	if not _ripples.is_empty():
		_cull_waves(now_ms)
		_ripple_cache_ms = -1  # 每帧时钟推进 → 缓存作废，绘制时按当前 ms 重算
		dirty = true
	# 单格 pop：与波浪同帧驱动、互不覆盖；结束后从登记表移除（防无限增长）。
	if not _pops.is_empty():
		_cull_pops(now_ms)
		_pop_cache_ms = -1
		dirty = true
	# 【2026-09-30】主题波浪的逐帧驱动已删——换肤由 ThemeManager 分层过渡的
	# tween_method 驱动，每步 emit theme_changed → queue_redraw，不需要 _process 参与。
	if dirty:
		queue_redraw()
	# 无动画时彻底关掉逐帧回调：静态棋盘不需要每帧醒来
	if _ripples.is_empty() and _pops.is_empty() and _hint_until_ms < 0 \
			and _reject_until_ms < 0:
		set_process(false)


## 有动画要做时唤醒逐帧回调（由波浪/提示/拒绝反馈各自调用）。
func _request_frames() -> void:
	if not is_processing():
		set_process(true)


## 淘汰已结束（超过总时长）的波浪。返回是否发生了变化。
## 抽成带参函数：测试可注入时钟验证「结束后精确回到静止态」，不依赖真实时间。
func _cull_waves(now_ms: int) -> bool:
	if _ripples.is_empty():
		return false
	var before := _ripples.size()
	_ripples = _ripples.filter(func(rp): return float(now_ms) - float(rp["t0"]) < float(rp["total_ms"]))
	if _ripples.size() == before:
		return false
	if _ripples.is_empty():
		# 波浪结束：必须清缓存，否则绘制层会残留高亮（收尾无残留是硬约束）
		_ripple_cache.clear()
	return true


## 淘汰已结束（超过 POP_WD）的单格 pop。返回是否发生了变化。
## 结束后从登记表移除 → 表不无限增长；移除后该格查不到 pop → scale 恰为 1.0（无残留）。
## 抽成带参函数：测试可注入时钟验证收尾，不依赖真实时间。
func _cull_pops(now_ms: int) -> bool:
	if _pops.is_empty():
		return false
	var before := _pops.size()
	var dur_ms: float = ThemeManager.pop_duration() * 1000.0
	# 不用 Dictionary.filter（本引擎版本无此方法）：手工保留未结束项。
	var kept := {}
	for pos in _pops:
		if float(now_ms) - float(_pops[pos]) < dur_ms:
			kept[pos] = _pops[pos]
	if kept.size() == before:
		return false
	_pops = kept
	if _pops.is_empty():
		_pop_cache.clear()
	return true


# ============ 渲染（§8.4.8 逐格绘制，全部色值经 ThemeManager） ============

## 棋盘垫子向每边外扩的像素。太小（<6）垫子看起来像描边而不是"板子"，
## 太大（>16）在 5×5 小盘上垫子比棋盘本身还显眼。
const MAT_GROW := 10.0
## 玻璃垫板的外扩（网页 --mat-pad:14px，按本项目格子比例 ≈12px）。
## 玻璃面板要有「罩住棋盘」的存在感，外扩必须比 cozy 不透明垫板大一档。
const MAT_GROW_GLASS := 12.0

## ── CozyStyle 圆角瓦片（2026-09-29）────────────────────────────────────────────
## CozySudoku 的棋盘不是「方格 + 网格线」，而是**一块块圆角瓦片留缝拼在板子上**：
## 状态靠瓦片自身的底色与描边表达，不靠格线。这里按同样的几何复刻 ——
##   瓦片 = 格子矩形向内缩 GAP、四角倒 RADIUS 的圆角；缝里透出来的就是棋盘垫子
##   （board_mat）⇒「格线」由**间隙**天然构成，那圈 1px 描边不再需要。
##
## **只在有垫子的主题下生效**（CozyStyle 五套）。dark/light 的 board_mat 是全透明
## ⇒ `_cozy_tiles()` 为假 ⇒ `_draw_tile` / `_tile_rect` / `_draw_tile_outline`
## 三个函数**第一行就原路返回**，走的还是改造前那一条 `draw_rect`（同样的 rect、
## 同样的 inset、同样的 width）⇒ **瓦片几何**对旧主题是严格恒等的（零回归）。
##
## ⚠️ 别把这句话读成「旧主题的截图一个像素都不变」—— 那一天还做了两处**全局**改动，
## 它们同样作用在 dark/light 上，实测让这两套主题的棋盘截图有非零差异：
##   · 棋盘数字从 `ThemeDB.fallback_font` 改成主题链的 Label 字体（见 `_board_font`）；
##   · 图标按钮的内容边距 16/8 → 9/9 ⇒ 毛笔按钮最小宽度 −14px ⇒ 棋盘可用区变化、
##     整块棋盘平移约 1px。
## 截图对比实测：dark 79,335 px 差异中 76,388 px 落在棋盘区，差异图（`_pv/diff_amp.py`
## 产出）显示差异**只沿字形轮廓与格子边缘分布**，格角在前后两张里都是方的 ——
## 即「几何没变、位置挪了 1px」。要断言的是几何恒等，不是截图逐像素相等。
##
## 【2026-09-29 二次实测修正】原值 0.055 / 0.24 是上一轮从**模糊截图目测**得到的，
## 两个都偏大。这次从官方 1920×1080 截图逐像素量（`_pv/measure_board.py` +
## `_pv/ascii_cell.py` 把格子直接打成 ASCII 图读），结果：
##
##   格缝：原作 格 47px ┃ 缝 3px ┃ 格 → pitch = 50px（47+3=50 自洽，硬阈值直读）
##         ⇒ **缝/格 = 6.4%**。而我这边 `rect.grow(-w * 0.055)` 是**四边各缩 5.5%**，
##         相邻两格之间实际留下 11% —— 常数名、注释、实际效果三者不一致，
##         注释写「缝 ≈ 格宽 5.5%」，代码却给了一倍。
##   圆角：原作硬阈值直读 r ≈ 5px / 格 47px ⇒ **10.6%**。
##         （阈值取格色与缝色亮度的中点，而过零点即真实几何边，所以是无偏估计。）
##         我这边 0.24 × 瓦片边长 ≈ **格边长的 21%**，整整圆了一倍 ——
##         瓦片因此从「略微倒角」变成了「软糖」，是观感差异最大的一处。
##
## 修正后的语义（与名字一致、与实测一致）：
##   TILE_GAP_FRAC    = **相邻两格之间的总缝宽** / 格边长
##   TILE_RADIUS_FRAC = **圆角半径** / 格边长
const TILE_GAP_FRAC := 0.064
const TILE_RADIUS_FRAC := 0.106

var _tile_sb: StyleBoxFlat = null
var _tile_sb_radius := -1.0
var _tile_line_sb: StyleBoxFlat = null
var _tile_line_radius := -1.0


## 是否走 CozyStyle 圆角瓦片（判据 = 该主题画不画棋盘垫子）。
func _cozy_tiles() -> bool:
	return ThemeManager.board_mat().a > 0.0


## 线稿密度基准（2026-09-30 网页复刻校准）：chain-lab.html 的线稿（格描边 1px、
## 内顶高光 1px）是按**格边长 ≈64px** 的浏览器渲染设计的。本项目格边长随盘面
## scale-to-fit（24~108px+），固定 1px 在大格子上相对只有网页六成粗——实测左/下
## 边缘对比度只有 +12/255（网页同位 +33），用户观感「只有顶上一条线、四周没描」。
## 故所有瓦片线稿按 cell_px/64 等比缩放（下限 1px），小格子回落到 1px 不受影响。
const LINE_REF_CELL := 64.0


## 线稿有效宽度：palette 声明值（按 64px 基准格）× 格边长/64，下限 1px。
## base=0（非玻璃主题无描边）恒返回 0，旧主题零回归。
func _scaled_line_w(base: int) -> int:
	if base <= 0:
		return 0
	return maxi(1, roundi(float(base) * float(cell_px) / LINE_REF_CELL))


## 瓦片**填充**样式（缓存单例，fill-only——描边环由 `_tile_line_stylebox` 单独承担）。
## 【2026-09-30 background-clip 对齐】StyleBoxFlat 的 fill 会内缩到描边之下：一体式
## 「fill+border」stylebox 的描边实际压在**裸垫板**上（实测 60+0.18×195=95.1，与截图
## 逐位吻合），对比度只有网页的一半——CSS 的 background 默认 `background-clip:
## border-box`，fill 铺满到描边外缘、描边压在合成色上。故拆两笔：fill 满铺整瓦片
## （含描边区），描边环叠上。`_draw()` 每帧每格调用，复用同一实例（同旧注释理由）。
func _tile_stylebox(radius: float) -> StyleBoxFlat:
	if _tile_sb == null:
		_tile_sb = StyleBoxFlat.new()
		_tile_sb.anti_aliasing = true
	# 半径变化才重建几何
	if not is_equal_approx(_tile_sb_radius, radius):
		_tile_sb_radius = radius
		var r := clampi(int(roundf(radius)), 2, 40)
		_tile_sb.set_corner_radius_all(r)
		# 半径变大后 6 边细分的多边形会被看成一圈多边形而不是圆（同 UiTheme._round 口径）
		# 细分提到 40：用户 5.5x 放大复查时 24 段弧有可见棱面（「过渡不够圆滑」）
		_tile_sb.corner_detail = clampi(r + 10, 12, 40)
	return _tile_sb


## 瓦片的绘制矩形（自格子矩形向内缩出间隙）。非 Cozy 主题返回原矩形。
##
## 单侧内缩 = **总缝宽的一半** —— `grow()` 是四边同时缩，所以想让「相邻两格之间」
## 留下 TILE_GAP_FRAC × 格边长 的缝，单侧只能缩一半。
## 上一版直接缩了整个 TILE_GAP_FRAC，缝因此是标称值的两倍。
##
## 下限 0.5px：窗口极小时（cell_px = MIN_CELL_PX = 24）缝只有 1.5px，
## 四舍五入别把它抹成 0，否则瓦片又拼回一整片、圆角反而成了锯齿。
func _tile_rect(rect: Rect2) -> Rect2:
	if not _cozy_tiles():
		return rect
	return rect.grow(-maxf(0.5, rect.size.x * ThemeManager.tile_gap_frac() * 0.5))


## 填充一格：Cozy = 圆角瓦片（间隙即分格线）；其余主题 = 原 `draw_rect`（逐像素不变）。
## revealed=true 时取「翻开格」的内顶高光与玻璃边色（棱镜玻璃用；其余主题这些色透明，无效果）。
func _draw_tile(rect: Rect2, col: Color, revealed: bool = false) -> void:
	if not _cozy_tiles():
		draw_rect(rect, col)
		return
	var r := _tile_rect(rect)
	# 【2026-09-30 描边锐化】间隙内缩会产生 .78 这类小数边，1~2px 描边跨在两个
	# 像素上被 AA 摊薄（实测左右边缘对比度腰斩：+32 预期 → +16 实测）——用户观感
	# 「只有顶上一条线、四周没描」。浏览器渲染 border 同样做设备像素对齐，故绘制
	# 用**整数对齐**的瓦片矩形；_tile_rect 的原始几何仍供命中/轮廓使用（契约测试钉它）。
	r = Rect2(r.position.round(), r.size.round())
	# 半径按**格边长**取，不按内缩后的瓦片边长 ——
	# TILE_RADIUS_FRAC 的定义就是「半径 / 格边长」（对齐实测口径）。
	var radius := maxf(2.0, rect.size.x * ThemeManager.tile_radius_frac())
	# ① 填充：铺满整瓦片（含描边区）—— CSS `background-clip: border-box` 语义
	var sb := _tile_stylebox(radius)
	sb.bg_color = col
	draw_style_box(sb, r)
	# ② 描边环（draw_center=false）：压在 fill 合成色上，对比度对齐网页。
	#    颜色按状态取：未翻开 tile_border(.18) / 已翻开 tile_border_open(.09)，
	#    宽度按格边长等比缩放（LINE_REF_CELL 基准）。
	var bw := _scaled_line_w(ThemeManager.tile_border_width())
	var bcol := ThemeManager.tile_border_open() if revealed else ThemeManager.tile_border()
	if bw > 0 and bcol.a > 0.0:
		var sbd := _tile_line_stylebox(radius, bw)
		sbd.border_color = bcol
		draw_style_box(sbd, r)
	# 玻璃内顶高光（近似 CSS inset 0 1px 0）：原生无 inset 阴影，故只画顶边。
	# 【2026-09-29 二次修正】CSS 的这条高光带会**沿圆角弧线包住上两角**、在弧线切线
	# 变竖直处自然消失（可视带 = 圆角矩形与其下移 1px 拷贝之间的区域），且画在 border
	# 内侧。此前先是无脑全宽直线（大圆角下两端越出圆角 ~20px），后改为按 y=1.5 切割量
	# 截短——但那只是把越界换成了「距边 21px 处悬空起笔/收笔」的两条硬端点，用户复查
	# 仍觉突兀。现在直接沿圆角路径铺 1px 折线：左边缘 y=hrad 处 → 左上弧 → 顶边 →
	# 右上弧 → 右边缘，端点落在弧线竖直切点（与 CSS 可视带的消失位置一致），
	# 并整体内缩 border 宽（inset 阴影画在 padding box 内的语义）。
	var ins := ThemeManager.tile_inset_open() if revealed else ThemeManager.tile_inset()
	if ins.a > 0.0 and r.size.y > 4.0:
		var rad: float = maxf(2.0, rect.size.x * ThemeManager.tile_radius_frac())
		var bw_px := float(_scaled_line_w(ThemeManager.tile_border_width()))
		var hr: Rect2 = r.grow(-bw_px)
		var hrad: float = minf(maxf(1.0, rad - bw_px), minf(hr.size.x, hr.size.y) * 0.5)
		# 高光带高随格边长等比缩放（与描边同口径，64px 基准 1px）
		var lw := maxf(1.0, float(cell_px) / LINE_REF_CELL)
		_draw_top_highlight(hr, hrad, lw, ins)


## 内顶高光（**实心新月形矢量多边形**，2026-09-30 第四版）：
## 形状 = CSS `inset 0 lw 0` 的精确可视区 = **padding-box 减去其下移 lw 的拷贝**——
## 顶边直段高 lw，两角沿圆弧锥形收细、在切点处宽度趋零没入侧描边。
##
## 为什么是多边形：① 恒宽折线复刻不了「趋零」新月（端头怼在竖边描边上，用户两轮
## 截图圈出的过渡突兀 / 白线跨层 / 分离不对齐）；② Godot 的 antialiased 折线/线段
## 对半透明色会在每个接头 AA 叠加成虚线点（第三版实测）——逐段方案在引擎层不可行。
## 多边形 + 项目开启 `msaa_2d=2`（本次一并设置）→ 边缘获硬件抗锯齿，无点、无棱面。
func _draw_top_highlight(hr: Rect2, hrad: float, lw: float, ins: Color) -> void:
	if hrad < 2.0:
		# 圆角小到可以忽略：退化为顶边矩形带（带体仍在 padding-box 内）
		draw_rect(Rect2(hr.position.x, hr.position.y, hr.size.x, lw), ins)
		return
	var cl := Vector2(hr.position.x + hrad, hr.position.y + hrad)   # 左上弧圆心
	var cr := Vector2(hr.position.x + hr.size.x - hrad, hr.position.y + hrad)  # 右上弧圆心
	var n := 24   # 每弧 24 段（3.75°/段）——MSAA 下弦差 ≤ 0.02px，平滑
	var pts := PackedVector2Array()
	# 外沿：padding-box 顶部边界（左切点 → 左上弧 → 顶边 → 右上弧 → 右切点）
	pts.append(Vector2(hr.position.x, cl.y))
	for k in n + 1:
		var th: float = deg_to_rad(-90.0 + 90.0 * float(k) / float(n))
		pts.append(cl + Vector2(sin(th), -cos(th)) * hrad)
	for k in n + 1:
		var th: float = deg_to_rad(90.0 * float(k) / float(n))
		pts.append(cr + Vector2(sin(th), -cos(th)) * hrad)
	# 内沿：同形边界**下移 lw**，反向回走（右切点 → 右上弧 → 顶边 → 左上弧 → 左切点）
	var off := Vector2(0.0, lw)
	for k in n + 1:
		var th: float = deg_to_rad(90.0 - 90.0 * float(k) / float(n))
		pts.append(cr + off + Vector2(sin(th), -cos(th)) * hrad)
	for k in n + 1:
		var th: float = deg_to_rad(-90.0 * float(k) / float(n))
		pts.append(cl + off + Vector2(sin(th), -cos(th)) * hrad)
	draw_colored_polygon(pts, ins)


## 瓦片**描边**样式（缓存单例，与填充样式分开 —— 同一个实例既填又描会让边框宽度## 残留到下一次填充上）。`draw_center = false` ⇒ 只画边框，不铺底。
func _tile_line_stylebox(radius: float, width: int) -> StyleBoxFlat:
	if _tile_line_sb == null:
		_tile_line_sb = StyleBoxFlat.new()
		_tile_line_sb.anti_aliasing = true
		_tile_line_sb.draw_center = false
	if not is_equal_approx(_tile_line_radius, radius):
		_tile_line_radius = radius
		var r := clampi(int(roundf(radius)), 2, 40)
		_tile_line_sb.set_corner_radius_all(r)
		_tile_line_sb.corner_detail = clampi(r + 10, 12, 40)
	var w := maxi(1, width)
	# 只在真的变了才写：StyleBoxFlat 每次 set_border_width_* 都会 emit changed
	if _tile_line_sb.border_width_top != w:
		_tile_line_sb.set_border_width_all(w)
	return _tile_line_sb


## 描边一格：Cozy = 与瓦片同形的圆角描边（**含同一个间隙**，所以描边正好箍在瓦片上）；
## 其余主题 = 原 `rect.grow(-inset)` 方角描边（逐像素不变）。
##
## 为什么必须同形：方角描边是按**原格矩形**画的，而瓦片已经内缩出缝、四角是圆的 ——
## 直接沿用会在缝里画出一个方框，四角横切圆弧，看起来像"选中的方块露出来了"。
## 光标框 / 提示描边 / 猜测被拒闪烁三处都走本函数，改一处即可全中。
func _draw_tile_outline(rect: Rect2, col: Color, width: float, inset: float) -> void:
	if not _cozy_tiles():
		draw_rect(rect.grow(-inset), col, false, width)
		return
	var r := _tile_rect(rect).grow(-inset)
	if r.size.x <= 2.0 or r.size.y <= 2.0:
		return
	var sb := _tile_line_stylebox(maxf(2.0, rect.size.x * ThemeManager.tile_radius_frac()), int(roundf(width)))
	sb.border_color = col
	draw_style_box(sb, r)


## 棋盘垫子（mat）—— CozyStyle 的 BoardBg 角色，见 ThemeManager.board_mat() 的说明。
##
## 插在 `_draw()` 里、所有格填充之前，所以它天然位于棋盘与动效之下，
## 且与格子共用同一套坐标（board_origin / cell_px）⇒ 窗口缩放、换关、切主题都自动跟随，
## 不需要任何布局同步代码。
##
## **蜂窝盘与自定义几何盘不画**：它们的格子是内接正方形/多边形，逐格拼不出一个矩形外框，
## 外扩矩形反而会在四周露出方角，收益为负。矩形路径覆盖了全部经典 / 变体关卡。
func _draw_board_mat(size: Vector2i) -> void:
	if _hex_layout() or _custom_layout():
		return
	var sb := _mat_stylebox()
	if sb == null:
		return
	var grow := MAT_GROW_GLASS if ThemeManager.is_glass() else MAT_GROW
	var rect := Rect2(board_origin, Vector2(size) * cell_px).grow(grow)
	if ThemeManager.is_glass():
		# 【2026-09-30 三层构造】CSS 语义对齐：.mat 的 box-shadow **只画在元素外**
		#（半透背景底下没有影）。StyleBoxFlat 的影画在整块 rect 后面 ⇒ 直接一笔画
		# 会让白 .05 面板被自己的黑影衬成深色板（真机采样：缝色 B 通道暗 ~30/255）。
		# 三步还原：① 画带影 stylebox ② 背景贴图同区域重绘（等效 CSS 影裁剪）
		# ③ 画无影面板本体（半透明白 fill + 1px 白边）。
		draw_style_box(sb, rect)
		_redraw_bg_over(rect)
		var fill := _glass_mat_fill_stylebox()
		if fill != null:
			draw_style_box(fill, rect)
	else:
		draw_style_box(sb, rect)


## 异形盘垫子（逐格外扩版）：把「格与格之间的缝」铺成本主题的板色，而不是露出视口底色。
## 调用点在 _draw()（见那里的长注释）。两条硬约束：
##   ① 板色必须**不透明**才允许逐格重叠铺（半透板会叠深）⇒ 棱镜玻璃等 a<1 的主题直接跳过；
##   ② 只在**真有缝**时铺；已经严丝合缝的镶嵌盘与两格几何重叠处 ⇒ 不画（零回归）。
const SEAM_MIN_PX := 0.5    # 缝宽 ≤ 此值 ⇒ 视为无缝（格边严丝合缝 / 两格几何重叠），不补
const SEAM_PAD_PX := 0.75   # 补缝余量：盖住格线半宽与浮点误差，缝里不留原始底色


func _draw_shape_mat() -> void:
	var pad := ThemeManager.board_mat()
	if not _shape_mat_is_opaque(pad):
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	for p: Vector2i in board.grid.all_positions():
		var poly := _cell_polygon(p)
		if poly.size() < 3:
			continue
		var k := _shape_mat_scale(p, poly)
		if k <= 1.0:
			continue   # 无缝可补（_shape_mat_scale 只在「与邻格真有缝」时 > 1）
		draw_colored_polygon(scale_polygon_about(poly, _cell_center(p), k), pad)


## 板色是否**够不透明**到可以逐格重叠铺。半透板逐格重叠会叠深（越叠越实）⇒ 必须跳过。
## 抽成 static 纯函数：让单测能直接钉住「棱镜玻璃那种 a=0.05 的板色必须被判为不可铺」。
static func _shape_mat_is_opaque(pad: Color) -> bool:
	return pad.a >= 0.999


## 该格需要的外扩缩放比（绕格心等比缩放）；**只有「与邻格之间真有一条缝」时才 > 1**。
##
## 缝宽口径 = **真·多边形间距**（两格多边形的最近点距），见 _polygon_gap。
## ⚠️ 不能用「格心距 − 两边内切半径」，更不能用「格心距/2 − 本格内切半径」：
## 两者都只在**相邻两格同尺寸、且共享边垂直于格心连线**时才成立。实测两种情况会算错 ——
##   ① 蜂窝/方阵：两式都对（相邻同尺寸）；
##   ② 扇形格（同心环盘）：共享边是**径向**的，与格心连线不垂直 ⇒ 算出 1.8× 的假缝；
##   ③ 混排格（截角三角盘：三角形 + 十二边形）：内切半径差 6 倍 ⇒ 算出 3.7× 的假缝。
## 假缝的后果是把垫色糊到盘的轮廓**之外** —— 玩家看到盘外多一圈假边框，比不补更丑。
## 故直接用真·多边形间距：共享边/几何重叠恰好为 0（零回归），有缝才为正。
##
## 缝宽 ≤ SEAM_MIN_PX ⇒ 返回 1.0（无缝可补）；否则把该格外扩到「中缝 + SEAM_PAD_PX」：
## k·inr = inr + 缝宽/2 + 余量（外扩量 = 缝宽/2 + 余量 ⇒ 盘边缘的溢出也只有这么多，不会成框）。
## 无邻格 / 邻格数据缺失 / 洞格（get_cell()==null）/ 内切半径为 0 ⇒ 返回 1.0（不外扩）。
func _shape_mat_scale(pos: Vector2i, poly: PackedVector2Array) -> float:
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return 1.0
	_ensure_seam_cache()
	if not _seam_ratio_cache.has(pos):
		return 1.0
	var inr := _polygon_inradius(poly, _cell_center(pos))
	if inr <= 0.001:
		return 1.0
	# 缓存里是**缝宽 / 本格内切半径**（无量纲）：与 unit_px 无关 ⇒ 缩放窗口不用重建缓存。
	var gap_px := float(_seam_ratio_cache[pos]) * inr
	if gap_px <= SEAM_MIN_PX:
		return 1.0   # 无缝可补（含两格几何重叠 / 共享边）
	return 1.0 + (gap_px * 0.5 + SEAM_PAD_PX) / inr


## 缝宽比缓存：Vector2i → 缝宽 / 本格内切半径。**无量纲**（与 unit_px 无关）。
## 只在换 Board 时重建一次：真·多边形间距是 O(格数 × 邻数 × 顶点²)，每帧算会掉帧；
## 而几何一旦落盘就不变（格心/顶点都随 unit_px 等比缩放，比值恒定）。
var _seam_ratio_cache: Dictionary = {}
## 缓存属于哪个 Board（**持引用**：Board 是 RefCounted ⇒ 旧盘不会被回收、instance_id 不会被复用）。
var _seam_ratio_board: Board = null


## 重建缝宽比缓存（口径见 _shape_mat_scale）。
func _ensure_seam_cache() -> void:
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	if _seam_ratio_board == board and not _seam_ratio_cache.is_empty():
		return
	_seam_ratio_board = board
	_seam_ratio_cache.clear()
	for p: Vector2i in board.grid.all_positions():
		var poly := _cell_polygon(p)
		if poly.size() < 3:
			continue
		var inr := _polygon_inradius(poly, _cell_center(p))
		if inr <= 0.001:
			continue
		var gap := INF
		for q: Vector2i in board.grid.get_neighbors(p):
			if board.grid.get_cell(q) == null:
				continue   # 洞格（异形拓扑的盘外格）
			var qpoly := _cell_polygon(q)
			if qpoly.size() < 3:
				continue
			gap = minf(gap, _polygon_gap(poly, qpoly))
		if is_finite(gap):
			_seam_ratio_cache[p] = gap / inr


## 两个凸多边形之间的最短距离；相交或共享边 ⇒ 0。
## 凸多边形的最小距离必在「一方的顶点 ↔ 另一方的边」上取得，故逐顶点量到对边即可。
static func _polygon_gap(a: PackedVector2Array, b: PackedVector2Array) -> float:
	if a.size() < 3 or b.size() < 3:
		return 0.0
	# 先做包含判定：一方的顶点落进另一方内部（几何重叠）⇒ 距离 0。
	# 只靠顶点—对边距离不够：顶点深深嵌进对方内部时那段距离反而是正的。
	for v in a:
		if Geometry2D.is_point_in_polygon(v, b):
			return 0.0
	for v in b:
		if Geometry2D.is_point_in_polygon(v, a):
			return 0.0
	var best := INF
	var na := a.size()
	var nb := b.size()
	for i in na:
		var p := a[i]
		var q := a[(i + 1) % na]
		for j in nb:
			best = minf(best, _point_seg_dist(b[j], p, q))
	for j in nb:
		var p := b[j]
		var q := b[(j + 1) % nb]
		for i in na:
			best = minf(best, _point_seg_dist(a[i], p, q))
	return 0.0 if not is_finite(best) else best


## 点到线段的最短距离（垂足落在线段外时退化为到端点的距离）。
static func _point_seg_dist(pt: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0000001:
		return pt.distance_to(a)
	var t := clampf((pt - a).dot(ab) / l2, 0.0, 1.0)
	return pt.distance_to(a + ab * t)


## 凸多边形对**格心**的内切半径（格心到各边的最短距离）。
## 用途：把「外扩多少像素」换算成「绕格心的缩放比」。蜂窝/自定义盘的格心必在多边形内部。
static func _polygon_inradius(poly: PackedVector2Array, c: Vector2) -> float:
	var best := INF
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var ab := poly[(i + 1) % n] - a
		var l := ab.length()
		if l < 0.0001:
			continue
		best = minf(best, absf((c - a).cross(ab)) / l)
	return 0.0 if not is_finite(best) else best


## 用烘焙背景贴图把 rect 区域重画一遍（玻璃垫板下方的「影擦除」）。
## 贴图整铺视口（_draw_prism_background 同口径），局部坐标 = 视口坐标，按比例取源区域。
## 贴图缺失（兜底单色分支）时退化为铺一块主题底色。
func _redraw_bg_over(rect: Rect2) -> void:
	if _prism_bg_tex == null:
		_prism_bg_tex = load("res://assets/bg_prism.png") as Texture2D
	if _prism_bg_tex != null:
		var vp := get_viewport_rect()
		var ts := Vector2(_prism_bg_tex.get_size())
		var src := Rect2((rect.position - vp.position) * ts / vp.size, rect.size * ts / vp.size)
		draw_texture_rect_region(_prism_bg_tex, rect, src)
	else:
		draw_rect(rect, ThemeManager.bg())


## 棱镜玻璃的烘焙渐变背景（含毛玻璃模糊，见 gen_prism_bg.py）。
## 仅玻璃主题调用；其余主题走旧 flat 背景分支。贴图加载失败则退化为主题底色。
func _draw_prism_background() -> void:
	if _prism_bg_tex == null:
		_prism_bg_tex = load("res://assets/bg_prism.png") as Texture2D
	if _prism_bg_tex != null:
		draw_texture_rect(_prism_bg_tex, get_viewport_rect(), false)
	else:
		# 贴图缺失兜底：棱镜主题自己的 bg（单源，不再写死 #141834）
		draw_rect(get_viewport_rect(), ThemeManager.bg())


## 垫子样式（缓存）。颜色变了才重建 —— `_draw()` 每帧都跑，逐帧 new StyleBoxFlat
## 会在波浪动效期间变成每秒上百个对象。dark/light 主题 board_mat() 返回全透明 → 返回 null
## = 一个矩形都不画，旧主题逐像素不变。
##
## 【2026-09-29】阴影不再写死 `Color(0,0,0,0.10)`：同一份固定纯黑 α 在七套底色上
## 深浅差 6 倍（粉彩底掉 43/255、深底只掉 7/255），是用户说的"阴影没适配"。
## 现在由 `ThemeManager.shadow(bg, MAT 档)` 反解，影色取该主题自己的深色调。
## 缓存判据随之从"只看垫子色"改成"垫子色 + 影色"都相同 —— 两者都随主题走。
func _mat_stylebox() -> StyleBoxFlat:
	var c := ThemeManager.board_mat()
	if c.a <= 0.0:
		return null
	# 【2026-09-30 三层构造】玻璃主题走专属路径：半透明白面板 + 1px 白边 + 大柔影，
	# 全部来自 ThemeManager 的 mat_* 键（网页 [data-theme=prism] 的 .mat token 原值）。
	# 旧路径（cozy 不透明垫板 + shadow() 反解影色）保持逐像素不变。
	if ThemeManager.is_glass():
		return _glass_mat_stylebox(c)
	var sh := ThemeManager.shadow(ThemeManager.bg(), ThemeManager.SHADOW_DROP_MAT)
	if _mat_sb != null and _mat_sb_color == c and _mat_sb_shadow == sh:
		return _mat_sb
	if _mat_sb == null:
		_mat_sb = StyleBoxFlat.new()
		_mat_sb.set_corner_radius_all(18)
		_mat_sb.corner_detail = 20
		_mat_sb.shadow_size = 10
		_mat_sb.shadow_offset = Vector2(0, 3)
	_mat_sb.bg_color = c
	_mat_sb.shadow_color = sh
	_mat_sb_color = c
	_mat_sb_shadow = sh
	return _mat_sb


## 玻璃垫板（棱镜三层的**中层**）—— 对齐网页 chain-lab.html：
##   .mat{ background:rgba(255,255,255,.05);            ← 半透明白，缝里读出「淡灰」
##         border:1px solid rgba(255,255,255,.14);      ← 玻璃面板的白边
##         border-radius:26px;
##         box-shadow:0 30px 70px -30px rgba(0,0,0,.6); ← 大柔影 = 悬浮高度
##         backdrop-filter:blur(14px) }                 ← 透镜（烘焙背景已含等效柔化）
func _glass_mat_stylebox(fill: Color) -> StyleBoxFlat:
	var bc := ThemeManager.mat_border()
	var bw := ThemeManager.mat_border_w()
	var rad := ThemeManager.mat_radius()
	var sc := ThemeManager.mat_shadow_color()
	var ssz := ThemeManager.mat_shadow_size()
	var soff := ThemeManager.mat_shadow_offset()
	var key := "%s|%s|%d|%.1f|%s|%.1f|%s" % [fill, bc, bw, rad, sc, ssz, soff]
	if _gmat_sb != null and _gmat_key == key:
		return _gmat_sb
	# 影体：bg 全透明 + 影参数（先画，rect 内的部分随后被背景重绘抹掉）
	if _gmat_shadow_sb == null:
		_gmat_shadow_sb = StyleBoxFlat.new()
		_gmat_shadow_sb.corner_detail = 20
	_gmat_shadow_sb.bg_color = Color(0, 0, 0, 0)
	_gmat_shadow_sb.set_corner_radius_all(clampi(int(roundf(rad)), 2, 60))
	_gmat_shadow_sb.shadow_size = ssz
	_gmat_shadow_sb.shadow_offset = soff
	_gmat_shadow_sb.shadow_color = sc
	# 面板体：fill + 白边，无影（影由上面的影体承担，避免衬底）
	if _gmat_fill_sb == null:
		_gmat_fill_sb = StyleBoxFlat.new()
		_gmat_fill_sb.corner_detail = 20
	_gmat_fill_sb.bg_color = fill
	_gmat_fill_sb.set_corner_radius_all(clampi(int(roundf(rad)), 2, 60))
	_gmat_fill_sb.set_border_width_all(bw)
	_gmat_fill_sb.border_color = bc
	_gmat_sb = _gmat_shadow_sb   # 兼容旧引用：_mat_stylebox 的返回值仍是「带影体」
	_gmat_key = key
	return _gmat_shadow_sb


## 玻璃垫板的**面板体**（无影）：_glass_mat_stylebox() 已按同一缓存键建好，
## 这里只取。调用顺序契约：必须先调过 _glass_mat_stylebox（_mat_stylebox 已保证）。
func _glass_mat_fill_stylebox() -> StyleBoxFlat:
	return _gmat_fill_sb


## 棋盘文字（数字 / ? / ∞ / *）的字体。
##
## **不要**用 `ThemeDB.fallback_font`：那是**引擎内置回退字体**，与
## `project.godot [gui] theme/custom_font` 设的全局字体不是一套 ——
## 棋盘数字笔画带衬线感，和界面上其它文字明显两个风格（2026-09-29 放大截图核对时发现）。
##
## 【2026-09-29 二次修订】改为**等宽数字专用字体**，也就是原作棋盘数字实际用的那款
## （Gen Jyuu Gothic Monospace Heavy，见 CozySudoku 分析报告 §2.3）。
##
## 为什么必须等宽 —— 文源圆体是**比例**字体，实测（字号 56，`Font.get_string_size`）：
##     "1" → 20.5px      "8" → 37.0px      差 16.5px = **45%**
## 后果两条：
##   ① 计时器 / 剩余雷数这类读数会随数字变化左右抖动；
##   ② 每格数字的光学中心不一致（"1" 在格子里偏右、"8" 才居中），九宫看不清齐。
## 原作就是为了消掉这两点才在棋盘上用 Monospace 版。
##
## 取值顺序：
##   ① 本控件自己被设了 font override → 用它（测试会用这个探针，也允许将来按主题换字）
##   ② UiFonts.digit() → 等宽数字字体（带中文回退）
##   ③ 主题链里的 Label 字体
##   ④ 引擎回退字体（保底，至少画得出字）
func _board_font() -> Font:
	if has_theme_font_override("font"):
		return get_theme_font("font", "Label")
	var d := UiFonts.digit()
	if d != null:
		return d
	var f: Font = get_theme_font("font", "Label")
	return f if f != null else ThemeDB.fallback_font


func _draw() -> void:
	var session := GameSession
	if session.board == null or session.board.grid == null:
		return
	var board: Board = session.board
	# 自定义盘（数据驱动）：盘面分三重身份，先算一次供下面各分支复用。
	var custom := _custom_layout()
	# 背景（palette.background）：board_view 本身是全屏 Control（锚点 preset 15），于是直接在
	# **自己的绘制遍**里铺一块视口大小的底色块 —— 不动 GameScreen / 场景树 / 游戏场景。
	# 子节点（绘画层 / HUD / 底栏）在本控件之后绘制，天然覆盖其上（背景仍在下层）。
	# 无 palette.background → 不画（保持原样，矩形关卡零变化）。
	# ⚠️ 2026-09-22：此处原先还要求 `custom`（自定义几何盘），与 _custom_palette 的耦合同源，
	# 于是声明了 background 的蜂窝关也画不出底色。现只以「取到了不透明色」为条件。
	# 背景（palette.background / 棱镜烘焙贴图）：board_view 本身是全屏 Control，直接在
	# 自己的绘制遍里铺视口大小的底 —— 子节点（绘画层/HUD/底栏）随后绘制，天然覆盖其上。
	# use_bg_gradient 翻转时贴图 α 在过渡窗口内淡入/淡出（网页 background .4s 的等价物）。
	var grad := ThemeManager.use_bg_gradient()
	if int(grad) != _bg_grad_last:
		_bg_grad_last = int(grad)
		_bg_fade_t0 = Time.get_ticks_msec()
	var fade_p := 1.0
	if _bg_fade_t0 >= 0:
		fade_p = clampf(float(Time.get_ticks_msec() - _bg_fade_t0) / BG_FADE_MS, 0.0, 1.0)
		if fade_p >= 1.0:
			_bg_fade_t0 = -1
	if grad:
		if _prism_bg_tex == null:
			_prism_bg_tex = load("res://assets/bg_prism.png") as Texture2D
		if _prism_bg_tex != null:
			# 淡入期其下透出全局清屏色（ThemeManager 正在把它渐变为新主题底）→ 衔接自然
			draw_texture_rect(_prism_bg_tex, get_viewport_rect(), false, Color(1.0, 1.0, 1.0, fade_p))
		else:
			# 贴图缺失兜底：棱镜主题自己的 bg（单源，不再写死 #141834）
			draw_rect(get_viewport_rect(), ThemeManager.bg())
	else:
		var bg := _pal_color("background", Color(0.0, 0.0, 0.0, 0.0))
		if bg.a > 0.0:
			draw_rect(get_viewport_rect(), bg)
		# 离开棱镜：旧渐变贴图在新底色上淡出
		if fade_p < 1.0 and _prism_bg_tex != null:
			draw_texture_rect(_prism_bg_tex, get_viewport_rect(), false, Color(1.0, 1.0, 1.0, 1.0 - fade_p))
	@warning_ignore("shadowed_variable_base_class")
	var size := board.grid.size()
	@warning_ignore("shadowed_variable_base_class")
	var scale := float(cell_px) / 48.0
	var font := _board_font()
	var endgame: bool = board.state != Board.GameState.PLAYING
	# 总开关状态：关闭时本帧走静止绘制路径（无收缩/无脉冲/线色原值）。
	# 这里再兜底清一次在途波浪/单格 pop，保证任何重绘入口（窗口缩放/主题切换/测试直调）都无残留。
	var effects_on := _reveal_effects_enabled()
	if not effects_on and (not _ripples.is_empty() or not _pops.is_empty()):
		_clear_wave_state()
	# 变体纹理：本帧只求值一次，逐格绘制时读缓存（见 _tex_kind_now 声明处）
	_tex_kind_now = _theme_texture()
	_tex_col_now = _texture_color() if _tex_kind_now != "" else Color(0, 0, 0, 0)

	var hex := _hex_layout()
	# CozyStyle 棋盘垫子（2026-09-29）：必须早于所有格填充，垫在下面。
	_draw_board_mat(size)
	# 异形盘的「垫子」（2026-10-09）：_draw_board_mat 是**矩形**垫，套在多边形盘上四角会露方角
	#（上面那条注释说的就是这件事），所以异形盘一直没有垫子 —— 代价是格与格之间的缝直接露出
	# 视口底色（近黑）：异形盘的格线于是变成「细线 + 高对比黑带 + 细线」，既碎又脏；
	# 而矩形盘同一位置露的是主题板色 —— 这正是玩家说的「异形关比普通关丑」的结构差异。
	# 改为**逐格外扩**的垫法：每格按「到最近邻格心的距离」外扩到中缝，相邻格的外扩层在缝里
	# 拼成连续的一片板色；各格填充随后把内部盖回去 ⇒ 缝里留下主题板色。
	# 板色不透明（CozyStyle 契约）+ 本来无缝的盘 k≈1 不画 ⇒ 两种情况下都不会改变观感。
	if _cozy_tiles() and (hex or custom):
		_draw_shape_mat()
	for r in size.y:
		for c in size.x:
			var pos := Vector2i(c, r)
			var cell := board.grid.get_cell(pos)
			# 异形拓扑（AdjacencyGrid）洞格返回 null（口径与 save/hud/stats 的 all_positions 对齐）：
			# 此前直接 _draw_cell(null) 空引用中止 _draw → 棋盘渲染整体失效。
			if cell == null:
				continue
			var rect := _cell_rect(pos)
			# 自定义盘：矩形基准换成「内容盒」——底色由多边形承担（下面的多边形填充），
			# 矩形只用来给内容（数字/问号/旗子）定位并作为动效收缩基准。见 _custom_content_rect。
			if custom:
				rect = _custom_content_rect(pos)
			# 翻开动效几何：波浪 + 单格 pop **相乘**（s_total = s_pop × s_wave）。
			# 两者都 ≤1.0 → 零间隙下相乘只会更小、天然不可能压到邻格。关闭总闸时走原矩形。
			var rrect: Rect2 = _reveal_rect_for(pos, rect) if effects_on else rect
			# pop 颜色插值进度（0→1；无 pop = 1.0 = 状态色），供 _draw_cell 混色
			var pop_e: float = _pop_progress(pos) if effects_on else 1.0
			# 自定义盘：**多边形本体**在这里填（底色层），_draw_cell 只负责内容。
			# 收缩比同样取自 rrect（wave/pop 既有几何）→ 两个动效状态机一行未改。
			if custom:
				var shrink := rrect.size.x / maxf(rect.size.x, 0.001)
				var poly_c := _cell_polygon(pos)
				if poly_c.size() >= 3:
					draw_colored_polygon(scale_polygon_about(poly_c, _cell_center(pos), shrink),
							_cell_base_color(pos, cell, pop_e))
			# 蜂窝：六边形本体在这里填（背景层），_draw_cell 只负责内接正方形与内容。
			# 两者同色（_cell_base_color）⇒ 正方形被六边形完全覆盖 = 恰好一个六边形。
			# 收缩比直接取自 rrect（wave/pop 既有几何）→ 动效在蜂窝盘上照样「原地收缩」，
			# 而**没有**改动那两个状态机的任何一行。
			elif hex:
				var shrink := rrect.size.x / maxf(rect.size.x, 0.001)
				draw_colored_polygon(hex_polygon_px(pos, _hex_unit_px, board_origin, shrink),
						_cell_base_color(pos, cell, pop_e))
			_draw_cell(pos, cell, rrect, scale, font, endgame, pop_e)
			# 变体纹理：用**内容盒**（自定义/蜂窝盘的内接矩形）定位 ⇒ 徽记不会越出多边形；
			# 仅 HIDDEN 格、仅 palette.texture 非空时绘制（无声明 = 零绘制，零回归）
			if not endgame:
				_draw_cell_texture(cell, rect, scale)

	# 波浪颜色脉冲（0 间隙方案：位移/放大被禁 → 颜色通道增强）
	if not endgame and effects_on:
		_draw_wave_color_pulse()

	# 网格线独立绘制遍（本方案主通道）：必须晚于填充与脉冲，且几何取自**原格矩形**——
	# 填充收缩时线不动，「网格永远笔直」成为结构性保证。
	_draw_grid_lines()

	# 拓扑呈现遍（环绕回卷边框 / 边界通道）：只画"这个盘是怎么回事"，不碰任何邻接语义。
	# 放在网格线之后、雷体与悬停之前：它是背景级的结构提示，不该盖住线索数字与棋子。
	_draw_topology_hints()

	# 终局揭晓（非 PLAYING）：全部雷位画雷体 + 引爆格 danger 底
	if endgame:
		_draw_mines_reveal(board, scale)
	else:
		# 试玩期「检查进度」标出来的错旗（文档 §7）。终局那一遍已经把所有错旗都画了 ⇒
		# 这里只在非终局补画，免得同一格叠出双线。
		_draw_wrong_flag_marks(scale)

	# 悬停反馈（§8.4.4；终局不响应）
	# hover_highlight 只决定"是否连带高亮 8 邻"；关闭时仍高亮鼠标所在格本身，否则悬停将毫无反馈
	if not endgame and hover_pos.x >= 0 and SettingsManager != null:
		_draw_hover_highlight(hover_pos, SettingsManager.hover_highlight)

	# 键盘光标（2px 描边框，accent alpha 0.65，与悬停可叠加）
	if not endgame and session.cursor.x >= 0 and SettingsManager != null and SettingsManager.keyboard_enabled:
		# 与格子同形：蜂窝 = 沿六边形描边；矩形 = 原 grow(-1) 逐像素不变。
		var col := ThemeManager.accent()
		col.a = 0.65
		_draw_cell_outline(session.cursor, col, 2.0, 1.0)

	if not endgame:
		_draw_hint(scale, font)
		_draw_reject()


## 无猜模式「猜测被拒」反馈：该格画一圈危险色描边，闪烁两下后淡出。
func _draw_reject() -> void:
	if _reject_pos.x < 0 or GameSession.board == null or GameSession.board.grid == null:
		return
	if not GameSession.board.grid.in_board(_reject_pos):
		return
	var remain: float = float(_reject_until_ms - Time.get_ticks_msec()) / float(REJECT_FLASH_MS)
	if remain <= 0.0:
		return
	var col := ThemeManager.danger()
	col.a = clampf(abs(sin((1.0 - remain) * TAU * 2.0)), 0.25, 1.0) * clampf(remain, 0.0, 1.0)
	_draw_cell_outline(_reject_pos, col, 3.0, 2.0)


## 提示高亮：结论格 safe=绿描边 / mine=红描边；依据线索格 accent 细描边。
## 推理文字由 HintPanel 浮动窗口显示（可拖拽/缩放/调字体），不在此绘制。
@warning_ignore("shadowed_variable_base_class")
func _draw_hint(scale: float, _font: Font) -> void:
	if _hint_steps.is_empty():
		return
	for s in _hint_steps:
		var step := s as ReasoningStep
		if step == null:
			continue
		var p: Vector2i = step.pos
		if not GameSession.board.grid.in_board(p):
			continue
		# 弱提示（对标 doc10 §3.2）：只画依据线索，不画结论格 —— 玩家自己推可推格
		if step.method != "weak":
			var col := ThemeManager.safe() if step.state == "safe" else ThemeManager.danger()
			_draw_cell_outline(p, col, 3.0 * maxf(scale, 0.6), 2.0)
		for src in step.sources:
			var sp: Vector2i = src
			if not GameSession.board.grid.in_board(sp):
				continue
			var scol := ThemeManager.accent()
			scol.a = 0.8
			_draw_cell_outline(sp, scol, 2.0, 1.0)


@warning_ignore("shadowed_variable_base_class")
@warning_ignore("unused_parameter")
func _draw_cell(pos: Vector2i, cell: Cell, rect: Rect2, scale: float, font: Font, endgame: bool, pop_e: float = 1.0) -> void:
	# 自定义盘：格子**底色**已由 _draw() 的多边形填充画好（poly_filled），此处只画内容——
	# 传入的 rect 也已换成「内容盒」（见 _custom_content_rect）：若仍 draw_rect 底色，
	# 会沿着格与格之间的缝露出一块方块（多边形不是矩形）。
	var poly_filled := _custom_layout()
	match cell.state:
		Cell.State.HIDDEN:
			if not poly_filled:
				# 走 _cell_base_color ⇒ 矩形/挖洞盘也能吃到颜色分组（分色棋盘）
				_draw_tile(rect, _cell_base_color(pos, cell, pop_e))
		Cell.State.FLAGGED:
			_draw_flag(rect, scale, not poly_filled)
		Cell.State.QUESTION:
			if not poly_filled:
				_draw_tile(rect, _cell_base_color(pos, cell, pop_e))
			_draw_question(rect, scale, font)
		Cell.State.REVEALED:
			# 单格 pop 的颜色通道：由「瞬变」改为 0.20s 内 未翻开色 → 已翻开色 插值。
			# pop_e = sin(PI*p/2) ∈ [0,1]；无 pop（静止/未登记）时传 1.0 → 精确取状态色。
			if not poly_filled:
				_draw_tile(rect, _cell_base_color(pos, cell, pop_e), true)
			_draw_clue_value(cell, rect, scale, font)


## 绘制翻开格的线索值（变体感知）：? 格 → "?"；HV 双值 → "A·B"；FR ∞ → "∞"；数字 0+（含 0 与大值，见 _draw_single_clue）。
@warning_ignore("shadowed_variable_base_class")
func _draw_clue_value(cell: Cell, rect: Rect2, scale: float, font: Font) -> void:
	# 终极模式星号格（对标 doc10 §2.4）：值对玩家隐藏，只画星号
	if cell.starred:
		var text := "*"
		var fsize := int(26.0 * maxf(scale, 0.6))
		var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
		draw_string(font,
			rect.position + Vector2((rect.size.x - tw.x) * 0.5, rect.size.y * 0.5 + tw.y * 0.34),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, ThemeManager.accent())
		return
	# ? 遮蔽格（interval 约束）
	if cell.is_hidden_clue():
		_draw_question(rect, scale, font)
		return
	# E 类线索混合：一格同时给出两个线索值 → 上下两行分绘，中线分隔
	if cell.value2 != null:
		var half_h: float = rect.size.y * 0.5
		_draw_single_clue(cell.value, Rect2(rect.position, Vector2(rect.size.x, half_h)), scale, font)
		_draw_single_clue(cell.value2, Rect2(rect.position + Vector2(0, half_h), Vector2(rect.size.x, half_h)), scale, font)
		var my: float = rect.position.y + half_h
		draw_line(Vector2(rect.position.x + 5.0 * scale, my), Vector2(rect.position.x + rect.size.x - 5.0 * scale, my), ThemeManager.grid_line(), 1.0)
		return
	_draw_single_clue(cell.value, rect, scale, font)


## 单个线索值文本绘制（居中于给定矩形；半格高度时自动缩小字号）。
@warning_ignore("shadowed_variable_base_class")
func _draw_single_clue(v: Variant, rect: Rect2, scale: float, font: Font) -> void:
	var text := ""
	# 文字色：自定义盘走 palette.revealed_text（palette 只有这一个文字色 ⇒ 数字/双值/∞ 共用它；
	# 否则数字色来自主题，压在 palette.revealed 的深底上可能糊掉）。无 palette → 主题色不变。
	# 数字色的过渡插值在 ThemeManager.number() 内部（分层过渡的配色段）。
	var col := _pal_color("revealed_text", ThemeManager.text())
	if v is Array:
		# HV 纵横分计 [正交, 对角]。防御：长度不足 2 时退化为单值，避免越界（mod 规则可能返回畸形）。
		if (v as Array).size() >= 2:
			text = "%d·%d" % [int(v[0]), int(v[1])]
		else:
			text = str(v)
	elif v is String:
		text = "∞" if v == "inf" else str(v)     # FR 首雷无雷哨兵
	elif v is int and v >= 0:
		text = str(v)
		# number(n) 对 n<1 或 n>8 退化为主文本色，所以 0 与大值（异形拓扑 dist_sum / mod 规则）
		# 都用主文本色（可读但不抢眼），不再因 v <= 12 硬上限而漏画（那会是又一种「空白格」）。
		col = _pal_color("revealed_text", ThemeManager.number(v))
	if text == "":
		return
	var fs2 := int(round(26.0 * scale))
	if rect.size.y < rect.size.x * 0.75:
		fs2 = int(round(16.0 * scale))           # 线索混合半格
	elif text.length() > 1:
		fs2 = int(round(20.0 * scale))           # 多字符（双值/∞/大数）缩小字号
	var baseline: float = rect.size.y * 0.5 + fs2 * 0.35
	# 数字辉光（近似 CSS text-shadow）：仅棱镜等主题 num_glow 不透明时生效，6 向偏移叠加伪造 bloom。
	var glow := ThemeManager.num_glow()
	if glow.a > 0.0:
		var gcol := Color(glow.r, glow.g, glow.b, glow.a * 0.5)
		for o in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1), Vector2(-1, -1), Vector2(1, 1)]:
			draw_string(font, rect.position + Vector2(0, baseline) + o, text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs2, gcol)
	draw_string(font, rect.position + Vector2(0, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs2, col)


## 居中「?」（QUESTION 标记态与 interval 遮蔽格共用，保证两处永远一致）。
## 与 _draw_single_clue 同口径：x 不手动偏移，交给 width=rect.size.x + CENTER 居中。
## 历史 bug：既手动偏移 -fs*0.3 又传 width+CENTER → 双重居中，问号右偏近半格
##（48px 格子、fs=20 时偏 18px）。
@warning_ignore("shadowed_variable_base_class")
func _draw_question(rect: Rect2, scale: float, font: Font) -> void:
	var fs := int(round(20.0 * scale))
	draw_string(font, rect.position + Vector2(0, rect.size.y * 0.5 + fs * 0.35), "?", HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, fs,
			_pal_color("revealed_text", ThemeManager.text_secondary()))


## §8.4.8 FLAGGED：HIDDEN 底 + 旗杆 draw_rect + 三角 draw_polygon（48px 基准坐标×scale）
@warning_ignore("shadowed_variable_base_class")
func _draw_flag(rect: Rect2, scale: float, with_bg: bool = true) -> void:
	if ThemeManager.flag_style() == "prism":
		_draw_flag_prism(rect, scale, with_bg)
		return
	if with_bg:
		# 走 _draw_tile 而非裸 draw_rect：CozyStyle/棱镜的格子是**圆角瓦片**，
		# 方形旗底的四角会伸出圆角外（在缝隙里露出四个小方块角）；
		# 非 Cozy 主题 _draw_tile 内部就是 draw_rect，逐像素不变。
		_draw_tile(rect, _cell_hidden_color())
	# 旗杆色：自定义盘用 palette.revealed（原版深灰）——palette.flagged_tile 是浅色，
	# 主题的 text_secondary 在深色主题下是浅色，压在浅底上会看不见；palette 无旗子专用色。
	# 无 palette 时 _custom_palette() 为空 ⇒ 恒为主题色（逐像素不变）。
	var pole_col := ThemeManager.text_secondary()
	if not _custom_palette().is_empty():
		pole_col = _pal_color("revealed", pole_col)
	var x: float = rect.position.x
	var y: float = rect.position.y
	# 旗杆 Rect2(x+22, y+10, 2, 18)
	var pole := Rect2(x + 22.0 * scale, y + 10.0 * scale, 2.0 * scale, 18.0 * scale)
	draw_rect(pole, pole_col)
	# 三角 [(x+24,y+10),(x+24,y+22),(x+37,y+16)]
	var tri := PackedVector2Array([
		Vector2(x + 24.0 * scale, y + 10.0 * scale),
		Vector2(x + 24.0 * scale, y + 22.0 * scale),
		Vector2(x + 37.0 * scale, y + 16.0 * scale),
	])
	draw_polygon(tri, PackedColorArray([ThemeManager.danger()]))


## 棱镜旗：小棱镜（三角面劈成 3 块糖果色），落在 48px 基准坐标 × scale。无旗杆（网页原版即纯棱镜图形）。
func _draw_flag_prism(rect: Rect2, scale: float, with_bg: bool) -> void:
	if with_bg:
		# 同 _draw_flag：底必须随瓦片圆角（方底四角会越出玻璃圆角）
		_draw_tile(rect, _cell_hidden_color())
	var x: float = rect.position.x
	var y: float = rect.position.y
	var apex := Vector2(x + 30.0 * scale, y + 9.0 * scale)
	var bl := Vector2(x + 16.0 * scale, y + 34.0 * scale)
	var br := Vector2(x + 40.0 * scale, y + 34.0 * scale)
	var ctr := (apex + bl + br) / 3.0
	# 糖果三色唯一事实源 = ThemeManager.flag_prism_colors()（prism 数字表前 3 色）。
	# 原先此处写死 hex，与 _COZY_NUM["cozy_prism"] 双写 ⇒ 改数字色必漂移（2026-09-30 审计）。
	var candy: Array = ThemeManager.flag_prism_colors()
	draw_polygon(PackedVector2Array([apex, bl, ctr]), PackedColorArray([candy[0]]))
	draw_polygon(PackedVector2Array([apex, br, ctr]), PackedColorArray([candy[1]]))
	draw_polygon(PackedVector2Array([bl, br, ctr]), PackedColorArray([candy[2]]))


## 终局揭晓：全部雷位画雷体（圆 + 4 刺线）；引爆格先画 danger 底。
@warning_ignore("shadowed_variable_base_class")
func _draw_mines_reveal(board: Board, scale: float) -> void:
	var exploded: Vector2i = GameSession.exploded_pos
	var body_col := ThemeManager.mine_body()
	for m in board.get_mine_positions():
		if m == exploded:
			# 引爆格高亮：与格子同形（蜂窝 = 六边形填，矩形 = 原 draw_rect）
			_draw_cell_fill(m, ThemeManager.danger())
		var center := _cell_center(m)
		draw_circle(center, 11.0 * scale, body_col)
		var spike: float = 15.0 * scale
		draw_line(center + Vector2(0, 6.0 * scale), center + Vector2(0, 6.0 * scale + spike), body_col, 1.5 * scale)
		draw_line(center - Vector2(0, 6.0 * scale), center - Vector2(0, 6.0 * scale + spike), body_col, 1.5 * scale)
		draw_line(center + Vector2(6.0 * scale, 0), center + Vector2(6.0 * scale + spike, 0), body_col, 1.5 * scale)
		draw_line(center - Vector2(6.0 * scale, 0), center - Vector2(6.0 * scale + spike, 0), body_col, 1.5 * scale)
	# 插错旗画红叉（2026-09-25）：教程（tutorial_classic_0.txt）一直承诺
	# 「插错的旗会显示红叉」，但实现里从未画过 —— 典型的「文案承诺 ≠ 实现」。
	# **只在终局揭晓时画**：对局中判断旗的对错等于泄露雷位（作弊）。
	var wrong_col := ThemeManager.danger()
	var gsz: Vector2i = board.grid.size()
	for gy in gsz.y:
		for gx in gsz.x:
			var wc: Cell = board.grid.get_cell(Vector2i(gx, gy))
			if wc == null or wc.state != Cell.State.FLAGGED:
				continue
			var wp := Vector2i(gx, gy)
			if board.is_mine(wp):
				continue
			_draw_wrong_cross(wp, scale, wrong_col)


## 「插错旗」的红叉——终局揭晓与试玩期「检查进度」**共用同一支笔**（线宽/颜色/大小只有一处定义，
## 否则两处迟早长得不一样）。
func _draw_wrong_cross(pos: Vector2i, scale: float, col: Color) -> void:
	var c := _cell_center(pos)
	var r: float = 9.0 * scale
	draw_line(c + Vector2(-r, -r), c + Vector2(r, r), col, 2.5 * scale)
	draw_line(c + Vector2(r, -r), c + Vector2(-r, r), col, 2.5 * scale)


## 试玩期「检查进度」标出来的错旗（文档 §7）。空 = 没标记。
## **只在试玩态落下**（见 `_on_progress_check_requested` 的闸），且**盘面一变就清**（见 `_on_cell_changed`）。
var _wrong_flag_marks: Array[Vector2i] = []


func _draw_wrong_flag_marks(scale: float) -> void:
	if _wrong_flag_marks.is_empty():
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var col := ThemeManager.danger()
	for pos in _wrong_flag_marks:
		if not board.grid.in_board(pos):
			continue   # 异形盘的洞格：包围盒里但不是有效格
		_draw_wrong_cross(pos, scale, col)


## 试玩期「检查进度」（文档 §7「检查进度（标记插错的旗）」）：标出插错的旗 / 收起标记。
## 【为什么只在试玩里生效】对局中当场判定旗的对错 == 泄露雷位（正式游戏是作弊）⇒
## 这里按 `playtest_return` 再兜一道闸：就算将来有人在正式对局里发这个信号，也标不出任何东西。
## 【为什么不是开关而是两个动作】标记会被盘面变化清掉，若做成"再次点击即收起"，
## 按钮显示的状态就会和实际不一致（用户按了没反应）。标/清各是一个明确动作，没有隐藏状态。
func _on_progress_check_requested(mark: bool) -> void:
	if str(GameSession.playtest_return) == "":
		return
	var board: Board = GameSession.board
	if not mark:
		if not _wrong_flag_marks.is_empty():
			_wrong_flag_marks.clear()
			queue_redraw()
		return
	_wrong_flag_marks = PROGRESS_CHECK.wrong_flags(board)   # 判据在 core，这里只落笔
	queue_redraw()


## §8.4.4 悬停高亮：中心格内陷（恒有，保证鼠标有落点反馈）
## + 8 邻柔光（仅 hover_highlight 开启时），不改变格子状态色
func _draw_hover_highlight(center_pos: Vector2i, with_neighbors: bool) -> void:
	var board: Board = GameSession.board
	if board == null:
		return
	# 中心格遮罩（与格子同形：蜂窝 = 六边形；矩形 = 原 draw_rect 逐像素不变）
	_draw_cell_fill(center_pos, ThemeManager.hover_center_overlay())
	if not with_neighbors:
		return
	# 周围邻格柔光：改走**拓扑邻域**（L5，2026-09-21 审计修复）。原实现按包围盒 8 邻偏移枚举，
	# 蜂窝盘上会把"几何相邻但拓扑不相邻"的格点亮（与线索语义矛盾，玩家会误读相邻关系）。
	# 矩形盘的 get_neighbors 就是 8 邻（含 in_board 过滤）⇒ 行为等价；形状盘则自动正确。
	for np: Vector2i in board.grid.get_neighbors(center_pos):
		_draw_cell_fill(np, ThemeManager.hover_neighbor_overlay())


# ============ 翻开动效开关（总闸 + 波浪细项） ============

## 翻开动效总闸（波浪 + 后续单格 pop）判定：唯一读点，后续单格 pop 复用本函数。
## 唯一开关即 SettingsManager.ripple_enabled（语义已扩展为总闸，界面标签「翻开动效（波浪 / 单格）」）。
## 读取刻意用 get_node_or_null 而非直接引用 autoload 名 `SettingsManager`：
## headless / 单测环境若未注册该 autoload，直接引用会在脚本解析期就报错；
## 这里把「设置系统缺失」一律按默认（开）处理，绝不抛错。
func _reveal_effects_enabled() -> bool:
	var sm: Node = get_node_or_null("/root/SettingsManager")
	if sm == null:
		return true
	var v: Variant = sm.get("ripple_enabled")
	return bool(v) if v is bool else true


## 丢弃全部翻开动效状态（波浪 + 单格 pop）与几何缓存（新对局 / 关掉总开关时复用）。
## 缓存必须同步清空——否则绘制层会残留收缩与线色高亮（收尾无残留是硬约束）；
## pop 清空后该格查不到记录 → scale 回 1.0、颜色走状态色（同样无残留）。
func _clear_wave_state() -> void:
	_ripples.clear()
	_ripple_cache.clear()
	_ripple_cache_ms = -1
	_pops.clear()
	_pop_cache.clear()
	_pop_cache_ms = -1


# ============ 单格 pop（动效规范两件套之一；与波浪**相乘**合成） ============

## 合成波浪 + pop 的绘制矩形：先取波浪收缩，再叠加 pop 收缩（两次都是绕中心相乘）。
## s_total = s_pop × s_wave，两者都落在 [0,1] → 相乘只会更小，零间隙下天然不可能压到邻格。
func _reveal_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	return _pop_rect_for(pos, _ripple_rect_for(pos, rect))


## pop 活跃期返回原地收缩后的绘制矩形（在传入矩形上绕中心乘 s_pop）；否则原样返回。
func _pop_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	var s := _pop_scale_at(pos)
	if s >= 1.0:
		return rect
	var half: Vector2 = rect.size * 0.5 * s
	var cpos: Vector2 = rect.position + rect.size * 0.5
	return Rect2(cpos - half, half * 2.0)


## 该格当前 pop 缩放：POP_SCALE_MIN + (1-POP_SCALE_MIN)*e（e 单调缓出）。
## 无记录（未登记 / 已结束被淘汰）→ 1.0（静止态，恒 <= 1.0）。at_ms 仅供测试注入时钟。
func _pop_scale_at(pos: Vector2i, at_ms: int = -1) -> float:
	var rec := _pop_rec(pos, at_ms)
	return float(rec["s"]) if not rec.is_empty() else 1.0


## 该格 pop 颜色插值进度 e ∈ [0,1]；无记录 → 1.0（= 已翻开色，静止态）。
## at_ms 仅供测试注入时钟。
func _pop_progress(pos: Vector2i, at_ms: int = -1) -> float:
	var rec := _pop_rec(pos, at_ms)
	return float(rec["e"]) if not rec.is_empty() else 1.0


## 查该格 pop 缓存记录（必要时按当前/注入时钟重算）。无记录返回空字典。
func _pop_rec(pos: Vector2i, at_ms: int = -1) -> Dictionary:
	if _pops.is_empty():
		return {}
	var now_ms := at_ms if at_ms > 0 else Time.get_ticks_msec()
	if _pop_cache_ms != now_ms:
		_rebuild_pop_cache(now_ms)
	return _pop_cache.get(pos, {})


## 重算 pop 缩放/进度缓存。at_ms 仅供测试注入时钟（<= 0 → 真实时钟）。
## p = clamp((now - t0)/POP_WD, 0, 1)；e = sin(PI*p/2)（单调缓出 0→1）；
## s = POP_SCALE_MIN + (1-POP_SCALE_MIN)*e ∈ [0.86, 1.0]（已砍过冲项，见 POP_WD 注释）。
func _rebuild_pop_cache(at_ms: int = -1) -> void:
	_pop_cache.clear()
	_pop_cache_ms = at_ms if at_ms > 0 else Time.get_ticks_msec()
	var now_ms := _pop_cache_ms
	var dur_ms: float = ThemeManager.pop_duration() * 1000.0
	for pos in _pops:
		var p: float = clampf(float(now_ms - float(_pops[pos])) / dur_ms, 0.0, 1.0)
		var e: float = sin(PI * p * 0.5)
		_pop_cache[pos] = {"e": e, "s": POP_SCALE_MIN + (1.0 - POP_SCALE_MIN) * e}


# ============ 开格波浪（§8.4.5 重写：图距离分环 + 相位差；0 间隙只走收缩/颜色通道） ============

## 环 ring 相对环 0 的起播延迟（秒）= 时间模型 delay_of 再按 WAVE_DELAY_CAP 封顶。
## 封顶策略见常量注释：环再多也不让末环无限等，总时长因此有硬上限。
func _ring_delay_sec(ring: int) -> float:
	return minf(RIPPLE_RINGS.delay_of(ring, WAVE_WS), WAVE_DELAY_CAP)


## 以 start 为环 0 起点构建一条波浪：RippleRings 按图距离分环 → 逐环错峰延迟 → cover 渐隐。
## 环内顺序不影响观感（同环延迟相同）；0 间隙下禁用位移与放大。
##
## cells：Board.flood_planned 给的**本次实际 HIDDEN→REVEALED 集合**。
##   非空 → 波浪只波及这些格（不再去点亮尚未翻开的格；环由 RippleRings 按图距离算出，
##          再与泛洪集合取交——环序错峰保证是「一圈推开」而不是「整片闪一下」）。
##   空   → 退化路径：按几何环取全盘（保留给直接调用 / 单测的兼容入口）。
func _start_wave(start: Vector2i, cells: Array = []) -> void:
	# 双保险：即便调用方（_on_flood_planned）没拦，关闭时也绝不建立波浪。
	if not _reveal_effects_enabled():
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var board_size: Vector2i = board.grid.size()
	# 拓扑无关：邻接关系由 grid 提供（矩形 8 邻 / 异形邻接表皆可）。
	var rings: Array = RIPPLE_RINGS.build(start, board_size, board.grid.get_neighbors, WAVE_MAX_RINGS)
	if rings.is_empty():
		return
	# 权威泛洪集合（非空时只让「本次真正翻开的格」参与波浪）。
	var flood_only := not cells.is_empty()
	var in_flood := {}
	for p in cells:
		in_flood[p] = true
	# 逐环收集成员：flood_only 时与泛洪集合取交（空环直接跳过，不影响环序）。
	var ring_members: Array = []
	var total_cells := 0
	for ring in rings:
		var members: Array = []
		for p in (ring as Array):
			if not flood_only or in_flood.has(p):
				members.append(p)
		ring_members.append(members)
		total_cells += members.size()
	if total_cells <= 0:
		return
	# cover 是连续参数：波及格数达到 总格数 × COVER 即停；跨过目标的那一环按
	# frac = (target - 已累计) / 环内格数 衰减振幅，避免「多一格就整环全亮」的阶跃。
	var target: int = maxi(int(floor(float(total_cells) * WAVE_COVER)), 1)
	var ring_of := {}
	var amp_of := {}
	var ring_sizes: Array = []
	var cum := 0
	var last_ring := 0
	for i in ring_members.size():
		var members: Array = ring_members[i]
		var n: int = members.size()
		if n <= 0:
			continue
		var frac := 1.0
		if cum + n > target:
			frac = clampf(float(target - cum) / float(n), 0.0, 1.0)
		if frac > 0.0:
			for p in members:
				ring_of[p] = i
				amp_of[p] = frac
			ring_sizes.append(n)
			last_ring = i
		cum += n
		if cum >= target:
			break
	if ring_of.is_empty():
		return
	# 环起播延迟表（0..last_ring）：仅供演出/校验读取，单调不降且末值 ≤ WAVE_DELAY_CAP。
	var ring_delays: Array = []
	for i in range(last_ring + 1):
		ring_delays.append(_ring_delay_sec(i))
	# 打架处理：**新波浪覆盖旧波浪**（clear 后只留这一条）。
	# 为什么选覆盖而非合并/排队：① 同一时间只有一条波浪 → 零叠加风险、收尾判断简单（无残留）；
	# ② 玩家连点时后一次点击才是意图焦点，旧波把 t0 归零重放会与新波互相打断；
	# ③ 分环只影响绘制层，覆盖不会改变任何格的状态（状态早已是最终态）。
	_ripples.clear()
	_ripples.append({
		"pos": start,
		"t0": float(Time.get_ticks_msec()),
		"ring_of": ring_of,
		"amp_of": amp_of,
		"total_rings": last_ring,
		"ring_sizes": ring_sizes,
		"ring_delays": ring_delays,
		"cells": ring_of.size(),
		"target": target,
		# 总时长 = 末环起播延迟 + 末环时长（含长尾）→ _process 依此淘汰，结束后无残留。
		# 上界 = WAVE_DELAY_CAP + WAVE_WD * WAVE_TAIL_MULT（错峰与收尾都有硬上限）。
		"total_ms": (_ring_delay_sec(last_ring) + WAVE_WD * _ring_wd_mult(last_ring, last_ring)) * 1000.0,
	})
	_ripple_cache_ms = -1
	_request_frames()


## 环 ring 的波形时长倍率：只有最后一环走「渐慢长尾」（WAVE_TAIL_MULT），其余环恒为 1。
## last_ring 由调用方传入（同一记录的末环），避免在记录尚未入队时反查全局状态。
func _ring_wd_mult(ring: int, last_ring: int) -> float:
	return WAVE_TAIL_MULT if ring == last_ring else 1.0


## 波浪高亮色（从主题派生，禁止硬编码 RGB）：以翻开底色为底向主题强调色提亮。
## 深浅两种模式下都明显「比网格线亮」，且随主题/皮肤切换自动跟随。
func _wave_glow_color() -> Color:
	var c: Color = ThemeManager.cell_revealed().lerp(ThemeManager.accent(), 0.7)
	c.a = 1.0
	return c


## pos 处于活跃波浪时返回「原地收缩」后的绘制矩形；否则原样返回。
## 几何每帧统一算一次（_rebuild_ripple_cache），此处只查表——避免 O(格子数 × 涟漪数)。
func _ripple_rect_for(pos: Vector2i, rect: Rect2) -> Rect2:
	if _ripples.is_empty():
		return rect
	if _ripple_cache_ms != Time.get_ticks_msec():
		_rebuild_ripple_cache()
	var e: Dictionary = _ripple_cache.get(pos, {})
	if e.is_empty():
		return rect
	# 0 间隙棋盘禁位移与放大（会压到邻格）：只做绕中心的原地收缩。
	var half: Vector2 = rect.size * 0.5 * float(e["s"])
	var cpos: Vector2 = rect.position + rect.size * 0.5
	return Rect2(cpos - half, half * 2.0)


## 重算波浪几何/强度缓存。at_ms 仅供测试注入时钟（<= 0 → 用真实时钟）。
## 时间轴：t = (now - t0)/1000 - 环起播延迟(ring)，waveE = sin(PI*clamp(t/WD,0,1))*振幅。
## 末环的 WD 放大 WAVE_TAIL_MULT（渐慢长尾）；waveE 是唯一能精确回到 0 的曲线，
## 故动画收尾绝不残留（s 回 1.0、线色回原值）——长尾只改时长，不改「归零」性质。
func _rebuild_ripple_cache(at_ms: int = -1) -> void:
	_ripple_cache.clear()
	_ripple_cache_ms = at_ms if at_ms > 0 else Time.get_ticks_msec()
	if _ripples.is_empty():
		return
	var now_ms := _ripple_cache_ms
	for rp in _ripples:
		var t0: float = float(rp["t0"])
		var ring_of: Dictionary = rp["ring_of"]
		var amp_of: Dictionary = rp["amp_of"]
		var last_ring: int = int(rp["total_rings"])
		for pos in ring_of:
			var ring: int = int(ring_of[pos])
			var wd: float = WAVE_WD * _ring_wd_mult(ring, last_ring)
			var t: float = float(now_ms - t0) / 1000.0 - _ring_delay_sec(ring)
			var e: float = sin(PI * clampf(t / wd, 0.0, 1.0)) * float(amp_of.get(pos, 1.0))
			if e <= 0.0:
				continue  # t<=0（未开始）或 t>=WD（已结束）→ 不入缓存 = 精确静止态
			if _ripple_cache.has(pos):
				continue  # 命中语义：首条影响该格的波浪决定其形变
			_ripple_cache[pos] = {"s": 1.0 - WAVE_SHRINK * e, "g": e}


## 波浪颜色脉冲：受波及格按 WP * 0.55 * waveE 叠加高亮色（峰值约 0.41，双主题可见）。
func _draw_wave_color_pulse() -> void:
	if _ripples.is_empty() or not _reveal_effects_enabled():
		return
	if _ripple_cache_ms != Time.get_ticks_msec():
		_rebuild_ripple_cache()
	var glow := _wave_glow_color()
	for pos in _ripple_cache:
		var g: float = float(_ripple_cache[pos]["g"])
		var a: float = WAVE_WP * WAVE_PULSE_MAX * g
		if a <= 0.0:
			continue
		var col := glow
		col.a = a
		_draw_cell_fill(pos, col)


## 波浪高亮描边的线宽：静止 = base，随波浪强度 g 线性加粗到 base + WAVE_LINE_GAIN。
## 收尾质感项「涟漪线的线宽」：波前经过时线略粗 → 边缘更锐、更「立」；
## g=0 时精确回 base（非波浪帧与旧行为逐像素一致，避免静态棋盘观感变化）。
## base 默认 1.0 = 矩形盘旧行为；异形盘传 _shape_grid_line_w()（见该函数）。
func _grid_line_width(g: float, base: float = 1.0) -> float:
	return base + WAVE_LINE_GAIN * clampf(g, 0.0, 1.0)


## 网格线独立绘制遍（0 间隙方案的主通道）。
## 几何永远取自**原格矩形**，填充即使在收缩，线层也不动 → 线永远笔直。
## 受波及格描边颜色按 glow*waveE 混向高亮色、线宽按 _grid_line_width(waveE) 略粗；
## waveE=0 时精确回到 grid_line 原色 + 1.0 线宽（无残留）。抗锯齿只在被波及格开启。
##
## 蜂窝分支（二选一里的「按六边形描边」，而非「跳过」）：矩形网格线切进六边形内部会毁掉形状，
## 而波浪高亮线宽/线色是本方案的主通道，整遍跳过等于让蜂窝盘丢掉波浪反馈。静态帧走
## **边去重 + 斜边抗锯齿**（_draw_grid_lines_dedup：共享边只画一遍、斜边平滑），波浪帧保留
## 逐格描边（_draw_grid_lines_per_cell：每格线色/线宽独立变化）。几何一律取自不收缩的
## _cell_polygon，与填充收缩解耦 ⇒ 「线永远笔直」的不变量照旧。
func _draw_grid_lines() -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	var board: Board = GameSession.board
	var board_size: Vector2i = board.grid.size()
	var line := _outline_color()
	var glow := _wave_glow_color()
	var has_wave := not _ripples.is_empty() and _reveal_effects_enabled()
	if has_wave and _ripple_cache_ms != Time.get_ticks_msec():
		_rebuild_ripple_cache()
	var custom := _custom_layout()
	if _hex_layout() or custom:
		if has_wave:
			_draw_grid_lines_per_cell(board, line, glow)
		else:
			_draw_grid_lines_dedup(line)
		# 自定义盘：**矩形/蜂窝网格线整遍跳过**（它们会切进多边形内部），轮廓已由上面的
		# 逐格多边形折线承担；随后在最上层再画花纹高亮折线（填充 → 轮廓 → 高亮）。
		if custom:
			_draw_custom_highlights()
		return
	for r in board_size.y:
		for c in board_size.x:
			var pos := Vector2i(c, r)
			if board.grid.get_cell(pos) == null:
				continue  # 异形拓扑洞格（与填充遍同口径）
			var rect := Rect2(board_origin + Vector2(c, r) * cell_px, Vector2(cell_px, cell_px))
			var col := _outline_color()
			var lw := 1.0
			if has_wave:
				var e: Dictionary = _ripple_cache.get(pos, {})
				if not e.is_empty():
					var g: float = float(e["g"])
					col = line.lerp(glow, WAVE_GLOW * g)
					lw = _grid_line_width(g)
			# CozyStyle：分格完全由瓦片**间隙**承担，静态帧一律不画 rect 描边 ——
			# 描边是沿原格矩形画的，会横切圆角、在四个角上露出方角小块。
			# 波浪帧仍画「高亮框」（翻开动效的主通道），但改走 **圆角同形** 描边
			# （_draw_tile_outline）—— 方角高亮框在棱镜大圆角下四角越出瓦片，
			# 是「格子边界超出圆角」的另一处来源；非 Cozy 主题保持方角逐像素不变。
			if _cozy_tiles():
				if lw <= 1.0:
					continue
				_draw_tile_outline(rect, col, lw, 0.0)
			else:
				# 只有被波浪波及（lw>1）时才开抗锯齿：静态帧保持原绘制路径不变。
				draw_rect(rect, col, false, lw, lw > 1.0)


## 波浪路径：逐格闭合折线（旧行为原样保留 —— 被波及格的线色/线宽逐格独立变化）。
func _draw_grid_lines_per_cell(board: Board, line: Color, glow: Color) -> void:
	var base_w := float(_shape_grid_line_w())
	for p: Vector2i in board.grid.all_positions():
		var col := _outline_color()
		var lw := base_w
		var e: Dictionary = _ripple_cache.get(p, {})
		if not e.is_empty():
			var g: float = float(e["g"])
			col = line.lerp(glow, WAVE_GLOW * g)
			lw = _grid_line_width(g, base_w)
		var poly := _cell_polygon(p)
		if poly.size() < 3:
			continue
		poly.append(poly[0])   # 闭合（draw_polyline 画的是折线）
		draw_polyline(poly, col, lw, lw > 1.0)


## 异形盘（蜂窝 / 自定义几何盘）的**视觉格边长**（像素）。
## 不直接用布局给的 cell_px：那是「内容盒」口径（蜂窝盘上只有内接正方形大小，
## ≈ 视觉格边长的 3/4），照它算线宽会整体偏细一档。
## 蜂窝 = 平顶六边形的对边距（2×内切半径）；自定义盘 = 1 个世界单位对应的像素数。
func _shape_visual_cell_px() -> float:
	if _custom_layout():
		return _custom_unit_px
	if _hex_layout():
		return 2.0 * HEX_INRADIUS * _hex_unit_px
	return float(cell_px)


## 异形盘格线宽度（整数 1~3px）——**与瓦片线稿同口径**：按视觉格边长 / LINE_REF_CELL 取整。
##
## 为什么必须按尺寸缩放：矩形/瓦片线稿一直走 _scaled_line_w（大格子上 2~3px），
## 而异形盘的格线历史上恒画 1px。1px 的**斜边**必然落在非整数像素上，同一条线
## 沿线灰阶会在 4 档之间跳（实测：横边 60px 恒为同一灰阶，斜边逐行抖 58/75/91/125）
## ⇒ 玩家描述为「线不连续 / 颗粒感 / 像素感」，而且只出现在异形盘（矩形盘没有斜边、
## 线又落在整数像素上，天然没有这个现象）。
## 线宽 ≥2px 时线芯像素被完整覆盖，沿线灰阶恒定，只剩两侧由 AA/MSAA 平滑的羽边。
func _shape_grid_line_w() -> int:
	return clampi(roundi(_shape_visual_cell_px() / LINE_REF_CELL), 1, 3)


## 静态帧：**边去重 + 斜边抗锯齿** 的网格线（蜂窝 + 自定义盘共用；矩形路径不走这里）。
## 旧逐格闭合折线把每条共享边画两遍：两侧描边因落盘量化误差（≤1e-4 世界单位，落屏
## ≤0.002px）不完全重合，偶尔错开一个像素行 → 「断线/颗粒感」。这里把全部格的边按端点
## 归并（0.05px 容差空间哈希，远小于格间最短边 ≥8px，绝不误并），每条边恰好画一次 →
## 线宽一致、连续。同时对斜边开抗锯齿：60° 对角线在 1px 无 AA 时逐列硬跳 2 行（台阶 =
## 「像素感」来源），AA 后平滑；横竖边保持无 AA（整数像素下本就精确，避免 AA 羽化晕边）。
## 线宽走 _shape_grid_line_w()：1px 细斜线沿线灰阶抖动（颗粒感）的根治手段，见该函数。
func _draw_grid_lines_dedup(line: Color) -> void:
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var lw := float(_shape_grid_line_w())
	var reps: Array[Vector2] = []   # 归并后的顶点代表表（首见坐标为准）
	var vmap: Dictionary = {}       # 0.05px 空间哈希格 → 顶点代表序号
	var edges: Dictionary = {}      # "ia|ib"（ia<ib）→ 已画过
	for p: Vector2i in board.grid.all_positions():
		var poly := _cell_polygon(p)
		if poly.size() < 3:
			continue
		var ids: Array[int] = []
		ids.resize(poly.size())
		for i in poly.size():
			ids[i] = _canon_vertex(poly[i], reps, vmap)
		for i in poly.size():
			var ia: int = ids[i]
			var ib: int = ids[(i + 1) % poly.size()]
			if ia == ib:
				continue   # 退化边（理论不出现）：跳过
			var key := "%d|%d" % [mini(ia, ib), maxi(ia, ib)]
			if edges.has(key):
				continue   # 共享边：另一格已画过，只归并不重画
			edges[key] = true
			var a := reps[ia]
			var b := reps[ib]
			# 横竖边（轴对齐）无 AA：整数像素下本就精确；斜边开 AA 消除台阶。
			var axis_aligned: bool = absf(a.y - b.y) < 0.001 or absf(a.x - b.x) < 0.001
			draw_line(a, b, line, lw, not axis_aligned)


## 顶点归并：0.05px 网格哈希 + 3×3 邻域查重，返回该顶点的代表序号。
## 容差 ~0.05px：远大于量化残差（≤0.002px）→ 两侧共享边端点必归并；远小于格间最短边
## （≥8px）→ 不同顶点绝不误并。首次见到的顶点以其精确坐标为代表（不做坐标修改）。
func _canon_vertex(v: Vector2, reps: Array[Vector2], vmap: Dictionary) -> int:
	var gx := int(floor(v.x * 20.0))
	var gy := int(floor(v.y * 20.0))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var k := Vector2i(gx + dx, gy + dy)
			if vmap.has(k):
				return int(vmap[k])
	var idx := reps.size()
	reps.append(v)
	vmap[Vector2i(gx, gy)] = idx
	return idx


# ============ 自定义盘的「雏菊链」高亮折线（花纹本体） ============

## 逐格画高亮折线：按 hl 的**顶点索引顺序** moveTo(poly[hl[0]]) 然后依次 lineTo(poly[hl[i]])
## ——开放折线、**绝不闭合**。顺序错会画出错误的图案（数据里 31 个六边形一律 (0,1,2,3)，
## 180 个五边形分 6 种朝向 × 30 个，拼出的正是「雏菊链」）；索引越界/顶点不足则整格不画。
## 线色 palette.tile_highlight（无 palette → 主题网格线色）。
# ============ 拓扑呈现（环绕 / 虫洞 / 不可能几何 / 折叠） ============
##
## 单一事实源 = `AdjacencyGrid.view_meta`（由 core/topology_model.gd 的 view_meta() 生成）。
## 本层**只画**，绝不改邻接语义：谁是邻居一律问 `grid.get_neighbors()`，
## 呈现元数据缺省（旧关卡 / 普通矩形盘）⇒ 本层整段不画，视觉零变化。

## 当前盘的呈现元数据（非 AdjacencyGrid / 无元数据 ⇒ 空字典）。
func _view_meta() -> Dictionary:
	var b: Board = GameSession.board
	if b == null or b.grid == null or not (b.grid is AdjacencyGrid):
		return {}
	var meta: Dictionary = (b.grid as AdjacencyGrid).view_meta
	return meta


## 环绕轴开关。返回 {"horizontal": bool, "vertical": bool}。
## 判据取 `view_meta.wrap`（TopologyModel 写入），缺字段时按 kind=="wrap" 兜底成全开。
func _wrap_axes() -> Dictionary:
	var meta := _view_meta()
	var w: Variant = meta.get("wrap", null)
	if w is Dictionary:
		var wd: Dictionary = w
		return {
			"horizontal": bool(wd.get("horizontal", true)),
			"vertical": bool(wd.get("vertical", true)),
		}
	if str(meta.get("kind", "")) == TopologyModel.VIEW_WRAP:
		return {"horizontal": true, "vertical": true}
	return {"horizontal": false, "vertical": false}


## 拓扑呈现主入口（环绕 = 回卷边框 / 虫洞 = 洞口徽章 / 不可能几何 = 连接透镜；
## 折叠的专属视图见各自分支）。
func _draw_topology_hints() -> void:
	var meta := _view_meta()
	if meta.is_empty():
		return
	var kind := str(meta.get("kind", ""))
	if kind == TopologyModel.VIEW_WRAP:
		_draw_wrap_hints()
	elif kind == TopologyModel.VIEW_WORMHOLE:
		_draw_wormhole_hints()
	elif kind == TopologyModel.VIEW_IMPOSSIBLE:
		_draw_impossible_hints()
	elif kind == TopologyModel.VIEW_FOLD:
		_draw_fold_hints()


## 环绕盘：一圈虚线「回卷边框」+ 四条边的双向箭头 +（悬停到边格时）穿过边界的虚线通道。
##
## 【为什么需要】环绕只改了邻接表：屏幕上 (0,y) 与 (cols-1,y) 之间没有任何视觉联系，
## 玩家看到对边格一起高亮只会觉得是 bug。边框负责"常驻地说"这盘是环绕的，
## 通道负责在悬停时把"从哪边出去、从哪边进来"当场演示一遍。
func _draw_wrap_hints() -> void:
	var axes := _wrap_axes()
	var h_on := bool(axes["horizontal"])
	var v_on := bool(axes["vertical"])
	if not h_on and not v_on:
		return
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return
	var grid: GridInterface = b.grid
	var size := grid.size()
	if size.x <= 0 or size.y <= 0:
		return
	# 棋盘包围盒（矩形路径 = 原格矩形并集；环绕盘恒走这条路径，见 WrapTopology.build 的 style="custom"）。
	# 用 _cell_rect 的两个角算，避免每帧遍历 up-to-64x64 个格。
	var bb := _cell_rect(Vector2i.ZERO).merge(_cell_rect(size - Vector2i.ONE))
	var acc := ThemeManager.accent()
	var gap := maxf(4.0, float(cell_px) * 0.18)
	var frame := bb.grow(gap)
	var lw := maxf(1.0, float(cell_px) * 0.045)
	var frame_col := acc
	frame_col.a = 0.26
	# 回卷边框：四边虚线（dash 随格宽缩放，密而不糊）
	var dash := maxf(3.0, float(cell_px) * 0.22)
	var p := frame.position
	var e := frame.end
	draw_dashed_line(Vector2(p.x, p.y), Vector2(e.x, p.y), frame_col, lw, dash)
	draw_dashed_line(Vector2(e.x, p.y), Vector2(e.x, e.y), frame_col, lw, dash)
	draw_dashed_line(Vector2(e.x, e.y), Vector2(p.x, e.y), frame_col, lw, dash)
	draw_dashed_line(Vector2(p.x, e.y), Vector2(p.x, p.y), frame_col, lw, dash)
	# 四边中点：一对内外箭头（"出得去、进得来"），只在启用的轴上画
	var arrow_col := acc
	arrow_col.a = 0.60
	var asz := maxf(4.0, float(cell_px) * 0.20)
	if h_on:
		var my := (p.y + e.y) * 0.5
		_draw_wrap_arrows(Vector2(p.x, my), Vector2(-1.0, 0.0), asz, arrow_col)
		_draw_wrap_arrows(Vector2(e.x, my), Vector2(1.0, 0.0), asz, arrow_col)
	if v_on:
		var mx := (p.x + e.x) * 0.5
		_draw_wrap_arrows(Vector2(mx, p.y), Vector2(0.0, -1.0), asz, arrow_col)
		_draw_wrap_arrows(Vector2(mx, e.y), Vector2(0.0, 1.0), asz, arrow_col)
	# 悬停通道：把"这一格跨过边界连到哪一格"画成两条穿过边框的虚线
	if hover_pos.x >= 0 and grid.in_board(hover_pos):
		_draw_wrap_tunnels(hover_pos, frame, arrow_col, lw)


## 边界双向箭头：尖端 outward，尾部两条斜线（"出/入"各一枚，形成 ⇄ 的读法）。
func _draw_wrap_arrows(tip: Vector2, outward: Vector2, sz: float, col: Color) -> void:
	var base := tip - outward * sz
	var side := Vector2(-outward.y, outward.x) * sz * 0.55
	draw_polyline(PackedVector2Array([base + side, tip, base - side]), col, 1.6, true)


## 悬停格的「环绕通道」：对每个"跨越大半个盘"的邻居各画一条穿框虚线。
## 判据：|dx|>1 或 |dy|>1（环绕折返后的邻接）——普通 8 邻恒为 1，绝不会误画。
func _draw_wrap_tunnels(pos: Vector2i, frame: Rect2, col: Color, lw: float) -> void:
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return
	var grid: GridInterface = b.grid
	var center := _cell_center(pos)
	var dash := maxf(2.0, float(cell_px) * 0.16)
	for nb in grid.get_neighbors(pos):
		var d := nb - pos
		if absi(d.x) <= 1 and absi(d.y) <= 1:
			continue
		# 出边方向 = 从对端指回本格（本格 (0,y) 的对端在 (cols-1,y) ⇒ 从左边出去）
		var dir := Vector2(signi(pos.x - nb.x), signi(pos.y - nb.y))
		var exit := _frame_exit_point(center, dir, frame)
		draw_dashed_line(center, exit, col, lw, dash)
		_draw_wrap_arrows(exit, dir, maxf(3.0, float(cell_px) * 0.16), col)
		# 入边：对端格同样画一条（从对端指向本格的方向出去）
		var dir2 := Vector2(signi(nb.x - pos.x), signi(nb.y - pos.y))
		var center2 := _cell_center(nb)
		var exit2 := _frame_exit_point(center2, dir2, frame)
		draw_dashed_line(center2, exit2, col, lw, dash)


## 从 from 沿 dir（分量取 ±1）到 frame 边框的交点。
func _frame_exit_point(from: Vector2, dir: Vector2, frame: Rect2) -> Vector2:
	var out := from
	if dir.x > 0.0:
		out.x = frame.end.x
	elif dir.x < 0.0:
		out.x = frame.position.x
	if dir.y > 0.0:
		out.y = frame.end.y
	elif dir.y < 0.0:
		out.y = frame.position.y
	return out


## —— 虫洞呈现 ——
## 【为什么需要】虫洞是"屏幕远、邻接近"的边：(0,0) 的线索数把 (7,7) 也算进去，
## 不画出来玩家只会当成数错。所以：两端常驻"洞口徽章"（同色 = 同一根管子），
## 悬停任一端时把管子**当场连起来**（虚线 + 对端放大 + 对端描边）。
## 【为什么不常驻画线】多对虫洞的连线会互相交叉成一团乱麻；徽章已经能"常驻回答"
## 谁和谁一对（同色 + 同序号），连线只在玩家主动看的时候出现。
func _draw_wormhole_hints() -> void:
	var meta := _view_meta()
	var raw: Variant = meta.get("portals", [])
	if not (raw is Array):
		return
	var portals: Array = raw
	if portals.is_empty():
		return
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return
	var grid: GridInterface = b.grid
	var count := portals.size()
	var hit: Dictionary = {}
	for i in count:
		var item_v: Variant = portals[i]
		if not (item_v is Dictionary):
			continue
		var item: Dictionary = item_v
		var a_v: Variant = TopologyModel.parse_pos(item.get("a", null))
		var b_v: Variant = TopologyModel.parse_pos(item.get("b", null))
		if a_v == null or b_v == null:
			continue
		var pa: Vector2i = a_v
		var pb: Vector2i = b_v
		if not grid.in_board(pa) or not grid.in_board(pb):
			continue
		var col := _portal_color(i, count)
		_draw_portal_badge(pa, col, 1.0)
		_draw_portal_badge(pb, col, 1.0)
		if hover_pos == pa or hover_pos == pb:
			hit = {"a": pa, "b": pb, "col": col}
	if hit.is_empty():
		return
	var ha: Vector2i = hit["a"]
	var hb: Vector2i = hit["b"]
	var hc: Color = hit["col"]
	var other: Vector2i = hb if hover_pos == ha else ha
	_draw_portal_tunnel(ha, hb, hc)
	_draw_portal_badge(other, hc, 1.8)
	_draw_cell_outline(other, hc, 2.5, 1.0)


## 一对虫洞一种颜色：从主题强调色出发按黄金角散开（任意对数都分得开、又不离主题太远）。
func _portal_color(i: int, count: int) -> Color:
	var base := ThemeManager.accent()
	var hue := fposmod(base.h + float(i) * 0.6180339887, 1.0)
	var sat := clampf(maxf(base.s, 0.55), 0.0, 1.0)
	var val := clampf(maxf(base.v, 0.88), 0.0, 1.0)
	var col := Color.from_hsv(hue, sat, val, 1.0)
	col.a = clampf(maxf(base.a, 0.9), 0.0, 1.0)
	return col


## 洞口徽章的圆心（纯几何，供绘制与测试共用）：格内左上角，避让数字所在的中宫。
func _portal_badge_at(pos: Vector2i) -> Vector2:
	var r := _cell_rect(pos)
	return r.position + Vector2(r.size.x, r.size.y) * 0.24


## 洞口徽章半径（纯几何）：随格宽缩放、有下限，再乘 hover 放大系数。
func _portal_badge_radius(pos: Vector2i, mul: float) -> float:
	var r := _cell_rect(pos)
	return maxf(3.0, minf(r.size.x, r.size.y) * 0.15) * mul


## 虫洞通道折线（纯几何）：两端格心之间一条轻微外弓的二次贝塞尔——外弓是为了不和网格线读混。
## 拆成纯函数是为了让"通道真的连到两端格心、且中点确实外弓"可以被断言（见 test_topology_view）。
func _portal_tunnel_points(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	var pa := _cell_center(a)
	var pb := _cell_center(b)
	var d := pb - pa
	var seg := 26
	var ctrl := (pa + pb) * 0.5
	if d.length() > 0.001:
		var n := Vector2(-d.y, d.x).normalized()
		ctrl += n * minf(d.length() * 0.11, maxf(6.0, float(cell_px) * 1.4))
	var pts := PackedVector2Array()
	for k in seg + 1:
		var t := float(k) / float(seg)
		pts.append(pa.lerp(ctrl, t).lerp(ctrl.lerp(pb, t), t))
	return pts


## 洞口徽章：格内左上角的"甜甜圈"（实心外环 + 深色内孔）——读作一个洞，不抢数字的位置。
func _draw_portal_badge(pos: Vector2i, col: Color, mul: float) -> void:
	var r := _cell_rect(pos)
	if r.size.x <= 0.0:
		return
	var at := _portal_badge_at(pos)
	var rad := _portal_badge_radius(pos, mul)
	draw_circle(at, rad, col)
	var ring := Color(0.0, 0.0, 0.0, clampf(col.a * 0.55, 0.0, 1.0))
	draw_arc(at, rad, 0.0, TAU, 20, ring, maxf(1.0, rad * 0.30), true)
	draw_circle(at, maxf(1.0, rad * 0.42), Color(0.0, 0.0, 0.0, clampf(col.a * 0.78, 0.0, 1.0)))


## 虫洞通道：两端格心之间一条轻微外弓的粗线（几何见 _portal_tunnel_points）。
func _draw_portal_tunnel(a: Vector2i, b: Vector2i, col: Color) -> void:
	var pts := _portal_tunnel_points(a, b)
	var lw := maxf(1.5, float(cell_px) * 0.08)
	var glow := col
	glow.a = clampf(col.a * 0.22, 0.0, 1.0)
	draw_polyline(pts, glow, lw * 2.8, true)
	draw_polyline(pts, col, lw, true)
	draw_circle(pts[0], lw * 0.85, col)
	draw_circle(pts[pts.size() - 1], lw * 0.85, col)


# ============ 连接透镜（不可能几何盘，2026-10-09） ============

## 本盘是否支持连接透镜 = 呈现种类为「不可能几何」**且**起落几何（custom_shapes）齐备。
## 为什么必须两者都判：等轴菱面的错觉来自**每个方块被拆成三个菱形面**这套几何，
## 少了几何数据就只能退回方块格子——那时「看着碰上」这件事根本不存在，透镜无话可说。
func supports_lens() -> bool:
	if str(_view_meta().get("kind", "")) != TopologyModel.VIEW_IMPOSSIBLE:
		return false
	return _custom_layout()


func lens_enabled() -> bool:
	return _lens_on


## 开关透镜（返回开启后的状态；HUD 与测试共用这一句判据）。
func toggle_lens() -> bool:
	_lens_on = not _lens_on
	queue_redraw()
	return _lens_on


## 不可能几何的「实缝 / 角接」分类（纯几何 + 邻接表；不碰 draw_* ，可单测）。
##
## 【为什么要分类】等轴菱面把每个方块画成三个菱形面，整盘读起来像一摞 3D 立方体；但引擎眼里的
## 「谁挨着谁」是**共边**（同一方块的三个面两两相连、跨方块只有特定朝向的面对相连）。于是屏幕上
## **顶点相接**（看起来碰上了）的两格可能根本不是邻居——玩家「看不清是凸还是凹、分不清算不算挨着」
## 的根源就在这儿。分类把眼睛看到的相邻拆成两批：
##   · seams  —— 图上相邻、且两格多边形**共享一条边**：at = 共享边中点（"真的焊住了"）；
##   · ghosts —— 图上**不相邻**、但两格多边形共享一个顶点：at = 该顶点（"只是看着碰上"）。
## `at` 一律是**世界坐标**（与 custom_shapes 同一坐标系），绘制侧只做一次 world→screen。
## 结果按 board 实例缓存：custom_shapes 随关卡 JSON 一次性载入、不可变 ⇒ 一局只算一次。
func _impossible_pairs() -> Dictionary:
	var b: Board = GameSession.board
	if b == null or b.grid == null or not _custom_layout():
		return {"seams": [], "ghosts": []}
	var key: int = b.get_instance_id()
	if key == _impl_key:
		return {"seams": _impl_seams, "ghosts": _impl_ghosts}
	_impl_key = key
	_impl_seams = []
	_impl_ghosts = []
	var grid: GridInterface = b.grid
	# 世界坐标多边形 +「量化顶点 → 拥有它的格」倒排表。
	# ⚠️ `_custom_cell(pos)["poly"]` **本身已经是世界绝对坐标**（_ensure_custom_cache 里
	# 就把 center 加成过了，见那里的 abs_poly）——这里再叠一次格心会让**任何两格都不再共享
	# 顶点**，症状是 seams/ghosts 双空（本实现第一版就是这么错的，被 test_topology_view 当场抓住）。
	var world_poly: Dictionary = {}
	var own: Dictionary = {}
	var vpos: Dictionary = {}
	for pos in grid.all_positions():
		var c := _custom_cell(pos)
		if c.is_empty():
			continue
		var w: PackedVector2Array = c["poly"]
		world_poly[pos] = w
		for v2: Vector2 in w:
			var vk := _impl_vkey(v2)
			if not own.has(vk):
				own[vk] = []
				vpos[vk] = v2
			(own[vk] as Array).append(pos)
	# 角接：共享顶点但**不是**邻居的格子对（同一对只记一条；顶点坐标由量化键回放）
	var seen: Dictionary = {}
	for vk2: Variant in own.keys():
		var ids: Array = own[vk2]
		if ids.size() < 2:
			continue
		var at: Vector2 = vpos[vk2]
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var pa: Vector2i = ids[i]
				var pb: Vector2i = ids[j]
				if grid.get_neighbors(pa).has(pb):
					continue
				var pk := "%d,%d|%d,%d" % [pa.x, pa.y, pb.x, pb.y]
				if seen.has(pk):
					continue
				seen[pk] = true
				_impl_ghosts.append({"a": pa, "b": pb, "at": at})
	# 实缝：图上相邻的一对，取共享边（两个共享顶点）的中点；每对只走一遍
	for pos_v: Variant in world_poly.keys():
		var a2: Vector2i = pos_v
		var poly_a: PackedVector2Array = world_poly[pos_v]
		for nb: Vector2i in grid.get_neighbors(a2):
			if not world_poly.has(nb):
				continue
			if not _impl_before(a2, nb):
				continue
			var shared := _impl_shared_vertices(poly_a, world_poly[nb])
			if shared.size() < 2:
				continue
			_impl_seams.append({"a": a2, "b": nb, "at": (shared[0] + shared[1]) * 0.5})
	return {"seams": _impl_seams, "ghosts": _impl_ghosts}


## 顶点量化键（1e4 分辨率）：同一个共享顶点由两格各自算出，浮点误差 ≪ 1e-4
##（落盘按 1e-7 量化，见 tools/gen_iso_cubes_levels.gd::_custom_shapes）。
## 分辨率不能再粗：等轴菱面的顶点间距是 0.5 世界单位，1e4 下仍有 5000 个刻度的余量。
static func _impl_vkey(v: Vector2) -> Vector2i:
	return Vector2i(int(round(v.x * 10000.0)), int(round(v.y * 10000.0)))


## 两格多边形共享的顶点（按量化键比对；返回出现在 pa 里的那些）。
static func _impl_shared_vertices(pa: PackedVector2Array, pb: PackedVector2Array) -> Array[Vector2]:
	var keys_b: Dictionary = {}
	for v: Vector2 in pb:
		keys_b[_impl_vkey(v)] = true
	var out: Array[Vector2] = []
	for v2: Vector2 in pa:
		if keys_b.has(_impl_vkey(v2)):
			out.append(v2)
	return out


## (y,x) 字典序的前后判据：让「一对边」只从一端走一遍（坐标可为负，故不写成数字比较）。
static func _impl_before(a: Vector2i, b: Vector2i) -> bool:
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


## 连接透镜的绘制入口。默认只在**悬停格**上亮出它自己的实缝与角接（悬停即问
## 「这一格到底和谁挨着」）；打开透镜后整盘常驻，把「看着连 / 真的连」一次摊开对照。
func _draw_impossible_hints() -> void:
	if not _custom_layout():
		return
	var pairs := _impossible_pairs()
	var seams: Array = pairs["seams"]
	var ghosts: Array = pairs["ghosts"]
	if seams.is_empty() and ghosts.is_empty():
		return
	var b: Board = GameSession.board
	var hover_on := hover_pos.x >= 0 and b != null and b.grid != null and b.grid.in_board(hover_pos)
	if not _lens_on and not hover_on:
		return
	for rec: Variant in seams:
		var d: Dictionary = rec
		var a: Vector2i = d["a"]
		var nb: Vector2i = d["b"]
		var hot := hover_on and (a == hover_pos or nb == hover_pos)
		if not _lens_on and not hot:
			continue
		_draw_impl_seam(d["at"], hot)
	for rec2: Variant in ghosts:
		var g: Dictionary = rec2
		var ga: Vector2i = g["a"]
		var gb: Vector2i = g["b"]
		var hot2 := hover_on and (ga == hover_pos or gb == hover_pos)
		if not _lens_on and not hot2:
			continue
		_draw_impl_ghost(g["at"], hot2)


## 实缝标记：共享边中点的一枚**实心钉**（+ 一圈压暗外环）——读作「这两格焊住了」。
func _draw_impl_seam(world_at: Vector2, hot: bool) -> void:
	var at := _custom_world_to_screen(world_at)
	var col := ThemeManager.accent()
	col.a = 0.95 if hot else 0.40
	var r := maxf(2.0, float(_custom_unit_px) * (0.10 if hot else 0.075))
	draw_circle(at, r, col)
	var ring := Color(0.0, 0.0, 0.0, clampf(col.a * 0.45, 0.0, 1.0))
	draw_arc(at, r, 0.0, TAU, 14, ring, maxf(1.0, r * 0.35), true)


## 角接标记：共享顶点上的**空心环 + 斜杠**（"∅" 的读法）——「只是看着碰上了，不算相邻」。
func _draw_impl_ghost(world_at: Vector2, hot: bool) -> void:
	var at := _custom_world_to_screen(world_at)
	var col := ThemeManager.text_secondary()
	col.a = 0.95 if hot else 0.42
	var r := maxf(2.5, float(_custom_unit_px) * (0.13 if hot else 0.10))
	var w := maxf(1.0, r * 0.32)
	draw_arc(at, r, 0.0, TAU, 16, col, w, true)
	var d := r * 0.72
	draw_line(at + Vector2(-d, -d), at + Vector2(d, d), col, w, true)


# ============ 静态折叠（折叠盘，2026-10-09） ============
#
# 【为什么需要】折叠只改了邻接表：远侧翻过去压在近侧上，(5,y) 与 (0,y) 变成真邻居，
# 但屏幕上它们仍隔着一整排格子。不画出来玩家只会觉得线索数错。呈现分两层：
#   · 常驻：折痕线（一条虚线折痕 + 指向近侧的「合拢」记号）+ 折起来时把**每一折翻走的
#     那片纸**各压暗一层（读作"这片是被翻过来盖住的"）；
#   · 摊平视图（HUD 开关）：把每对 a↔b 的镜像虚线画出来，顺着线就能看清"谁盖在谁身上"。
# 悬停任一格时把它的**所有**叠合对家当场连起来并描边（与虫洞的悬停通道同一读法）。
#
# 【多折（折纸族）】一条盘可以按顺序折好几次（风琴折 / 十字折 / 阶梯折）：
# 第 k 折翻走的那片纸 = 满足前面每一折的近侧约束、且落在第 k 折远侧的格（_fold_flap_cells）。
# 折痕线按折序画，外折实、内折淡；悬停时同一格可能连出好几条叠合线 —— 这正是"摞了几层"的读法。

## 本盘是否支持折叠视图 = 呈现种类为「折叠」**且**带折痕声明（缺一不可，理由同 supports_lens：
## 少了折痕就没有"谁盖在谁身上"可言，按钮点了没东西）。
func supports_fold() -> bool:
	if str(_view_meta().get("kind", "")) != TopologyModel.VIEW_FOLD:
		return false
	# 走 fold_list（两种声明形态都认）：单折 {axis, at} 与多折 {folds: [...]} 等价对待，
	# 免得这里只认单折 ⇒ 折纸族（多折）的按钮装不上（"core 有、UI 零引用"的老病）。
	return not _fold_folds().is_empty()


func fold_flat_enabled() -> bool:
	return _fold_flat


## 开关「摊平看」（返回摊平后的状态；HUD 与测试共用这一句判据）。
func toggle_fold_view() -> bool:
	_fold_flat = not _fold_flat
	queue_redraw()
	return _fold_flat


## 折痕声明 {axis, at}；不是折叠盘 ⇒ 空字典。
func _fold_decl() -> Dictionary:
	var meta := _view_meta()
	if str(meta.get("kind", "")) != TopologyModel.VIEW_FOLD:
		return {}
	var f: Variant = meta.get("fold", {})
	return (f as Dictionary).duplicate(true) if f is Dictionary else {}


## 折痕序列（规范化成 [{axis, at}, ...]，多折时按折序）。不是折叠盘 ⇒ 空数组。
func _fold_folds() -> Array:
	return FoldModel.fold_list(_fold_decl())


## 折叠审计（配对表 + 摞 + 最厚层数），按 board 实例 id 缓存 —— 与 _impossible_pairs 同一套路：
## 折痕随关卡 JSON 一次性载入、不可变，一局只算一次。判据完全走 FoldModel.audit_folds，
## 呈现层不自己算折痕（本仓铁律：判据只有一个事实源）。
func _fold_audit() -> Dictionary:
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return {}
	var key: int = b.get_instance_id()
	if key == _fold_key:
		return _fold_audit_cache
	_fold_key = key
	_fold_audit_cache = {}
	_fold_pairs_cache = []
	var folds := _fold_folds()
	if folds.is_empty():
		return _fold_audit_cache
	var positions: Array[Vector2i] = []
	for p in b.grid.all_positions():
		positions.append(p)
	_fold_audit_cache = FoldModel.audit_folds(folds, positions)
	_fold_pairs_cache = _fold_audit_cache["pairs"] as Array
	return _fold_audit_cache


## 配对表（a 底层 / b 覆层）。摊平视图、悬停连线与用例都读这一份。
func _fold_pairs() -> Array:
	_fold_audit()
	return _fold_pairs_cache


## 每一折画在屏幕上的位置：按折序返回 [{axis, at, seg}, ...]。
## 落位算不出来的折（盘太窄 / 洞把折痕那一列挖空）会被跳过 —— 返回条数可能少于折痕数。
## 【为什么给用例留这个口子】画布函数没法断言，把"每折各有一条折痕线"拆成几何查询就测得了。
func _fold_creases() -> Array:
	var out: Array = []
	for f_v: Variant in _fold_folds():
		var f: Dictionary = f_v
		var axis := str(f.get("axis", ""))
		var at := int(f.get("at", 0))
		var seg := _fold_crease_segment(axis, at)
		if seg.size() == 2:
			out.append({"axis": axis, "at": at, "seg": seg})
	return out


## 第 k 折翻走的那片纸：满足**前面每一折**的近侧约束，且落在第 k 折的远侧。
## 多折时"哪片纸是被哪一折翻走的"要按这个顺序算 —— 直接按 idx ≥ at 涂会重复涂到已被前面折走的区域。
func _fold_flap_cells(folds: Array, k: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var b: Board = GameSession.board
	if b == null or b.grid == null or k < 0 or k >= folds.size():
		return out
	var fk: Dictionary = folds[k]
	var k_axis := str(fk.get("axis", ""))
	var k_at := int(fk.get("at", 0))
	for p in b.grid.all_positions():
		var inside := true
		for j in k:
			var fj: Dictionary = folds[j]
			if FoldModel.index_of(p, str(fj.get("axis", ""))) >= int(fj.get("at", 0)):
				inside = false
				break
		if inside and FoldModel.index_of(p, k_axis) >= k_at:
			out.append(p)
	return out


## 折痕在屏幕上的坐标（axis x ⇒ 竖直线 x 坐标；axis y ⇒ 水平线 y 坐标）。
## 纯几何：取一对「折痕两侧都有格」的相邻格，用两格心中点定折痕 —— 对挖洞盘也稳。
## 找不到这样一对（盘太窄 / 洞把折痕那列挖空）⇒ null（调用方不画）。
func _fold_crease_coord(axis: String, at: int) -> Variant:
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return null
	var grid: GridInterface = b.grid
	var size := grid.size()
	if size.x <= 0 or size.y <= 0:
		return null
	if axis == FoldModel.AXIS_X:
		for y in size.y:
			var a := Vector2i(at - 1, y)
			var c := Vector2i(at, y)
			if grid.in_board(a) and grid.in_board(c):
				return ((_cell_center(a) + _cell_center(c)) * 0.5).x
	else:
		for x in size.x:
			var a2 := Vector2i(x, at - 1)
			var c2 := Vector2i(x, at)
			if grid.in_board(a2) and grid.in_board(c2):
				return ((_cell_center(a2) + _cell_center(c2)) * 0.5).y
	return null


## 折痕线段（纯几何，供绘制与测试共用）：横跨棋盘包围盒（外扩 gap），两端点见返回序。
func _fold_crease_segment(axis: String, at: int) -> PackedVector2Array:
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return PackedVector2Array()
	var size := b.grid.size()
	if size.x <= 0 or size.y <= 0:
		return PackedVector2Array()
	var coord_v: Variant = _fold_crease_coord(axis, at)
	if coord_v == null:
		return PackedVector2Array()
	var coord := float(coord_v)
	var bb := _cell_rect(Vector2i.ZERO).merge(_cell_rect(size - Vector2i.ONE))
	var gap := maxf(4.0, float(cell_px) * 0.18)
	var frame := bb.grow(gap)
	if axis == FoldModel.AXIS_X:
		return PackedVector2Array([Vector2(coord, frame.position.y), Vector2(coord, frame.end.y)])
	return PackedVector2Array([Vector2(frame.position.x, coord), Vector2(frame.end.x, coord)])


## 折叠呈现主入口。单折（fold_01..06）与多折（折纸族）共用这一条路径 ——
## 区别只在 _fold_folds() 返回几条折痕，绘制逻辑不做分支（免得两套画法各自跑偏）。
func _draw_fold_hints() -> void:
	if not supports_fold():
		return
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return
	var grid: GridInterface = b.grid
	var folds := _fold_folds()
	var acc := ThemeManager.accent()
	var pairs := _fold_pairs()
	# 1) 摊平视图：常驻画出每对 a↔b 的镜像虚线（谁盖在谁身上一眼可见）
	if _fold_flat:
		var link_col := acc
		link_col.a = 0.30
		for pr_v: Variant in pairs:
			var pr: Dictionary = pr_v
			_draw_fold_link(pr["a"], pr["b"], link_col, 1.0)
	else:
		# 2) 折起来：把**每一折翻走的那片纸**压暗 —— 读作"这片被翻过去盖住了"。
		#    越晚折的片涂得越浅（折序由外到内 ⇒ 视觉上正好是一层层盖上来）。
		_draw_fold_flaps(folds)
	# 3) 折痕线（常驻）+ 合拢记号：每一折各画一条，外折实、内折淡（折序一眼可辨）
	var lw := maxf(1.0, float(cell_px) * 0.045)
	var dash := maxf(3.0, float(cell_px) * 0.20)
	var k := 0
	for cr_v: Variant in _fold_creases():
		var cr: Dictionary = cr_v
		var seg: PackedVector2Array = cr["seg"]
		var crease_col := acc
		crease_col.a = maxf(0.28, 0.55 - 0.13 * float(k))
		draw_dashed_line(seg[0], seg[1], crease_col, lw, dash)
		_draw_fold_crease_marks(seg, str(cr["axis"]), crease_col)
		k += 1
	# 4) 悬停：把这一格的叠合对家当场连起来 + 描边（与虫洞的悬停通道同一读法）。
	#    多折时同一格可能被好几层压着 ⇒ 这里**不 break**，逐条全画（单折时最多一条，行为不变）。
	if hover_pos.x >= 0 and grid.in_board(hover_pos):
		for pr2_v: Variant in pairs:
			var pr2: Dictionary = pr2_v
			var pa: Vector2i = pr2["a"]
			var pb: Vector2i = pr2["b"]
			if hover_pos == pa or hover_pos == pb:
				var other: Vector2i = pb if hover_pos == pa else pa
				_draw_fold_link(hover_pos, other, acc, 1.6)
				_draw_cell_outline(other, acc, 2.5, 1.0)


## 每一折「翻走的那片纸」各压暗一层 —— 用格填充色叠低 alpha 暗色。
## 只做低 alpha：提示层晚于数字绘制，压太狠会让线索读不清。
## 第 k 折那片由 _fold_flap_cells 算（它排除掉"前面几折已经折走的区域"），
## 所以多折时既不会重复涂、也不会把已经不在纸上的格子算进来。
func _draw_fold_flaps(folds: Array) -> void:
	for k in folds.size():
		var tint := ThemeManager.text_secondary()
		tint.a = maxf(0.03, 0.08 - 0.025 * float(k))
		for p in _fold_flap_cells(folds, k):
			_draw_cell_fill(p, tint)


## 叠合连线：a↔b 之间一条轻微外弓的**虚线**（复用虫洞通道的几何，读法一致：
## 外弓是为了不和网格线读混；虚线是为了和虫洞的"实管子"区分开）。
func _draw_fold_link(a: Vector2i, b: Vector2i, col: Color, mul: float) -> void:
	var pts := _portal_tunnel_points(a, b)
	var lw := maxf(1.4, float(cell_px) * 0.055) * clampf(mul, 1.0, 2.0)
	var dash := maxf(3.0, float(cell_px) * 0.18)
	_draw_dashed_polyline(pts, col, lw, dash)
	draw_circle(pts[0], lw * 0.8, col)
	draw_circle(pts[pts.size() - 1], lw * 0.8, col)


## 折痕两端的「合拢」记号：沿折痕一串指向**近侧**的 V 形箭头（读作"远侧沿这里翻过去"）。
## 近侧方向：axis x ⇒ -x；axis y ⇒ -y（与 FoldModel 的近/远侧定义一致）。
func _draw_fold_crease_marks(seg: PackedVector2Array, axis: String, col: Color) -> void:
	var sz := maxf(4.5, float(cell_px) * 0.24)
	var dir := Vector2(-1.0, 0.0) if axis == FoldModel.AXIS_X else Vector2(0.0, -1.0)
	for t in [0.12, 0.5, 0.88]:
		_draw_fold_chevron(seg[0].lerp(seg[1], t), dir, sz, col)


## 单枚 V 形箭头：尖端在 at、开口朝 dir 的反方向（即"从这里翻向 dir"）。
func _draw_fold_chevron(at: Vector2, dir: Vector2, sz: float, col: Color) -> void:
	var back := at - dir * sz
	var side := Vector2(-dir.y, dir.x) * sz * 0.62
	draw_polyline(PackedVector2Array([back + side, at, back - side]), col, maxf(1.2, sz * 0.20), true)


## 任意折线画虚线（draw_dashed_line 只吃直线；叠合连线是外弓曲线，故自己按段切）。
## 相位跨段连续（remain 在段间传递），折点处不会出现"双倍实段 / 双倍空段"。
func _draw_dashed_polyline(pts: PackedVector2Array, col: Color, width: float, dash: float) -> void:
	if pts.size() < 2:
		return
	var on := true
	var remain := dash
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len <= 0.0001:
			continue
		var dir := seg / seg_len
		var pos := 0.0
		while pos < seg_len:
			var step := minf(remain, seg_len - pos)
			if on:
				draw_line(a + dir * pos, a + dir * (pos + step), col, width, true)
			pos += step
			remain -= step
			if remain <= 0.0001:
				on = not on
				remain = dash


func _draw_custom_highlights() -> void:
	if _custom_cells.is_empty():
		return
	var col := _pal_color("tile_highlight", ThemeManager.grid_line())
	var sc := _custom_scale()
	for key in _custom_cells:
		var cell: Dictionary = _custom_cells[key]
		# 索引序 → 屏幕顶点序列（越界/不足 → 空数组 = 整格不画）
		var pts := custom_hl_points(cell["poly"], cell["hl"], sc, board_origin)
		if pts.size() >= 2:
			_draw_hl_polyline(pts, cell["taper"], col)


## 高亮折线（含 taper 的分段变宽）。原版用一支**可缩放笔宽**的笔画这条开放折线；Godot 的
## draw_polyline 只有等宽，故此处分段变宽：普通段一条 draw_line（满宽 CUSTOM_HL_W），只有
## taper 为 true 的那一端所在段细分成 CUSTOM_HL_TAPER_STEPS 段、线宽线性过渡到 CUSTOM_HL_TAPER_W。
## ⚠️ 简化（如实标注）：真 taper 是沿笔画切向连续收细（尖端收敛到一点），本实现是**阶梯近似**
##    （段内等宽）；视觉差异 = 收细端有 ≤4 级台阶、末端是 CUSTOM_HL_TAPER_W(=1.0px) 的平头
##    而不是收敛到 0。数据里 taper=(true,true) 151 格两端都收细、(true,false)/(false,true) 各 30 格收一端。
## taper 语义：数组两端分别对应折线的首端（hl[0]）与末端（hl[last]）。
func _draw_hl_polyline(pts: PackedVector2Array, taper: Array, col: Color) -> void:
	var n := pts.size()
	for i in n - 1:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var w0 := CUSTOM_HL_W
		var w1 := CUSTOM_HL_W
		if taper.size() >= 2:
			if i == 0 and bool(taper[0]):
				w0 = CUSTOM_HL_TAPER_W
			if i == n - 2 and bool(taper[1]):
				w1 = CUSTOM_HL_TAPER_W
		if is_equal_approx(w0, w1):
			draw_line(a, b, col, w0, true)
			continue
		for k in CUSTOM_HL_TAPER_STEPS:
			var f0 := float(k) / float(CUSTOM_HL_TAPER_STEPS)
			var f1 := float(k + 1) / float(CUSTOM_HL_TAPER_STEPS)
			draw_line(a.lerp(b, f0), a.lerp(b, f1), col, lerpf(w0, w1, (f0 + f1) * 0.5), true)


# ============ 输入（§10.9；一切入口第一行检查 state == PLAYING） ============

## 语音播报（2026-09-25 无障碍审计）：棋盘内容全是 _draw 绘制，屏幕阅读器读不到任何
## 信息 —— 盲人玩家此前无法获知盘面。只在设置开启且有可用语音时播报；
## headless / 无语音环境自动跳过（测试零副作用）。
func _speak(text: String) -> void:
	if SettingsManager == null or not SettingsManager.tts_enabled or text == "":
		return
	if _tts_available < 0:
		# 语音枚举有开销，只查一次（测试/无语音环境恒为 0，之后直接短路）
		_tts_available = 0 if DisplayServer.tts_get_voices().is_empty() else 1
	if _tts_available == 0:
		return
	DisplayServer.tts_stop()      # 打断上一句：连续移动时不排队积压
	DisplayServer.tts_speak(text, "")


## 播报光标格的位置与**玩家可见**状态（红线：不得泄露雷位；星号/遮蔽格如实说明）。
func _announce_cursor(pos: Vector2i) -> void:
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	var cell: Cell = board.grid.get_cell(pos)
	if cell == null:
		return
	var where := "第 %d 行 第 %d 列" % [pos.y + 1, pos.x + 1]
	match cell.state:
		Cell.State.HIDDEN:
			_speak(where + "，未翻开")
		Cell.State.FLAGGED:
			_speak(where + "，已插旗")
		Cell.State.QUESTION:
			_speak(where + "，问号")
		Cell.State.REVEALED:
			if cell.starred:
				_speak(where + "，线索已隐藏")
			elif cell.is_hidden_clue():
				_speak(where + "，遮蔽线索格")
			elif cell.value is int:
				var n := int(cell.value)
				_speak((where + "，数字 %d" % n) if n > 0 else (where + "，空白"))
			else:
				_speak(where + "，特殊线索格")


## 触摸事件处理：短按翻开 / 长按插旗（计时器到点触发）/ 拖动取消（见 _gui_input 的 drag 分支）。
func _handle_screen_touch(ev: InputEventScreenTouch) -> void:
	_last_touch_ms = Time.get_ticks_msec()
	accept_event()
	if GameSession.state != GameSession.State.PLAYING:
		_touch_timer.stop()
		_touch_pos = Vector2i(-1, -1)
		return
	# 坐标换算：InputEventScreenTouch.position 是**屏幕坐标**（鼠标事件在 _gui_input 里
	# 已被引擎换算成控件局部坐标，触摸没有）——减去控件原点才是 _pick 期望的局部坐标。
	var pos := _pick(ev.position - global_position)
	if ev.pressed:
		if pos.x < 0:
			_touch_pos = Vector2i(-1, -1)
			return
		_touch_pos = pos
		_touch_long_fired = false
		_touch_timer.start()
	else:
		_touch_timer.stop()
		var tap_ok := pos.x >= 0 and pos == _touch_pos and not _touch_long_fired
		_touch_pos = Vector2i(-1, -1)
		_touch_long_fired = false
		if not tap_ok:
			return
		# 短按 = 与鼠标左键同口径（点已翻开的数字格则一键展开）
		if _quick_actions_enabled() and _is_revealed(pos):
			GameSession.chord(pos)
		else:
			GameSession.reveal(pos)


## 长按判定到点：插旗（触屏没有右键）；已翻开的数字格则一键展开（替代鼠标二次点击）。
## 震动反馈只在移动设备有效，桌面静默忽略。
func _on_touch_long_press() -> void:
	if _touch_pos.x < 0 or GameSession.state != GameSession.State.PLAYING:
		return
	_touch_long_fired = true
	if _is_revealed(_touch_pos):
		GameSession.chord(_touch_pos)
	else:
		GameSession.toggle_flag(_touch_pos)
	Input.vibrate_handheld(30)


func _gui_input(event: InputEvent) -> void:
	# 触摸手势（独立于模拟鼠标，见 TOUCH_LONG_PRESS_MS 处注释）
	if event is InputEventScreenTouch:
		_handle_screen_touch(event as InputEventScreenTouch)
		return
	if event is InputEventScreenDrag:
		_touch_timer.stop()              # 拖动 = 取消长按（否则拖过格子会误插旗）
		_touch_pos = Vector2i(-1, -1)
		return
	if event is InputEventMouseButton \
			and Time.get_ticks_msec() - _last_touch_ms < TOUCH_MOUSE_SUPPRESS_MS:
		# 该鼠标事件是触摸合成的：手势已由 _handle_screen_touch 处理，这里吞掉避免双触发
		return
	if event is InputEventMouseButton:
		if GameSession.state != GameSession.State.PLAYING:
			return  # 终局冻结（重开/返回是 HUD/GameOver 层的例外按钮）
		# 伙伴优先于格子：先问它一下。命中就吞掉事件 —— 伙伴撞不到格子（停靠区在棋盘
		# 右边缘之外），所以"优先"在这里不会抢走任何一次翻格。
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and _pet_touched():
			accept_event()
			return
		var pos := _pick(event.position)
		if pos.x < 0:
			return
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			# 双击的第二下必须忽略（2026-09-25 审计）：第一次点击已把该格翻开，
			# 第二下会落到下面的 chord 分支 —— 玩家只是手快连点，却可能因
			# 「邻域旗数恰好等于数字」而当场引爆。单击才是 chord 的唯一入口。
			if event.double_click:
				accept_event()
				return
			# 左键点已翻开的数字格 = 一键展开（chord）；点未翻开格 = 正常翻开
			if _quick_actions_enabled() and _is_revealed(pos):
				GameSession.chord(pos)
			else:
				GameSession.reveal(pos)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			if _quick_actions_enabled():
				GameSession.chord(pos)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			GameSession.toggle_flag(pos)
			# 按住右键拖动 = 连续插旗（与 chord 同源的 QoL，市面标配）
			if _quick_actions_enabled():
				_flag_dragging = true
				_flag_drag_last = pos
			accept_event()
		elif event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
			_flag_dragging = false
			_flag_drag_last = Vector2i(-1, -1)
			accept_event()
	elif event is InputEventMouseMotion:
		if GameSession.state == GameSession.State.PLAYING:
			var pos := _pick(event.position)
			if _flag_dragging and (event.button_mask & MOUSE_BUTTON_MASK_RIGHT) != 0:
				# 拖动只「插」不「取消」：每进入一个新格补一面旗，
				# 避免把已插好的旗拖没了（拖动中不做 toggle 循环）
				if pos.x >= 0 and pos != _flag_drag_last:
					_flag_drag_last = pos
					_flag_if_hidden(pos)
			if pos != hover_pos:
				hover_pos = pos
				queue_redraw()


## 最上层的可见弹出层（设置弹窗 / 确认框 / 暂停面板）；没有则返回 null。
## ★ 历史 bug：PopupPanel/ConfirmationDialog **不会自动吃掉未处理的按键**，
## 于是设置弹窗开着时按 R 会把对局重开、按空格还在翻格。这里显式让弹窗优先。
func _first_visible_popup() -> Window:
	var tree := get_tree()
	if tree == null:
		return null
	return _scan_window(tree.root)


func _has_open_popup() -> bool:
	return _first_visible_popup() != null


func _scan_window(n: Node) -> Window:
	for c in n.get_children():
		var w := _scan_window(c)
		if w != null:
			return w
		if c is Window and c != get_tree().root and (c as Window).visible:
			return c as Window
	return null


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	# 长按按键的自动重复（echo）必须忽略（2026-09-25 审计）：否则长按 F 会在
	# 隐藏→旗→问号 间循环、长按 H 反复扣提示充能、长按空格连发翻格、长按 R 连弹重开框。
	# **移动键例外**：它本来就靠 echo 连发（长按方向键连续移动是期望行为，见下方 match）。
	if event.echo:
		var kc_echo: int = (event as InputEventKey).keycode
		if kc_echo in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
				SettingsManager.key_for("move_up"), SettingsManager.key_for("move_down"),
				SettingsManager.key_for("move_left"), SettingsManager.key_for("move_right")]:
			pass
		else:
			return
	# ESC 关闭最上层弹窗（Godot 的 Window/Popup 不自带 ESC 关闭行为）
	if event.keycode == KEY_ESCAPE:
		var top := _first_visible_popup()
		if top != null:
			top.hide()
			accept_event()
			return
	if _has_open_popup():
		return
	if SettingsManager != null and not SettingsManager.keyboard_enabled:
		return
	if GameSession.state != GameSession.State.PLAYING:
		# 重开是终局例外（HUD/GameOver 也有按钮；键盘通道同样允许）。
		# PAUSED 不放行：对局仍在进行，直接重开会绕过 ui_confirm 的二次确认（误触丢进度）。
		if event.keycode == SettingsManager.key_for("restart") and GameSession.state == GameSession.State.ENDED:
			GameSession.restart()
			accept_event()
		return
	# 绘画模式切换键（可重绑定）
	if event.keycode == SettingsManager.key_for("draw") and not event.ctrl_pressed and not event.shift_pressed:
		_toggle_paint_mode()
		accept_event()
		return
	# 绘画模式：只响应绘画快捷键，忽略翻格/插旗/移动等游戏键
	if _drawing != null and _drawing.is_paint_mode():
		if _handle_paint_key(event):
			accept_event()
		return
	# 暂停 / 继续键（State.PAUSED 此前从未被任何 UI 触发，这里给它的真实入口）
	if event.keycode == SettingsManager.key_for("pause"):
		_toggle_pause()
		accept_event()
		return
	var board: Board = GameSession.board
	if board == null or board.grid == null:
		return
	@warning_ignore("shadowed_variable_base_class")
	var size := board.grid.size()
	var cur: Vector2i = GameSession.cursor
	var handled := true
	# 键位查表（2026-09-25 无障碍审计）：所有动作走 SettingsManager.key_for ——
	# 玩家可在设置页「按键」分区重绑定。**方向键/回车/翻页键仍是硬编码附加键**
	# （不参与重绑定，见 SettingsManager.RESERVED_KEYS），保证改键后导航能力永不丢失。
	var kc: int = (event as InputEventKey).keycode
	# 2026-09-28（用户决策）：**进行中**的 R 键重开已删除（HUD 按钮与暂停菜单同步删）。
	# 终局（ENDED）的键盘重开仍可用——见本函数上方的终局例外分支与结算层按钮。
	if kc == SettingsManager.key_for("undo"):
		# 游戏操作撤销（与绘画模式的 Ctrl+Z 撤销笔迹独立：绘画模式此处分流不到这）
		if event.ctrl_pressed and not event.shift_pressed:
			GameSession.undo_move()
		else:
			handled = false
	elif kc == SettingsManager.key_for("flag"):
		GameSession.toggle_flag(cur)
	elif kc == SettingsManager.key_for("hint"):
		GameSession.request_hint()
	elif kc == SettingsManager.key_for("reveal") or kc == KEY_ENTER:
		# 与鼠标同口径：光标停在已翻开的数字格上时执行一键展开（回车是附加键）
		if _quick_actions_enabled() and _is_revealed(cur):
			GameSession.chord(cur)
		else:
			GameSession.reveal(cur)
	elif kc == KEY_HOME:
		cur.x = 0
	elif kc == KEY_END:
		cur.x = size.x - 1
	elif kc == KEY_PAGEUP:
		cur.y = 0
	elif kc == KEY_PAGEDOWN:
		cur.y = size.y - 1
	elif kc == SettingsManager.key_for("move_up") or kc == KEY_UP:
		cur.y = maxi(cur.y - 1, 0)
	elif kc == SettingsManager.key_for("move_down") or kc == KEY_DOWN:
		cur.y = mini(cur.y + 1, size.y - 1)
	elif kc == SettingsManager.key_for("move_left") or kc == KEY_LEFT:
		if cur.x == 0:
			# 回环：左边界 → 上一行右端
			if cur.y > 0:
				cur.y -= 1
				cur.x = size.x - 1
		else:
			cur.x -= 1
	elif kc == SettingsManager.key_for("move_right") or kc == KEY_RIGHT:
		if cur.x == size.x - 1:
			# 回环：右边界 → 下一行左端
			if cur.y < size.y - 1:
				cur.y += 1
				cur.x = 0
		else:
			cur.x += 1
	else:
		handled = false
	if handled:
		GameSession.cursor = cur
		queue_redraw()
		accept_event()
		# 语音播报（2026-09-25 无障碍）：键盘是无障碍主通道，操作后播报光标格状态
		_announce_cursor(cur)


# ============ 绘画模式（P 键 / 快捷键） ============

func _toggle_paint_mode() -> void:
	if _drawing != null:
		_drawing.toggle_paint_mode()
		if _toolbar != null:
			_toolbar.refresh()


## 绘画模式下的快捷键：ESC 退出 / E 橡皮 / C 清空 / 1~7 选色 / [ ] 粗细 / Ctrl+Z·Y 撤销重做
func _handle_paint_key(event: InputEventKey) -> bool:
	if event.ctrl_pressed:
		if event.keycode == KEY_Z:
			if event.shift_pressed:
				_drawing.redo()
			else:
				_drawing.undo()
			return true
		if event.keycode == KEY_Y:
			_drawing.redo()
			return true
		return false
	match event.keycode:
		KEY_ESCAPE:
			_drawing.set_paint_mode(false)
			if _toolbar != null:
				_toolbar.refresh()
			return true
		KEY_E:
			_drawing.toggle_eraser()
			return true
		KEY_C:
			_drawing.clear_all()
			return true
		KEY_1:
			_drawing.set_color(0)
			return true
		KEY_2:
			_drawing.set_color(1)
			return true
		KEY_3:
			_drawing.set_color(2)
			return true
		KEY_4:
			_drawing.set_color(3)
			return true
		KEY_5:
			_drawing.set_color(4)
			return true
		KEY_6:
			_drawing.set_color(5)
			return true
		KEY_7:
			_drawing.set_color(6)
			return true
		KEY_BRACKETLEFT:
			_drawing.cycle_size(-1)
			return true
		KEY_BRACKETRIGHT:
			_drawing.cycle_size(1)
			return true
	return false


# ============ 暂停 / 破坏性操作确认 ============

## 暂停 / 继续。GameSession.set_paused 此前只有测试在调用，这里是它真实的 UI 入口。
func _toggle_pause() -> void:
	if GameSession.state == GameSession.State.PAUSED:
		GameSession.set_paused(false)
		if _pause_menu != null:
			_pause_menu.hide()
		queue_redraw()
	elif GameSession.state == GameSession.State.PLAYING:
		GameSession.set_paused(true)
		if _pause_menu != null:
			_pause_menu.popup_center_refreshed()
	# 伙伴跟着暂停/继续（见 _sync_pet_frozen 的两条理由）
	_sync_pet_frozen()



## 外部入口（HUD「暂停」按钮）。
func toggle_pause() -> void:
	_toggle_pause()


## 2026-09-28（用户决策）：**进行中**的重开入口已全部移除（HUD 按钮 / R 键 / 暂停菜单），
## 本函数当前**无 UI 调用者**。保留原因：UiConfirm.confirm_restart 的「有进度才确认」口径
## 仍被 test_ui_confirm 覆盖，且终局重开若将来需要二次确认可直接复用。
## 历史理由（保留）：重开是不可撤销的破坏性操作：R 键与 WASD 光标键同处主键盘区，误触代价是丢整局。
func _confirm_restart() -> void:
	UiConfirm.confirm_restart(self, func(): GameSession.restart())


## 连携操作总开关（一键展开 chord + 右键拖动插旗）。默认开启，可在设置页关掉。
func _quick_actions_enabled() -> bool:
	return SettingsManager == null or SettingsManager.quick_actions


## 右键拖动状态（连续插旗）
var _flag_dragging := false
var _flag_drag_last: Vector2i = Vector2i(-1, -1)


## 拖动插旗：只对未翻开格生效（不取消已有旗）。
func _flag_if_hidden(pos: Vector2i) -> void:
	if GameSession.board == null or GameSession.board.grid == null:
		return
	if not GameSession.board.grid.in_board(pos):
		return
	var cell := GameSession.board.grid.get_cell(pos)
	if cell != null and cell.state == Cell.State.HIDDEN:
		GameSession.toggle_flag(pos)


## 该格是否已翻开（决定左键/空格走「翻开」还是「一键展开」）。
func _is_revealed(pos: Vector2i) -> bool:
	if GameSession.board == null or GameSession.board.grid == null:
		return false
	var cell := GameSession.board.grid.get_cell(pos)
	return cell != null and cell.state == Cell.State.REVEALED


func _pick(local_pos: Vector2) -> Vector2i:
	if cell_px <= 0:
		return Vector2i(-1, -1)
	if GameSession.board == null or GameSession.board.grid == null:
		return Vector2i(-1, -1)
	if _custom_layout():
		return _pick_custom(local_pos)
	if _hex_layout():
		return _pick_hex(local_pos)
	var rel := local_pos - board_origin
	var c := floori(rel.x / float(cell_px))
	var r := floori(rel.y / float(cell_px))
	@warning_ignore("shadowed_variable_base_class")
	var size := GameSession.board.grid.size()
	if c < 0 or c >= size.x or r < 0 or r >= size.y:
		return Vector2i(-1, -1)
	# 异形拓扑洞格：包围盒内的洞不是有效格（与 _draw/save/hud 的 all_positions 口径对齐）
	if GameSession.board.grid.get_cell(Vector2i(c, r)) == null:
		return Vector2i(-1, -1)
	return Vector2i(c, r)


## 蜂窝命中测试：取最近的格心，距离 ≤ 内切半径 × 1.15 才算命中（否则返回 -1,-1）。
## 为什么取「最近格心」而不是像矩形那样反算行列：六边形格心是斜交晶格，且盘是被**截断**的
## （包围盒内有洞格），反算出的最近格可能落在盘外还得再做邻居搜索——本盘最多几十格，直接扫全格心
## 更短也更不容易写错。1.15 的宽容：相邻格心距 0.866 > 两格内切半径和 0.823，六边形之间本就留了
## ~5% 的缝，恰好点在缝里时不该「点了个空」（也顺便盖住半个格子的边缘误点）。
func _pick_hex(local_pos: Vector2) -> Vector2i:
	var limit := HEX_INRADIUS * 1.15 * _unit_px()
	var best := Vector2i(-1, -1)
	var best_d := limit
	for p: Vector2i in GameSession.board.grid.all_positions():
		var d := local_pos.distance_to(_cell_center(p))
		if d <= best_d:
			best_d = d
			best = p
	return best


## 自定义盘命中测试：**多边形包含判定**（不是「最近格心」）。为什么不用最近格心：本盘每格形状
## 与朝向都不同（尖角五边形/六边形混排），最近格心会在尖角处把点判给邻格。
## 211 格全扫一遍、每帧最多一次（hover）可接受；先用外接矩形（_cell_rect）粗筛，再做精确判定。
## 多边形两两不重叠（数据已核：0 对相交）⇒ 首个命中即唯一命中，遍历序不影响结果。
func _pick_custom(local_pos: Vector2) -> Vector2i:
	var b: Board = GameSession.board
	if b == null or b.grid == null:
		return Vector2i(-1, -1)
	for p: Vector2i in b.grid.all_positions():
		if not _cell_rect(p).has_point(local_pos):
			continue
		if custom_point_in_cell(local_pos, _cell_polygon(p)):
			return p
	return Vector2i(-1, -1)
