# ci_quick.ps1 —— 增量门禁：**只跑被这次改动碰到的用例**（日常迭代用，秒级~几十秒）。
#
# 为什么：全量门禁即使分片后仍要 ~100 s（unit 10 片 92 s + ui 快片 13 s），而迭代期往往只动了
# 一两个文件。它的价值在于"改什么就测什么"，**不是**替代全量验收。
#
# ⚠ 纪律（不给自己留侥幸）：
#   · 它**只做日常迭代**；提交前/发版前仍跑 `tools/ci_check.ps1`（完整验收再加 `$env:CI_FULL=1`）；
#   · 变了代码却**映射不到任何用例** ⇒ 直接判红并提示跑全量，**绝不静默通过**；
#   · 只改了文档/资源（无 .gd）⇒ 明说"无相关改动"，退出 0。
#
# 用法： powershell -File tools/ci_quick.ps1            # 按 git 工作区改动自动选测
#        powershell -File tools/ci_quick.ps1 -Base HEAD~1
param(
    [string]$Base = 'HEAD',
    [string]$Godot = $env:GODOT_BIN
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if (-not $Godot) {
    $Godot = (Get-ChildItem 'D:\Godot.NET' -Recurse -Filter '*console.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1).FullName
}

# 1) 这次动了哪些文件（含未跟踪）
$changed = @()
$changed += @(git diff --name-only $Base 2>$null)
$changed += @(git status --porcelain 2>$null | ForEach-Object { ($_ -replace '^...', '').Trim() })
$changed = @($changed | Where-Object { $_ -ne '' } | Sort-Object -Unique)
if ($changed.Count -eq 0) { Write-Host '  没有检测到任何改动'; exit 0 }

$gd = @($changed | Where-Object { $_ -match '\.gd$' })
Write-Host ('  改动文件 {0} 个（其中 .gd {1} 个）' -f $changed.Count, $gd.Count)
if ($gd.Count -eq 0) { Write-Host '  只动了非脚本文件（文档/资源）⇒ 无相关用例可跑'; exit 0 }

# 2) 变更文件 → 受影响的用例（按文件名/基名匹配；命中即收录）
#    `always` = 每次增量都跑的冒烟集：挑的是**实测快**且覆盖共享契约的文件（2 文件 3.4 s）
$always = @('test_editor_doc', 'test_wrap_topology')
$map = @{
    'level_editor'   = @('test_editor_ux', 'test_level_editor_smoke')
    'editor_canvas'  = @('test_level_editor_smoke')
    'editor_help'    = @('test_editor_ux')
    'editor_doc'     = @('test_editor_doc', 'test_editor_verify', 'test_editor_ux')
    'batch_forge'    = @('test_batch_forge', 'test_level_sets')
    'workshop_pack'  = @('test_workshop_pack', 'test_mod_import', 'test_example_mod')
    'level_sets'     = @('test_level_sets', 'test_batch_forge')
    'level_select'   = @('test_level_select_interaction', 'test_ui_mounts')
    'mod_api'        = @('test_mod_api', 'test_mod_import', 'test_example_mod')
    'mod_select'     = @('test_level_select_interaction')
    'theme_manager'  = @('test_ui_mounts')
    'progress_store' = @('test_progress_store')
    'save_coordinator' = @('test_save_coordinator')
    'board_view'     = @('test_single_cell_pop', 'test_wave_stagger', 'test_progress_check')
    'puzzle_generator' = @('test_generator_multifaceted', 'test_solver_budget')
    'rule_registry'  = @('test_rule_platform', 'test_spec_schema')
    # 【2026-10-03 补】新增 core 模块长期没进映射表 ⇒ 改了它们却"映射不到用例"，
    # 增量门禁会漏测（是我自己的债，一次性补全）。
    'hotmap'         = @('test_hotmap')
    'replay_model'   = @('test_replay_model')
    'repair_suggest' = @('test_repair_suggest')
    'mega_cell'      = @('test_mega_cell')
    'shape_dag'      = @('test_shape_dag', 'test_shape_dag_mapping')
    'shape_boolean'  = @('test_shape_boolean')
    'level_format'   = @('test_level_format_layers', 'test_level_format_integration')
    'template_library' = @('test_template_library')
    'domino_model'   = @('test_domino_model')
    'share_code'     = @('test_share_code')
    'perf_ledger'    = @('test_perf_ledger')
    'difficulty'     = @('test_difficulty_stars')
    'editor_verify'  = @('test_editor_verify')
    'proof_log'      = @('test_proof_log_limits')
    'editor_bindings' = @('test_editor_shortcuts')
    'editor_view_state' = @('test_editor_shortcuts')
    # 由实测输出补：`shape_generator` 之前也漏（改它会映射不到用例）。
    # ⚠ 不要在此重复已有键（`editor_canvas` 上方已定义）——PowerShell 哈希表重复键会**解析失败**，
    # 把整个增量门禁弄坏（2026-10-03 我当场犯过这个错，立刻撤回）。
    'shape_generator' = @('test_shape_generator_params', 'test_shape_outline_wiring')
    # 由实跑输出补（只补**有据可查**的；`board`/`gen_common`/`gen_shape_levels`/`gen_style_shape_levels`
    # 目前没有确定对应的用例文件 ⇒ **故意不猜**，脚本会照旧提示"映射表里没有它"，提醒跑全量）。
    'variant_grid_matrix' = @('test_variant_grid_matrix')
    'variant_registry' = @('test_variant_catalog')
    'gen_geo_levels'  = @('test_geo_levels')
    # 2026-10-09 补：本轮新增/接线用到的 core 模块（之前不在映射表 ⇒ 改了它们增量门禁会漏测）。
    'glyph_font'     = @('test_glyph_font')
    'coloring_preview' = @('test_coloring_preview')
    'submission_queue' = @('test_submission_queue')
    'shape_reflow'   = @('test_shape_reflow')
    'stats_histogram' = @('test_stats_histogram')
    'editor_disclosure' = @('test_editor_disclosure')
    'text_to_shape'  = @('test_text_to_shape')
    'file_lock'      = @('test_file_lock')
    'level_thumbnail' = @('test_level_thumbnail')
    'stroke_limits'  = @('test_drawing_stroke_limits')
    # 2026-10-09 补：缩略图显示控件（改它会影响编辑器面板的可见控件）。
    'level_thumb_view' = @('test_level_thumbnail', 'test_level_editor_smoke')
    # 2026-10-09 补：试玩期「检查进度」（文档 §7）——判据 + HUD/对局两端的接线。
    'progress_check' = @('test_progress_check')
    # 2026-10-09 补：形状间空隙的「填充」（文档 §3「填充系统」）——判据 + UI 接线。
    'shape_fill'     = @('test_shape_fill')
    'hud'            = @('test_ui_rework_contract', 'test_board_view_interaction', 'test_progress_check')
    'game_session'   = @('test_board_view_interaction', 'test_ui_rework_contract', 'test_progress_check')
}

$want = New-Object System.Collections.Generic.List[string]
foreach ($n in $always) { $want.Add($n) }
$hitRules = @()
foreach ($f in $gd) {
    $bn = [IO.Path]::GetFileNameWithoutExtension($f)
    # 改测试文件本身 ⇒ 直接跑它
    if ($bn -like 'test_*') { $want.Add($bn); $hitRules += ($bn + '（改的就是它）'); continue }
    $matched = $false
    foreach ($k in $map.Keys) {
        if ($bn -eq $k -or $bn -like ($k + '_*') -or (($f -replace '\\', '/') -match ('/' + $k + '\.gd$'))) {
            foreach ($t in $map[$k]) { $want.Add($t) }
            $hitRules += ("$bn → " + ($map[$k] -join ', '))
            $matched = $true
        }
    }
    if (-not $matched) { $hitRules += ("$bn → **映射表里没有它**") }
}
$want = @($want | Sort-Object -Unique)
$hitRules | ForEach-Object { Write-Host ('    ' + $_) }

# 3) 按目录分派（复用已验证的分片器；每个目录一条 `-Only` 正则）
$byDir = @{}
foreach ($t in $want) {
    foreach ($d in @('test/unit', 'test/ui')) {
        if (Test-Path ("$d/$t.gd")) {
            if (-not $byDir.ContainsKey($d)) { $byDir[$d] = New-Object System.Collections.Generic.List[string] }
            $byDir[$d].Add($t)
            break
        }
    }
}
$found = ($byDir.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
if (-not $found -or $found -eq 0) {
    Write-Host '  ❌ 变了脚本却映射不到任何用例 ⇒ 请跑全量门禁 tools\ci_check.ps1'; exit 1
}
if ($hitRules -match '\*\*映射表里没有它\*\*') {
    Write-Host '  ⚠ 有文件不在映射表里（上面已标出）—— 本次结果不完整，提交前请跑全量门禁'
}

$fail = 0
foreach ($d in ($byDir.Keys | Sort-Object)) {
    $re = ($byDir[$d] -join '|')
    Write-Host ("  [{0}] {1} 个用例文件" -f $d, $byDir[$d].Count)
    # ⚠ 日志名必须带 `$PID`：两份**并发**的增量门禁（例如多个子 Agent 同时在跑）会写同一个
    # `tools/_quick_<dir>.log` ⇒ 互相覆盖 ⇒ 表现为"偶发只收到一部分用例"的红。
    # 2026-10-03 两位子 Agent 都撞到过这个假红（分片日志当时已按 PID 隔离，**漏了这一层**）。
    $qlg = "tools/_quick_{0}_{1}.log" -f ($d -replace '[^a-zA-Z0-9]', '_'), $PID
    & powershell -NoProfile -ExecutionPolicy Bypass -File tools/gut_shards.ps1 -Dir ("res://" + $d) `
        -Shards 2 -Only $re -Log $qlg -Godot $Godot
    if ($LASTEXITCODE -ne 0) { $fail++ }
    $lg = $qlg
    if (Test-Path $lg) {
        Get-Content $lg -Encoding UTF8 | Select-String -Pattern '^Tests\s|^Passing Tests|^Failing Tests' |
            ForEach-Object { Write-Host ('    ' + $_.Line.Trim()) }
        Remove-Item -LiteralPath $lg -Force -ErrorAction SilentlyContinue
    }
}
if ($fail -ne 0) { Write-Host '  ❌ 增量门禁未通过'; exit 1 }
Write-Host '  ✅ 增量门禁通过（提交前请跑全量：tools\ci_check.ps1）'
exit 0
