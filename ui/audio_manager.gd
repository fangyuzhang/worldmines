# audio_manager.gd —— 音效播放器（plan1.1 §9.6 素材包入库）
# autoload 名：AudioManager
# 程序化生成的 4 个基础音效（assets/sfx/）：翻开 / 插旗 / 爆炸 / 胜利。
# 播放器池 + 流缓存，避免频繁 IO；enabled 关闭时静默跳过（设置项控制）。
extends Node

const SFX := {
	"reveal": "res://assets/sfx/reveal.wav",
	"flag": "res://assets/sfx/flag.wav",
	"explode": "res://assets/sfx/explode.wav",
	"win": "res://assets/sfx/win.wav",
}

var enabled: bool = true
var _cache := {}
var _players: Array[AudioStreamPlayer] = []


func _ready() -> void:
	# 开机同步音效开关：本 autoload（注册序 7）在 SettingsManager（序 4）之后就绪，
	# 由自己读取持久化值。原实现在 SettingsManager.load_cfg 里反向写本节点，
	# 因 autoload _ready 时序失败导致 sfx_enabled=false 开机不生效。
	# 运行时切换仍由 SettingsManager.set_sfx_enabled 双向同步（含测试断言依赖）。
	if SettingsManager != null:
		enabled = SettingsManager.sfx_enabled
	for i in 8:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


## 播放音效（按名称）。未启用或资源缺失时静默跳过。
func play(sound_name: String) -> void:
	if not enabled:
		return
	var stream := _load(sound_name)
	if stream == null:
		return
	for p in _players:
		if not p.playing:
			p.stream = stream
			p.play()
			return


func _load(sound_name: String) -> AudioStream:
	if not SFX.has(sound_name):
		return null
	if _cache.has(sound_name):
		return _cache[sound_name]
	var path: String = SFX[sound_name]
	if not ResourceLoader.exists(path):
		return null
	# 【09-28 审计修复 R1】原先 `AudioStreamWAV.load_from_file(path)` 直读 res:// 原始 wav：
	# 编辑器态能读到磁盘文件，但**导出后 wav 源文件不进 PCK**（只会打进 .godot/imported/*.sample，
	# 且 export_presets 的 include_filter 未列 assets/sfx/*）⇒ load_from_file 返回 null ⇒
	# play() 静默 return ⇒ **发布版翻开/插旗/爆炸/胜利四个音效全部无声且无任何日志**。
	# 改为走资源加载（拿导入后的 AudioStream），编辑器与导出行为一致；失败时留告警便于发现。
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("AudioManager: 音效加载失败 %s（请确认该 wav 已随导出包）" % path)
		return null
	_cache[sound_name] = stream
	return stream
