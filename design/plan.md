# tingres Plan Architecture & Contract

The `plan` package bridges the untyped parse AST from `parse` and the execution engine in `exec`. It is responsible for semantic analysis, type resolution, plan tree construction, and cost-based query optimization.

## 1. Expression IR (`plan.Expr`)

Expressions are typed physical expression representations where every expression carries its resolved PostgreSQL result type OID (`types.Oid`).

Variants:
- `Const(ConstExpr)`: evaluated literal or constant SQL value.
- `ColRef(ColRefExpr)`: tuple attribute reference by executor row buffer slot index, or range table index and attribute number.
- `Param(ParamExpr)`: numbered parameter ($1..$n).
- `FuncCall(FuncCallExpr)`: invocation of resolved scalar function (`types.Func`).
- `OpCall(OpCallExpr)`: invocation of resolved operator (`types.Func`).
- `BoolExpr(BoolExpr)`: boolean combination (AND, OR, NOT) with SQL 3-valued truth semantics.
- `NullTest(NullTestExpr)`: IS NULL / IS NOT NULL test.
- `Case(CaseExpr)`: CASE WHEN ... THEN ... ELSE ... END conditional evaluation.
- `Coalesce(CoalesceExpr)`: first non-null argument evaluation.
- `Cast(CastExpr)`: explicit or implicit type and typmod coercion.
- `SubLink(SubLinkExpr)`: subquery expression (Scalar, Exists, In, Any, All) with correlated outer references.
- `AggRef(AggRefExpr)`: aggregate function invocation referencing a grouping slot.
- `WindowFuncRef(WindowFuncRefExpr)`: window function invocation referencing a window slot.
- `RowExpr(RowExpr)`: anonymous composite row constructor.
- `ArrayExpr(ArrayExpr)`: SQL array constructor.

## 2. Physical Plan Nodes (`plan.Plan`)

All physical plan nodes provide:
- `Cols() []ColDesc`: output tuple descriptors for PostgreSQL `RowDescription`.
- `Cost() Cost`: startup cost, total cost, estimated rows, and tuple width.
- `Children() []Plan`: child plan nodes for execution pipeline construction.

### Row Layout & Join Semantics
- **Scan nodes** (`SeqScan`, `IndexScan`, `IndexOnlyScan`): tuples are laid out in table attribute order (attno 1..N) or as projected in `Cols`.
- **Join nodes** (`NestLoop`, `HashJoin`, `MergeJoin`): tuples are concatenated left-first: outer columns `[0..N-1]` followed by inner columns `[N..N+M-1]`. In outer joins, unmatched rows have opposing side columns filled with NULL Datums. Semi/anti joins return only outer columns.
- **Filter**: preserves identical row layout, passing through rows that evaluate to TRUE.
- **Project**: creates a new tuple layout corresponding to the evaluated projection expressions.
- **Sort**: preserves row layout while sorting rows by keys; supports top-N bounded sort via `Limit`.
- **Aggregates** (`HashAgg`, `GroupAgg`): grouping keys are placed in leading positions, followed by aggregate values in their respective slots.
- **WindowAgg**: preserves input columns and appends window function results.
- **SetOp / Append**: preserves unified column layout matching `Cols`.
- **Values / Result**: produces tuples whose slots match the evaluated expressions.
- **ModifyTable**: executes INSERT, UPDATE, or DELETE. If `Returning` is specified, produces output rows described by `Cols`.
- **Utility**: wraps DDL and transaction control commands (`CreateTable`, `AlterTable`, `Drop`, `Begin`, `Commit`, etc.) for direct execution.

## 3. Preparation & Execution Protocol

`Prepare(c catalog.Catalog, t txn.Txn, s parse.Stmt, paramTypes []Oid) !Prepared` validates catalog entities, resolves types, generates the physical plan, and stamps the prepared plan with `CatalogVersion`. Cached statements call `Prepared.Valid(c)` to verify freshness before reuse.
