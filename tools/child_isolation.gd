# child_isolation.gd —— 生成工具的「进程隔离」通用封装（2026-09-24）
#
# ## 解决什么问题
#
# CP-SAT 的 `max_time_in_seconds` 只约束**求解**阶段，且 OR-Tools **不提供中止接口**
# （求解线程无法被安全强制终止）。实测大网格 + 变体规则时单次 `Solve()` 会长期不返回：
# 进程 CPU 近 0、无任何输出，从外部与死锁无法区分，只能手动杀进程 —— 整批白跑。
#
# 各生成工具原有的**看门狗**只在「两次求解调用之间」检查耗时，对单次挂死无能为力
# （实测 hard 档在 holed7 上就是这么挂住的）。只有把求解放进**独立进程**才能超时强杀。
#
# ## 用法（各生成工具三处接线）
#
#   const ChildIso := preload("res://tools/child_isolation.gd")
#
#   # ① 首帧分派
#   func _process(_delta):
#       if not _started:
#           _started = true
#           if ChildIso.is_child_mode():
#               ChildIso.run_child(...)      # 见 ②
#           else:
#               _run()
#
#   # ② 子进程侧：只做第 index 个规格
#   func _run_child_mode():
#       var a := ChildIso.child_args()        # [index, marker]
#       var code := 0 if _gen_one(SPECS[int(a[0])]) else 1
#       ChildIso.write_marker(str(a[1]), code)
#       _request_exit(code)
#
#   # ③ 父进程侧：循环里换成隔离调用
#   for i in SPECS.size():
#       var code := ChildIso.run_child("res://tools/xxx.gd", i) if isolate else ...
#
# ## 为什么规格传**索引**而不是内容（与 gen_variant_shape_levels 的差异，是有意的）
#
# 那几个工具的规格是**文件内常量** `SPECS`：同一份脚本 ⇒ 父子看到同一张表 ⇒ 索引足够，
# 而且能避开一个真坑 —— SPECS 里含 `Vector2i`（bbox / off_board），`JSON.stringify` 之后
# 反序列化回来是字符串或数组，**不再是 Vector2i**，子进程里按类型遍历会直接崩。
# 而 gen_variant_shape_levels 的 combos 是**运行期按 --tier 算出来的**（父子参数不同源），
# 所以它走「JSON 传规格」，那边没有 Vector2i、序列化安全 —— 两种做法各有其因，不是不一致。
extends RefCounted

## 单关子进程的默认上限。正常关实测 1~90 秒，5 分钟给了 3 倍以上余量；
## 再放宽就失去「及早失败」的意义（挂死的组合本来也产不出东西）。
const DEFAULT_TIMEOUT_MS := 300000
const POLL_MS := 250
## 子进程协作目录（规格、完成标记都放这里；user:// 不污染仓库）。
const WORK_DIR := "user://_child_work"


## 当前进程是否是「子进程侧」（命令行首参数为 child）。
static func is_child_mode() -> bool:
	var a := OS.get_cmdline_user_args()
	return a.size() >= 1 and str(a[0]) == "child"


## 子进程侧读参数：返回 [index:int, marker:String]。
static func child_args() -> Array:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		return [0, ""]
	return [int(str(a[1])), str(a[2])]


## 子进程侧写完成标记（父进程靠它判断结束；内容即退出码）。
static func write_marker(marker: String, code: int) -> void:
	if marker == "":
		return
	var f := FileAccess.open(marker, FileAccess.WRITE)
	if f != null:
		f.store_string(str(code))
		f.close()


## 父进程侧：把第 index 个规格放进独立子进程生成。
## 返回 0=成功 / 1=生成失败 / 2=超时被强杀。
static func run_child(tool_res_path: String, index: int, timeout_ms: int = DEFAULT_TIMEOUT_MS) -> int:
	DirAccess.make_dir_recursive_absolute(WORK_DIR)
	var tag := tool_res_path.get_file().get_basename()
	var marker := "%s/%s_%d.done" % [WORK_DIR, tag, index]
	var abs_marker := ProjectSettings.globalize_path(marker)
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(abs_marker)
	var pid := OS.create_process(OS.get_executable_path(), PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", tool_res_path,
		"--", "child", str(index), marker,
	]))
	if pid <= 0:
		push_error("%s #%d: 子进程启动失败" % [tag, index])
		return 1
	var waited := 0
	while waited < timeout_ms:
		OS.delay_msec(POLL_MS)
		waited += POLL_MS
		if FileAccess.file_exists(marker):
			var f := FileAccess.open(marker, FileAccess.READ)
			var code := 1
			if f != null:
				code = int(str(f.get_as_text()).strip_edges())
				f.close()
			return code
	if OS.is_process_running(pid):
		OS.kill(pid)
	push_error("%s #%d: 子进程超过 %d 秒未完成 —— 已强杀（CP-SAT 单次 Solve 无中止接口）" % [
		tag, index, timeout_ms / 1000])
	return 2
