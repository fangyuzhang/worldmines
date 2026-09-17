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
	var wav := AudioStreamWAV.load_from_file(path)
	if wav == null:
		return null
	_cache[sound_name] = wav
	return wav
