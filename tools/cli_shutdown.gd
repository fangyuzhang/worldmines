# cli_shutdown.gd —— 离线 CLI 脚本（extends SceneTree 的工具脚本）的可靠退出
#
# 为什么需要（实测数据，勿删，勿改回 quit()）：
#   Godot 4.7.2 mono 在本工程里会出现「任务全部跑完、日志打完，但进程不退出」。
#   实测（同一条命令重复跑）：
#     只有 print + quit(0) 的空脚本 ............ 7/8 挂
#     空白最小工程 ............................. 0/6 挂
#     空白最小工程 + C# ........................ 0/6 挂
#     空白最小工程 + Jolt Physics .............. 0/6 挂
#   即与业务逻辑、CP-SAT、MCP 插件都无关。输出顺序是线索：脚本日志先于 autoload
#   的 _ready() 打印，说明 _initialize() 里的 quit() 是在 autoload 尚未初始化完时
#   发出的，关机流程与之抢跑 → 概率性死锁。
#
# 对策（实测 0/8 挂）：
#   1) 打开 flush_stdout_on_print —— stdout 重定向到文件时是全缓冲，后面可能被强杀，
#      必须保证每条 print 立刻落盘，否则日志丢尾；
#   2) 延后几帧再退，让 autoload 初始化完毕；
#   3) 起一个延时子进程做看门狗：正常退出了它空转，没退掉就在 GRACE_SEC 后强杀本进程。
#
# 用法（不要用 class_name 引用，headless 下新全局类不在 .godot 缓存里会解析失败）：
#   const CliShutdown := preload("res://tools/cli_shutdown.gd")
#
#   func _initialize() -> void:
#       ... 干活 ...
#       CliShutdown.request_exit(0)      # 代替 quit(0)
#
#   func _process(_delta: float) -> bool:
#       return CliShutdown.poll(self)    # 直接 return 即可
extends RefCounted

const FRAMES_BEFORE_EXIT := 3
const GRACE_SEC := 2

static var _armed := false
static var _code := 0
static var _frames := 0
static var _wd_armed := false


## 在 CLI 脚本 _initialize() 末尾调用，代替 quit()。**登记退出 + 立刻装好看门狗**（真正的退出在 poll()）。
##
## 【09-28 审计修复 P2：兜底必须"当帧"装上，不能等 poll 的第 3 帧】
## 依据（服务器一次挂死 ≥7h17m 的取证）：挂死日志**已打印到 batch_all_variants 的"事件记录"行**
##（在 request_exit 之前），说明 request_exit 之前的代码都跑到了；而 `_arm_watchdog()` 原先只在
## poll() 的第 3 帧执行 ⇒ 主循环一旦卡在"登记"与"第 3 帧"之间，`sleep 2; kill -9` 的强杀子进程
## **永远不会被装上**，父 shell 只能死等到进程外看门狗（`prod_watchdog.sh`）出手。
## 把 arm 提前到登记时安装（幂等：`_wd_armed` 守卫），无论主循环是否还能推进，进程都会在 GRACE_SEC 内被杀。
static func request_exit(code := 0) -> void:
	ProjectSettings.set_setting("application/run/flush_stdout_on_print", true)
	_code = code
	_frames = 0
	_armed = true
	_arm_watchdog()


## 在 CLI 脚本的 _process(delta) 里 `return CliShutdown.poll(self)`。
## 返回 false = 继续跑帧；true = 主循环可以结束（内部已请求 quit 并装好看门狗）。
static func poll(tree: SceneTree) -> bool:
	if not _armed:
		return false
	_frames += 1
	if _frames < FRAMES_BEFORE_EXIT:
		return false
	_arm_watchdog()
	tree.quit(_code)
	return true


## 延时子进程兜底：正常退出则 taskkill 打空；卡住则在 GRACE_SEC 后被强杀。
## 幂等（`_wd_armed`）：request_exit 与 poll 都可能调用，重复装会多起一个击杀子进程。
static func _arm_watchdog() -> void:
	if _wd_armed:
		return
	_wd_armed = true
	var pid := OS.get_process_id()
	# 第三参必须给 Array（传 null 会 Parse Error：Cannot pass a value of type "null" as "Array"）
	var sink: Array = []
	if OS.get_name() == "Windows":
		OS.execute("cmd", ["/c", "ping -n %d 127.0.0.1 >nul & taskkill /pid %d /f >nul 2>&1" % [GRACE_SEC + 1, pid]], sink, false)
	else:
		OS.execute("sh", ["-c", "sleep %d; kill -9 %d" % [GRACE_SEC, pid]], sink, false)
