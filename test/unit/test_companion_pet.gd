# test_companion_pet.gd —— 动物伙伴「占位猫」的结构镜像 / 状态机 / 布局代价 / 色板护栏
#
# 这个占位件的**全部价值**在于「后期换成真动画时不用改代码，只换数据」。所以本文件
# 守的不是"画得好不好看"（那只能靠截图），而是那三条**换资源时会静默失效**的契约：
#
#   ① 结构镜像：BONES/SLOTS/ANIMS/TRACKS 必须与真机骨架逐项对齐（56/30/18/6 轨道）。
#      漏一个动画 → 那条轨道永久停摆，而画面上只是"这次没眨眼"，谁也看不出来。
#   ② 状态机语义：loop 回绕 / 一次性播完清空 / 加权随机 / end-complete 同义。
#      写错了同样只是"有时候不动"，没有崩溃、没有报错。
#   ③ 布局代价：伙伴让位必须**只在必要时发生**，且 reserve=0 时与改造前逐像素相同。
#      这一条错了是 179 关的格子尺寸集体漂移，而截图里只是"好像小了点"。
#
# 另加两条工程一致性：board_view 与 companion_pet 各自独立声明的尺寸常量必须同值
#（沿用 HUD_SIDE_RESERVE 的守卫方式），以及伙伴色板的 8 条对比度护栏（P1..P8）。
extends GutTest

const RIG := preload("res://ui/companion_rig.gd")
const PET := preload("res://ui/companion_pet.gd")
const BV := preload("res://ui/board_view.gd")
const TM := preload("res://ui/theme_manager.gd")

var _pet


func before_each() -> void:
	# 固定种子：状态机用例要可复现（伙伴默认 randomize，这是刻意的 —— 真机上每局开
	# 场姿态不同才像活物；但测试需要确定值）。
	_pet = PET.new()
	_pet.rng_seed = 20260929
	add_child_autofree(_pet)
	_pet.size = PET.design_size()
	await get_tree().process_frame


## 新建一个伙伴并挂进树。add_child 会**同步**触发 _ready（_startup_tracks 随之跑完），
## 所以拿到实例后可以立刻读 track_state()，不必等帧。
func _new_pet(seed_value: int):
	var p = PET.new()
	p.rng_seed = seed_value
	add_child_autofree(p)
	return p


## 只取 6 条轨道的**动画名**。为什么不直接比 track_state()：本文件里每个伙伴都挂在树上，
## 引擎会按帧推进各自的播放头，而"创建时间不同 ⇒ 走过的帧数不同"——t 天然会漂。
## 动画名才是真正由种子决定、且与帧数无关的那部分。
func _anims(p) -> Array:
	var out: Array = []
	for st in p.track_state():
		out.append(str(st["anim"]))
	return out


# ============ ① 结构镜像：与真机 Spine 骨架逐项对齐 ============

func test_rig_counts_match_real_skeleton() -> void:
	assert_eq(RIG.SKELETON["bone_count"], 56, "真机 CozyCat 是 56 骨")
	assert_eq(RIG.SKELETON["slot_count"], 30, "真机 30 插槽")
	assert_eq(RIG.SKELETON["anim_count"], 18, "真机 18 段动画")
	assert_eq(RIG.BONES.size(), 56, "BONES 必须收全 56 根")
	assert_eq(RIG.SLOTS.size(), 30, "SLOTS 必须收全 30 个插槽")
	assert_eq(RIG.ANIMS.size(), 18, "ANIMS 必须收全 18 段")
	assert_eq(RIG.TRACKS.size(), 6, "规格书 §0 的状态机是 6 条轨道")


func test_bones_are_parent_before_child() -> void:
	## 真机的骨骼数组顺序保证「父必在子之前」，companion_pet._build_skeleton 直接依赖它
	## （一遍正向遍历，不排序）。若换资源时导出的表打乱了这个顺序，变换会算错一整帧。
	var idx := RIG.bone_index()
	var bad: Array = []
	for i in RIG.BONES.size():
		var b: Dictionary = RIG.BONES[i]
		var p := str(b.get("p", ""))
		if p == "":
			continue
		if not idx.has(p):
			bad.append("%s 的父 %s 不在表里" % [b["n"], p])
		elif int(idx[p]) >= i:
			bad.append("%s(第%d) 的父 %s(第%d) 排在其后" % [b["n"], i, p, int(idx[p])])
	assert_eq(bad, [], "骨骼顺序必须是「父在子之前」：%s" % str(bad))


func test_constraints_writers_come_before_readers() -> void:
	## 七条变换约束构成级联（FaceControl → FaceAll → EyeL/EyeR → Nose）。_apply_constraints
	## **只走一遍**，所以「写某骨」的约束必须排在「把该骨当 src 读」的约束之前，否则眼睛
	## 拿到的偏移会少一级（= 眼球不动），而这种缺失不会报错。
	var C: Array = RIG.CONSTRAINTS
	var bad: Array = []
	for k in C.size():
		var c: Dictionary = C[k]
		for j in k:
			var d: Dictionary = C[j]
			if (c["b"] as Array).has(str(d["src"])):
				bad.append("第%d条 %s 把 %s 当 src，但第%d条 %s 才写它" % [
					j, d["n"], d["src"], k, c["n"]])
	assert_eq(bad, [], "约束必须「先写后读」：%s" % str(bad))
	# FaceControl 由视线直接写入（_apply_gaze），不能又被某条约束覆盖，否则两份写入叠加
	for c in C:
		assert_false((c["b"] as Array).has("FaceControl"),
			"FaceControl 是视线的写入端，不该同时是约束的目标（%s）" % c["n"])


func test_track_weights_sum_to_1000() -> void:
	## pick_weighted 的入参是 0..999 的整数随机数。权重和必须是 1000，否则：
	## 小于 1000 → 末尾动画永远抽不到；大于 1000 → 部分随机数落到表外（走兜底分支）。
	for tr in RIG.TRACKS:
		var total := 0
		for w in (tr["anims"] as Array):
			total += int(w[1])
		assert_eq(total, 1000, "轨道 %s 的权重和应为 1000（实得 %d）" % [tr["id"], total])


func test_every_track_animation_has_positive_duration() -> void:
	assert_eq(RIG.missing_or_zero_duration(), [],
		"轨道引用的每一段动画都必须存在于 ANIMS 且时长 > 0（否则该轨道永久停摆）")


func test_referenced_anims_cover_all_but_scratch() -> void:
	## 18 段动画里被 6 条轨道引用的是 17 段；剩下那一段是 "Temp" —— Spine 编辑器里的
	## 临时动画，真机也没有把它挂进状态机。这里显式钉住这个差集，免得将来有人
	## "顺手补全"时把 Temp 也挂上（那会抽到一段空动画）。
	var ref: Array = RIG.referenced_anims()
	var all: Array = RIG.anim_names()
	all.sort()
	var extra: Array = []
	for a in all:
		if not ref.has(a):
			extra.append(a)
	assert_eq(ref.size(), 17, "6 条轨道共引用 17 段动画")
	assert_eq(extra, ["Temp"], "未被引用的应只有编辑器的临时动画 Temp（实得 %s）" % str(extra))


func test_every_part_is_drawn_exactly_once() -> void:
	## DRAW_ORDER 是绘制顺序表（照真实插槽顺序），PARTS 是图元表。两张表错位 =
	## 某个部位永远不画（或者被画两次）。允许的差集只能来自"纯功能骨骼"——
	## 这些骨骼在真机里有插槽但没有贴图（FaceControl / FaceAll / 视线的中间骨等）。
	var missing: Array = []
	for bn in PET.PARTS.keys():
		if not PET.DRAW_ORDER.has(bn):
			missing.append(bn)
	assert_eq(missing, [], "PARTS 里的每个部位都必须在 DRAW_ORDER 里（否则永远不画）：%s" % str(missing))
	var dup: Array = []
	var seen := {}
	for bn in PET.DRAW_ORDER:
		if seen.has(bn):
			dup.append(bn)
		seen[bn] = true
	assert_eq(dup, [], "DRAW_ORDER 不得重复：%s" % str(dup))


func test_draw_order_mirrors_real_slot_order() -> void:
	## 两处照抄真机的**反直觉**前后关系（写成"修正"就破坏了镜像）：
	##   ① 外耳画在头**之前**（真机 BC_Ear_R 槽位 09 / Bc_Head 槽位 11）⇒ 外耳被头压住一半；
	##   ② 内耳画在头**之后**（槽位 26/27）⇒ 露在外面；
	##   ③ 尾巴画在身体之前（槽位在躯干前）。
	var i_head: int = PET.DRAW_ORDER.find("Head")
	var i_ear_outer: int = PET.DRAW_ORDER.find("EarR1")
	var i_ear_inner: int = PET.DRAW_ORDER.find("EarR2")
	var i_body: int = PET.DRAW_ORDER.find("Body")
	var i_tail: int = PET.DRAW_ORDER.find("Tail1")
	assert_true(i_ear_outer >= 0 and i_head >= 0, "前置：外耳与头都在表里")
	assert_lt(i_ear_outer, i_head, "外耳必须画在头之前（真机槽位 09 < 11，靠头压住耳根）")
	assert_gt(i_ear_inner, i_head, "内耳必须画在头之后（真机槽位 26/27，露在外面）")
	assert_lt(i_tail, i_body, "尾巴必须画在身体之前（否则尾根会盖在肚子上）")


# ============ ② 状态机语义 ============

func test_tracks_are_six_and_click_starts_empty() -> void:
	var st: Array = _pet.track_state()
	assert_eq(st.size(), 6, "6 条轨道")
	assert_eq([st[0]["id"], st[1]["id"], st[2]["id"], st[3]["id"], st[4]["id"], st[5]["id"]],
		["idle", "tail", "ear", "eye", "plant", "click"], "轨道顺序/语义须与规格书 §0 一致")
	for i in 5:
		assert_ne(str(st[i]["anim"]), "", "开场应给 %s 轨道抽一段动画" % st[i]["id"])
	assert_eq(str(st[5]["anim"]), "", "点击轨道开场必须为空（只在一击时播）")


func test_weighted_pick_is_exact_for_the_real_tables() -> void:
	## pick_weighted 是**阈值扫**不是比例抽：r ∈ 0..999 时每一段动画命中的 r 个数
	## 必须**正好等于**它的权重。所以可以逐 r 精确断言（不用统计近似）。
	for tr in RIG.TRACKS:
		var counts := {}
		for r in 1000:
			var a: String = RIG.pick_weighted(tr["anims"], r)
			counts[a] = int(counts.get(a, 0)) + 1
		for w in (tr["anims"] as Array):
			assert_eq(int(counts.get(str(w[0]), 0)), int(w[1]),
				"轨道 %s：%s 命中了 %d 次，权重是 %d" % [tr["id"], w[0], int(counts.get(str(w[0]), 0)), int(w[1])])


func test_click_track_plays_once_then_clears() -> void:
	## track 5：loop=false 且 on="" ⇒ 播完**清空**（不是回绕、也不是停在末帧）。
	_pet.trigger_click()
	var st: Array = _pet.track_state()
	assert_eq(str(st[5]["anim"]), "IdleClick", "点一下应播 IdleClick")
	assert_eq(str(st[5]["dur"]), "1.3339", "IdleClick 时长应是真机的 1.3339s")
	# 推进到超过时长 → 清空
	_pet._advance_tracks(1.5)
	assert_eq(str(_pet.track_state()[5]["anim"]), "", "一次性动画播完必须清空该轨道")


func test_loop_track_wraps_instead_of_clearing() -> void:
	## track 0（Ideal）：loop=true ⇒ 回绕，永不落空。这里不关心换成哪一段，
	## 只钉住"回绕后仍有动画、且 t 落在 [0, dur)"。
	var dur: float = RIG.anim_duration(str(_pet.track_state()[0]["anim"]))
	_pet._advance_tracks(dur + 0.05)
	var st0: Dictionary = _pet.track_state()[0]
	assert_ne(str(st0["anim"]), "", "loop 轨道回绕后不得为空")
	assert_lt(float(st0["t"]), float(st0["dur"]) + 0.0001, "回绕后 t 必须落回区间内")
	assert_gt(float(st0["dur"]), 0.0, "循环轨道必须抽到有时长的动画")


func test_end_and_complete_are_synonyms() -> void:
	## 规格书 §0 写「尾巴用 complete 事件」，但真机 events 段只定义了 end，且 Tail1/Tail2
	## 的末帧事件也是 end@3.0（见 _pv/cat_anim_probe.txt）。严格按 complete 判定的话
	## 尾巴会永久停摆 ⇒ 代码把 complete 当 end 的同义写法。这条用例就是那个决定的守卫。
	var ti: int = RIG.track_index("tail")
	var tr: Dictionary = RIG.TRACKS[ti]
	assert_eq(str(tr["on"]), "complete", "前置：尾巴轨道的声明事件名仍是规格书的 complete")
	_pet._set_track(ti, "Tail1")
	_pet._fire("complete", tr, ti, "Tail1")
	assert_true(["Tail1", "Tail2"].has(str(_pet.track_state()[ti]["anim"])),
		"complete 必须能推进尾巴轨道（与 end 同义）")
	# 未声明依赖事件的轨道（plant, on=""）不得被切走
	var pi: int = RIG.track_index("plant")
	_pet._set_track(pi, "Plants")
	_pet._fire("", RIG.TRACKS[pi], pi, "Plants")
	assert_eq(str(_pet.track_state()[pi]["anim"]), "Plants", "未声明事件的轨道不切换（永不切换）")
	# 陌生事件名不得推进
	_pet._set_track(ti, "Tail1")
	_pet._fire("bogus", tr, ti, "Tail1")
	assert_eq(str(_pet.track_state()[ti]["anim"]), "Tail1", "未声明的事件名不得推进轨道")


func test_same_seed_gives_identical_startup_pose() -> void:
	## 确定性：固定种子 → 开场姿态完全一致。这条同时证明伙伴**没有**碰 RNGService
	##（那条流是关卡生成的 golden 种子回归基准，被伙伴每帧抽一次就打乱了）。
	##
	## 两个实例都在本用例内新建：不能拿 before_each 那个当基准 —— 它已经跑过若干帧，
	## 而 ear/eye 是一次性轨道（播完必然换段），帧数一多基准自己就漂了。
	var a = _new_pet(20260929)
	var b = _new_pet(20260929)
	assert_eq(_anims(a), _anims(b), "同种子必须得到同一开场姿态")
	# 反向：换种子必须换姿态。⚠️ 单个种子对对碰有 ~3% 的偶然全同率（6 条轨道各抽一次
	# 加权随机、恰好全落在同一档），只试一个种子会变成间歇性红的假失败 —— 这里扫 12 个
	# 种子并要求大多数不同，"没对上"的概率低到可忽略。
	var n_diff := 0
	for s in range(100, 112):
		if _anims(_new_pet(s)) != _anims(b):
			n_diff += 1
	assert_gte(n_diff, 6,
		"12 个不同种子里至少 6 个应与基准姿态不同（种子没接上的话这条会红）")


func test_react_is_throttled_and_cooldown_guarded() -> void:
	## 盘面每翻一格都会 _on_cell_changed → react()。泛洪一次可能连发几十次，
	## 若没有闸门，猫会抽成癫痫。两道闸：REACT_MIN_GAP_MS 去抖 + CLICK_COOLDOWN_MS 冷却。
	_pet._react_last_ms = -100000
	_pet._click_until_ms = -100000
	_pet.react(1.0)
	assert_ne(str(_pet.track_state()[5]["anim"]), "", "第一次 react 应播点击反应")
	# 冷却内再点：不得重启（t 会保持原值，而不是回 0）
	_pet._track_t[5] = 0.4
	_pet.react(1.0)
	assert_almost_eq(float(_pet.track_state()[5]["t"]), 0.4, 0.001,
		"冷却期内的 react 不得重启动画")


func test_frozen_stops_time_but_keeps_state() -> void:
	_pet.frozen = true
	var before: Array = _pet.track_state()
	_pet._process(0.5)
	assert_eq(_pet.track_state(), before, "冻结时姿态不得推进（暂停/终局）")
	_pet.frozen = false
	_pet._process(0.5)
	assert_ne(_pet.track_state(), before, "解冻后应恢复推进")


# ============ ③ 视线链（规格书 §0 那句「C3.lerp 跟随鼠标 X」）============

func _clear_tracks() -> void:
	for ti in RIG.TRACKS.size():
		_pet._track_anim[ti] = ""


func test_gaze_cascades_through_the_constraint_chain() -> void:
	## 写源头（Chest 旋转 + FaceControl 平移）之后，偏移必须按约束的 mix 逐级衰减到脸上：
	##   FaceControl ×1 → FaceAll ×0.3 → EyeL/EyeR ×0.3×0.5 = ×0.15
	## 这条同时守住「约束只走一遍」的正确性：若顺序写反，下面第三、四行会各差一级。
	_clear_tracks()
	_pet._gaze = 1.0
	_pet._pose()
	var gx: float = PET.GAZE_TX
	assert_almost_eq(_pet._off_p[int(_pet._idx["Chest"])].length(), 0.0, 0.001,
		"视线写 Chest 的是**旋转**不是平移")
	assert_almost_eq(_pet._off_r[int(_pet._idx["Chest"])],
		deg_to_rad(PET.GAZE_CHEST_DEG), 0.0001, "Chest 的旋转应等于 GAZE_CHEST_DEG")
	assert_almost_eq(_pet._off_p[int(_pet._idx["FaceControl"])].x, gx, 0.001,
		"FaceControl 拿到视线全量平移（它是链的源头）")
	assert_almost_eq(_pet._off_p[int(_pet._idx["FaceAll"])].x, gx * 0.3, 0.001,
		"FaceAll 应拿到 0.3 倍（约束 FaceControl_Face 的 mixX）")
	assert_almost_eq(_pet._off_p[int(_pet._idx["EyeR"])].x, gx * 0.15, 0.001,
		"EyeR 应拿到 0.3×0.5 = 0.15 倍（级联，不是 0.5）")
	assert_almost_eq(_pet._off_p[int(_pet._idx["EyeL"])].x, gx * 0.15, 0.001, "EyeL 同 EyeR")


func test_gaze_sources_are_resolved_from_the_rig_not_hardcoded() -> void:
	## 视线链的**源骨名**必须按候选表解析，不能写死在 _apply_gaze 里 —— 换动物时名字会变
	## （黑猫有专门的 FaceControl，规格书里的小老虎/小黑熊只有 FaceAll）。
	## 写死的症状是**静默降级**：不报错、不崩溃，只是平移支路整个失效。
	## 实测（_pv/rig_swap_drill.py）：小老虎因此丢掉 54% 的视线响应（103.5px → 47.6px）。
	assert_eq(str(RIG.GAZE_ROT_BONES[0]), "Chest", "黑猫的旋转源仍是 Chest（候选首位）")
	assert_eq(str(RIG.GAZE_TX_BONES[0]), "FaceControl", "黑猫的平移源仍是 FaceControl（候选首位）")
	assert_eq(_pet._gaze_rot_i, int(_pet._idx["Chest"]), "应解析到 Chest 的下标")
	assert_eq(_pet._gaze_tx_i, int(_pet._idx["FaceControl"]), "应解析到 FaceControl 的下标")
	# 黑猫的解析结果与"写死名字"逐值相同 ⇒ 这次改动对黑猫零行为变化
	# 解析器本身
	assert_eq(_pet._pick_bone(["NoSuchBone"]), -1, "一个都不存在必须是 -1（而不是崩、也不是取 0）")
	assert_eq(_pet._pick_bone(["NoSuchBone", "Head"]), int(_pet._idx["Head"]), "应跳过缺失的候选")
	assert_eq(_pet._pick_bone([]), -1, "空候选表也是 -1")


func test_gaze_tx_branch_is_load_bearing() -> void:
	## 平移支路不能是摆设：关掉它，眼球的世界位移必须**明显变小**。
	## ⚠️ 必须比二维位移的**长度**，不能只比 x —— 黑猫的 Body 是 r=90 的骨，
	## 它把 FaceControl 局部的 +x 映射到世界的 +y（实测该支路在 y 上 175.7、x 上 0）。
	## 只看 x 会得出"这条支路根本没生效"的错误结论（钻取时踩过这个坑）。
	_clear_tracks()
	var on := _eye_move()
	var saved: int = _pet._gaze_tx_i
	_pet._gaze_tx_i = -1
	var off := _eye_move()
	_pet._gaze_tx_i = saved
	assert_gt(on.length(), off.length() * 1.10,
		"关掉平移支路后眼球世界位移应明显变小（开 %.1f / 关 %.1f）"
		% [on.length(), off.length()])
	# 本地增量口径更硬：EyeR 拿到 0.15×全量；关掉后必须是 0
	_pet._gaze = 1.0
	_pet._pose()
	assert_almost_eq(_pet._off_p[int(_pet._idx["EyeR"])].length(), PET.GAZE_TX * 0.15, 0.001,
		"开着时 EyeR 的本地平移 = 0.15 × GAZE_TX（级联 0.3×0.5）")
	_pet._gaze_tx_i = -1
	_pet._pose()
	assert_almost_eq(_pet._off_p[int(_pet._idx["EyeR"])].length(), 0.0, 0.001,
		"关掉后 EyeR 必须完全没有平移（只剩 Chest 旋转带来的世界位移）")
	_pet._gaze_tx_i = saved
	_pet._gaze = 0.0
	_pet._pose()


## gaze 在 -1 → +1 之间，EyeR 的世界位移矢量（长度才有意义，见上面的 r=90 说明）。
func _eye_move() -> Vector2:
	_pet._gaze = 1.0
	_pet._pose()
	var a: Vector2 = _pet.bone_world("EyeR").origin
	_pet._gaze = -1.0
	_pet._pose()
	var b: Vector2 = _pet.bone_world("EyeR").origin
	_pet._gaze = 0.0
	_pet._pose()
	return a - b


func test_gaze_direction_follows_mouse_side() -> void:
	_clear_tracks()
	_pet._gaze = -1.0
	_pet._pose()
	assert_almost_eq(_pet._off_p[int(_pet._idx["FaceControl"])].x, -PET.GAZE_TX, 0.001,
		"鼠标在左侧时 FaceControl 应向负方向偏（左右不能反）")
	assert_lt(_pet._off_r[int(_pet._idx["Chest"])], 0.0, "Chest 的旋转方向应随之取反")


func test_gaze_converges_frame_rate_independently() -> void:
	## C3.lerp 必须写成 1-exp(-k·dt) 而不是 k·dt 直乘：后者在低帧率下过冲、在 144fps 与
	## 30fps 上手感不同。这里用「一次大步」与「两次半步」对比，差一个 (1-er) 项。
	_clear_tracks()
	_pet._gaze = 0.0
	_pet._pointer = Vector2(1000.0, 0.0)
	_pet._update_gaze(0.5)
	var big: float = _pet._gaze
	_pet._gaze = 0.0
	_pet._update_gaze(0.25)
	_pet._update_gaze(0.25)
	assert_almost_eq(_pet._gaze, big, 0.02,
		"半步两次与一次整步应几乎同值（帧率无关收敛）")


# ============ ④ 布局代价：让位只在必要时发生，且 reserve=0 逐像素等价 ============

func test_zero_reserve_layout_is_pixel_identical_to_before() -> void:
	## 改造前矩形路径的居中公式是 (vp.x − board_w)/2；改造后写成
	## avail_left + (avail_w − board_w)/2（= 左边缘锚定，好让 reserve>0 时从右侧收）。
	## 两者在 reserve=0 时必须**恒等**，否则 179 关的格子尺寸集体漂移。
	var vp := Vector2(1280.0, 720.0)
	var avail_h: float = vp.y - 64.0 - 64.0 - 48.0
	var avail_left: float = 24.0 + BV.HUD_SIDE_RESERVE
	for cols in [4, 5, 9, 12, 16, 24, 48, 60]:
		for rows in [4, 5, 8, 9, 12, 16, 24]:
			var reserve: float = 0.0
			var avail_w: float = vp.x - 48.0 - 2.0 * BV.HUD_SIDE_RESERVE - reserve
			var cell: int = maxi(floori(min(avail_w / float(cols), avail_h / float(rows))), BV.MIN_CELL_PX)
			var bw: float = float(cols) * float(cell)
			assert_almost_eq(avail_left + (avail_w - bw) * 0.5, (vp.x - bw) * 0.5, 0.0001,
				"%d×%d：新公式在 reserve=0 时必须与旧公式逐像素相同" % [cols, rows])


func test_real_rect_level_keeps_legacy_cell_size_at_zero_reserve() -> void:
	## 上一条是纯公式代数；这条是**端到端**：把改造前的公式在测试里独立写一遍，
	## 再与实际 layout 结果比。只比 reserve=0 ↔ reserve=0 等于自证（两边都跑新代码），
	## 所以这里必须独立重算旧式，否则「逐像素等价」这个承诺根本没有守卫。
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var bv = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(bv)
	await get_tree().process_frame
	assert_false(bv._hex_layout() or bv._custom_layout(), "前置：classic_01 必须走矩形路径")
	var vp: Vector2 = bv.get_viewport_rect().size
	var g: Vector2i = GameSession.board.grid.size()
	var avail_h: float = vp.y - 64.0 - 64.0 - 48.0
	# 旧式（2026-09-28 定稿的侧列版本，不含伙伴 reserve）
	var avail_w: float = vp.x - 48.0 - 2.0 * BV.HUD_SIDE_RESERVE
	var legacy_cell: int = maxi(floori(min(avail_w / float(g.x), avail_h / float(g.y))), BV.MIN_CELL_PX)
	assert_eq(bv.cell_px, legacy_cell, "reserve=0 时格子尺寸必须与改造前完全相同")
	assert_almost_eq(bv.board_origin.x,
		(vp.x - float(g.x) * float(legacy_cell)) * 0.5, 0.001,
		"reserve=0 时棋盘横向位置必须与改造前完全相同（旧式是 vp.x 居中）")
	assert_almost_eq(bv.board_origin.y,
		64.0 + (avail_h - float(g.y) * float(legacy_cell)) * 0.5, 0.001,
		"reserve=0 时棋盘纵向位置必须与改造前完全相同")


func test_pet_reserve_is_exactly_width_plus_edges() -> void:
	## 让位宽度必须**正好**是 PET_W + 2×PET_EDGE：小了 = 让位了还放不下（白亏格子），
	## 大了 = 白让位。这个等式也解释了"让位后条带恒 ≥ PET_W"（推导见 _apply_layout）。
	assert_almost_eq(BV.PET_RESERVE, BV.PET_W + 2.0 * BV.PET_EDGE, 0.001,
		"PET_RESERVE 必须 = PET_W + 2×PET_EDGE")
	assert_lt(BV.PET_MIN_W, BV.PET_W, "PET_MIN_W 必须 < PET_W（它管的是'缩到多小就不显示'）")


func test_board_view_and_pet_agree_on_dock_size() -> void:
	## 两处**独立声明**的尺寸常量必须同值（board_view 会被 headless 工具链间接加载，
	## 不给编译期依赖再添一环 ⇒ 用值复制 + 本守卫，与 HUD_SIDE_RESERVE 同款做法）。
	assert_almost_eq(BV.PET_W, PET.DESIGN_W, 0.001,
		"board_view.PET_W 必须 = companion_pet.DESIGN_W")
	assert_almost_eq(BV.PET_EDGE, PET.EDGE, 0.001,
		"board_view.PET_EDGE 必须 = companion_pet.EDGE")
	# 停靠区高度必须由骨架长宽比推出（硬编码近似值会让猫"胖一圈"且很难反查）
	var ds: Vector2 = PET.design_size()
	assert_almost_eq(ds.y, PET.DESIGN_W / RIG.ASPECT, 0.001,
		"design_size 的高度必须 = 宽 / 真机骨架长宽比")
	assert_almost_eq(ds.x / ds.y, RIG.ASPECT, 0.001, "design_size 的长宽比必须是骨架长宽比")


func test_pet_dock_sits_between_board_and_hud_column() -> void:
	## 端到端：真实关卡下停靠区必须落在「棋盘右边缘」与「HUD 右列保留线」之间，
	## 且伙伴矩形不越界。右列按钮实际占 x ∈ [vp.x−96, vp.x−12]
	##（offset_right −12、按钮宽 84），故停靠区右界 vp.x−116 要留出 ≥ 20px 间隙。
	assert_true(GameSession.start_level("res://levels/classic_01.json"), "需要一个真实关卡")
	var bv = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(bv)
	await get_tree().process_frame
	await get_tree().process_frame
	# 视口尺寸是下面全部像素断言的前提（project.godot 定的是 1280×720）。显式钉住它，
	# 免得哪天 CI 改了窗口尺寸，断言变成"在某个体积未知的窗口里恰好成立"。
	var vp := Vector2(1280.0, 720.0)
	assert_almost_eq(bv.get_viewport_rect().size.x, vp.x, 0.5,
		"前置：测试视口宽必须是 1280（project.godot window/size/viewport_width）")
	assert_almost_eq(bv.get_viewport_rect().size.y, vp.y, 0.5,
		"前置：测试视口高必须是 720")
	var dock: Rect2 = bv._pet_dock_rect(vp)
	assert_gte(dock.position.x, bv.board_vis_rect.end.x, "停靠区不得压在棋盘上")
	assert_lte(dock.position.x + dock.size.x, vp.x - BV.HUD_SIDE_RESERVE - BV.PET_EDGE + 0.001,
		"停靠区不得越过 HUD 右列保留线")
	assert_not_null(bv._pet, "board_view 必须真的创建了伙伴")
	assert_true(bv._pet.visible, "classic_01 的条带够宽，伙伴应当显示")
	assert_almost_eq(bv._pet.size.x / bv._pet.size.y, RIG.ASPECT, 0.001,
		"伙伴实际尺寸的长宽比必须与骨架一致（不符会被 companion_pet 等比留白，看不出错）")


func test_board_vis_rect_matches_drawn_bounds() -> void:
	## board_vis_rect 必须等于**实绘**包围盒（把全部格子的轮廓并起来）。第一版拿
	## board_origin 当左边缘，在 girih_02（自定义盘的世界坐标为负）上偏了近 50px，
	## 症状是"合法条带被算窄、伙伴莫名消失"。
	for path in ["res://levels/classic_01.json", "res://levels/hex_01.json",
			"res://levels/girih_02.json", "res://levels/sty_sq_wide.json"]:
		if not ResourceLoader.exists(path):
			continue
		assert_true(GameSession.start_level(path), "前置：start_level(%s)" % path)
		var bv = load("res://ui/board_view.tscn").instantiate()
		add_child_autofree(bv)
		bv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		await get_tree().process_frame
		await get_tree().process_frame
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in GameSession.board.grid.all_positions():
			for v in bv._cell_polygon(p):
				lo = Vector2(minf(lo.x, v.x), minf(lo.y, v.y))
				hi = Vector2(maxf(hi.x, v.x), maxf(hi.y, v.y))
		assert_almost_eq(bv.board_vis_rect.position.x, lo.x, 0.5,
			"%s：board_vis_rect 左边缘必须等于实绘左边缘" % path.get_file())
		assert_almost_eq(bv.board_vis_rect.size.x, hi.x - lo.x, 0.5,
			"%s：board_vis_rect 宽度必须等于实绘宽度" % path.get_file())
		bv.queue_free()
		GameSession.state = GameSession.State.IDLE
		GameSession.board = null


func test_reserve_only_when_it_actually_helps() -> void:
	## 两遍法的核心承诺：**只有**在让位真的能腾出条带时才让位。
	## 用 classic_01（不让位就够）验证它**没有**被多扣 216px；再用一关宽扁盘
	##（sty_sq_wide：不让位时条带 ≈ 0）验证让位后条带 ≥ PET_MIN_W。
	## 情形 A：足够宽 → _layout() 走完一遍就该收工，格子一格都不缩。
	assert_true(GameSession.start_level("res://levels/classic_01.json"))
	var a = load("res://ui/board_view.tscn").instantiate()
	add_child_autofree(a)
	await get_tree().process_frame
	await get_tree().process_frame
	var vp_a: Vector2 = a.get_viewport_rect().size
	var cell_a: int = a.cell_px
	a._apply_layout(vp_a, 0.0)
	var strip_a: float = a._pet_dock_rect(vp_a).size.x
	assert_gte(strip_a, BV.PET_MIN_W, "前置：classic_01 不让位就够宽（实得 %.0f）" % strip_a)
	assert_eq(a.cell_px, cell_a, "同一 reserve 重排必须幂等")
	a._layout()
	assert_eq(a.cell_px, cell_a, "classic_01 不该被让位（否则格子白缩 216px）")
	assert_true(a._pet.visible, "classic_01 的伙伴应可见")
	a.queue_free()
	GameSession.state = GameSession.State.IDLE
	GameSession.board = null

	# 情形 B：宽扁盘 → 让位后条带必须够宽
	if ResourceLoader.exists("res://levels/sty_sq_wide.json"):
		assert_true(GameSession.start_level("res://levels/sty_sq_wide.json"))
		var b = load("res://ui/board_view.tscn").instantiate()
		add_child_autofree(b)
		await get_tree().process_frame
		await get_tree().process_frame
		var vp_b: Vector2 = b.get_viewport_rect().size
		b._apply_layout(vp_b, 0.0)
		var strip0: float = b._pet_dock_rect(vp_b).size.x
		b._layout()
		var strip1: float = b._pet_dock_rect(vp_b).size.x
		assert_lt(strip0, BV.PET_MIN_W, "前置：sty_sq_wide 不让位时条带不够（实得 %.0f）" % strip0)
		assert_gte(strip1, BV.PET_MIN_W, "让位后条带必须够宽（实得 %.0f）" % strip1)
		# 让位后条带恒为 PET_RESERVE + 24 − 2×PET_EDGE（推导见 board_view._apply_layout：
		# 左边缘锚定 ⇒ 棋盘右边缘 = 128 + avail_w，与 vp.x 和盘面几何都无关）。
		assert_almost_eq(strip1, BV.PET_RESERVE + 24.0 - 2.0 * BV.PET_EDGE, 0.5,
			"让位后的条带宽度应是定值 %.0f（左边缘锚定的推论）" % (BV.PET_RESERVE + 24.0 - 2.0 * BV.PET_EDGE))
		assert_true(b._pet.visible, "让位后伙伴应可见")
		b.queue_free()
		GameSession.state = GameSession.State.IDLE
		GameSession.board = null


# ============ ⑤ 命中：轮廓命中，不是控件矩形 ============

func test_hit_test_follows_the_drawn_shape() -> void:
	## 停靠区是个矩形控件，但**空白角落必须放行**给棋盘 —— 否则那一片死区会吞掉点击。
	## 命中口径与 _draw_part 同源（同一张 PARTS 表 + 同一套 _world 变换），故这里用
	## 猫身/猫头的中点必中、控件四角必不中来钉住"不是整块矩形"。
	_pet.position = Vector2(900.0, 400.0)
	_pet.size = PET.design_size()
	_pet._clear_all_offsets_for_test()
	var cx: float = _pet.global_position.x
	var cy: float = _pet.global_position.y
	var w: float = _pet.size.x
	var h: float = _pet.size.y
	# 控件四角：必须放行（这是"矩形控件"与"轮廓命中"的唯一区别）
	for c in [Vector2(cx + 1.0, cy + 1.0), Vector2(cx + w - 1.0, cy + 1.0),
			Vector2(cx + 1.0, cy + h - 1.0), Vector2(cx + w - 1.0, cy + h - 1.0)]:
		assert_false(_pet.hit_test(c), "停靠区角落不该被判定为命中（会吞掉棋盘的点击）")
	# 躯干中部：必须命中。取「Body 骨沿骨轴 300」而不是 Body 骨的 origin ——
	# 后者（rig (0,15)）换算到 Body 块的局部正好是 (0,0)，而 Body 块是 ox=400/rx=400 的
	# 椭圆，于是 dx²+dy² 恰好 = 1.0，落在 <= 1.0 的**边界**上；仿射求逆的浮点误差会让它
	# 在 1.0 两侧跳 ⇒ 间歇性红。沿骨轴 300 落在块内，余量充足。
	var body: Transform2D = _pet.bone_world("Body")
	var body_scr: Vector2 = _pet._screen_xf() * (body * Vector2(300.0, 0.0))
	assert_true(_pet.hit_test(body_scr + _pet.global_position),
		"躯干正中必须命中（否则点猫没反应）")


func test_bone_world_reflects_hierarchy() -> void:
	## 头必须在身体之上（root y 更大），且头的位置随 Chest 的旋转变化 —— 这是
	## "层级真的在传递"的最小证据。第一版 _build_skeleton 的父指针若写错，这里会红。
	_pet._clear_all_offsets_for_test()
	var body: Transform2D = _pet.bone_world("Body")
	var head: Transform2D = _pet.bone_world("Head")
	assert_gt(head.origin.y, body.origin.y, "头必须在身体之上（Body 骨 r=90，向上生长）")
	var hand: Transform2D = _pet.bone_world("Hand")
	assert_eq(hand, Transform2D(), "不存在的骨骼应返回单位变换（调用方不必判空）")


# ============ ⑥ 伙伴色板护栏（与 _pv/derive_cozy.py 的 P1..P8 同门槛）============

func test_all_cozy_themes_have_the_full_pet_family() -> void:
	## 五套 CozyStyle 主题必须各有完整的 10 个 pet_* 键。缺键不会崩 —— pet_c 会静默回落到
	## 通用派生分支，猫照样能看，但**丢掉了该主题的色相/饱和度指纹**（CozyStyle 的毛色色相
	## 取自本主题的 BoardBg、鼻子取自暖色带最远点、叶取自工程 safe 绿），观感立刻从"这套主题
	## 的猫"退化成"通用灰猫"。这种降级不报错、只在截图里能看出来，所以必须逐键钉住。
	var want: Array = ["fur", "fur_2", "patch", "ink", "eye", "pupil", "nose",
		"leaf", "leaf_2", "shadow"]
	for m in TM.COZY_IDS:
		var pal: Dictionary = TM._COZY[m]
		var lack: Array = []
		for k in want:
			if not pal.has("pet_" + k):
				lack.append(k)
		assert_eq(lack, [], "%s 缺 pet_* 键：%s" % [m, str(lack)])


## 门禁取色：先找伙伴键（pet_<k>），再找主题角色键（<k>），最后才落回 pet_c 的派生分支。
##
## ⚠️ 不能一律走 pet_c()：门禁里的 `bg` 是**页面底色**，而 pet_c("bg") 会落到它的兜底分支
## （返回 text()）—— 那会把"毛 vs 页面"悄悄换成"毛 vs 正文色"，门禁照样绿，守的却不是原来那条。
func _pal_color(pal: Dictionary, t, k: String) -> Color:
	if pal.has("pet_" + k):
		return pal["pet_" + k]
	if pal.has(k):
		return pal[k]
	return t.pet_c(k)


func test_pet_palette_contrast_gates() -> void:
	## 8 条配对护栏，**7 套具体主题共用一个门槛表**：CozyStyle 五套直接读 pet_* 族，
	## dark / light 没有这一族、走 pet_c 的派生分支（_pet_solve 按同一批目标解明度）。
	## 先做一次标准值交叉验证，证明两份实现给出同一个数。
	assert_almost_eq(TM.contrast_ratio(Color("#777777"), Color("#FFFFFF")),
		4.4780885, 0.001, "WCAG 对比度公式必须与标准一致（#777 on #FFF ≈ 4.478）")
	var gates: Array = [
		["fur", "bg", 2.0, "猫毛必须能从页面底色里分出来"],
		["ink", "fur", 3.0, "描边必须能压在毛色上（否则整只猫糊成一团）"],
		["patch", "fur", 1.4, "口鼻斑必须能从毛色里分出来"],
		["eye", "fur", 1.9, "眼白必须能从毛色里分出来"],
		["pupil", "eye", 4.5, "虹膜压眼白（眼睛没有瞳就只是一块白斑）"],
		["nose", "fur", 1.4, "鼻色必须能从毛色里分出来"],
		["leaf", "bg", 1.4, "草叶必须能从页面底色里分出来"],
		["leaf_2", "leaf", 1.2, "两色叶才有层次"],
	]
	# TM 是 Node：不挂树也能用（这里只读 _active 与静态方法），但必须显式回收，
	# 否则 GUT 会把它报成 orphan。
	var t = autofree(TM.new())
	var worst := INF
	var worst_where := ""
	var n_themes := 0
	for m in TM.THEME_IDS:
		if m == "system":
			continue      # "system" 不是色板（按系统明暗落到 dark / light）
		var pal: Dictionary = TM._COZY[m] if TM.COZY_IDS.has(m) else (TM._DARK if m == "dark" else TM._LIGHT)
		t._active = pal
		n_themes += 1
		for gi in gates.size():
			var g: Array = gates[gi]
			var r: float = TM.contrast_ratio(
				_pal_color(pal, t, str(g[0])), _pal_color(pal, t, str(g[1])))
			if r / float(g[2]) < worst:
				worst = r / float(g[2])
				worst_where = "%s P%d %s⊥%s" % [m, gi + 1, g[0], g[1]]
			assert_gt(r, float(g[2]),
				"%s：P%d pet_%s⊥%s = %.3f:1（需 >%.1f，%s）"
					% [m, gi + 1, g[0], g[1], r, float(g[2]), g[3]])
	assert_eq(n_themes, 7, "必须覆盖 dark / light + CozyStyle 五套，共 7 套具体主题")
	# CozyStyle 的 P2/P5/P6 和派生分支的目标值都是"解到刚好过线"，余量天然很薄
	#（实测最紧 ≈1.01x）。把最紧的一条印出来，下次改色板就不必从"测试红了"倒推是哪条。
	gut.p("  最紧护栏：%s，余量 %.3fx" % [worst_where, worst])


func test_pet_nose_hue_differs_from_fur() -> void:
	## 鼻色相必须离毛色相足够远。这是真踩过的 bug：第一版从 NumWrong 借色相，而陶土主题的
	## BoardBg（毛色来源）与 NumWrong 同为暖红 ⇒ 鼻子和毛**完全同色**（0.0°，只剩亮度差），
	## 猫变成没鼻子。修法 = "在暖色带 [338°, 32°] 内挑离毛色最远的点"，本用例守卫那个决定。
	##
	## 门槛 20° 就是 _pv/derive_cozy.py 里那一条（`nose_dh < 20°` 即失败），不是随手定的。
	## 该做法能给出的**严格下界是 27°**：暖色带宽 54°，毛色落在带内时离最远端点至少 27°
	##（毛色恰在带中心时取到）。实测最小值 31.1°（陶土）。所以别把门槛提到 30 以上 ——
	## 那会让"陶土毛色再深一档"这类合法调整直接变红。
	##
	## 只对 CozyStyle 家族断言：dark / light 的毛色是中性灰（色相无定义），鼻子由 _pet_away
	## 只改明度 ⇒ 色相距离恒等于"danger 与中性灰之差"，不是这里的那个设计决定。
	var min_d := INF
	var min_where := ""
	for m in TM.COZY_IDS:
		var pal: Dictionary = TM._COZY[m]
		var f: float = (pal["pet_fur"] as Color).h
		var n: float = (pal["pet_nose"] as Color).h
		var d: float = absf(f - n)
		d = minf(d, 1.0 - d) * 360.0          # 环形最短色距（度）
		if d < min_d:
			min_d = d
			min_where = m
		assert_gt(d, 20.0,
			"%s：鼻色相与毛色相只差 %.1f°（需 >20°，否则鼻子看不见）" % [m, d])
	gut.p("  最紧鼻色相差：%s %.1f°（该做法的严格下界是 27°）" % [min_where, min_d])


func test_legacy_themes_really_use_the_derived_branch() -> void:
	## 上一条对 dark / light 走的是 pet_c 的**派生**分支。若哪天有人给 _DARK/_LIGHT 补上
	## pet_* 键，那条用例就会悄悄变成"在测色板"而不是"在测派生" —— 这里显式钉住前提；
	## 顺带守住派生不能退化成"全身一个色"（那正是第一版亮色主题的样子：描边对毛色 1.33:1）。
	# TM 是 Node：不挂树也能用（这里只读 _active 与静态方法），但必须显式回收，
	# 否则 GUT 会把它报成 orphan。
	var t = autofree(TM.new())
	var keys: Array = ["fur", "fur_2", "patch", "ink", "eye", "pupil", "nose", "leaf", "leaf_2"]
	for m in ["dark", "light"]:
		var pal: Dictionary = TM._DARK if m == "dark" else TM._LIGHT
		var has: Array = []
		for k in keys:
			if pal.has("pet_" + k):
				has.append(k)
		assert_eq(has, [], "%s 不应带 pet_* 键（带了的话派生分支就没人测了）" % m)
		t._active = pal
		var vals: Array = []
		var dup: Array = []
		for k in keys:
			var c: Color = t.pet_c(str(k))
			if vals.has(c):
				dup.append(k)
			vals.append(c)
		assert_eq(dup, [], "%s：派生退化成同色了（%s ⇒ 一块纯剪影）" % [m, str(dup)])
		# 派生值必须不透明：半透明的毛色会随页面底色漂，上面的对比度护栏也就失去意义。
		for k in keys:
			assert_almost_eq(t.pet_c(str(k)).a, 1.0, 0.001, "%s：pet_%s 必须不透明" % [m, k])
