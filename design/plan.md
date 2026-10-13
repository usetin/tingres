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

`Prepare(c catalog.Catalog, t txn.Txn, s parse.Stmt, paramTypes []Oid) !Prepared` validates catalog entities, resolves types, generates the physical plan, and stamps the prepared plan with `CatalogVersion`. Cached statements call `Prepared.Valid(c)` to verify freshness before reuse. `NormalizeStatement(sql)` builds the cache key (literals replaced by `?`, `$n` parameters and quoted identifiers preserved, comments and extra whitespace removed).

## 4. Optimizer

`PlanQuery` runs after `AnalyzeStatement`:

- **Constant folding** (`foldExpr`) evaluates constant sub-expressions through the resolved `types.Func`.
- **Predicate pushdown**: top-level WHERE conjuncts are split (`splitConjunction`) and each single-relation qual is pushed into its scan as a filter; an index prefix of equality/range quals becomes an `Index Cond`.
- **Index selection**: `catalog.Index` carries no key list, so key columns are decoded from the index name (`<table>_<col>...[_pkey|_key|_idx]`). A unique index whose whole key is matched by equality always yields an `Index Scan` (primary-key point-lookup fast path); non-unique indexes are chosen only when cheaper than a sequential scan. A B-tree whose leading columns match the ORDER BY / GROUP BY keys is used as an ordered scan to avoid a Sort.
- **Join ordering**: comma-separated FROM items are ordered greedily (cheapest relation first, then the cheapest join), and each WHERE qual is pushed into the join that first makes it evaluable. An equality connecting the two sides makes a `Hash Join` (keys split out), otherwise a `Nested Loop`.
- **Aggregation**: streaming `GroupAgg` when the input already arrives ordered on the GROUP BY keys, otherwise `HashAgg`. ORDER BY bounded by a constant LIMIT sets `SortNode.Limit` for a top-N heap.

The cost model uses PostgreSQL's constants (`seq_page_cost=1`, `random_page_cost=4`, `cpu_tuple_cost=0.01`, `cpu_index_tuple_cost=0.005`, `cpu_operator_cost=0.0025`) and PostgreSQL's default operator selectivities. The catalog exposes no `reltuples`/`relpages`/column statistics, so row counts default to 100 and widths to 8 bytes per column.

## 5. EXPLAIN

`Explain(p, analyze)` renders PostgreSQL-style text: a node line with `(cost=.. rows=.. width=..)`, then indented `Filter:`, `Index Cond:`, `Hash Cond:`, `Merge Cond:`, `Join Filter:`, `Sort Key:` and `Group Key:` lines, using an expression renderer that qualifies columns by relation when the plan has more than one relation. `ExplainJson(p)` emits `FORMAT JSON` with node type, costs, rows, width, details and children. `ExplainAnalyze(p, stats)` annotates a plan with `NodeStat` measurements (`ActualRows`, `Loops`, `ActualTimeMs`) supplied by exec, addressed by root path.

## 6. Known gaps

- IN/EXISTS decorrelation to semi/anti joins, view expansion and column pruning are not implemented; subqueries are planned as `SubLink`/scalar subplans.
- Index-only scan selection (the node and EXPLAIN exist) and Merge Join selection are not implemented; merge joins are still executed as hash joins by exec.
- `UPDATE`/`DELETE` with `FROM`/`USING` are not supported.
- `catalog.Index` has no key list and the catalog has no statistics, so index selection and row estimates use the name convention and defaults above.
- Analyzer errors carry SQLSTATE and message but `Position == 0`: `parse`'s `Token.Pos` is not a character offset (see `BUGS.md`).
- An `IndexScan`/`IndexOnlyScan` plan is not yet executable by `exec` (`BuildCursor` has no case for it and returns an empty cursor), so an end-to-end PK point lookup returns no rows until the exec agent implements that node against this contract.
