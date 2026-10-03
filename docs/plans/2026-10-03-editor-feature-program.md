# 关卡编辑器 · 功能程序（对照《功能清单与注意事项》）

> 来源：用户提供的《关卡编辑器 · 功能清单与注意事项》（GLM5.3 建议稿）+ 2026-10-03 两轮子 Agent 只读勘察。
> 本文件是**可执行计划**：每个包都写明挂点（file:line）、验收方式（无头 GUT）与已知风险。
> 工作约定：**改代码由主 Agent 写 → 立刻跑 `tools/ci_check.ps1` 全量门禁 → 红了当场修 → 子 Agent 独立复核**。
> 不外包"改码"这一步：本会话多次证明未过门禁的改动会连坐数十条用例。

## 一、状态总表

| 包 | 内容（清单条目） | 状态 | 备注 |
|---|---|---|---|
| **W-I** | 输入侧总量闸门（数据爆炸 I） | ✅ 已交付 | `core/level_guard.gd` + `_load_from_text` 两道闸（先字节后规模）；用例：4000×4000 拒载、5000 条雷位拒载、>2MB 拒载、正常关卡不误伤 |
| **W-S** | 保存原子写（清单·一"保存不得自创一套"） | ✅ 已交付 | `_save()` 改 tmp→rename，失败删 tmp；用例：无 `.tmp` 残留 + 重复保存 |
| **W-B** | 邻接规模门禁（数据爆炸 B：>30 警告/>80 阻止） | ✅ 已交付 | `EditorDoc.validate()` 1b 段（一处加、问题面板/试玩/打包三处生效）；用例：35 警告、80 边界只警告、120 阻止、默认不误报 |
| **W1** | 撤销改 diff + 深度 ≥200（清单·一 + 数据爆炸 D） | ⏳ 方案就绪 | 见第二节；内存算式：快照 ≈2MB/步（200 步≈400MB）→ diff ≈20B/格（200 步全满≈20MB） |
| **W3** | 问题面板分级 ❌/⚠️/💡 + 点击跳转（清单·六） | ⏳ 方案就绪 | 见第三节 |
| **W4** | 按岛分别判定可解性（清单·六，硬约束） | ⏳ 方案就绪 | 见第三节 |
| W2 | 编辑/试玩"作弊信息"统一状态机（清单·二） | 待勘察 | 显雷/热力图必须由一个状态机控制，禁止各功能自判；现在画布恒显雷 |
| W5 | 快捷键体系（Tab 秒切 / B·E·M·S·1~9 / Ctrl+G / Alt 吸管 / F1；面板切换改 Ctrl+Tab） | 待勘察 | 现有只有 Ctrl+Z/Y/S/C/V；Tab 被秒切占用后必须留 Ctrl+Tab 给键盘用户 |
| W6 | 大棋盘性能：渲染缓存 + 校验降级顺序（清单·十 1/4） | 待勘察 | 5000 格不能逐帧重绘 |
| W7 | 快照配额 + quarantine 过期 + 内容哈希去重（数据爆炸 F） | 待建子系统 | 现在只有单份 autosave（tmp→rename），**没有快照目录** |
| W8 | 形状子系统（形状库→布尔→文字/手绘→DAG→栅格化预算/精度→腐蚀膨胀→自定义格形→复合格） | 待建子系统 | 仓库只有 9 族固定几何（`core/shape_generator.gd`），无 union/xor/DAG/复合格/顶点预算 |
| W9 | 变体×网格兼容矩阵 + 勾选即时禁用（清单·五，硬约束） | 待勘察 | `core/variant_registry.gd` 已有 forbid/warn 基础 |
| W10 | 回放 UI 虚拟化 + 日志字节上限 + 猜点热力图（清单·六 + 数据爆炸 H） | 待建 UI | `core/proof_log.gd` 有数据与轮数上限，无回放 UI |

**尚未有任何挂点、必须先建子系统的清单项**（不要硬塞空壳）：形状 DAG / 布尔运算 / 文字转形状 / 手绘轮廓 / 参数化填充 / 栅格精度 / 腐蚀膨胀 / Voronoi / 复合格 / 历史快照 / 推理链回放 UI / 猜点热力图 / 多岛屿底板。

## 二、W1 撤销改 diff（照此实施）

**结论：落点在 `EditorDoc`，不在画布。** `snapshot()` 调用点只有 4 处（`ui/level_editor.gd:1238,1248,1260,2501`），`restore()` 在 `1250,1262`。

1. 真源字段（`core/editor_doc.gd:27-81`）：`title/rows/cols`、结构 `wrap/dirs/include_self`、盘面 `mines/obstacles/revealed`、规则 `rule_spec/clue_rule_id/global_rule_ids`、`declared_total_mines`、预留 `warp_points/regions`、`foreign_topology`、`shape_kind/shape_params`、无损 `passthrough/_revealed_extras/_revealed_merge`。
2. **派生可重算、绝不进 diff**：`topology()` 217-252、`grid()` 257-271、`preview_clues/cells` 347-405、`cell_count/density` 126-145、`validate()` 437 —— 由 `struct_signature()` 195-214 签名驱动缓存。
3. 建议粒度：按"格 × 字段"记 before/after；一步用 `PackedInt32Array` 存 `[x,y,field,before,after]`（≈20B/格）+ 少量标量（rows/cols/wrap/dirs/shape_kind/rule_spec 的 before/after）。**不动 `to_level_json/load_from`**（`level` 仍是唯一序列化口径）。
4. 在 `EditorDoc` 加 `begin_step()/record_cell()/commit_step()`；**改动源必须全覆盖**：`ui/editor_canvas.gd:287-305`（三集合逐格改）、`level_editor.gd:1079-1090`（`_drop_off_board` 批量删）、`1016/1044/1057`（尺寸/环绕/邻域/形状）。
5. 保留 `level_editor.gd:1230-1235` 的 700ms 合并窗与 `editor_canvas.gd:191,196,262` 的手势撤销点，但合并语义从"跳过 snapshot"改成"**继续写同一条 pending record**"；油漆桶/矩形/粘贴/清空/随机布雷仍走 `_push_undo(false)`（1015/1043/1056/1294/1327/1349/1767/1778）⇒ 一次填充天然 1 条 record。
6. **深度 50→200 只动 `level_editor.gd:29`**（另两处 50 是游戏侧涂鸦/走子历史，互不共享）。
7. 已知隐患（顺手修）：`snapshot()`（791-805）不含 `shape_kind/shape_params`，而 `load_from:864-867` 会清零二者 ⇒ 现在"换形状后撤销"会退回方阵；diff 必须带上这两个标量。
8. 测试影响：`test_editor_doc.gd:523-556` 断言的是 `snapshot/restore` **本身**（把它们留作降级路径即不用改）；`test_level_editor_smoke.gd:191-212`（真实鼠标事件撤销）语义不变、必绿；**全仓没有任何用例断言栈长或 `UNDO_LIMIT`**，所以提 200 无红。
9. 切片顺序（每步配一条无头断言）：
   - **S1** 单格 diff + "撤销回到改动前"（沿用 `smoke:191-212` 的事件路径）；
   - **S2** 提到 200 + 断言"连点 250 次后 `_undo.size()==200`"；
   - **S3** 填充/粘贴/清空合并为 1 条 record（断言 `_undo.size()` 只 +1 且 record 格数 = 矩形面积）；
   - **S4** 结构标量 + 大批量降级回 `snapshot()`（断言"换形状 → 撤销仍返回原 `shape_kind`"）。
   - 守卫：每步 record 字节 < 1KB（防悄悄退回快照）。

## 三、W3 问题面板分级 + W4 按岛判定（照此实施）

### W3
1. `validate()` 现在只有 `errors/warnings` 两桶（`core/editor_doc.gd:438-439,620`，`_issue` 在 635，`pos=(-1,-1)` 表示与格无关）。**💡 info 桶要新加**：把 `498 density_high`、`608/612/616/618` 这类"非阻塞纯提醒"降为 info；`ok = errors.is_empty()` 语义不动；`highlight_cells`（627）同时收 infos。
2. 可点列表：`ui/level_editor.gd:1442-1460` 的 `_plain_label` 换成 `flat` 的 `Button`（保留字体/颜色 override，`_plain_label` 在 `:882`），`pressed` → 新增 `EditorCanvas.focus_cell(pos)`。
   - 画布现成：`highlight` 字段 `ui/editor_canvas.gd:43`、`set_highlight()` 77、绘制 332；**缺"跳到格"**：按 `cell_rect()`（105）反算 `pan` 使该格居中并抬 `zoom`（画布直接挂 `body`，无外层 ScrollContainer，改 `pan` 即可）。
3. 保留 12 条截断，但头行改"❌3 ⚠️5 💡2"计数 + 折叠展开（别一屏刷几百行）。
4. 测试：`test_level_editor_smoke.gd:57` 只断言 `_issues_box` 非空（**保留变量名即可**）；`:112-116` 只查验证面板；**没有任何用例断言那 12 条文本**，UI 改动不引发红。

### W4（硬约束：多岛必须按岛分别判定）
1. 切岛：用 `doc.grid()`（`editor_doc.gd:257-269`）的 `get_neighbors` 做 BFS —— **邻接就是文档自己的 dirs/wrap，不要另加 D8**；可搬的 BFS 在 `tools/board_validate.gd:253-273`（含按大小降序）。`AdjacencyGrid` 本身没有 components 函数。
2. 每岛建模：该岛格子 + 岛内边组成新 `AdjacencyGrid`（`adjacency_grid.gd:27`，必要时 `normalized()` 88-123）；`total_mines` 用**该岛**雷数（现在 `editor_verify.gd:108` 用整盘）；`RuleOracle.new(rule, globals, 包围盒, 岛雷数, 岛topo)`（`rule_oracle.gd:69`）。
3. 预算：总 8s **不许翻倍** —— 逐岛传"剩余额度"（单岛保底 500ms），岛按格数降序，小岛先出结论（现在 `editor_verify.gd:36,111,113`）。
4. 合成：全 `no_guess` → `no_guess`；任一 `contradiction` → `contradiction`（列岛号）；其余 → `needs_guess`，reason 列"2 号岛需要盲猜 N 次"；`stats` 增 `islands:[{id,cells,mines,state,rounds,left,guesses}]`。
5. 测试影响：`test_editor_verify.gd` 全在单连通盘（`:42,58,75,89,97,106,119,135`），结论态不变；但 `:51-53,70` 断言 `stats["solutions"]/forced_*` ⇒ 要么保留为"跨岛和"，要么加岛维度；`:142-143` 要求 `backend/label` 仍在顶层。UI（`level_editor.gd:2333-2348`、`test_editor_ux.gd:370`）只消费 state/label/reason/stats，兼容。
6. 最小切片：`editor_verify.gd` 加 `verify_islands(doc, opts)`（返回结构同 `verify()` + `islands`），**先不动 UI**；新增用例：用障碍列造两块互不连通的盘 ⇒ 断言"整体 needs_guess 且 islands 恰好 1 个 no_guess + 1 个 needs_guess"。

## 四、清单里"未被任何包覆盖"的注意事项（避免遗漏）

- **重栅格化的映射**（形状非破坏编辑、面积重叠映射、映射不到的手工格**不自动删**）：依赖 W8；
- **边缘平滑（腐蚀/膨胀）的硬约束**：执行前后校验"连通区域数量不变"，变了就拒绝并高亮 —— 依赖 W8，但**校验器可以先行**（W4 的连通分量正好复用）；
- **复合格三坑**（禁止嵌套、密度稀释警告、邻接 >30/>80）：W8 内，邻接阈值已由 W-B 提供；
- **Voronoi 邻接阈值（共边 < 平均边长 2% 不算邻居）+ 种子量化**：W8 内；
- **形状依赖 DAG + 环检测**：W8 内，且必须第一天就用图存（清单原文警告：用列表存后期"删除中间形状"会整条链悬空）；
- **变体规则配置的即时禁用**：W9；
- **异步栅格化的崩溃恢复**（不许"一半新一半旧"落盘）：W7+W8 交界，规则是"要么完成要么回滚"；
- **危险操作差异预览**（合并复合格/布尔/大范围填充）：W8；
- **两层格式（结果层 vs 设计层）+ 文件锁 + 版本迁移 + 外部资产安全检查**：`EditorDoc` 已有"结果层 JSON + 设计层 spec 随包"雏形（`core/editor_doc.gd:10-18,654-660`），缺**文件锁**与**版本迁移**；本条应独立成包 **W11**（尚未勘察）。
