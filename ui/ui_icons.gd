# ui_icons.gd —— 程序化图标工厂（**不声明 class_name**，调用方走 preload）
#
# 为什么集中到一处：本工程不引入外部图标资源，图标一律"内联 SVG 字符串 → ImageTexture"。
# 「书」这个造型在**两处**用到 —— 选关页右上角的规则图鉴、对局 HUD 的教程入口。
# 它前后迭代过两轮才定下来（下面 `book()` 的注释记着），再抄一份必然漂移；
# 而且漂移的表现是"两个地方的书长得不一样"，肉眼很难断言，只能靠截图偶然发现。
#
# ⚠️ 刻意**不写 `class_name`**：headless 下新全局类不在 `.godot` 缓存里会报
#    "Identifier not found"（坑表 #26；`ui/hud.gd` 开头对 TutorialOverlayScript 有同样的
#    处理）。调用方写 `const Icons := preload("res://ui/ui_icons.gd")` 即可，
#    static 函数在 preload 实例上照样能调。
#
# 着色口径：SVG 里的 `fill="#FFFFFF"` 是**占位**，真实颜色由 Button 的
# `icon_normal_color` 等主题项覆盖（见 ui/level_select.gd::_style_icon_button）。
# 这样同一个纹理在七套主题下自动跟着 text() 走，不必每个主题烘一份纹理。
extends RefCounted


## 内联 SVG 字符串 → 纹理。失败/空图返回 null（图标缺失不影响按钮可点性，只少个图案）。
static func texture(svg: String) -> Texture2D:
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


## 书本（规则图鉴 / 教程）：**展开的书**——上下各向书脊收腰的单片剪影，32×32 视图框。
##
## 2026-09-29 重画，两次迭代（原始记录见 ui/level_select.gd 的历史）：
##   ① 旧版两页是**贴合**的（左页画到 x=16、右页从 x=16 起，只在上下沿留了个 2px 的弧口），
##      缩到 22px 时弧口被抗锯齿糊掉 ⇒ 整个图标退化成**一块深色圆角方块**
##      （放大截图确认：与齿轮并排时就是"方块 + 齿轮"）。
##   ② 改成"两片留 3px 中缝的独立圆角矩形"后又踩一坑：22px 下读作 **⏸ 暂停**——
##      两片等高、等宽、竖直平行的方块，与播放器暂停图标是同一个形状。
##
## 终版用**单片剪影**：封面两端 (2.8,2.6)/(29.2,2.6) 比书脊 (16,6.6)/(16,29.4) 高，
## 上下各向中间收 4px 的腰 ⇒ 一眼是"摊开的书"，不可能与暂停混淆；
## 且只有一条轮廓，小尺寸下没有会被糊掉的内缝。上下对称（y 2.6..29.4，中心 16）——
## 图标本身偏心的话，正方形按钮里摆正也救不回来。
static func book() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><path fill=\"#FFFFFF\" d=\"M16 6.6 L2.8 2.6 V26.2 L16 29.4 L29.2 26.2 V2.6 Z\"/></svg>")


## 齿轮（设置）：evenodd 圆环 + 4 直齿 + 4 斜齿，32×32 视图框。
##
## 2026-09-29 造型对齐 CozyStyle：CozySudoku 的齿轮是**厚环 + 圆头短齿**的胖齿轮，
## 缩到 40×40 按钮上（≈22px）依然认得出是齿轮。旧版齿宽 4、环厚 5 在 22px 下齿会细成
## 一排毛刺。现取 环厚 5.6（外 9.5 / 孔 3.9）+ 齿 5.4×6.6 / rx 1.8。
##
## ⚠️ 齿必须**压进环里** 1.3px（齿根圆心距离 = 9.5 + 3.3 − 1.3 = 11.5）。
##    旧版齿根正好停在环外沿（y=7 == 16−9），抗锯齿下一圈会有肉眼可见的**接缝**。
static func gear() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><g fill=\"#FFFFFF\"><path fill-rule=\"evenodd\" d=\"M16 6.5a9.5 9.5 0 1 1 0 19 9.5 9.5 0 0 1 0-19zm0 5.6a3.9 3.9 0 1 0 0 7.8 3.9 3.9 0 0 0 0-7.8z\"/><rect x=\"13.3\" y=\"1.2\" width=\"5.4\" height=\"6.6\" rx=\"1.8\"/><rect x=\"13.3\" y=\"24.2\" width=\"5.4\" height=\"6.6\" rx=\"1.8\"/><rect x=\"1.2\" y=\"13.3\" width=\"6.6\" height=\"5.4\" rx=\"1.8\"/><rect x=\"24.2\" y=\"13.3\" width=\"6.6\" height=\"5.4\" rx=\"1.8\"/><rect x=\"5.17\" y=\"4.57\" width=\"5.4\" height=\"6.6\" rx=\"1.8\" transform=\"rotate(-45 7.87 7.87)\"/><rect x=\"21.43\" y=\"4.57\" width=\"5.4\" height=\"6.6\" rx=\"1.8\" transform=\"rotate(45 24.13 7.87)\"/><rect x=\"5.17\" y=\"20.83\" width=\"5.4\" height=\"6.6\" rx=\"1.8\" transform=\"rotate(45 7.87 24.13)\"/><rect x=\"21.43\" y=\"20.83\" width=\"5.4\" height=\"6.6\" rx=\"1.8\" transform=\"rotate(-45 24.13 24.13)\"/></g></svg>")


## 地雷（对局 HUD 的「剩余雷数」读数）：经典扫雷符号 —— 圆体 + 八向引信 + 高光。
## 八向引信 = 横 / 竖两根 + rotate(45) 复用同一对，全部画在圆体**下面**，
## 圆体 r=9.2 只盖住中段，四向各露 4.6px 的尖。
##
## 为什么用图标而不是继续写「剩余雷数 10」：这是一次**形态**改造（用户 2026-09-29 授权），
## 「雷 + 计数」是扫雷类型里比文字更通用的记法（Windows 扫雷同款），
## 而且把「剩余」这个语义从字面上挪给了 tooltip —— 顶栏因此少一段固定文案。
## 负数（旗标比雷多）用 danger 字色 + tooltip 说明，不再拖一句长括号。
static func mine() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><g fill=\"#FFFFFF\"><rect x=\"14.6\" y=\"2.2\" width=\"2.8\" height=\"27.6\" rx=\"1.4\"/><rect x=\"2.2\" y=\"14.6\" width=\"27.6\" height=\"2.8\" rx=\"1.4\"/><g transform=\"rotate(45 16 16)\"><rect x=\"14.6\" y=\"2.2\" width=\"2.8\" height=\"27.6\" rx=\"1.4\"/><rect x=\"2.2\" y=\"14.6\" width=\"27.6\" height=\"2.8\" rx=\"1.4\"/></g><circle cx=\"16\" cy=\"16\" r=\"9.2\"/><circle cx=\"12.7\" cy=\"12.7\" r=\"2.3\" opacity=\"0.55\"/></g></svg>")


## 时钟（对局 HUD 的计时读数）：厚环 + 指向 12 与 3 的两根圆头指针。
##
## ⚠️ 刻意**全用填充**、不用 stroke：ThorVG 对 `fill="none" stroke="…"` 的支持在本工程
##    其余图标上没验证过，而 `_svg_texture` 失败是**静默**降级（按钮少个图案）。
##    全填充与齿轮/书本同一条已验证的路径。
static func clock() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><g fill=\"#FFFFFF\"><path fill-rule=\"evenodd\" d=\"M16 3.8a12.2 12.2 0 1 1 0 24.4 12.2 12.2 0 0 1 0-24.4zm0 3.4a8.8 8.8 0 1 0 0 17.6 8.8 8.8 0 0 0 0-17.6z\"/><rect x=\"14.7\" y=\"8.9\" width=\"2.6\" height=\"7.5\" rx=\"1.3\"/><rect x=\"14.7\" y=\"14.7\" width=\"6.9\" height=\"2.6\" rx=\"1.3\"/></g></svg>")


## ✕（浮动弹窗关闭）：两根 45° 圆头短棒交叉，32×32 视图框。
##
## 为什么做成图标（2026-09-29 用户反馈「教程和叉号在右上角有些突兀」）：
## 原先关闭按钮直接写 text = "✕"，字符叉的笔画粗细 / 大小 / 垂直位置**跟字体走**
## （文源圆体的 ✕ 又粗又靠上），与标题栏并排的图标体系放在一起明显突兀；
## 换成与齿轮 / 书本同一套「内联 SVG + icon 色主题项」后，粗细、颜色、悬停着色
## 全部自动与其它图标一致。
static func close() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><g fill=\"#FFFFFF\"><rect x=\"14.4\" y=\"3.5\" width=\"3.2\" height=\"25\" rx=\"1.6\" transform=\"rotate(45 16 16)\"/><rect x=\"14.4\" y=\"3.5\" width=\"3.2\" height=\"25\" rx=\"1.6\" transform=\"rotate(-45 16 16)\"/></g></svg>")


## 灯泡（提示）：圆顶 + 收腰灯颈 + 两道灯座。
## 顶栏右上角与毛笔组成**图标工具簇**（对齐 CozySudoku 顶栏右侧一排白色线性图标的做法）；
## 禁用态（提示模式关掉）由 `icon_disabled_color` 走 text_secondary()，不另画灰版。
static func hint() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><g fill=\"#FFFFFF\"><circle cx=\"16\" cy=\"12.6\" r=\"9.2\"/><path d=\"M10.4 18.4h11.2v3.2a2 2 0 0 1-2 2h-7.2a2 2 0 0 1-2-2z\"/><rect x=\"12.2\" y=\"25\" width=\"7.6\" height=\"2.4\" rx=\"1.2\"/><rect x=\"13\" y=\"28.2\" width=\"6\" height=\"2.4\" rx=\"1.2\"/></g></svg>")


## 调色板（换肤/主题切换）：**实心圆盘 + 拇指孔 + 三个颜料孔**的剪影，32×32 视图框。
##
## 造型口径与齿轮/时钟同一条已验证路径：**全填充**（ThorVG 的 stroke 支持在本工程
## 没验证过，且 `_svg_texture` 失败是静默降级）。evenodd 让拇指孔与颜料孔成为"透底"的
## 洞 —— 白模被按钮的 icon 色乘色后，洞里露出的是按钮底色，缩到 22px 时
## 「圆盘 + 3 个点 + 一个偏心大孔」依然读作调色板，不会退化成一块曲奇。
## 三个颜料孔特意**不等距**（颜料本就随手挤）：全等距会读成骰子/音量键。
static func skin() -> Texture2D:
	return texture("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" viewBox=\"0 0 32 32\"><path fill=\"#FFFFFF\" fill-rule=\"evenodd\" d=\"M16 3.5a12.5 12.5 0 1 1 0 25 12.5 12.5 0 0 1 0-25zM10.5 18.2a2.8 2.8 0 1 0 0 5.6 2.8 2.8 0 0 0 0-5.6zM11 8.1a2.1 2.1 0 1 0 0 4.2 2.1 2.1 0 0 0 0-4.2zM16.8 6.1a2.1 2.1 0 1 0 0 4.2 2.1 2.1 0 0 0 0-4.2zM22.2 10.3a2.1 2.1 0 1 0 0 4.2 2.1 2.1 0 0 0 0-4.2z\"/></svg>")
