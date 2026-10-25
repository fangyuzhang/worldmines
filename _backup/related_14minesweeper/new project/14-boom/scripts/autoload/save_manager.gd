extends Node
## 存档框架（基于 GodotSavesAddon 插件）。
##
## 设计目标（轻量 + 高性能 + 可直接用于产品）：
##   1. 多存档槽位 —— profile 即槽位名（slot_1..slot_N + main 主进度），插件原生支持
##   2. 自动备份 —— 插件 keep_backups 自动生成 .bak1..N 滚动备份，防损坏
##   3. Steam 云存档兼容 —— 存档为标准 .sav JSON（Steam Cloud 可同步目录），
##      并提供 export_slot_bytes / import_slot_bytes 对接 GodotSteam RemoteStorage
##   4. 完整性 —— SHA-256 校验和 + 版本迁移（插件内置）
##   5. 快速 —— JSON 纯文本（无加密/压缩开销），同步写入，数百字节微秒级
##
## 用法：
##   SaveManager.save_slot("slot_1", {"score": 100})
##   var d := SaveManager.load_slot("slot_1")
##   SaveManager.list_slots()            # ["main", "slot_1", ...]
##   SaveManager.export_slot_bytes("slot_1")   # 给 Steam.fileWrite
##   SaveManager.import_slot_bytes("slot_1", bytes)  # 从 Steam.fileRead
##   SaveManager.delete_slot("slot_1")

const SLOT_DIR := "save"
const SLOT_EXT := ".sav"
const MAIN_SLOT := "main"
const VERSION := "1.1"

## 变体解锁门槛（GDD §5.2.1）
const VARIANT_UNLOCKS := [
	{ "wins": 0, "ids": ["classic", "4N"] },
	{ "wins": 3, "ids": ["MX", "RF"] },
	{ "wins": 6, "ids": ["FR", "Clock", "DT", "Quadrant", "HV", "PF"] },
	{ "wins": 12, "ids": ["SC", "EP", "HaloDiff", "LoopRuns"] },
	{ "wins": 20, "ids": ["CC"] },
]

## 难度解锁门槛（GDD §5.2.2）
const DIFFICULTY_UNLOCKS := [
	{ "diff": 0, "wins": 0 },
	{ "diff": 1, "wins": 3 },
	{ "diff": 2, "wins": 5 },
]

var _save: Save
var data := {
	"version": VERSION,
	"player_name": "玩家",
	"settings": { "sound_volume": 0.7, "music_volume": 0.5, "fullscreen": false, "theme": "dark" },
	"progress": {
		"unlocked_variants": [],
		"unlocked_difficulties": [0],
		"total_games": 0,
		"total_wins": 0,
		"win_streak": 0,
		"best_streak": 0,
		"total_play_time_seconds": 0,
	},
	"best_times": {},
	"wins_by_difficulty": [0, 0, 0],
}
var _play_time_start := 0

func _ready() -> void:
	# 初始化插件 Save 节点（纯数据层，不挂 UI）
	_save = Save.new()
	_save.folder_name = SLOT_DIR
	_save.file_format = "json"
	_save.keep_backups = true
	_save.backup_limit = 3
	_save.use_encryption = false      # 轻量：纯文本即可，加密留给导出/Steam 层
	_save.use_compression = false
	_save.use_integrity_checksum = true   # 检测损坏/篡改
	_save.print_in_terminal = false
	_save.auto_load_on_ready = false
	_save.auto_save_interval = 0.0
	add_child(_save)
	load_main()

# ================= 多槽位存档（插件封装） =================

## 保存数据到槽位。slot 如 "slot_1"、"main"。自动备份由插件处理。
func save_slot(slot: String, slot_data: Dictionary) -> bool:
	_save.save_data(slot_data, slot, SLOT_EXT)
	return true

## 读取槽位数据；不存在或损坏返回空 Dictionary。
func load_slot(slot: String) -> Dictionary:
	return _save.edit_data(slot, SLOT_EXT)

## 列出所有存档槽位（含备份文件过滤）。返回如 ["main", "slot_1"]。
func list_slots() -> Array:
	var out: Array = []
	for f in _save.list_profiles(SLOT_EXT):
		if f.ends_with(SLOT_EXT) and not f.begins_with("."):
			out.append(f.trim_suffix(SLOT_EXT))
	return out

## 槽位是否存在
func has_slot(slot: String) -> bool:
	return list_slots().has(slot)

## 删除槽位（连同其备份）
func delete_slot(slot: String) -> void:
	var path := _slot_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	for i in range(1, _save.backup_limit + 1):
		var bak := "%s.bak%d" % [path, i]
		if FileAccess.file_exists(bak):
			DirAccess.remove_absolute(bak)

## 导出槽位原始字节（Steam 云上传用）
func export_slot_bytes(slot: String) -> PackedByteArray:
	var path := _slot_path(slot)
	if not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b

## 从原始字节导入槽位（Steam 云下载后恢复）
func import_slot_bytes(slot: String, bytes: PackedByteArray) -> bool:
	var path := _slot_path(slot)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true

## 槽位文件路径（user://save/<slot>.sav）
func _slot_path(slot: String) -> String:
	return "user://%s/%s%s" % [SLOT_DIR, slot, SLOT_EXT]

# ================= 主进度（业务层，存 main 槽位） =================

## 加载主进度
func load_main() -> void:
	var d := load_slot(MAIN_SLOT)
	if not d.is_empty():
		_merge(data, d)

## 保存主进度
func save_main() -> void:
	save_slot(MAIN_SLOT, data)

## 兼容旧接口
func save_game() -> void:
	save_main()

func load_game() -> void:
	load_main()

## 某变体是否解锁
func is_variant_unlocked(id: String) -> bool:
	return _variant_unlocked_ids().has(id)

## 某难度是否解锁
func is_difficulty_unlocked(idx: int) -> bool:
	for d in data.progress.unlocked_difficulties:
		if int(d) == idx:
			return true
	return false

func _variant_unlocked_ids() -> Array:
	var wins: int = int(data.progress.total_wins)
	var unlocked: Array = []
	for tier in VARIANT_UNLOCKS:
		var t: Dictionary = tier as Dictionary
		if wins >= int(t.wins):
			for id_str in (t.ids as Array):
				if not unlocked.has(id_str):
					unlocked.append(id_str)
	return unlocked

## 记录一局结束
func record_game(won: bool, difficulty: int, elapsed: float, variants: Array) -> void:
	data.progress.total_games += 1
	if won:
		data.progress.total_wins += 1
		data.progress.win_streak += 1
		data.progress.best_streak = maxi(data.progress.best_streak, data.progress.win_streak)
		if difficulty >= 0 and difficulty < data.wins_by_difficulty.size():
			data.wins_by_difficulty[difficulty] += 1
		for i in range(1, DIFFICULTY_UNLOCKS.size()):
			if is_difficulty_unlocked(i):
				continue
			if int(data.wins_by_difficulty[i - 1]) >= int((DIFFICULTY_UNLOCKS[i] as Dictionary).wins):
				data.progress.unlocked_difficulties.append(i)
		var key := _time_key(difficulty, variants)
		if not data.best_times.has(key) or elapsed < float(data.best_times[key]):
			data.best_times[key] = elapsed
	else:
		data.progress.win_streak = 0
	save_main()

func start_play_session() -> void:
	_play_time_start = Time.get_ticks_msec()

func _tally_play_time() -> void:
	if _play_time_start > 0:
		data.progress.total_play_time_seconds += int((Time.get_ticks_msec() - _play_time_start) / 1000.0)
		_play_time_start = 0

func _time_key(difficulty: int, variants: Array) -> String:
	var gen: Array = []
	var num: Array = []
	for v in variants:
		if v is VariantBase:
			var vb: VariantBase = v as VariantBase
			if vb.category == VariantBase.Category.GENERATION:
				gen.append(vb.id)
			else:
				num.append(vb.id)
	var diff_name := "custom"
	if difficulty == 0: diff_name = "easy"
	elif difficulty == 1: diff_name = "medium"
	elif difficulty == 2: diff_name = "hard"
	return "%s_%s" % [diff_name, ",".join(gen + num)]

func best_time(difficulty: int, variants: Array) -> float:
	return float(data.best_times.get(_time_key(difficulty, variants), -1.0))

func _merge(target: Dictionary, source: Dictionary) -> void:
	for k in source.keys():
		if target.has(k) and target[k] is Dictionary and source[k] is Dictionary:
			_merge(target[k], source[k])
		else:
			target[k] = source[k]
