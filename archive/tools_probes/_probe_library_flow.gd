# _probe_library_flow.gd —— 关卡库全链路 probe（2026-09-17）
#
# 验的是玩家真正走的链路：
#   ① ModAPI 自举：res://demo/mods/* → user://mods/* → 加载（22 席官方算子注册）
#   ② LevelLibrary：catalog 读取 + 集文件读取（idx 与难度排序）
#   ③ materialize：库里的一关落成可对局文件
#   ④ 用**引擎同路径**（Board.new().load_level）构造该文件 → 网格/雷数一致
#   ⑤ ProofLog.build → 序贯可解（正式内容必须无猜可推）
#   ⑥ LevelSequence：lib 路径解析 / 进度键 / 下一关推进（跨档跨尺寸）
extends SceneTree

const CliShutdown := preload("res://tools/cli_shutdown.gd")


func _initialize() -> void:
	var fail := 0

	# ① 自举
	var api: Object = load("res://core/mod_api.gd").new()
	var n_loaded: int = int(api.call("bootstrap_bundled_mods"))
	print("[1] 自举加载 Mod 数 = %d（期望 22）" % n_loaded)
	if n_loaded < 22:
		fail += 1
	var rule_ok := 0
	for rid in ["o1", "o4", "o5x", "o10", "s1", "s3", "s7", "z1", "z5"]:
		if RuleRegistry.default().resolve(StringName(rid)) != null:
			rule_ok += 1
	print("[1] 抽查规则注册 %d/9" % rule_ok)
	if rule_ok < 9:
		fail += 1

	# ② 库读取
	var cat: Dictionary = LevelLibrary.catalog()
	print("[2] catalog 变体数 = %d；o10 各档关数：%s" % [cat.size(), str(LevelLibrary.counts("o10", 7))])
	if LevelLibrary.count("o10", 7, "easy") <= 0 or LevelLibrary.count("o4", 9, "hard") <= 0:
		print("!!! 库读取异常")
		fail += 1

	# ③ 物化 + ④ Board 构造 + ⑤ 序贯可解（随机抽 3 个变体各 1 关）
	var cases := [["o10", 7, "normal", 3], ["o4", 9, "hard", 0], ["s1", 8, "easy", 0]]
	for c in cases:
		var mode := str(c[0])
		var side := int(c[1])
		var tier := str(c[2])
		var idx := int(c[3])
		if LevelLibrary.count(mode, side, tier) <= 0:
			print("!!! [%s %d×%d %s] 库内无此集（跳过）" % [mode, side, side, tier])
			continue
		var path: String = LevelLibrary.materialize(mode, side, tier, idx)
		if path == "" or not FileAccess.file_exists(path):
			print("!!! [%s %d×%d %s #%d] materialize 失败" % [mode, side, side, tier, idx])
			fail += 1
			continue
		var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
		var board := Board.new()
		board.load_level(d)
		var mines := int(d.get("total_mines", -1))
		var b_ok: bool = board.grid != null and board.total_mines == mines
		var log: Dictionary = ProofLog.build(d)
		var solved := bool(log.get("solved", false))
		print("[3] %s %d×%d %s #%d → Board ok=%s（雷 %d）｜序贯可解=%s（%d 步/%d 轮）" % [
			mode, side, side, tier, idx, str(b_ok), mines, str(solved),
			(log.get("steps", []) as Array).size(), int(log.get("rounds", 0))])
		if not b_ok or not solved:
			fail += 1

	# ⑥ 序列：解析 / 进度键 / 下一关
	var lp: String = LevelSequence.lib_path("o10", 7, "normal", 3)
	var parsed: Dictionary = LevelSequence.parse_path(lp)
	var key: String = LevelSequence.progress_key(lp)
	var nxt: Dictionary = LevelSequence.advance(lp)
	print("[4] parse=%s" % str(parsed))
	print("[4] progress_key=%s（期望 lib://o10/7/normal/3）" % key)
	print("[4] advance #3 → %s（同档下一关）" % str(nxt))
	var last_i := LevelLibrary.count("o10", 7, "normal") - 1
	var nxt2: Dictionary = LevelSequence.advance(LevelSequence.lib_path("o10", 7, "normal", last_i))
	print("[4] advance 末关 → %s（应跨档/跨尺寸）" % str(nxt2))
	if parsed.get("size", 0) != 7 or str(parsed.get("tier", "")) != "normal" \
			or str(parsed.get("mode", "")) != "o10" or key != "lib://o10/7/normal/3" \
			or str(nxt.get("idx", -1)) != "4":
		print("!!! 序列函数异常")
		fail += 1

	# ⑦ 多词模式名（含下划线的混合变体 id）解析不受影响
	var mixed_key := LevelSequence.progress_key(LevelSequence.lib_path("pf_hv", 6, "easy", 12))
	print("[5] 混合 id 解析：%s（期望 lib://pf_hv/6/easy/12）" % mixed_key)
	if mixed_key != "lib://pf_hv/6/easy/12":
		fail += 1

	print("=== 关卡库全链路：%s（失败 %d）===" % ["OK" if fail == 0 else "FAIL", fail])
	CliShutdown.request_exit(0 if fail == 0 else 1)
