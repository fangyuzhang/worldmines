# PATCH-002（2026-08-25）：验证体系改用 GUT 框架

> 来源：用户开工前决策问答，覆盖正文 §4.4 及验证体系相关条款。

## 裁决

- **测试框架由 gdUnit4 改为 GUT**（版本 9.7.1，兼容 Godot 4.7.x）。
- **变更原因**：项目选用 Godot-MCP-Native 插件，其 `run_project_tests` 工具原生支持 GUT（`framework="gut"`），可实现全自动化测试与验收闭环；gdUnit4 不在其支持范围。
- **验证目标不变**：§4.4 要求验证的六类内容全部保留——
  1. RNG 确定性（同种子同结果）
  2. 已知答案 vs 引擎重算（test_classic_known）
  3. 传播器 ⊆ Oracle（test_oracle_3x3）
  4. 关卡纯逻辑可解 + 唯一解（test_levels_solvable）
  5. 存档往返（test_save_roundtrip）
  6. 穷举（test_exhaustive_4x4，默认关闭，nightly）

## 语法对照

| 维度 | gdUnit4 | GUT |
|---|---|---|
| 测试基类 | `extends GdUnitTestSuite` | `extends GutTest` |
| 断言 | `assert_that(x).is_equal(y)` | `assert_eq(x, y)` |
| 测试方法 | `func test_x()` | `func test_x()`（同名） |

## 交付物调整

- 原 §4.4 "gdUnit 完整运行日志" 改为 "GUT 完整运行日志"。
- 测试目录约定：`res://tests/unit/`（单元测试）、`res://tests/integration/`（集成测试）。
