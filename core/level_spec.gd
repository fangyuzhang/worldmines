# level_spec.gd —— 关卡设计规格常量（GDD 02 号 §7.1 / R07）
#
# R07：单变体官方关**固定雷数**，难度不靠加大棋盘或改变雷数，而靠
# 变体复杂度、混合档位、问号格数量、推理链长度与 L3 反证深度递进。
#
# 尺寸范围（v2.9.3 扩展）：5×5 ~ 9×9（9×9=32 雷，2026-09 加入，延续 R07 的
# 40% 密度 + 递增规律 26→32）。10×10 及以上仍不在官方规格内。
#
# 注意口径：这是「官方关」的设计约定；随机关卡 / 生成器测试用更少雷数
# （如 5×5/4 雷）**不受此约束**——本模块只提供规格锚点，不改变生成器默认行为。
class_name LevelSpec
extends RefCounted


## 单变体官方关固定雷数（R07）。返回 -1 表示该尺寸不在官方规格内。
static func default_mines_for_size(size: Vector2i) -> int:
	if size.x == 5 and size.y == 5:
		return 10
	if size.x == 6 and size.y == 6:
		return 14
	if size.x == 7 and size.y == 7:
		return 20
	if size.x == 8 and size.y == 8:
		return 26
	if size.x == 9 and size.y == 9:
		return 32
	return -1
