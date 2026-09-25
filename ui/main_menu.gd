# main_menu.gd —— 主菜单 + 未完成对局自动恢复【plan1.1 §10.7.7-①】
# 文案唯一来源 §8.5：标题「世界扫雷」，按钮 开始游戏/规则图鉴/设置/模组/退出。
# v3.2：检测到未完成对局不再弹窗询问，直接自动恢复；无法恢复时隔离备份 + toast。
#
# 2026-09-23（用户决策）：删除主菜单的「教程」总入口。教程改为**上下文相关**——
# 选关页弹窗（看该变体教程）与对局 HUD 左上角（看当前变体教程），
# 共用 `ui/tutorial_overlay.gd` 的 static `show_for()`。
extends Control

## 自动恢复进程级门控：每次启动只在**首次进入主菜单**时尝试一次。
## 必须用 static（场景节点会随切页重建，实例字段保不住）——否则「暂停→回主菜单」
## 会立刻又被自动恢复弹回对局，用户永远到不了主菜单。
static var _auto_restore_done := false


func _ready() -> void:
    add_to_group("themed")
    ThemeManager.theme_changed.connect(_on_theme_changed)
    _build_ui()
    _schedule_prewarm()
    _check_crash_restore()


## 延迟一帧预热（2026-09-22 性能）：**先让主菜单渲染出来**，预热的开销放下一帧吃
##（process_frame 信号在节点 _process 之前发射）。
##
## 为什么不用 await：await 恢复时节点可能已不在树 → get_tree() 为 null → 真机崩溃
##（选关页同款事故记录）；信号连接随对象销毁自动断开，回调内再查一次树内状态即可。
## 若玩家在两帧内点「开始游戏」（实际不可能），切场景会在该帧同步等预热完成——
## 行为不劣于未优化前（那时预热就在切场景路径上）。
func _schedule_prewarm() -> void:
    var tree := get_tree()
    if tree == null:
        return
    tree.process_frame.connect(_prewarm_deferred, CONNECT_ONE_SHOT)


## 三项预热（2026-09-22 实测口径，全部从"点开始游戏之后的等待"前移到这里）：
##   ① board_view.tscn 首次 load ≈ 190ms（首次进关的顿挫源）
##   ② level_select.tscn 首次 load ≈ 257ms（脚本编译 + 依赖 + 场景构建）
##   ③ 异形页关卡扫描 ≈ 117ms（91 个 JSON 全量解析，原先在选关页建页时同步跑）
## 前两项直接 load 后**必须用 static 持有引用**——裸 load 的返回值无引用会被释放、
## 资源缓存随之失效（实测踩过：预热"做了"，选关页仍付全价）。
func _prewarm_deferred() -> void:
    if not is_inside_tree():
        return
    if _board_view_prewarmed == null:
        _board_view_prewarmed = load("res://ui/board_view.tscn")
    if _level_select_prewarmed == null:
        _level_select_prewarmed = load("res://ui/level_select.tscn")
    _prewarm_shape_scan()


static var _board_view_prewarmed: PackedScene = null
static var _level_select_prewarmed: PackedScene = null
static var _shape_scan_prewarmed := false


## 预热异形页的关卡扫描：`level_select._shape_levels()` 首次调用要扫 res://levels/
## 全部关卡 JSON（实测 91 个文件 ≈ 117ms），填充其**类级 static 缓存**。
## 用一个未入树的临时实例调用——该函数只读文件 + 写 static 缓存，
## 不依赖实例状态与场景树（已逐行核对）；实例用完即 free，不进树、不产生任何 UI。
func _prewarm_shape_scan() -> void:
    if _shape_scan_prewarmed:
        return
    _shape_scan_prewarmed = true
    var ls_script: GDScript = load("res://ui/level_select.gd")
    if ls_script == null:
        return
    var probe: Control = ls_script.new()
    if probe == null:
        return
    probe.call("_shape_levels")
    probe.free()


func _build_ui() -> void:
    var center := CenterContainer.new()
    center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(center)
    var vbox := VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 16)
    center.add_child(vbox)
    _vbox = vbox

    var title := Label.new()
    title.text = "世界扫雷"
    title.add_theme_font_size_override("font_size", 48)
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.custom_minimum_size = Vector2(400, 64)
    vbox.add_child(title)

    # 键盘可达（2026-09-25 无障碍审计）：此前全部 FOCUS_NONE ⇒ 键盘-only 玩家
    # **连游戏都进不去**（对局内键盘支持很完整，却卡在门外）。主菜单是总入口，先开这里。
    # VBoxContainer 内的按钮由引擎自动推导上下邻居（方向键/Tab 可走）。
    var first_btn: Button = null
    for cap in ["开始游戏", "规则图鉴", "设置", "模组", "退出"]:
        var btn := Button.new()
        btn.text = cap
        btn.focus_mode = Control.FOCUS_ALL
        btn.custom_minimum_size = Vector2(240, 48)
        btn.pressed.connect(_on_button.bind(cap))
        vbox.add_child(btn)
        if first_btn == null:
            first_btn = btn
    # 进场把焦点给「开始游戏」：键盘用户开屏即可回车进入（延迟一帧：场景刚实例化时
    # 节点还未完成布局，立即 grab_focus 可能被引擎丢弃）。
    if first_btn != null:
        first_btn.grab_focus.call_deferred()
    _title_label = title
    # Mod 纯数据挂载点（P4）：显示在按钮列末尾；无挂载时不产生任何节点
    UiMounts.append(vbox, UiMounts.SLOT_MAIN_MENU, self)
    _apply_theme()


var _title_label: Label
var _vbox: VBoxContainer


func _on_button(cap: String) -> void:
    match cap:
        "开始游戏":
            get_tree().change_scene_to_file("res://ui/level_select.tscn")
        "规则图鉴":
            get_tree().change_scene_to_file("res://ui/codex.tscn")
        "设置":
            get_tree().change_scene_to_file("res://ui/settings_panel.tscn")
        "模组":
            get_tree().change_scene_to_file("res://ui/mod_select.tscn")
        "退出":
            SaveCoordinator.clear_temp()  # 清存活标志，防误报（§10.7.7-①）
            get_tree().quit()


# ============ 崩溃恢复检测（验收项 3） ============

## 启动时的存档处理（2026-09-19 改）：**不再自动进入对局** —— 无论如何都留在主菜单，
## 由玩家自己从选关页重新选择。
##
## 为什么改：原 v3.2 行为是「有未终局对局就直接续上，不弹窗」（触发源包括非正常退出，
## 如点窗口叉号 / Alt+F4，也包括主动退出与回主菜单）。结果是玩家下次打开游戏**直接跳回
## 那一关**，想换关或先看菜单都被跳过，观感像「游戏没退出干净」。
##
## 存档本身**保留不删**：玩家从选关页点进同一关时，`LevelSelect._try_resume_saved`
## 会自动续上未完成进度（含重开窗口后的续档），进度不会丢。
##
## 坏档照旧隔离并提示（§10.7.4）；终局盘不恢复也不提示（失败局 SL 复活禁令，见
## restore_from_save 同口径）。有未完成对局时只给一条轻提示，让玩家知道进度还在。
func _check_crash_restore() -> void:
    if _auto_restore_done:
        return
    _auto_restore_done = true
    var d := SaveCoordinator.load_save()
    if d.is_empty():
        # TEMP 残留但读不出 → 真坏档，隔离（保留原崩溃检测口径）
        if SaveCoordinator.has_crash_leftover():
            SaveCoordinator.quarantine()
            _toast("存档无法恢复，已隔离备份")
        return
    var meta_v: Variant = d.get("metadata", {})
    var meta: Dictionary = meta_v if meta_v is Dictionary else {}
    if bool(meta.get("ended", false)):
        return  # 终局盘不可恢复也不提示（失败局 SL 复活禁令，见 restore_from_save 同口径）
    # 有未完成对局 → 只提示，不跳转（不用 GameSession.restore_from_save：留给选关页按需恢复，
    # 避免主菜单就把对局状态恢复进内存、玩家却去玩别的关）
    _toast(_saved_level_hint(str(meta.get("level_path", ""))), false)


## 把存档里的关卡路径转成一句可读提示。库关卡路径形如
## `<PLAY_DIR>/<mode>_<size>_<tier>_<idx>.json`，可解析出「变体 · 尺寸 · 档」；
## 其他命名（生成关等）一律走兜底文案 —— 不猜，乱猜的提示比笼统更糟。
func _saved_level_hint(level_path: String) -> String:
    var fallback := "有一局未完成的对局，从选关页进入同一关可继续。"
    var parts := level_path.get_file().get_basename().split("_")
    if parts.size() < 4:
        return fallback
    var mode := str(parts[0])
    var side := str(parts[1])
    var tier := str(parts[2])
    if not side.is_valid_int() or not Difficulty.TIERS.has(tier):
        return fallback
    return "有一局未完成的对局：%s · %s×%s · %s。从选关页进入同一关可继续。" % [
        VariantCatalog.display_name(mode), side, side,
        Difficulty.tier_text(tier)]


# ============ toast（场景内顶部 Label + Timer，2s 自动消失；文案 §8.5） ============

## toast 统一走 UiToast（原先此处与 level_select 各实现了一份完全相同的 Label+Timer）。
func _toast(msg: String, danger: bool = true) -> void:
    UiToast.popup(self, msg, danger)


# ============ 主题（所有色值经 ThemeManager） ============

func _apply_theme() -> void:
    if _title_label != null:
        _title_label.add_theme_color_override("font_color", ThemeManager.text())
        if _vbox != null:
            for c in _vbox.get_children():
                if c is Button:
                    _style_button(c)
    queue_redraw()


func _style_button(btn: Button) -> void:
    UiTheme.style_button(btn)


func _on_theme_changed() -> void:
    _apply_theme()
