# level_staging.gd —— 生成器写盘的「暂存 → 校验 → 原子转正」小工具（2026-09-23 审计）
#
# 为什么需要：四个生成器（geo / style / variant / iso_cubes）原来直接
# FileAccess.open("res://levels/<file>", WRITE) 覆盖正式文件，自校验失败再 remove
# —— 盘上原有的好文件被「覆盖后删除」，净结果永久丢失；批量在后半程失败时还会留下
# 半写批次。gen_shape_levels 有自己的 TMP_DIR 暂存机制，其余四家没有。
#
# 三步用法：
#   var tmp := LevelStaging.write_text(path, text)  # 写暂存；"" = 写失败
#   ...用 tmp 做自校验（LevelLoader.load_level(tmp) 能正常读）...
#   通过 → LevelStaging.promote(tmp, path)（同目录原子 rename）
#   失败 → LevelStaging.discard(tmp)（只删自己写的暂存，正式文件原封不动）
#
# 暂存目录 = res://levels/_staging/：它是**子目录**，而 LevelLoader.list_levels() 与
# tools/import_*_to_lib.gd 都只扫 res://levels 顶层 ⇒ 崩溃残留的暂存文件不会被误当关卡。
extends RefCounted

const STAGING_DIR := "res://levels/_staging"


## 暂存路径：res://levels/_staging/<file>（按需建目录）。
static func staging_path(path: String) -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STAGING_DIR))
	return STAGING_DIR + "/" + path.get_file()


## 写暂存文件；返回暂存路径（"" = 失败）。
static func write_text(path: String, text: String) -> String:
	var tmp := staging_path(path)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("[staging] 无法写入 %s" % tmp)
		return ""
	f.store_string(text)
	f.close()
	return tmp


## 校验通过后把暂存原子转正到正式路径（同目录 rename）。false = 失败（正式文件未动）。
static func promote(tmp: String, path: String) -> bool:
	if tmp == "":
		return false
	var err := DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp),
			ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("[staging] 转正失败（err=%d）：%s → %s" % [err, tmp, path])
		return false
	return true


## 丢弃暂存（只删自己写的那个文件）。
static func discard(tmp: String) -> void:
	if tmp != "":
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
