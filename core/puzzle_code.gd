# puzzle_code.gd —— 关卡分享码（PZ1，GDD 13 号 §13.3）
#
# PZ1 格式：`PZ1|<线索规则>|<全局规则(+分隔)>|<列>x<行>|<雷数>|<遮蔽数>|<gen_seed>`
# 例：`PZ1|classic|mx|5x5|4|0|1000`
#
# 用途：把「确定性生成参数」编码成可分享、可复现的短码（给工坊/好友直传铺路）。
# 复现走 generate_with_rules（同参数 + 同 seed → 同盘，零外部求解器依赖）。
class_name PuzzleCode
extends RefCounted

const PREFIX := "PZ1"


## 编码关卡生成参数 → PZ1 分享码。
static func encode(clue_rule_id: String, global_rule_ids: Array, size: Vector2i, mine_count: int, mask_count: int, seed: int) -> String:
	var gs := "+".join(global_rule_ids)
	return "|".join([PREFIX, clue_rule_id, gs, "%dx%d" % [size.x, size.y], str(mine_count), str(mask_count), str(seed)])


## 解码 PZ1 分享码 → 参数字典；非法返回 {}。
static func decode(code: String) -> Dictionary:
	if code == "" or not code.begins_with(PREFIX + "|"):
		return {}
	var parts := code.split("|")
	if parts.size() != 7:
		return {}
	var globals: Array = []
	if parts[2] != "":
		globals = parts[2].split("+")
	var sz := parts[3].split("x")
	if sz.size() != 2 or not _is_int(sz[0]) or not _is_int(sz[1]):
		return {}
	return {
		"clue": parts[1],
		"globals": globals,
		"size": Vector2i(int(sz[0]), int(sz[1])),
		"mines": int(parts[4]),
		"mask_count": int(parts[5]),
		"seed": int(parts[6]),
	}


## 用分享码复现关卡（确定性构造）。参数非法/规则未知时返回 {}。
static func reproduce(code: String) -> Dictionary:
	var p := decode(code)
	if p.is_empty():
		return {}
	return PuzzleGenerator.new().generate_with_rules(
		p["clue"], p["globals"], p["size"], p["mines"], p["seed"], p["mask_count"])


static func _is_int(s: String) -> bool:
	if s.is_empty():
		return false
	for i in s.length():
		var ch := s[i]
		if not (ch >= "0" and ch <= "9"):
			return false
	return true
