class_name ShareCode
extends RefCounted

## 分享分级之「短码」层（GDD 文档「八、导入导出 · 分享分级」）。
##
## 【分级判据 —— 读 core/level_format.gd 得到的代码事实，不是凭感觉划线】
##   · `LevelFormat.DESIGN_KEYS` = 编辑器字段，其中 `shape_kind` / `shape_params` 是**形状定义**：
##     它是"这张盘怎么造出来的"，属设计层（编辑器用来重建盘，游戏侧一概不读）。
##   · `LevelFormat.RESULT_KEYS` = 游戏必需项。其中 `topology`（外部/异形邻域）与
##     `prototypes`（原型顶点）是**自由几何**：格子一多，体积没有任何固定上界。
##   · 真正被渲染层当盘型吃的是关卡顶层的 `custom_shapes`（`ui/board_view.gd` 的
##     `_custom_layout()` 要求它非空且 `cells` 为非空数组，见该文件 :666-671；它也是
##     `LevelSets.GAME_KEYS` 里游戏侧会读的键）——即"自定义形状"在代码里的落点。
##   ⇒ **含自定义形状/自由几何（custom_shapes、prototypes、外部 topology）或参数化形状
##     （shape_kind / shape_params 非空）⇒ 走文件（kind="file"）；纯矩形盘且在容量内 ⇒ 走短码。**
##     这正是文档"含自定义形状的 → 文件形式，UI 明示"在代码里的可执行判据。
##
## 【格式 v1】`base64url( 载荷 ‖ 校验 )`，无填充。字符集仅 `A-Za-z0-9-_` ⇒ URL 安全、
##   可贴聊天/二维码；纯本地运算 ⇒ **断网可用**。
##   · 载荷 = [version:1B][flags:1B][varint rows][varint cols][varint total_mines]
##            [mines 位图 ceil(rows*cols/8)B][revealed 位图 同长]
##            [可选 rule: varint len + utf8 id + 1B level][可选 spec: varint len + utf8 JSON]
##   · 校验 = 4B FNV-1a 32（大端），覆盖整段载荷 ⇒ 改一字符 / 截断必被发现。
##
## 【确定性】位图天然与书写顺序无关；`spec` 用 `JSON.stringify`（其 sort_keys 默认 true，
##   键有序）。同一关卡任意字典/数组书写顺序都得到**同一短码**，不掺时间、不掺随机。
##
## 【模块独立性】只吃 / 吐 `Dictionary`，不写盘、不建对象；唯一外部依赖是只读复用
##   `LevelFormat.MAX_CELL_BUDGET`（格数口径单一真源）。

const CURRENT_VERSION := 1

const KIND_CODE := "code"
const KIND_FILE := "file"

const CHECKSUM_BYTES := 4
# 载荷 flags 位
const FLAG_RULE := 1
const FLAG_SPEC := 2
## 【文档 §8】**只读分享**：作者声明“这份分享件只许玩、不许改”。
## 兼容性：`flags` 是 1 字节，**旧解码器只会当作“不认识的位”忽略它**（不参与任何判断）⇒
## 属“只增不改不删”的可加不可改扩展，**不必升版本号**；新解码器读旧码也只是该位为 0。
const FLAG_READONLY := 4

## 短码原始载荷上限（字节）。依据：短码的使用场景是"粘贴即玩 / 扫码"，base64url 会把体积
## 放大 4/3 ⇒ 384B 载荷 ≈ 512 字符，已接近聊天输入框与二维码的舒适上限；而一张 40×40=1600 格
## 的矩形盘，光 mines + revealed 两个位图就要 2×200=400B ⇒ 本就该走文件。故 384B 为界。
const MAX_PAYLOAD_BYTES := 384


# ==================== 分级 ====================

## 判定一张关卡该走短码还是文件。返回 `{kind, reason}`；reason 在 file 时给可读依据。
static func classify(level: Dictionary) -> Dictionary:
	var geo := _geometry_reason(level)
	if geo != "":
		return {"kind": KIND_FILE, "reason": geo}
	var built := _build_payload(level, read_only_of(level))
	if not bool(built.get("ok", false)):
		return {"kind": KIND_FILE,
			"reason": "%s（短码无法承载，请走文件形式）" % str(built.get("reason", ""))}
	var bytes := int(built.get("bytes", 0))
	if bytes > MAX_PAYLOAD_BYTES:
		return {"kind": KIND_FILE,
			"reason": "载荷 %d 字节超过短码上限 %d 字节（短码只服务小关卡），请走文件形式" % [bytes, MAX_PAYLOAD_BYTES]}
	return {"kind": KIND_CODE, "reason": ""}


## 这份关卡是否声明了“只读分享”（文档 §8）。**唯一事实来源**：设计层 `editor_meta.read_only`。
## 短码（结果层）走载荷 flags 位，文件形式走这里 —— 两条路都归到这一个判据，UI 不许自己拼条件。
static func read_only_of(level: Dictionary) -> bool:
	var meta: Variant = level.get("editor_meta", null)
	if meta is Dictionary:
		return bool((meta as Dictionary).get("read_only", false))
	return false


## `read_only_of` 的写侧：给一份关卡**盖上**“只读分享”声明，其余 `editor_meta.*` 原样保留。
## 与读侧成对放在同一个模块里 —— 这样“写什么键、读什么键”只有一处定义，调用方（编辑器 / 打包器）
## 都不许自己拼这个字段名。纯函数：不改写调用方的字典。
static func with_read_only(level: Dictionary) -> Dictionary:
	var out := level.duplicate(true)
	var meta: Dictionary = {}
	if out.get("editor_meta", null) is Dictionary:
		meta = (out["editor_meta"] as Dictionary).duplicate(true)
	meta["read_only"] = true
	out["editor_meta"] = meta
	return out


# ==================== 编码 ====================

## 小关卡 → 可粘贴短码。返回 `{ok, code, reason, bytes}`。
## `bytes` = 原始载荷字节数（不含 4B 校验位）；超 `opts.max_bytes`（默认 MAX_PAYLOAD_BYTES）⇒ ok=false。
## 任何失败都**不抛异常**，只给可读 reason 并建议走文件。
static func encode(level: Dictionary, opts := {}) -> Dictionary:
	var geo := _geometry_reason(level)
	if geo != "":
		return {"ok": false, "code": "", "bytes": 0,
			"reason": "%s ⇒ 请改用文件形式分享" % geo}
	# 只读：显式传入优先；关卡自己声明了只读（设计层）也算 ⇒ 与 `classify` 同一真源。
	var read_only := read_only_of(level)
	if opts is Dictionary:
		read_only = read_only or bool((opts as Dictionary).get("read_only", false))
	var built := _build_payload(level, read_only)
	if not bool(built.get("ok", false)):
		return {"ok": false, "code": "", "bytes": int(built.get("bytes", 0)),
			"reason": str(built.get("reason", ""))}
	var payload: PackedByteArray = built["payload"]
	var limit := MAX_PAYLOAD_BYTES
	if opts is Dictionary and (opts as Dictionary).has("max_bytes"):
		limit = int((opts as Dictionary)["max_bytes"])
	if payload.size() > limit:
		return {"ok": false, "code": "", "bytes": payload.size(),
			"reason": "载荷 %d 字节超过短码上限 %d 字节（短码只服务小关卡）⇒ 请改用文件形式分享" % [payload.size(), limit]}
	var cs := _fnv1a_bytes(payload)
	var full := payload.duplicate()
	full.append((cs >> 24) & 0xFF)
	full.append((cs >> 16) & 0xFF)
	full.append((cs >> 8) & 0xFF)
	full.append(cs & 0xFF)
	return {"ok": true, "code": _b64url_encode(full), "reason": "", "bytes": payload.size()}


# ==================== 解码 ====================

## 短码 → 关卡。返回 `{ok, level, reason}`。**绝不抛异常**：失败一律 ok=false + 可读原因，
## 原因区分「空 / 字符非法 / 校验失败 / 版本不支持 / 内容超限 / 内容损坏」。
static func decode(code: String) -> Dictionary:
	if code == "":
		return {"ok": false, "level": {}, "reason": "分享码为空"}
	for i in code.length():
		var ch := code[i]
		if not _is_code_char(ch):
			return {"ok": false, "level": {},
				"reason": "分享码含非法字符「%s」：只允许 A-Z a-z 0-9 - _" % ch}
	var std := code.replace("-", "+").replace("_", "/")
	if std.length() % 4 == 1:
		return {"ok": false, "level": {}, "reason": "分享码长度非法（base64 长度 %% 4 == 1）"}
	while std.length() % 4 != 0:
		std += "="
	var bytes := Marshalls.base64_to_raw(std)
	if bytes.size() < 1 + CHECKSUM_BYTES:
		return {"ok": false, "level": {}, "reason": "分享码过短或已被截断（仅解出 %d 字节）" % bytes.size()}
	var payload := bytes.slice(0, bytes.size() - CHECKSUM_BYTES)
	var given := (bytes[bytes.size() - 4] << 24) | (bytes[bytes.size() - 3] << 16) \
		| (bytes[bytes.size() - 2] << 8) | bytes[bytes.size() - 1]
	var calc := _fnv1a_bytes(payload)
	if given != calc:
		return {"ok": false, "level": {},
			"reason": "校验失败：分享码内容被篡改或截断（校验位 %08x ≠ 实算 %08x）" % [given, calc]}

	# —— 校验通过后才解析；以下任何结构不符都归入「内容损坏」。
	var version := int(payload[0])
	if version > CURRENT_VERSION:
		return {"ok": false, "level": {},
			"reason": "版本不支持：分享码 v%d 高于本程序支持的最高版本 v%d" % [version, CURRENT_VERSION]}
	if payload.size() < 2:
		return {"ok": false, "level": {}, "reason": "内容损坏：分享码缺少标志位"}
	var flags := int(payload[1])
	var cur := 2
	var nums: Array = []
	for _k in 3:  # rows / cols / total_mines
		var rv := _read_varint(payload, cur)
		if int(rv[1]) < 0:
			return {"ok": false, "level": {}, "reason": "内容损坏：分享码非预期结束（截断）"}
		nums.append(int(rv[0]))
		cur = int(rv[1])
	var rows := int(nums[0])
	var cols := int(nums[1])
	var total_mines := int(nums[2])
	if rows < 1 or cols < 1:
		return {"ok": false, "level": {}, "reason": "内容损坏：尺寸非法（%dx%d）" % [rows, cols]}
	var cells := rows * cols
	if cells > LevelFormat.MAX_CELL_BUDGET:
		return {"ok": false, "level": {},
			"reason": "内容超限：%d 格超过硬上限 %d" % [cells, LevelFormat.MAX_CELL_BUDGET]}
	var bl := (cells + 7) / 8
	if cur + bl * 2 > payload.size():
		return {"ok": false, "level": {}, "reason": "内容损坏：位图长度与尺寸不符（分享码被截断？）"}
	var mine_bits := payload.slice(cur, cur + bl)
	cur += bl
	var rev_bits := payload.slice(cur, cur + bl)
	cur += bl

	var rule_id := ""
	var rule_level := false
	var spec: Variant = null
	if (flags & FLAG_RULE) != 0:
		var lr := _read_varint(payload, cur)
		if int(lr[1]) < 0:
			return {"ok": false, "level": {}, "reason": "内容损坏：规则段截断"}
		var ln := int(lr[0])
		cur = int(lr[1])
		if cur + ln + 1 > payload.size():
			return {"ok": false, "level": {}, "reason": "内容损坏：规则段长度越界"}
		rule_id = payload.slice(cur, cur + ln).get_string_from_utf8()
		cur += ln
		rule_level = int(payload[cur]) != 0
		cur += 1
	if (flags & FLAG_SPEC) != 0:
		var lr2 := _read_varint(payload, cur)
		if int(lr2[1]) < 0:
			return {"ok": false, "level": {}, "reason": "内容损坏：规则规格段截断"}
		var ln2 := int(lr2[0])
		cur = int(lr2[1])
		if cur + ln2 > payload.size():
			return {"ok": false, "level": {}, "reason": "内容损坏：规则规格段长度越界"}
		var s := payload.slice(cur, cur + ln2).get_string_from_utf8()
		cur += ln2
		var parsed: Variant = JSON.parse_string(s)
		if not (parsed is Dictionary):
			return {"ok": false, "level": {}, "reason": "内容损坏：规则规格不是合法 JSON 对象"}
		spec = _normalize_json_numbers(parsed)
	if cur != payload.size():
		return {"ok": false, "level": {},
			"reason": "内容损坏：分享码尾部有 %d 字节多余数据" % (payload.size() - cur)}

	var mines: Array = []
	var revealed: Array = []
	for idx in cells:
		var mask := 1 << (idx & 7)
		if (int(mine_bits[idx >> 3]) & mask) != 0:
			mines.append({"r": idx / cols, "c": idx % cols})
		if (int(rev_bits[idx >> 3]) & mask) != 0:
			revealed.append({"r": idx / cols, "c": idx % cols})
	if mines.size() != total_mines:
		return {"ok": false, "level": {},
			"reason": "内容损坏：雷数字段 %d 与雷位位图 %d 不一致" % [total_mines, mines.size()]}

	var level := {
		"size": {"rows": rows, "cols": cols},
		"total_mines": total_mines,
		"mines": mines,
		"revealed": revealed,
	}
	if (flags & FLAG_RULE) != 0 or spec != null:
		var rule := {"id": rule_id, "level": rule_level}
		if spec != null:
			rule["spec"] = spec
		level["rule"] = rule
	# 成功时额外带 `read_only`；**失败分支不含该键** ⇒ 调用方一律用 `get("read_only", false)`。
	return {"ok": true, "level": level, "read_only": (flags & FLAG_READONLY) != 0, "reason": ""}


# ==================== 载荷构造 ====================

## 关卡 → 载荷字节。返回 `{ok, payload, bytes, reason}`；bytes = 载荷字节数（不含校验位）。
static func _build_payload(level: Dictionary, read_only := false) -> Dictionary:
	var lv := _unwrap(level)
	var rows := int(lv.get("rows", 0))
	var cols := int(lv.get("cols", 0))
	var sv: Variant = lv.get("size", null)
	if sv is Dictionary:
		rows = int((sv as Dictionary).get("rows", rows))
		cols = int((sv as Dictionary).get("cols", cols))
	if rows < 1 or cols < 1:
		return _fail_build("关卡尺寸非法（%dx%d）" % [rows, cols])
	var cells := rows * cols
	var mine_pos := _collect_positions(lv, "mines", "mine")
	var rev_pos := _collect_positions(lv, "revealed", null)
	var bl := (cells + 7) / 8
	var mine_bits := PackedByteArray()
	mine_bits.resize(bl)
	var rev_bits := PackedByteArray()
	rev_bits.resize(bl)
	for p in mine_pos:
		var r := int(p["r"])
		var c := int(p["c"])
		if r < 0 or r >= rows or c < 0 or c >= cols:
			return _fail_build("雷位越界（r=%d, c=%d，盘为 %dx%d）" % [r, c, rows, cols])
		var idx := r * cols + c
		mine_bits[idx >> 3] = int(mine_bits[idx >> 3]) | (1 << (idx & 7))
	for p in rev_pos:
		var r2 := int(p["r"])
		var c2 := int(p["c"])
		if r2 < 0 or r2 >= rows or c2 < 0 or c2 >= cols:
			return _fail_build("已翻格越界（r=%d, c=%d，盘为 %dx%d）" % [r2, c2, rows, cols])
		var idx2 := r2 * cols + c2
		rev_bits[idx2 >> 3] = int(rev_bits[idx2 >> 3]) | (1 << (idx2 & 7))

	var rule := _rule_of(lv)
	var rule_id := str(rule.get("id", ""))
	var rule_level := bool(rule.get("level", false))
	var spec: Variant = rule.get("spec", null)
	var flags := 0
	if read_only:
		flags |= FLAG_READONLY
	if rule_id != "" or rule_level:
		flags |= FLAG_RULE
	if spec is Dictionary and not (spec as Dictionary).is_empty():
		flags |= FLAG_SPEC

	var out := PackedByteArray()
	out.append(CURRENT_VERSION)
	out.append(flags)
	_write_varint(out, rows)
	_write_varint(out, cols)
	_write_varint(out, int(lv.get("total_mines", mine_pos.size())))
	out.append_array(mine_bits)
	out.append_array(rev_bits)
	if (flags & FLAG_RULE) != 0:
		var id_bytes := rule_id.to_utf8_buffer()
		_write_varint(out, id_bytes.size())
		out.append_array(id_bytes)
		out.append(1 if rule_level else 0)
	if (flags & FLAG_SPEC) != 0:
		# JSON.stringify 的 sort_keys 默认 true ⇒ 键有序 ⇒ 确定性（见文件头）。
		var spec_bytes := JSON.stringify(spec).to_utf8_buffer()
		_write_varint(out, spec_bytes.size())
		out.append_array(spec_bytes)
	return {"ok": true, "payload": out, "bytes": out.size(), "reason": ""}


static func _fail_build(reason: String) -> Dictionary:
	return {"ok": false, "payload": PackedByteArray(), "bytes": 0, "reason": reason}


## 该关卡的"含自定义形状 / 自由几何"依据；无则返回 ""。
## 兼容信封（{version,result,design}）、纯结果层与平铺关卡三种输入。
static func _geometry_reason(level: Dictionary) -> String:
	var views: Array = [level]
	if level.get("result", null) is Dictionary:
		views.append(level["result"])
	if level.get("design", null) is Dictionary:
		views.append(level["design"])
	for v in views:
		var d: Dictionary = v
		var cs: Variant = d.get("custom_shapes", null)
		if cs is Dictionary and not (cs as Dictionary).is_empty():
			var cellsv: Variant = (cs as Dictionary).get("cells", null)
			if cellsv is Array and not (cellsv as Array).is_empty():
				return "含自定义多边形几何（custom_shapes.cells）：几何随关落盘、无固定体积上限"
		var sk := str(d.get("shape_kind", ""))
		if sk != "":
			return "含参数化形状定义（shape_kind=%s）：形状属设计层（LevelFormat.DESIGN_KEYS），短码只承载矩形盘结果层" % sk
		var sp: Variant = d.get("shape_params", null)
		if sp is Dictionary and not (sp as Dictionary).is_empty():
			return "含形状参数（shape_params）：形状属设计层，短码无法承载其自由几何"
		var topo: Variant = d.get("topology", null)
		if topo is Dictionary and not (topo as Dictionary).is_empty():
			return "含外部拓扑（结果层 topology）：邻域为自由几何、无固定体积上限"
		var pr: Variant = d.get("prototypes", null)
		if pr is Dictionary and not (pr as Dictionary).is_empty():
			return "含原型几何（结果层 prototypes）：顶点随关落盘、无固定体积上限"
	return ""


static func _unwrap(level: Dictionary) -> Dictionary:
	if level.get("result", null) is Dictionary:
		return level["result"] as Dictionary
	return level


## 规则归一：平铺（clue_rule/rule_level/custom.spec/rule_spec）与结果层（rule.id/level/spec）都收。
static func _rule_of(lv: Dictionary) -> Dictionary:
	var out := {"id": "", "level": false}
	if lv.get("rule", null) is Dictionary:
		var r: Dictionary = lv["rule"]
		out["id"] = str(r.get("id", ""))
		out["level"] = bool(r.get("level", false))
		if r.get("spec", null) is Dictionary and not (r["spec"] as Dictionary).is_empty():
			out["spec"] = (r["spec"] as Dictionary).duplicate(true)
	if str(out["id"]) == "":
		out["id"] = str(lv.get("clue_rule", ""))
	if not bool(out["level"]):
		out["level"] = bool(lv.get("rule_level", false))
	if not out.has("spec"):
		if lv.get("rule_spec", null) is Dictionary and not (lv["rule_spec"] as Dictionary).is_empty():
			out["spec"] = (lv["rule_spec"] as Dictionary).duplicate(true)
		elif lv.get("custom", null) is Dictionary:
			var c: Dictionary = lv["custom"]
			if c.get("spec", null) is Dictionary and not (c["spec"] as Dictionary).is_empty():
				out["spec"] = (c["spec"] as Dictionary).duplicate(true)
	return out


## 收集坐标：优先显式列表；否则从结果层 `cells` 派生（cell_flag 指定格上判据，如 "mine"）。
static func _collect_positions(lv: Dictionary, key: String, cell_flag: Variant) -> Array:
	var out: Array = []
	var raw: Variant = lv.get(key, null)
	if raw is Array and not (raw as Array).is_empty():
		for it in (raw as Array):
			var p := _pos_of(it)
			if not p.is_empty():
				out.append(p)
		return out
	var cellsv: Variant = lv.get("cells", null)
	if cell_flag != null and cellsv is Array:
		for c in (cellsv as Array):
			if c is Dictionary and bool((c as Dictionary).get(str(cell_flag), false)):
				out.append({"r": int((c as Dictionary).get("r", 0)), "c": int((c as Dictionary).get("c", 0))})
	return out


static func _pos_of(it: Variant) -> Dictionary:
	if it is Dictionary:
		var d: Dictionary = it
		return {"r": int(d.get("r", 0)), "c": int(d.get("c", 0))}
	if it is Array and (it as Array).size() >= 2:
		var a: Array = it
		return {"r": int(a[0]), "c": int(a[1])}
	return {}


# ==================== 底层工具 ====================

static func _is_code_char(ch: String) -> bool:
	if ch.length() != 1:
		return false
	if ch >= "A" and ch <= "Z":
		return true
	if ch >= "a" and ch <= "z":
		return true
	if ch >= "0" and ch <= "9":
		return true
	return ch == "-" or ch == "_"


## base64url（无填充）。URL 安全字符集，可安全粘贴。
static func _b64url_encode(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").rstrip("=")


static func _write_varint(out: PackedByteArray, value: int) -> void:
	var v := maxi(value, 0)
	while true:
		var b := v & 0x7F
		v = v >> 7
		if v > 0:
			out.append(b | 0x80)
		else:
			out.append(b)
			return


## 读 varint：返回 [value, next_cursor]；非法/截断时 next_cursor = -1。
static func _read_varint(bytes: PackedByteArray, cursor: int) -> Array:
	var shift := 0
	var result := 0
	var i := cursor
	while i < bytes.size():
		var b := int(bytes[i])
		i += 1
		result |= (b & 0x7F) << shift
		if (b & 0x80) == 0:
			return [result, i]
		shift += 7
		if shift > 63:
			return [0, -1]
	return [0, -1]


## 32 位 FNV-1a（确定性、跨平台）。载荷与校验位共用它。
static func _fnv1a_bytes(data: PackedByteArray) -> int:
	var h := 2166136261
	for b in data:
		h = h ^ int(b)
		h = (h * 16777619) & 0xFFFFFFFF
	return h


## JSON 数字一律是 float ⇒ 把整值还原成 int，使 `decode(encode(x)) == x` 对整数规格成立。
static func _normalize_json_numbers(v: Variant) -> Variant:
	if v is float:
		var f := v as float
		if is_finite(f) and absf(f) < 9.007199254740992e15 and f == floor(f):
			return int(f)
		return f
	if v is Array:
		var arr: Array = []
		for it in (v as Array):
			arr.append(_normalize_json_numbers(it))
		return arr
	if v is Dictionary:
		var out := {}
		var d: Dictionary = v
		for k in d.keys():
			out[k] = _normalize_json_numbers(d[k])
		return out
	return v
