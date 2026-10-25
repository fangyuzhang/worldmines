extends GutTest
## audio_manager.gd 盲区补测（2026-10-25 技术债清偿；此前仅被 test_settings_popup 顺带引用）。
## 无头模式无音频设备（dummy 驱动），play() 安全；重点测开关跳过 / 资源存在 / 缓存 / 未知名静默。

var _enabled_backup: bool


func before_all() -> void:
	_enabled_backup = AudioManager.enabled


func after_all() -> void:
	AudioManager.enabled = _enabled_backup


func test_sfx_table_complete_and_assets_exist() -> void:
	# 四个基础音效键齐 + 导入后的资源真实存在（缺文件会静默无声——09-28 审计 R1 的教训）
	assert_eq(AudioManager.SFX.size(), 4, "应有 4 个基础音效")
	for key in ["reveal", "flag", "explode", "win"]:
		assert_true(AudioManager.SFX.has(key), "缺音效键 %s" % key)
		assert_true(ResourceLoader.exists(AudioManager.SFX[key]),
			"音效资源不存在：%s（导出/导入链断裂会全程无声且无日志）" % AudioManager.SFX[key])


func test_play_disabled_is_silent_noop() -> void:
	AudioManager.enabled = false
	AudioManager.play("reveal")   # 不崩、不占用播放器
	var playing := 0
	for p in AudioManager._players:
		if p.playing:
			playing += 1
	assert_eq(playing, 0, "关闭态不得有播放器在响")


func test_play_unknown_name_is_silent_noop() -> void:
	AudioManager.enabled = true
	AudioManager.play("__no_such_sound__")
	assert_false(AudioManager._cache.has("__no_such_sound__"), "未知名不得进缓存")


func test_play_uses_player_pool_and_caches_stream() -> void:
	AudioManager.enabled = true
	AudioManager.play("reveal")
	var streamed := 0
	for p in AudioManager._players:
		if p.stream != null:
			streamed += 1
	assert_gte(streamed, 1, "播放后应至少有一个播放器持有流")
	# 缓存契约：同一音效二次加载必须命中同一实例（避免频繁 IO）
	assert_true(AudioManager._cache.has("reveal"), "首次播放后应入缓存")
	var first: AudioStream = AudioManager._cache.get("reveal")
	AudioManager.play("reveal")
	assert_same(first, AudioManager._cache.get("reveal"), "二次播放应复用缓存实例")
