using System;
using System.Collections.Generic;
using Godot;
using Google.OrTools.Sat;

namespace MinesweeperSolver
{
    /// <summary>
    /// 自举式规则平台的 C# CP-SAT 后端。
    /// 把 GDScript RuleBuilder 产出的可组合约束 IR（纯 Dictionary/Array，见 core/cp_ir.gd）
    /// 翻译成 OR-Tools CP-SAT 模型，做唯一解计数。
    ///
    /// spec 格式（RuleOracle.build_spec 组装）：
    ///   rows/cols: int          棋盘尺寸
    ///   total_mines: int        总雷数（-1 = 不约束）
    ///   safe_cells: [[r,c]..]   已知安全格（已翻开线索格）
    ///   mine_cells: [[r,c]..]   已知雷格
    ///   clues: [{r,c,ir:[约束IR..]}..]  各激活线索的约束
    ///   globals: [约束IR..]     全局规则约束
    ///   aux: [{i,kind:"bool"} | {i,kind:"int",lo,hi}..]
    ///   timeout_ms: int         求解超时
    ///
    /// 返回：0=无解, 1=唯一解, 2=多解（≥2 截断）。
    /// </summary>
    public partial class RuleSolver : RefCounted
    {
        private CpModel _model;
        private BoolVar[,] _cellVars;
        private int _cols;
        private int _rows; // 越界守卫用（与 RuleBuilder.cell_var「越界 → const 0」同语义）
        private BoolVar _constTrue; // 恒真 literal（固定格替换用）
        // 模型瘦身：safe/mine 格不建 BoolVar，用常量替换（key=r*_cols+c -> 0/1）。
        private readonly Dictionary<int, long> _fixedCells = new Dictionary<int, long>();
        private readonly Dictionary<int, IntVar> _auxIntVars = new Dictionary<int, IntVar>();
        private readonly Dictionary<int, BoolVar> _auxBoolVars = new Dictionary<int, BoolVar>();
        private readonly List<BoolVar> _freeVars = new List<BoolVar>();
        private readonly List<(int r, int c)> _freeCells = new List<(int r, int c)>();
        private readonly List<BoolVar> _clueGates = new List<BoolVar>();
        private int _remainingMines; // 自由格中还需布雷数（总雷数约束）
        // 被约束引用的格（线索 + 全局约束涉及的 cell）——候选格剪枝：只探测这些格，
        // 未被任何约束引用的格只受总雷数约束（free==remaining 时全必雷，否则全自由）。
        private readonly HashSet<int> _referencedCells = new HashSet<int>();

        /// <summary>
        /// 唯一解计数主入口（GDScript 经 load("res://solver/RuleSolver.cs").new() 调用）。
        /// </summary>
        public int CountSolutions(Godot.Collections.Dictionary spec)
        {
            try
            {
                BuildModel(spec);
            }
            catch (Exception e)
            {
                GD.PushError($"RuleSolver.BuildModel 失败: {e.Message}");
                return 0;
            }

            var solver = MakeSolver(spec);
            var status1 = solver.Solve(_model);
            if (status1 != CpSolverStatus.Optimal && status1 != CpSolverStatus.Feasible)
                return 0; // 无解

            // 记录第一解
            var firstSolution = new List<long>();
            foreach (var v in _freeVars)
                firstSolution.Add(solver.Value(v));

            // 第二解：重建模型 + 附加「排除第一解」约束。
            // 注意：不能在已求解过的 CpModel 上追加约束再复用 CpSolver——
            // 该模型协议已构建，新增约束不会进入第二次求解（表现为永远「多解」）。
            // 故重新 BuildModel，在创建后、求解前就加入排除条件。
            BuildModel(spec);
            var excludeLits = new List<ILiteral>();
            for (int i = 0; i < _freeVars.Count && i < firstSolution.Count; i++)
            {
                var v = _freeVars[i];
                excludeLits.Add(firstSolution[i] == 1 ? v.Not() : (ILiteral)v);
            }
            if (excludeLits.Count > 0)
                _model.AddBoolOr(excludeLits);
            var solver2 = MakeSolver(spec);
            var status2 = solver2.Solve(_model);
            return (status2 == CpSolverStatus.Optimal || status2 == CpSolverStatus.Feasible) ? 2 : 1;
        }

        /// <summary>
        /// 序贯演绎（forced-cell 检测）：返回当前模型下「状态被强制」的格——
        /// 在所有相容解中必为雷 / 必为安全的格。
        /// 用 CP-SAT assumption 对每个自由格做可满足性探测：
        ///   假设该格为安全不可行 → 必雷；假设为雷不可行 → 必安全。
        /// 返回 { "safe": [[r,c]..], "mine": [[r,c]..] }（两者皆空 = 无强制格，即需猜测）。
        /// 这是替代「全盘枚举」的关键：序贯求解每次只做 O(自由格数) 次假设探测，
        /// 而非枚举 C(n,k) 个相容解。
        /// </summary>
        public Godot.Collections.Dictionary FindForcedCells(Godot.Collections.Dictionary spec)
        {
            var result = new Godot.Collections.Dictionary();
            var safe = new Godot.Collections.Array();
            var mine = new Godot.Collections.Array();
            result["safe"] = safe;
            result["mine"] = mine;
            try
            {
                BuildModel(spec);
            }
            catch (Exception e)
            {
                GD.PushError($"RuleSolver.FindForcedCells: {e.Message}");
                return result;
            }

            // 复用单一 CpSolver 实例：每个自由格要做 assumption 探测，
            // 原先每次探测都 new 一个 solver（O(n) 次构造 + 参数字符串解析），
            // 这是序贯演绎在大盘上的主要开销。CpSolver 可安全地对同一 model 反复 Solve。
            var solver = MakeSolver(spec);
            var status = solver.Solve(_model);
            if (status != CpSolverStatus.Optimal && status != CpSolverStatus.Feasible)
                return result; // 无解

            // P0-性能优化：先解出「第一解」，利用其已知信息把每格 2 次探测降到 1 次。
            // 第一解里 v 是雷 → v==1 已可行，只需探测 v==0（安全）是否可行：不可行 → 必雷。
            // 第一解里 v 是安全 → 对称，只需探测 v==1（雷）。每格正好 1 次 Solve。
            // 总雷数约束强制：自由格数 == 剩余雷数 → 所有自由格必雷（纯约束推理，零探测）。
            if (_remainingMines >= 0 && _freeVars.Count == _remainingMines)
            {
                foreach (var (r, c) in _freeCells)
                    mine.Add(MakeCell(r, c));
                return result;
            }

            // P0-性能优化：先解出「第一解」，利用其已知信息把每格 2 次探测降到 1 次。
            // 第一解里 v 是雷 → v==1 已可行，只需探测 v==0（安全）是否可行：不可行 → 必雷。
            // 第一解里 v 是安全 → 对称，只需探测 v==1（雷）。每格正好 1 次 Solve。
            var firstSol = new long[_freeVars.Count];
            for (int i = 0; i < _freeVars.Count; i++)
                firstSol[i] = solver.Value(_freeVars[i]);

            for (int i = 0; i < _freeVars.Count; i++)
            {
                var v = _freeVars[i];
                var (r, c) = _freeCells[i];
                // 注意：这里**不能**剪掉「未被任何线索引用的格」。
                // 早前有个剪枝假设这类格只受总雷数约束、free>remaining 时必不强制——
                // 那是错的：当其余格已被线索逼成雷、总雷数恰好被填满时，这格会被
                // 「消元 + 总雷数」间接逼定为安全（classic_07 实测：模型数=1 却推不出，
                // 正是被这层剪枝吃掉了最后一个必安全格）。
                // assumption 探测本身对未引用格同样健全（firstSol 取唯一解的值，反值不可行即强制），
                // 故一律探测，牺牲一点无关格的探测成本换取完备性。
                if (firstSol[i] == 1)
                {
                    // 第一解 v 是雷：v==0 不可行 → v 必雷
                    _model.AddAssumptions(new ILiteral[] { v.Not() });
                    var st = solver.Solve(_model);
                    _model.ClearAssumptions();
                    // 只认 Infeasible（明确不可行）——Unknown（超时）绝不当「不可行」：
                    // 把不确定当确定会误报强制格 → 错误推理链/错误提示（R02「提示永不害死玩家」）。
                    if (st == CpSolverStatus.Infeasible)
                        mine.Add(MakeCell(r, c));
                }
                else
                {
                    // 第一解 v 是安全：v==1 不可行 → v 必安全
                    _model.AddAssumptions(new ILiteral[] { v });
                    var st = solver.Solve(_model);
                    _model.ClearAssumptions();
                    if (st == CpSolverStatus.Infeasible)
                        safe.Add(MakeCell(r, c));
                }
            }
            return result;
        }

        /// <summary>
        /// 采样一个满足全部约束（线索 + 全局规则 + 总雷数）的雷布局（第一可行解）。
        /// 多 G 组合的构造式布雷用——旧的「只取第一个 G 的 place_mines」会丢失状态性 G
        ///（dt 骨牌划分）或接受率极低，改由 CP-SAT 直接求满足全部 G 的布局。
        /// 返回 [[r,c]..]；无解（UNSAT/超时）返回空数组。
        /// </summary>
        public Godot.Collections.Array FindSolution(Godot.Collections.Dictionary spec)
        {
            try
            {
                BuildModel(spec);
            }
            catch (Exception e)
            {
                GD.PushError($"RuleSolver.FindSolution: {e.Message}");
                return new Godot.Collections.Array();
            }
            var solver = MakeSolver(spec);
            // 可复现性：FindSolution 的解必须确定（同 spec 同解），否则「落盘 seed 重放」会得到
            // 不同盘（probe40 实测 pf_classic/9x9 seed=4 重放不一致）。两个非确定源都要钉死：
            //   ① 多 worker 并行 → 线程调度决定先找到哪个可行解 → 强制单 worker；
            //   ② CP-SAT 内部随机 → 显式 random_seed（由生成器确定性 RNG 派生，spec 传入）。
            // 可行性/强制格探测（IsFeasible/ForcedCells）不受影响——布尔结论是数学事实。
            int seed = spec.ContainsKey("random_seed") ? spec["random_seed"].AsInt32() : 0;
            int timeoutMs = spec.ContainsKey("timeout_ms") ? spec["timeout_ms"].AsInt32() : 8000;
            solver.StringParameters =
                $"max_time_in_seconds:{timeoutMs / 1000.0} num_search_workers:1 random_seed:{seed}";
            var status = solver.Solve(_model);
            if (status != CpSolverStatus.Optimal && status != CpSolverStatus.Feasible)
                return new Godot.Collections.Array(); // 无解（UNSAT 或超时）
            var mines = new Godot.Collections.Array();
            // 固定雷格（spec 的 mine_cells）
            foreach (var kv in _fixedCells)
                if (kv.Value == 1)
                    mines.Add(MakeCell(kv.Key / _cols, kv.Key % _cols));
            // 自由格中第一解为雷的
            for (int i = 0; i < _freeVars.Count; i++)
            {
                if (solver.Value(_freeVars[i]) == 1)
                {
                    var (r, c) = _freeCells[i];
                    mines.Add(MakeCell(r, c));
                }
            }
            return mines;
        }

        /// <summary>
        /// 单格强制探测（P0-难度量化）：判断 (r,c) 是否被当前 spec 的全部约束「强制」——
        /// 在所有相容解中该格必为雷、或必为安全。
        /// 比 FindForcedCells 便宜：只做 2 次 assumption 探测，不遍历全部自由格。
        /// 用于「必要线索数」贪心移除——每移除一条线索就测一次 target 格是否仍被强制。
        /// </summary>
        public bool IsForcedCell(Godot.Collections.Dictionary spec, int r, int c)
        {
            try
            {
                BuildModel(spec);
            }
            catch (Exception e)
            {
                GD.PushError($"RuleSolver.IsForcedCell: {e.Message}");
                return false;
            }

            int rows = spec["rows"].AsInt32();
            int cols = spec["cols"].AsInt32();
            if (r < 0 || r >= rows || c < 0 || c >= cols)
                return false; // 越界坐标：防御（此前 _cellVars[r,c] 越界会抛异常穿过 try 边界）
            var v = _cellVars[r, c];
            if (v == null)
                return true; // 目标格是固定格（safe/mine），已确定 → 必然强制
            var solver = MakeSolver(spec);
            // 先检查模型有解：无解的 spec 谈不上「强制」——
            // 否则假设 safe 不可行（实为整体无解）会被误判为「必雷」。
            var status = solver.Solve(_model);
            if (status != CpSolverStatus.Optimal && status != CpSolverStatus.Feasible)
                return false;
            // 假设 v 安全（v==0）不可行 → v 必雷。只认 Infeasible：
            // Unknown（超时）不当「不可行」，避免把不确定误报为强制（与 FindForcedCells 同口径）。
            _model.AddAssumptions(new ILiteral[] { v.Not() });
            var stSafe = solver.Solve(_model);
            _model.ClearAssumptions();
            if (stSafe == CpSolverStatus.Infeasible)
                return true;
            // 假设 v 雷（v==1）不可行 → v 必安全
            _model.AddAssumptions(new ILiteral[] { v });
            var stMine = solver.Solve(_model);
            _model.ClearAssumptions();
            return stMine == CpSolverStatus.Infeasible;
        }

        /// <summary>
        /// 快速可行性判断：是否存在满足全部约束 + 总雷数的雷分布（只求第一个解，不做第二解排除）。
        /// 用于生成前预筛——对规则冗余/矛盾导致的 UNSAT 组合，立即拒绝，避免进入「换 seed 重试」的暴力生成。
        /// 与 CountSolutions 的区别：CountSolutions 会追加「排除第一解」再解一次以判唯一，
        /// 本方法只求「至少一个解」，成本约是 CountSolutions 的一半。
        /// </summary>
        public bool IsFeasible(Godot.Collections.Dictionary spec)
        {
            try
            {
                BuildModel(spec);
            }
            catch (Exception e)
            {
                GD.PushError($"RuleSolver.IsFeasible: {e.Message}");
                return false;
            }
            var solver = MakeSolver(spec);
            var status = solver.Solve(_model);
            return status == CpSolverStatus.Optimal || status == CpSolverStatus.Feasible;
        }

        /// <summary>
        /// 必要线索数（unsat_core 方案）：返回使格 (r,c) 被强制（必雷/必安全）所需的最少线索数。
        /// 对齐对标游戏的「最少线索数」复杂度：每条线索用 use_i 门控，assumptions 全激活，
        /// 假设格取某值不可满足 → unsat_core = 导致矛盾的线索门控子集（近似极小不可满足子集 MUS）。
        /// 返回 -1 表示格不被强制（两个取值都可行）。
        /// 注：unsat_core 不保证全局最小（OR-Tools 启发式），但通常显著优于移除顺序敏感的贪心；
        /// 且本方法用单 worker 求解，保证 core 的确定性。
        /// </summary>
        public int MinimalForcedClueCount(Godot.Collections.Dictionary spec, int r, int c)
        {
            int k0 = _ClueCoreSize(spec, r, c, 0);
            int k1 = _ClueCoreSize(spec, r, c, 1);
            if (k0 >= 0 && k1 < 0) return k0; // 必雷（cell==0 不可满足），必要线索 = core 大小
            if (k1 >= 0 && k0 < 0) return k1; // 必安全（cell==1 不可满足）
            return -1; // 不被强制（两方向都可满足）
        }

        /// <summary>
        /// 计算「使 cell==wantValue 不可满足」的线索门控子集大小（unsat_core + 迭代收缩）。
        /// 返回 -1 表示 cell==wantValue 可满足（该方向不被强制）。
        /// 迭代核心收缩（iterative core shrinking）：单次 unsat_core 不保证最小（MUS 是 Σ2 问题），
        /// 故把 core 作为下一轮的唯一激活集反复求 core，直到收敛——工程上逼近最小 MUS 的标准技术。
        /// 上限 4 轮（实测通常 2 轮内收敛），每轮一次 Solve。
        /// </summary>
        private int _ClueCoreSize(Godot.Collections.Dictionary spec, int r, int c, int wantValue)
        {
            try
            {
                BuildModel(spec, gateClues: true);
            }
            catch (Exception e)
            {
                GD.PushError($"RuleSolver.MinimalForcedClueCount: {e.Message}");
                return -1;
            }

            // 硬约束：格取 wantValue（要证明矛盾的前提，不是可移除的 assumption）
            var targetVar = _cellVars[r, c];
            if (targetVar == null)
            {
                // 目标格固定（safe/mine）：固定值==wantValue → 恒可满足（-1）；否则恒矛盾（0 条线索就推出）
                if (_fixedCells.TryGetValue(r * _cols + c, out long fixedVal))
                    return fixedVal == wantValue ? -1 : 0;
                return -1;
            }
            _model.Add(targetVar == wantValue);

            var solver = MakeSolver(spec);
            // unsat_core 需单 worker（多 worker 会并行找 core，结果不确定）
            solver.StringParameters = "num_search_workers:1";

            // 初始：全部线索激活
            var active = new HashSet<int>();
            for (int i = 0; i < _clueGates.Count; i++)
                active.Add(i);

            int lastSize = _clueGates.Count;
            for (int iter = 0; iter < 4; iter++)
            {
                var assumptions = new List<ILiteral>();
                for (int i = 0; i < _clueGates.Count; i++)
                {
                    // 激活集内的线索施加约束；集外的关闭（use_i = false）——关闭是放松，
                    // 不会出现在不可满足核心里，core 只会含激活门控。
                    assumptions.Add(active.Contains(i) ? (ILiteral)_clueGates[i] : _clueGates[i].Not());
                }
                _model.AddAssumptions(assumptions);
                var status = solver.Solve(_model);
                _model.ClearAssumptions();

                if (status == CpSolverStatus.Optimal || status == CpSolverStatus.Feasible)
                {
                    // 当前激活集不足以推出矛盾：cell==wantValue 可满足。
                    // 第一轮就有解 → 该方向不被强制（-1）；后续轮有解 → 上一轮 core 是最终答案。
                    return iter == 0 ? -1 : lastSize;
                }
                if (status == CpSolverStatus.Unknown)
                {
                    // 超时：无法判定矛盾（SufficientAssumptionsForInfeasibility 在未证明
                    // 不可行时不可用）→ 按「未被强制」返回（-1），绝不误报 core 大小
                    //（曾会把超时当不可行、core 空 → 误报「0 条线索推出」= 难度画像畸高）。
                    return -1;
                }

                var core = solver.SufficientAssumptionsForInfeasibility();
                var next = new HashSet<int>();
                foreach (var idx in core)
                    next.Add(idx);

                if (next.Count == 0 || (next.Count == lastSize && next.SetEquals(active)))
                    return next.Count; // 收敛（空 core 或不再缩小）

                active = next;
                lastSize = next.Count;
            }
            return lastSize;
        }

        private static Godot.Collections.Array MakeCell(int r, int c)
        {
            var cell = new Godot.Collections.Array { r, c };
            return cell;
        }

        // ==================== 模型构建 ====================

        private void BuildModel(Godot.Collections.Dictionary spec, bool gateClues = false)
        {
            int rows = spec["rows"].AsInt32();
            int cols = spec["cols"].AsInt32();
            int totalMines = spec["total_mines"].AsInt32();

            _model = new CpModel();
            _cols = cols;
            _rows = rows;
            _constTrue = _model.NewBoolVar("_const_true");
            _model.Add(_constTrue == 1);
            _auxIntVars.Clear();
            _auxBoolVars.Clear();
            _freeVars.Clear();
            _freeCells.Clear();
            _clueGates.Clear();
            _fixedCells.Clear();
            _referencedCells.Clear();

            // 安全格 / 已知雷（模型瘦身：不建变量，用常量 0/1 替换）
            var safeSet = new HashSet<int>();
            foreach (var sc in spec["safe_cells"].AsGodotArray())
            {
                var a = sc.AsGodotArray();
                int r = a[0].AsInt32(), c = a[1].AsInt32();
                safeSet.Add(r * cols + c);
                _fixedCells[r * cols + c] = 0;
            }
            var mineSet = new HashSet<int>();
            foreach (var mc in spec["mine_cells"].AsGodotArray())
            {
                var a = mc.AsGodotArray();
                int r = a[0].AsInt32(), c = a[1].AsInt32();
                mineSet.Add(r * cols + c);
                _fixedCells[r * cols + c] = 1;
            }

            // 只为自由格建布尔变量（safe/mine 格不占变量，模型显著缩小，Solve 更快）
            _cellVars = new BoolVar[rows, cols];
            for (int r = 0; r < rows; r++)
                for (int c = 0; c < cols; c++)
                    if (!safeSet.Contains(r * cols + c) && !mineSet.Contains(r * cols + c))
                    {
                        _cellVars[r, c] = _model.NewBoolVar($"cell_{r}_{c}");
                        _freeVars.Add(_cellVars[r, c]);
                        _freeCells.Add((r, c));
                    }

            // 总雷数约束
            _remainingMines = totalMines >= 0 ? totalMines - mineSet.Count : -1;
            if (totalMines >= 0 && _freeVars.Count > 0)
            {
                if (_remainingMines < 0 || _remainingMines > _freeVars.Count)
                    throw new InvalidOperationException($"总雷数约束矛盾: remaining={_remainingMines}");
                _model.Add(LinearExpr.Sum(_freeVars) == _remainingMines);
            }

            // aux 变量
            if (spec.ContainsKey("aux"))
            {
                foreach (var av in spec["aux"].AsGodotArray())
                {
                    var d = av.AsGodotDictionary();
                    int i = d["i"].AsInt32();
                    string kind = d["kind"].AsString();
                    if (kind == "int")
                        _auxIntVars[i] = _model.NewIntVar(d["lo"].AsInt64(), d["hi"].AsInt64(), $"aux_{i}");
                    else
                        _auxBoolVars[i] = _model.NewBoolVar($"aux_{i}");
                }
            }

            // 各线索约束
            if (spec.ContainsKey("clues"))
            {
                foreach (var cl in spec["clues"].AsGodotArray())
                {
                    var cd = cl.AsGodotDictionary();
                    ILiteral[] enforce = null;
                    if (gateClues)
                    {
                        // 每条线索一个门控变量：use_i 为真才施加该线索的全部约束。
                        // 用于 unsat_core 求「必要线索数」（对标游戏的精确最小集方案）。
                        var gate = _model.NewBoolVar($"use_{_clueGates.Count}");
                        _clueGates.Add(gate);
                        enforce = new ILiteral[] { gate };
                    }
                    foreach (var node in cd["ir"].AsGodotArray())
                        AddConstraint(node.AsGodotDictionary(), enforce);
                }
            }

            // 全局约束
            if (spec.ContainsKey("globals"))
            {
                foreach (var node in spec["globals"].AsGodotArray())
                    AddConstraint(node.AsGodotDictionary(), null);
            }
        }

        // ==================== IR 翻译 ====================

        private LinearExpr ToExpr(Godot.Collections.Dictionary e)
        {
            switch (e["t"].AsString())
            {
                case "const":
                    return LinearExpr.Constant(e["v"].AsInt64());
                case "cell":
                    {
                        int cr = e["r"].AsInt32(), cc = e["c"].AsInt32();
                        if (cr < 0 || cr >= _rows || cc < 0 || cc >= _cols)
                            return LinearExpr.Constant(0); // 越界 = const 0（与 RuleBuilder.cell_var 同语义；Mod IR 健壮性）
                        if (_fixedCells.TryGetValue(cr * _cols + cc, out long fv))
                            return LinearExpr.Constant(fv);
                        _referencedCells.Add(cr * _cols + cc);
                        return _cellVars[cr, cc];
                    }
                case "aux":
                    if (_auxIntVars.TryGetValue(e["i"].AsInt32(), out var iv))
                        return iv;
                    return _auxBoolVars[e["i"].AsInt32()];
                case "sum":
                    {
                        LinearExpr acc = LinearExpr.Constant(0);
                        foreach (var x in e["xs"].AsGodotArray())
                            acc = acc + ToExpr(x.AsGodotDictionary());
                        return acc;
                    }
                case "wsum":
                    {
                        var ws = e["ws"].AsGodotArray();
                        var xs = e["xs"].AsGodotArray();
                        LinearExpr acc = LinearExpr.Constant(0);
                        for (int i = 0; i < xs.Count; i++)
                        {
                            var x = xs[i].AsGodotDictionary();
                            long w = ws[i].AsInt64();
                            if (x["t"].AsString() == "const")
                                acc = acc + LinearExpr.Constant(w * x["v"].AsInt64());
                            else
                                acc = acc + LinearExpr.Affine(ToVar(x), w, 0);
                        }
                        return acc;
                    }
                case "lin":
                    {
                        var ws = e["ws"].AsGodotArray();
                        var xs = e["xs"].AsGodotArray();
                        LinearExpr acc = LinearExpr.Constant(e["c"].AsInt64());
                        for (int i = 0; i < xs.Count; i++)
                        {
                            var x = xs[i].AsGodotDictionary();
                            long w = ws[i].AsInt64();
                            if (x["t"].AsString() == "const")
                                acc = acc + LinearExpr.Constant(w * x["v"].AsInt64());
                            else
                                acc = acc + LinearExpr.Affine(ToVar(x), w, 0);
                        }
                        return acc;
                    }
            }
            throw new ArgumentException($"未知表达式节点: {e["t"].AsString()}");
        }

        private IntVar ToVar(Godot.Collections.Dictionary v)
        {
            switch (v["t"].AsString())
            {
                case "cell":
                    {
                        int cr = v["r"].AsInt32(), cc = v["c"].AsInt32();
                        if (cr < 0 || cr >= _rows || cc < 0 || cc >= _cols)
                            return _model.NewConstant(0); // 越界 = const 0（同 RuleBuilder.cell_var）
                        if (_fixedCells.TryGetValue(cr * _cols + cc, out long fv))
                            return _model.NewConstant(fv);
                        _referencedCells.Add(cr * _cols + cc);
                        return _cellVars[cr, cc];
                    }
                case "aux":
                    if (_auxIntVars.TryGetValue(v["i"].AsInt32(), out var iv))
                        return iv;
                    return _auxBoolVars[v["i"].AsInt32()];
            }
            throw new ArgumentException($"wsum 项必须是变量引用: {v["t"].AsString()}");
        }

        private ILiteral ToLit(Godot.Collections.Dictionary l)
        {
            switch (l["t"].AsString())
            {
                case "not":
                    return ToLit(l["x"].AsGodotDictionary()).Not();
                case "cell":
                    {
                        int cr = l["r"].AsInt32(), cc = l["c"].AsInt32();
                        if (cr < 0 || cr >= _rows || cc < 0 || cc >= _cols)
                            return _constTrue.Not(); // 越界 = const 0 → false 字面量（同 RuleBuilder.cell_var）
                        if (_fixedCells.TryGetValue(cr * _cols + cc, out long fv))
                            return fv == 1 ? _constTrue : _constTrue.Not();
                        _referencedCells.Add(cr * _cols + cc);
                        return _cellVars[cr, cc];
                    }
                case "aux":
                    if (_auxBoolVars.TryGetValue(l["i"].AsInt32(), out var bv))
                        return bv;
                    throw new InvalidOperationException("int aux 变量不能作布尔字面量");
                case "const":
                    // const 字面量（0=false / 非 0=true）：RuleBuilder.cell_var 越界返回
                    // const 0 并承诺「方便写开窗口规则」——支持它才能让越界格直接入
                    // 或门/蕴含（此前抛「未知字面量节点: const」炸整个 spec，mod 试验抓出）。
                    return l["v"].AsInt64() != 0 ? _constTrue : _constTrue.Not();
            }
            throw new ArgumentException($"未知字面量节点: {l["t"].AsString()}");
        }

        private void AddConstraint(Godot.Collections.Dictionary c, ILiteral[] enforce)
        {
            switch (c["t"].AsString())
            {
                case "eq":
                    Apply(_model.Add(ToExpr(c["a"].AsGodotDictionary()) == ToExpr(c["b"].AsGodotDictionary())), enforce);
                    break;
                case "le":
                    Apply(_model.Add(ToExpr(c["a"].AsGodotDictionary()) <= ToExpr(c["b"].AsGodotDictionary())), enforce);
                    break;
                case "lt":
                    Apply(_model.Add(ToExpr(c["a"].AsGodotDictionary()) < ToExpr(c["b"].AsGodotDictionary())), enforce);
                    break;
                case "bool_or":
                    {
                        var lits = ToLits(c["lits"].AsGodotArray());
                        if (lits.Count > 0)
                            Apply(_model.AddBoolOr(lits), enforce);
                        break;
                    }
                case "bool_and":
                    {
                        var lits = ToLits(c["lits"].AsGodotArray());
                        if (lits.Count > 0)
                            Apply(_model.AddBoolAnd(lits), enforce);
                        break;
                    }
                case "imp":
                    Apply(_model.AddImplication(ToLit(c["a"].AsGodotDictionary()), ToLit(c["b"].AsGodotDictionary())), enforce);
                    break;
                case "iff":
                    {
                        var a = ToLit(c["a"].AsGodotDictionary());
                        var b = ToLit(c["b"].AsGodotDictionary());
                        Apply(_model.AddImplication(a, b), enforce);
            #pragma warning disable S2234 // 故意的双向蕴含：等价约束 = a→b + b→a 两个方向（不是传反了）
                        Apply(_model.AddImplication(b, a), enforce);
            #pragma warning restore S2234
                        break;
                    }
                case "all_diff":
                    {
                        var exprs = ToExprs(c["xs"].AsGodotArray());
                        if (exprs.Count > 1)
                            Apply(_model.AddAllDifferent(exprs), enforce);
                        break;
                    }
                case "enforce":
                    {
                        var lits = ToLits(c["lits"].AsGodotArray());
                        if (lits.Count == 0)
                            break; // 开关列表为空 → 约束恒生效，但缺内层无从施加，忽略
                        var merged = enforce == null
                            ? lits.ToArray()
                            : MergeLits(enforce, lits.ToArray());
                        AddConstraint(c["c"].AsGodotDictionary(), merged);
                        break;
                    }
                default:
                    throw new ArgumentException($"未知约束节点: {c["t"].AsString()}");
            }
        }

        private static void Apply(Constraint ct, ILiteral[] enforce)
        {
            if (enforce != null && enforce.Length > 0)
                ct.OnlyEnforceIf(enforce);
        }

        private List<ILiteral> ToLits(Godot.Collections.Array arr)
        {
            var lits = new List<ILiteral>();
            foreach (var l in arr)
                lits.Add(ToLit(l.AsGodotDictionary()));
            return lits;
        }

        private List<LinearExpr> ToExprs(Godot.Collections.Array arr)
        {
            var exprs = new List<LinearExpr>();
            foreach (var x in arr)
                exprs.Add(ToExpr(x.AsGodotDictionary()));
            return exprs;
        }

        private static ILiteral[] MergeLits(ILiteral[] a, ILiteral[] b)
        {
            var merged = new ILiteral[a.Length + b.Length];
            a.CopyTo(merged, 0);
            b.CopyTo(merged, a.Length);
            return merged;
        }

        private static CpSolver MakeSolver(Godot.Collections.Dictionary spec)
        {
            int timeoutMs = spec.ContainsKey("timeout_ms") ? spec["timeout_ms"].AsInt32() : 8000;
            // num_workers 默认 1（2026-09-24，原 4）。两个理由：
            //   ① 确定性：CP-SAT 多线程搜索非确定 ⇒ 同 seed 两次生成可能得到不同盘面。
            //      实测重跑同一 SPEC 后 clue_count 12→8、关卡从「可推」变「不可推」——
            //      多线程是墙钟之外的另一层波动源，而项目目标是「重跑逐字节复现」。
            //   ② 稳定性：实测 6 个子进程同时挂死（CPU 近 0、无输出、内存停滞），
            //      多线程长尾/线程互等是嫌疑之一，单 worker 下不存在。
            // 性能折衷：批量离线场景可用 spec["num_workers"] 显式调回多线程（接口保留），
            // 但需接受上述两条风险并在调用处写明理由。unsat_core 路径（_ClueCoreSize）仍强制单 worker。
            int workers = spec.ContainsKey("num_workers") ? spec["num_workers"].AsInt32() : 1;
            // max_deterministic_time（OR-Tools 确定性工作量上限，单位≈参考机秒）：
            // 与 max_time_in_seconds 并存、谁先到谁停。它补上墙钟给不了的两件事：
            //   ① 病态实例的「无限枚举」在确定性工作量上有**硬上界**（墙钟下机器快跑得久、
            //      慢机器提前停——这正是重跑波动的根源，实测 6 子进程挂死 CPU 近 0）；
            //   ② 同 seed 同参数 ⇒ 恰好停在同一处 ⇒ 产物逐字节可复现。
            // 默认取墙钟秒数的 2 倍：正常求解先撞墙钟（行为不变），病态枚举被 det 上界兜住。
            // 可用 spec["max_deterministic_time"] 显式覆盖。
            // 注意 double 必须用 InvariantCulture 格式化——区域设置为逗号小数点时
            // StringParameters 会解析失败（顺带修掉 timeoutMs/1000.0 的同款隐患）。
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            double detSeconds = spec.ContainsKey("max_deterministic_time")
                ? System.Convert.ToDouble(spec["max_deterministic_time"], inv)
                : System.Math.Max(4.0, timeoutMs / 1000.0 * 2.0);
            string pars = string.Format(inv,
                "max_time_in_seconds:{0} max_deterministic_time:{1} num_search_workers:{2}",
                timeoutMs / 1000.0, detSeconds, workers);
            return new CpSolver
            {
                StringParameters = pars
            };
        }
    }
}
