# 2026-09-28 UI 重构设计：跳过主菜单 / HUD 两列 / 齿轮设置 / 删进行中重开

> 状态：用户已逐项确认（7 个决策点），本文档落档后开始实现。

## 一、用户决策（原始口径）

| # | 需求 | 用户选择 |
|---|---|---|
| 1 | 启动跳过开始界面，直接进关卡选择 | **main_menu 彻底删除**；「返回菜单」全改「返回关卡选择」；图鉴/模组入口搬到选关页 |
| 2 | 设置改成右上角小齿轮 | 弹出**弹窗**（复用 settings_popup），不做整页 |
| 3 | 模组管理入口放进 Mod 页面 | 选关页「Mod 页签」顶部加「模组管理」按钮 → 打开现有 mod_select 管理页（"模组设置界面" = 该管理页本身，不新增 per-mod 配置） |
| 4 | 退出改用窗口叉号 | 删游戏内「退出」按钮；关闭走窗口叉号（**需新增拦截**，见 §F） |
| 5 | 删掉"进行中重开" | 删 HUD 按钮 + `R` 键 + 暂停菜单「重新开始」；**保留终局结算的「重新开始」** |
| 6 | HUD 改两列 | 顶栏：雷数 + 时间 + 教程 + 提示；**左列**：关卡列表；**右列**：暂停、撤销、设置 |
| 7 | 图鉴入口 | 选关页右上角**并排两个小按钮**：书本（图鉴）+ 齿轮（设置） |

## 二、现状侦查结论（实现依据）

- 启动场景 `project.godot: run/main_scene="res://ui/main_menu.tscn"`。
- `main_menu.tscn` 有 **7 处代码引用**：`project.godot` / `settings_panel.gd:89` / `pause_menu.gd:76` /
  `mod_select.gd:180` / `level_select.gd:1296` / `hud.gd:77` / `game_over.gd:81` / `codex.gd:160`。
- HUD 现为**顶栏横排一行**（HFlowContainer：雷数·教程·时间·暂停·提示·撤销·设置·重开·关卡列表·主菜单），
  没有左右两列 —— 第 6 条是**新建布局**，不是挪位置。
- 棋盘输入走 `board_view._gui_input`（不是 `_input`）⇒ 上层 Button 会先消费点击，**竖列按钮不会穿透到棋盘**。
- **`settings_popup` 只是设置子集**（外观/操作/对局提示/其他；无按键/音效/皮肤/数据页签）⇒ 若齿轮只用它，
  按键重绑/皮肤/数据将**无入口**。处理：弹窗底部加「完整设置…」→ 打开整页 `settings_panel`。
- 全仓**没有任何 `NOTIFICATION_WM_CLOSE_REQUEST` 处理**：点叉号 = 直接退出，不存档、不清"存活标志"
  ⇒ 第 4 条表面是删按钮，实际必须**新增**关闭拦截。
- 重开现有 4 个入口：HUD 按钮 / `R` 键 / 暂停菜单「重新开始」/ 终局「重新开始」。
  离开对局自动存档（`save_now`）且重进自动续档 ⇒ 全删会导致"无法从头再来"，故保留终局重开（用户已确认）。
- 主菜单另承载两件逻辑需搬走：**预热**（board_view ≈190ms + 选关页自身 257ms + 异形页扫描 ≈117ms）、
  **未完成对局提示/崩溃隔离**（`_saved_level_hint` + toast + `SaveCoordinator.clear_temp`）。

## 三、逐项实现方案

### A. 启动改选关页 + 主菜单删除
1. `project.godot`：`run/main_scene` → `res://ui/level_select.tscn`。
2. 删除 `ui/main_menu.gd` / `main_menu.tscn` / `main_menu.gd.uid`。
3. 7 处引用改指：
   - `hud.gd`「主菜单」按钮 → **删除**（两列布局无此席位）。
   - `pause_menu.gd`「主菜单」→ **删除**（与页内「关卡列表」同功能，避免重复）。
   - `game_over.gd`「返回菜单」→ 改文案「返回关卡列表」，跳选关页（保留 `SaveCoordinator.clear()`：
     终局后本局已结束，清临时档是既有语义）。
   - `settings_panel.gd` / `mod_select.gd` / `codex.gd` 的「返回」→ 跳选关页。
   - `level_select.gd:1296 _on_back_pressed` → 跳选关页（自身页面：改为无操作/保留但改指）。
4. 逻辑搬迁（主菜单 → 选关页 `_ready`）：
   - 预热 `board_view.tscn`（static 持有 + 延迟一帧，原样搬）。
   - 未完成对局提示：读 `SaveCoordinator.load_save()` → toast「有一局未完成…」+ 失效存档隔离备份
     （`_saved_level_hint` 与隔离逻辑一并搬；headless 下不弹——沿用 `DisplayServer.get_name()` 判断）。

### B. HUD 两列布局（`hud.gd` 重构）
- **顶栏**（保留 HFlowContainer，高度 64）：雷数 · 时间 · 教程 · 提示。
- **左列**（VBoxContainer，锚左侧垂直居中）：关卡列表。
- **右列**（VBoxContainer，锚右侧垂直居中）：暂停 · 撤销 · 设置。
- 竖列视觉：容器 `modulate.a ≈ 0.55`，鼠标进入 → 1.0（`mouse_entered/exited`）；按钮 tooltip 保留。
- 点击命中：容器 `mouse_filter = PASS`（空白处不挡棋盘），仅 Button 消费点击。
- 键盘可达：所有按钮维持 `FOCUS_ALL`（无障碍基线不降）。
- 最小窗口 1024×576 下验证不挤压（竖列宽 ≈ 96 + 边距 12）。

### C. 删"进行中重开"
- `hud.gd`：删「重开」按钮。
- `pause_menu.gd`：删「重新开始」按钮 + 未接线的 `restart_requested` 信号。
- `board_view.gd`：删 `key_for("restart")` 的 **PLAYING** 分支；**ENDED 特例保留**（终局键盘重开）。
- `settings_panel.gd`：删「重开前确认」行（`SettingsManager.restart_confirm` 属性保留：存档兼容）。
- `SettingsManager.KEY_ACTION_LABELS["restart"]` **保留**（终局键盘重开仍用它；改键页不动）。
- `UiConfirm.confirm_restart` 保留（无 UI 调用者；函数级测试仍覆盖），加注释说明现状。
- 测试更新：`test_settings_grouping.gd` 的 `EXPECTED_ENTRIES` 删「重开前确认」行。

### D. 选关页右上角：书本 + 齿轮（图标按钮）
- 两个 40×40 图标按钮（`PRESET_TOP_RIGHT` 并排），**内联 SVG 绘制**（先例：`drawing_toolbar.gd`
  的 `load_svg_from_string`），不引入外部资源。
- 齿轮 → 实例化 `settings_popup.tscn` → `popup_centered()`（缓存单例，与 HUD 同款）。
- 书本 → `change_scene_to_file("res://ui/codex.tscn")`。
- 无障碍：`tooltip_text`（"设置" / "规则图鉴"）+ `FOCUS_ALL`。

### E. Mod 页签加「模组管理」入口
- 选关页 Mod 页（`PAGE_MOD`）顶部加按钮 → `change_scene_to_file("res://ui/mod_select.tscn")`。

### F. 窗口叉号退出拦截
- 在 autoload（`GameSession` 或 `SaveCoordinator`，取已注册者）加：
  - `_ready`：`get_tree().auto_accept_quit = false`。
  - `_notification(what)`：`NOTIFICATION_WM_CLOSE_REQUEST` → 若对局进行中 `GameSession.save_now()`
    → `SaveCoordinator.clear_temp()`（清存活标志，防误报）→ `get_tree().quit()`。
- 不改任何场景：autoload 常驻，选关页/对局/图鉴均可拦截。

### G. 测试与文档
- 全量跑 `test/unit` + `test/ui`，逐个修红灯（预期涉及：HUD 按钮断言、主菜单引用、设置项清单、
  暂停菜单按钮数、页面数断言等）。
- 文档同步：`HANDOFF.md` / `交接文档.md` 的"主场景"一行改为选关页（仅这两处必要更新）。

## 四、风险与已接受项

1. **`settings_popup` 是子集** → 用「完整设置…」兜住（§D），否则按键/皮肤/数据无入口。
2. **竖列遮挡棋盘**：半透明 + 仅按钮吃点击；最小窗口验证；不影响棋盘命中（`_gui_input` 语义已确认）。
3. **测试面广**：主菜单被多处测试引用，红灯属预期，逐个改成选关页口径。
4. **误开局无法复位**（用户已确认）：进行中重开删除后，玩家只能打完、终局重开、或从关卡列表重进
   （重进会续档 —— 这是设计后果，非缺陷）。
5. **不新增 per-mod 配置界面**（"模组设置"= 现有管理页，用户已确认）。

## 五、验收清单

- [ ] 启动游戏直接进选关页；右上角并排「书本 + 齿轮」。
- [ ] 齿轮弹窗可改设置；弹窗内「完整设置…」可进整页设置（六个页签全在）。
- [ ] 选关页 Mod 页签顶部有「模组管理」入口，可进 mod_select 并返回。
- [ ] 对局 HUD：顶栏 4 项（雷数/时间/教程/提示）+ 左列 1 项（关卡列表）+ 右列 3 项（暂停/撤销/设置）；
      **无**「重开」「主菜单」按钮；竖列半透明、悬停显形。
- [ ] 终局结算仍有「重新开始」；`R` 键在终局仍可重开，进行中无效。
- [ ] 暂停菜单无「重新开始」「主菜单」；有「继续游戏」「关卡列表」。
- [ ] 设置页无「重开前确认」行。
- [ ] 点窗口叉号：进度已保存 + 下次启动无误报"未完成对局"。
- [ ] `test/unit` + `test/ui` 全量通过。
