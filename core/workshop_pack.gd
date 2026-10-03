class_name WorkshopPack
extends RefCounted

## 本地 workshop 包生成器（编辑器 P3，2026-10-02）。
##
## 【这个包长什么样、为什么长这样】产物 = 一个 zip，内部布局**与 mod 目录完全一致**：
##   manifest.json       —— 元数据（schema 由 `core/manifest_parser.gd:30 validate` 定义，本文件写完必须自校一次）
##   entry.gd            —— GDScript 入口：把随包携带的规格注册进 RuleRegistry（契约：钩子 return true）
##   board.json          —— 自行声明的棋盘拓扑（仅当用了环绕/自定义邻域/障碍）
##   levels/<...>.json   —— 关卡**结果层**（游戏只读它；`Board.load_level` 直接能吃）
##   design/<...>.json   —— 关卡**设计层**（编辑器才读；坏了游戏照样玩，只是不能再编辑）
##   preview.png         —— 预览图（程序化画，不依赖截图与 UI）
## 之所以照抄 mod 目录布局：本仓**已有**的安装/加载链路（`ModAPI.install_from_dir` →
## `manifest_parser` → `ModAPI.get_board` → `LevelLoader`）不用改一行就能吃它，
## 而"另发明一种包格式"要多写一条只被自己使用的加载路径。
##
## 【2026-10-03 分层（文档「八」）】`levels/` 与 `design/` 同构并列（同相对路径、同集结构），
## 目录名取自 `LevelSets.LEVELS_DIR` / `LevelSets.DESIGN_DIR`（单一真源，写入方与读取方共用）。
##
## 【不联网、不假装】本文件只落盘；上传是 `core/steam_workshop.gd` 的**占位**接口，
## 当前一律返回"已生成本地 workshop 包，请手动上传"，绝不返回假成功。
##
## 【自校闭环】写完 zip 后**读回来核对条目**（ZIPReader），并且用 `ManifestParser` 校验 manifest——
## 需求要的是"能手动上传的包"，不是"写了个文件"。

const MANIFEST_NAME := "manifest.json"
const ENTRY_NAME := "entry.gd"
const BOARD_NAME := "board.json"
## 结果层 / 设计层目录名。必须与 `LevelSets` 同口径（测试里有一条断言钉住），
## 否则就会出现"打包写 design/、读取方找 levels/"这种分叉。
const LEVELS_DIR := "levels"
const DESIGN_DIR := "design"
## 随包携带的图文教程（P6）：安装后落在 `user://mods/<id>/tutorial/`，
## `core/tutorial.gd` 会去那里找 ⇒ 自创变体进游戏后点书本图标就能看到图例。
const TUTORIAL_DIR := "tutorial"
const PREVIEW_NAME := "preview.png"
const DEFAULT_DIR := "user://workshop_out"
const DEFAULT_VERSION := "1.0.0"

## 预览图上限（不追求好看，只求"包里有图"且不写爆磁盘）：每格 ~8 像素，整体裁到 512。
const PREVIEW_CELL_PX := 8
const PREVIEW_MAX_PX := 512

## 安装（解包）上限：与 `ui/skin_service.gd` 的 zip 收口同口径，防高压缩比炸弹写爆 user://
const MAX_INSTALL_FILES := 64
const MAX_INSTALL_BYTES := 8 * 1024 * 1024

const COLOR_BG := Color("#2b2f36")
const COLOR_HIDDEN := Color("#59616d")
const COLOR_MINE := Color("#c0392b")
const COLOR_SAFE := Color("#d9dde3")


## 把若干目录下的文件**递归**收成 zip 条目（保留相对路径），供批量关卡/教程图例随包携带。
## 不存在的目录直接跳过（调用方可以先问 `DirAccess.dir_exists_absolute`，这里不报错也不静默崩）。
static func _dir_files(dirs: Variant, prefix: String, ext: String) -> Array:
	var out: Array = []
	if not (dirs is Array):
		return out
	for d in (dirs as Array):
		var root := str(d)
		if root == "" or not DirAccess.dir_exists_absolute(root):
			continue
		var found: Array[String] = []
		_walk(root, "", ext, found)
		found.sort()
		for rel in found:
			out.append({"name": "%s/%s" % [prefix, rel],
				"text": FileAccess.get_file_as_string(root.path_join(rel))})
	return out


static func _walk(root: String, rel: String, ext: String, out: Array[String]) -> void:
	var here := root if rel == "" else root.path_join(rel)
	var d := DirAccess.open(here)
	if d == null:
		return
	for f in d.get_files():
		var f_s := str(f)
		if f_s.ends_with(ext):
			out.append(f_s if rel == "" else rel.path_join(f_s))
	for sub in d.get_directories():
		var s_s := str(sub)
		_walk(root, s_s if rel == "" else rel.path_join(s_s), ext, out)


## `levels/<大小>/<档位>.json` → `design/<大小>/<档位>.json`（与结果层同构，只换根目录）。
static func _design_name(levels_name: String) -> String:
	var rel := levels_name
	if rel.begins_with(LEVELS_DIR + "/"):
		rel = rel.substr(LEVELS_DIR.length() + 1)
	return "%s/%s" % [DESIGN_DIR, rel]


## 集文件文本 → 结果层集 / 设计层集（同顶层元数据、同集结构）。不是集文件 ⇒ `{ok:false}`（调用方原样随包）。
static func _layer_set_text(text: String) -> Dictionary:
	var parsed: Variant = SpecHelper.parse_json_safe(text)
	if not (parsed is Dictionary):
		return {"ok": false}
	var d: Dictionary = parsed
	if not (d.get("levels", null) is Array):
		return {"ok": false}
	var levels: Array = []
	var designs: Array = []
	for lv in (d["levels"] as Array):
		if not (lv is Dictionary):
			return {"ok": false}
		var env: Dictionary = lv if LevelSets.is_envelope(lv as Dictionary) else LevelSets.envelope(lv as Dictionary)
		var play := LevelSets.playable(env)
		if play.is_empty():
			return {"ok": false}   # 这一关转不成可开局的形态 ⇒ 整份原样随包（不写出坏结果层）
		levels.append(play)
		designs.append(LevelSets.design_of(env))
	var head := d.duplicate(true)
	head.erase("levels")
	head["version"] = LevelFormat.CURRENT_VERSION
	head["count"] = levels.size()
	var rset := head.duplicate(true)
	rset["levels"] = levels
	var dset := head.duplicate(true)
	dset["levels"] = designs
	return {"ok": true, "result": JSON.stringify(rset, "  "), "design": JSON.stringify(dset, "  ")}


## 体积预估（走近 `LevelFormat.estimate_bytes`；以"每关一次"累加，集文件顶层不计）。
static func _estimate_set_text(text: String) -> int:
	var parsed: Variant = SpecHelper.parse_json_safe(text)
	if not (parsed is Dictionary):
		return 0
	var d: Dictionary = parsed
	if not (d.get("levels", null) is Array):
		return LevelFormat.estimate_bytes(d)
	var total := 128
	for lv in (d["levels"] as Array):
		if lv is Dictionary:
			total += LevelFormat.estimate_bytes(lv as Dictionary)
	return total


## 默认输出目录（编辑器"生成包"的落点）。
static func default_dir() -> String:
	return DEFAULT_DIR


## 生成 zip。返回 {ok, reason, path, entries, id}。
## opts: {"id": String, "version": String, "title": String, "dir": String,
##        "description": String（可省）, "extra_manifest": Dictionary（可省）,
##        "levels_dirs": Array[String]（可省，批量关卡集目录）,
##        "tutorial_dirs": Array[String]（可省，图文教程目录）}
##
## 【P6 批量生产的两个新口子】
##   · `levels_dirs`：把目录下**递归**的 `*.json` 按原相对路径塞进 `levels/`。批量产出是
##     `levels/<大小>/<档位>.json` 集文件 ⇒ **分类信息就在包的目录结构里**，装到玩家机器上
##     照样是分好类的（不是"一堆平铺关卡"）。
##   · `extra_manifest`：合并进 manifest 顶层。`ManifestParser.validate` 里是 `duplicate(true)`，
##     未知顶层键**原样保留** ⇒ 分类索引（categories）能随包走，不用改解析器一行。
##   · `tutorial_dirs`：自创变体的图文图例随包携带，装完点书本图标就能看（见 `core/tutorial.gd`）。
static func build(doc: EditorDoc, opts: Dictionary = {}) -> Dictionary:
	if doc == null:
		return {"ok": false, "reason": "文档为空", "path": "", "entries": [], "id": ""}
	# 【真机修 2026-10-02】批量包（`levels_dirs`）**不许被「当前打开的文档」绑架**：
	# 真机实测 —— 用户盘上是一张试验盘（校验不过："雷数 81 ≥ 可用格数 81"），于是
	# **81 关、五十多秒全白生成**，打包这一步直接失败。批量包的内容是 levels/ 下的分类关卡集，
	# 与"当前盘"无关，所以批量模式跳过这道闸；单关包（老路径）仍然必须过校验。
	# 【审查修 A5（真 bug）】批量模式改由**真收到文件**决定（原来只看 `levels_dirs` 这个 key 在不在）：
	# 目录不存在/里面没有 json 时，原来会跳过当前文档校验、丢掉 board.json（盘型声明！）与 preview.png，
	# 却把"当前这张盘"当单关塞进 levels/ ⇒ 打出一个既未校验又缺拓扑的包。现在这种输入直接失败。
	var levels_dirs: Variant = opts.get("levels_dirs", [])
	var batch_files := _dir_files(levels_dirs, LEVELS_DIR, ".json")
	var batch_mode: bool = not batch_files.is_empty()
	if not batch_mode and levels_dirs is Array and not (levels_dirs as Array).is_empty():
		return {"ok": false, "reason": "批量目录里没有找到关卡文件（%s）—— 请确认目录存在且含 .json" % str(levels_dirs),
			"path": "", "entries": [], "id": ""}
	if not batch_mode:
		var rep := doc.validate()
		if not bool(rep["ok"]):
			var first := ""
			for it in rep["errors"]:
				first = str((it as Dictionary)["text"])
				break
			return {"ok": false, "reason": "文档未通过校验：%s" % first, "path": "", "entries": [], "id": ""}

	var pack_id := str(opts.get("id", ""))
	if pack_id == "":
		pack_id = _default_id(doc)
	var version := str(opts.get("version", DEFAULT_VERSION))
	var title := str(opts.get("title", doc.title))
	var slug := _slug(title if title != "" else pack_id)
	var level_name := "%s.json" % slug

	var dir := str(opts.get("dir", DEFAULT_DIR))
	DirAccess.make_dir_recursive_absolute(dir)
	var zip_path := dir.path_join("%s.zip" % pack_id)

	var manifest := {
		"id": pack_id,
		"name": title,
		"version": version,
		"api_version": ManifestParser.API_VERSION,
		"author": "编辑器",
		"description": str(opts.get("description", "%dx%d，%d 颗雷%s" % [doc.cols, doc.rows,
			doc.mine_count(), "，环绕边界" if doc.wrap else ""])),
		"entry": {"runtime": ManifestParser.RUNTIME_GDScript, "path": ENTRY_NAME},
		"capabilities": [],
	}
	# 分类等额外顶层键（例如 `categories`）：解析器不白名单化，放进来就能随包走
	var extra: Variant = opts.get("extra_manifest", {})
	if extra is Dictionary:
		for k in (extra as Dictionary).keys():
			manifest[k] = (extra as Dictionary)[k]
	# 自校：manifest 必须过仓库自己的校验器（"反推 schema" 就是这一步的产物）
	var mp := ManifestParser.new()
	var mv := mp.validate(manifest)
	if not bool(mv["ok"]):
		return {"ok": false, "reason": "生成的 manifest 未通过仓库校验器：%s" % str(mv["reason"]),
			"path": "", "entries": [], "id": pack_id}
	manifest = mv["manifest"]

	var level := doc.to_level_json()
	var env := LevelSets.envelope(level)
	var topo := doc.topology()
	var files: Array = [
		{"name": MANIFEST_NAME, "text": JSON.stringify(manifest, "  ")},
		{"name": ENTRY_NAME, "text": _entry_script(doc, pack_id)},
	]
	# 【分层落盘】结果层（`levels/...`，游戏只读它）+ 设计层（`design/...`，编辑器才读）。
	# 结果层用 `LevelSets.playable` 转成 Board/LevelLoader 直接能吃的形态：若直接写 `to_result_layer`
	# 的 cells，`LevelLoader` 会因"mines 与 total_mines 不符"把包内关卡拒载。
	var est_bytes := 0
	if batch_files.is_empty():
		est_bytes = LevelFormat.estimate_bytes(level)
		files.append({"name": "%s/%s" % [LEVELS_DIR, level_name],
			"text": JSON.stringify(LevelSets.playable(env), "  ")})
		files.append({"name": "%s/%s" % [DESIGN_DIR, level_name],
			"text": JSON.stringify(env["design"], "  ")})
	else:
		# 批量关卡集（`<大小>/<档位>.json`）：分类随包走，且**同样分层**（levels/ 与 design/ 同构并列）。
		# （`batch_files` 已提到函数开头算好：批量模式要靠"真收到文件"判定，见上面 A5 的修复。）
		for bf in batch_files:
			var fd: Dictionary = bf
			var lname := str(fd["name"])
			var text := str(fd.get("text", ""))
			est_bytes += _estimate_set_text(text)
			var layered := _layer_set_text(text)
			if bool(layered["ok"]):
				files.append({"name": lname, "text": str(layered["result"])})
				files.append({"name": _design_name(lname), "text": str(layered["design"])})
			else:
				# 不是集文件（例如作者手放的平铺单关）：原样随包，不擅自丢他的文件
				files.append(bf)
	files.append_array(_dir_files(opts.get("tutorial_dirs", []), TUTORIAL_DIR, ".txt"))
	# 棋盘拓扑与预览图描述的是**当前盘**这一张：批量包里不该混进来（那会让玩家看到一张
	# 与分类关卡无关的图/盘）。两者都只在单关包里写。
	if not batch_mode and not topo.is_empty():
		files.append({"name": BOARD_NAME, "text": JSON.stringify(_board_json(topo), "  ")})
	# 预览图同理：它画的是**当前盘**这一张 ⇒ 批量包里不该混进来（与分类关卡无关）。
	# （注：这段曾在同一次改动里被我误删过一次，导致单关包丢预览图 —— 故两条断言都写进测试里钉住。）
	if not batch_mode:
		var png := preview_png_bytes(doc)
		if not png.is_empty():
			files.append({"name": PREVIEW_NAME, "bytes": png})
	# 安装侧硬上限：撞墙时必须**当场说清楚**（而不是让玩家装完发现少了关卡）
	if files.size() > MAX_INSTALL_FILES:
		return {"ok": false, "reason": "包里有 %d 个文件，超过安装上限 %d 个 —— 批量关卡请按「大小 × 档位」合并成集文件（一关一文件必然超）" % [files.size(), MAX_INSTALL_FILES],
			"path": "", "entries": [], "id": pack_id}

	var zp := ZIPPacker.new()
	if zp.open(zip_path) != OK:
		return {"ok": false, "reason": "无法写入 zip：%s" % zip_path, "path": "", "entries": [], "id": pack_id}
	var entries: Array[String] = []
	for f in files:
		var fd: Dictionary = f
		var name := str(fd["name"])
		if zp.start_file(name) != OK:
			zp.close()
			return {"ok": false, "reason": "zip 条目写入失败：%s" % name, "path": "", "entries": [], "id": pack_id}
		if fd.has("bytes"):
			zp.write_file(fd["bytes"])
		else:
			zp.write_file(str(fd["text"]).to_utf8_buffer())
		zp.close_file()
		entries.append(name)
	zp.close()

	# 自校闭环：读回来核对条目（"写成功"≠"写对了"）
	var back := _list_zip(zip_path)
	if back.is_empty():
		return {"ok": false, "reason": "生成的 zip 读不回来（条目核对失败）", "path": zip_path, "entries": [], "id": pack_id}
	for e in entries:
		if not back.has(e):
			return {"ok": false, "reason": "zip 缺少条目 %s（回读核对失败）" % e, "path": zip_path, "entries": [], "id": pack_id}
	return {"ok": true, "reason": "", "path": zip_path, "entries": entries, "id": pack_id,
		"est_bytes": est_bytes}


## 程序化预览图（不截图、不依赖 UI ⇒ 无头环境也能生成）。
## 画法：雷=红、隐藏格=灰、其余=浅色底；每格 PREVIEW_CELL_PX 像素，整体裁到 PREVIEW_MAX_PX。
static func preview_png_bytes(doc: EditorDoc) -> PackedByteArray:
	var w := mini(doc.cols * PREVIEW_CELL_PX, PREVIEW_MAX_PX)
	var h := mini(doc.rows * PREVIEW_CELL_PX, PREVIEW_MAX_PX)
	if w <= 0 or h <= 0:
		return PackedByteArray()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(COLOR_BG)
	var ms := doc.mine_set()
	for y in doc.rows:
		for x in doc.cols:
			var px := x * PREVIEW_CELL_PX
			var py := y * PREVIEW_CELL_PX
			if px >= w or py >= h:
				continue
			var cw := mini(PREVIEW_CELL_PX, w - px)
			var ch := mini(PREVIEW_CELL_PX, h - py)
			var col := COLOR_HIDDEN
			if ms.has(Vector2i(x, y)):
				col = COLOR_MINE
			elif doc.revealed.has(Vector2i(x, y)):
				col = COLOR_SAFE
			# 留 1 像素网格线（视觉上更清楚哪些是格）
			img.fill_rect(Rect2i(px, py, maxi(cw - 1, 1), maxi(ch - 1, 1)), col)
	var png := img.save_png_to_buffer()
	return png


## 把本地 workshop 包**安装进 `user://mods/<id>/`**（玩家不必手动解压）。
##
## 为什么值得做：包生成出来后，若只能手动解压，作者/玩家很容易"不知道该放哪"；
## 而本仓**已有**完整的 Mod 加载链路（`ModAPI.load_mod` → `manifest_parser` →
## `entry.gd` 注册规则 → 关卡可玩）⇒ 装上就能玩，闭环才算真的合上。
##
## 安全纪律照抄 `ui/skin_service.gd:import_zip`（那是本仓已验证的 zip 收口）：
##   ① 条目数上限；② 解压总体积上限；③ zip-slip 拒绝（`..` 段 / 绝对路径 / 反斜杠）；
##   ④ 超限或写入失败**回滚**已写文件；⑤ **拒绝覆盖同名 Mod 目录**（那是玩家的东西）。
## 返回 `{ok, reason, mod_dir, files}`。
static func install_from_zip(zip_path: String, dst_root: String = "user://mods") -> Dictionary:
	var fail := func(r: String) -> Dictionary:
		return {"ok": false, "reason": r, "mod_dir": "", "files": []}

	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return fail.call("打不开 zip：%s（Godot 路径请用正斜杠 /）" % zip_path)
	var names: Array[String] = []
	for f in zr.get_files():
		names.append(str(f))

	# manifest 必须在包根（本生成器的布局如此；找不到就明说，别猜）
	if not names.has(MANIFEST_NAME):
		zr.close()
		return fail.call("包内没有根级 %s（包结构应为 manifest.json + levels/<name>.json）" % MANIFEST_NAME)
	var manifest_text := zr.read_file(MANIFEST_NAME).get_string_from_utf8()
	var mp := ManifestParser.new()
	var mv := mp.parse(manifest_text)
	if not bool(mv["ok"]):
		zr.close()
		return fail.call("manifest 未通过校验：%s" % str(mv["reason"]))
	var mod_id := str((mv["manifest"] as Dictionary)["id"])

	if names.size() > MAX_INSTALL_FILES:
		zr.close()
		return fail.call("包内条目 %d 个，超过上限 %d" % [names.size(), MAX_INSTALL_FILES])

	var dest := dst_root.path_join(mod_id)
	if DirAccess.dir_exists_absolute(dest):
		zr.close()
		return fail.call("同名 Mod 目录已存在，拒绝覆盖：%s（请先自行删除或改名）" % dest)

	DirAccess.make_dir_recursive_absolute(dest)
	var written: Array[String] = []
	var total := 0
	for name in names:
		var rel := name.replace("\\", "/")
		if rel == "" or rel.ends_with("/"):
			continue   # 目录条目：由 make_dir_recursive 负责
		var slip: bool = rel.begins_with("/") or rel.contains("\\") or rel.contains("..")
		if slip:
			_rollback(dest, written)
			zr.close()
			return fail.call("包内含可疑路径，已中止并回滚：%s" % rel)
		var bytes := zr.read_file(name)
		if bytes == null:
			continue
		total += bytes.size()
		if total > MAX_INSTALL_BYTES:
			_rollback(dest, written)
			zr.close()
			return fail.call("解压总量超过 %d MB，已中止并回滚" % (MAX_INSTALL_BYTES / 1048576))
		var target := dest.path_join(rel)
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var wf := FileAccess.open(target, FileAccess.WRITE)
		if wf == null:
			_rollback(dest, written)
			zr.close()
			return fail.call("写入失败：%s" % target)
		wf.store_buffer(bytes)
		wf.close()
		written.append(target)
	zr.close()
	return {"ok": true, "reason": "", "mod_dir": dest, "files": written}


static func _rollback(dest: String, written: Array[String]) -> void:
	for w in written:
		DirAccess.remove_absolute(w)
	# 目录也清掉（失败不留半个 Mod 目录，否则下次安装会被"同名已存在"挡住）
	var d := DirAccess.open(dest)
	if d != null:
		var dirs := d.get_directories()
		for sub in dirs:
			DirAccess.remove_absolute(dest.path_join(str(sub)))
	DirAccess.remove_absolute(dest)


static func _list_zip(path: String) -> Array[String]:
	var out: Array[String] = []
	var zr := ZIPReader.new()
	if zr.open(path) != OK:
		return out
	for f in zr.get_files():
		out.append(str(f))
	zr.close()
	return out


## 关卡里的 topology（形式 2：positions + neighbors）→ board.json 约定的形式 1（positions + adjacency 边表）。
## 为什么要转：`core/mod_api.gd:420-421` 明确写了 board.json 的约定是 `{positions, adjacency}`
##（`setup_from_topo` 两种都吃，但按约定写能让任何只实现形式 1 的消费方也能用）。
static func _board_json(topo: Dictionary) -> Dictionary:
	var positions: Array = []
	for p in topo.get("positions", []):
		positions.append(p)
	var adjacency: Array = []
	var seen := {}
	var nbs: Variant = topo.get("neighbors", {})
	if nbs is Dictionary:
		for key in nbs:
			var a := _parse_key(String(key))
			for nk in nbs[key]:
				var b := _parse_key(String(nk))
				var k1 := "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
				var k2 := "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
				if seen.has(k1) or seen.has(k2):
					continue
				seen[k1] = true
				adjacency.append({"a": {"x": a.x, "y": a.y}, "b": {"x": b.x, "y": b.y}})
	var out := {"positions": positions, "adjacency": adjacency}
	if topo.has("style"):
		out["style"] = topo["style"]
	if topo.has("editor"):
		out["editor"] = topo["editor"]
	return out


static func _parse_key(s: String) -> Vector2i:
	var parts := s.split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


static func _default_id(doc: EditorDoc) -> String:
	var sid := str(doc.rule_spec.get("id", ""))
	if sid != "":
		return _slug(sid)
	return "pack_%s" % _slug(doc.title)


static func _slug(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch := text[i]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") \
				or ch == "_" or ch == "-":
			out += ch
	if out == "":
		out = "level"
	if out.length() > 48:
		out = out.substr(0, 48)
	return out


## 生成包的入口脚本：注册随包携带的规格。
## 幂等（已注册就返回 true）：同一个包被加载两次、或编辑器同进程里已注册过，都不该失败。
static func _entry_script(doc: EditorDoc, pack_id: String) -> String:
	var spec_json := "{}"
	if not doc.rule_spec.is_empty():
		spec_json = JSON.stringify(doc.rule_spec, "  ")
	var lines := PackedStringArray()
	lines.append("# %s —— 由变体扫雷编辑器生成（本地 workshop 包入口）。" % pack_id)
	lines.append("# 契约：《变体规则编写规范》§2 —— 钩子必须 return true，否则本次加载判为失败。")
	lines.append("# 为什么把规格内联在这里：包要能**离线自洽**——玩家装上包就该有规则，")
	lines.append("# 不能依赖作者机器上注册过的状态（那正是「在我这儿好好的」的典型来源）。")
	lines.append("")
	lines.append("const SPEC := %s" % spec_json)
	lines.append("")
	lines.append("")
	lines.append("func on_load() -> bool:")
	lines.append("\tvar rid := str(SPEC.get(\"id\", \"\"))")
	lines.append("\tif rid == \"\":")
	lines.append("\t\treturn true   # 无自带规则（纯关卡包）：无需注册")
	lines.append("\tif RuleRegistry.default().resolve(StringName(rid)) != null:")
	lines.append("\t\treturn true   # 幂等：已注册（重复加载 / 与编辑器同进程）不算失败")
	lines.append("\tvar r := SpecRulePlugin.register_from_json(JSON.stringify(SPEC))")
	lines.append("\tif not bool(r.get(\"ok\", false)):")
	# 注意：这一行**只允许一个 %s**（即 pack_id）——生成出来的代码自己再去拼错误详情，
	# 否则 % 格式化会因占位符与实参数量不符而在运行期报错（写的时候踩过一次）。
	lines.append("\t\tpush_error(\"%s 规格注册失败：\" + str(r.get(\"errors\", [])))" % pack_id)
	lines.append("\t\treturn false")
	lines.append("\treturn true")
	lines.append("")
	return "\n".join(lines)
