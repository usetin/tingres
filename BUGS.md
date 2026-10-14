# Tin compiler bugs and missing Tin pieces

## Missing in Tin (NEEDS-TIN), worked around meanwhile

- NEEDS-TIN: `wire.Listen` has no SO_REUSEPORT option, so a server cannot open one listener per core on Linux
  (`packages/anvil` sets SO_REUSEPORT with its own `rt_sys_setsockopt`, which is trusted-code-only). Sketch:
  `wire.ListenReuse(addr str) !Listener` setting SO_REUSEPORT before bind, plus `hearth.Run` in `server.Serve`.
  Blocked file: `server/server.tin` (single shared listener today; connections are tasks, so every socket wait
  still lets the lane serve the other sessions).
- NEEDS-TIN: no way to take a signal from Tin. `anvil` can because it declares `rt_sig_block_term`/signalfd in
  trusted code; a normal program is killed by SIGTERM with no chance to send 57P01 to its clients, checkpoint, or
  reload `pg_hba.conf` on SIGHUP. Sketch: `quarry.OnSignal(SIGTERM, fn())` or exposing the runtime's
  `rt_signalfd`. Blocked file: `server/server.tin` (`server.Shutdown()` is the API; the process watches
  `--shutdown-file` and `--reload-file` as the stand-in, and `main.tin` exits 0 after a clean drain).
- NEEDS-TIN: `wire.Conn` has `LocalPort()` but no peer address, so `pg_hba.conf` cannot match the real client
  address. Sketch: `(c Conn) RemoteAddr() !str`. Blocked file: `server/server.tin` (`peer_address()` uses the
  listener's host until then).
- NEEDS-TIN: in a `shape`, a method whose result is fault-only (`mut F() !`) is accepted only as the last member
  (`toolchain/std/fs/fs.tin`'s `shape File` ends with `mut Close() !`); anywhere else the parser reports
  `E020 UNEXPECTED: expected a name, found 'mut'` on the *next* member. Minimal repro:
  `shape s { mut A() !\nmut B() !i64 }`. Worked around in `proto/proto.tin` by giving the write methods an `!i64`
  result. Blocked file: `proto/proto.tin`.
- NEEDS-TIN: fix the inline value-struct-in-enum-literal miscompile (repro
  `tests/compiler_bugs/inline_value_struct_enum_const.tin`, expected `a 23 1` / `b 23 2`). Blocked:
  `plan/analyze.tin` and `plan/planner.tin` constant construction (worked around by always materialising the datum
  into a local first, via `mkConstExpr`/`mkInt4Const`/`mkBoolConst`/`mkStrConst`/`mkNullConst`).

## Missing in other packages (NEEDS-OTHER), worked around inside `exec`

- NEEDS-OTHER: catalog: persist and recover user-table/index metadata and relation OIDs across `catalog.Open`.
  The `Catalog.tables`/`Catalog.names` maps are rebuilt empty on reopen, so after a restart `exec` cannot resolve a
  table by name and cannot rebuild a `catalog.Table` for an already-existing relation. Blocked:
  `exec.TestEndToEndOnRealStore` verifies durability by scanning the recovered heap relation directly; a real
  restart-with-catalog path needs catalog persistence.
- NEEDS-OTHER: txn: subtransaction / undo support for `ROLLBACK TO SAVEPOINT`. `txn.Manager` has no savepoint API
  and no way to restore a tuple deleted before a savepoint, so `exec.Session` tracks the command id at each
  SAVEPOINT and marks only the tuples written after it deleted. A row deleted before the savepoint stays deleted
  across `ROLLBACK TO`. Blocked file: `exec/session.tin` (`rollbackSavepointData`).
- NEEDS-OTHER: types/plan: a way to add session-dependent system functions (`version`, `current_database`,
  `current_schema`, `current_setting`, `pg_backend_pid`, `pg_table_is_visible`, `format_type`, ...) to the shared
  function registry, or planner support that defers them to exec. Other packages can only append to a `let`
  `types.builtinFuncRegistry` (immutable), so `exec/builtin_sys.tin` can only serve FROM-less SELECTs; psql's
  `\d`/`\l`/`\dn` queries mix these functions with `pg_catalog` columns. Blocked files: `exec/builtin_sys.tin`,
  `exec/session.tin` (`trySystemSelect`).
- NEEDS-OTHER: plan: `analyzeLiteral` keeps a string literal's SQL spelling (including the surrounding and doubled single quotes) in the constant datum, so a text constant holds `'a'` instead of `a`. exec decodes string constants in `normalizeConst` until the analyzer decodes the lexer token itself. Blocked files: `exec/expr.tin` (`normalizeConst`).
- NEEDS-OTHER: plan: UPDATE/DELETE modify plans do not carry tuple identity (TID). `planUpdate` wraps the target
  scan in a `Project` that replaces SET columns, so the original row no longer matches the stored tuple; exec walks
  the `Project`'s input and re-matches the old row instead. A ctid output (or the scan's TID) would make
  UPDATE/DELETE exact under concurrent writes and duplicates. Blocked file: `exec/dml.tin` (`ExecuteModifyTable`).

- NEEDS-TIN: value-struct stack aliasing. Two locals copied from the same struct (`mut ctxA = c.Ctx; ctxA.Row = a` then `mut ctxB = c.Ctx; ctxB.Row = b`) and passed to a `mut`-receiver call can both read the second slice: `exec.SortCursor.compare` returned 0 for rows 10 and 30, so ORDER BY never reordered. Observed only in the full exec package (a stand-alone 20-line version prints the correct `-20`), so there is no minimal repro yet. Worked around in `exec/operators.tin` by precomputing sort keys per row (and in `exec/expr.tin`/`plan/` by materialising values through helpers). Blocked file: `exec/operators.tin` (`SortCursor`).

## Compiler diagnostics that shaped the code (not bugs, but worth knowing)

- `E701 NOT_MUT: cannot modify parameter 'x'` follows *derived* values, not just direct writes: a value built from
  a parameter (even via a helper's return value, or a copy loop) may not be passed to a `mut` parameter or stored
  into a map. The server therefore threads `mut` parameters through the session helpers and hands `exec.Session`
  fresh slices it built itself.
- A `scope` block needs its enclosing function to return a fault (`E411`), and a function literal cannot capture a
  `mut` parameter (`E703`) — `server.spawn_client` copies its parameters into locals first.
- Consequence for `exec`: `exec.Session.BindBytes` trips `E701` for `paramValues`/`resultFormats` (its `s.Bind`
  stores them), so `server/session.tin` decodes Bind parameters itself and calls `exec.Session.Bind`. That is also
  what keeps a NULL parameter apart from an empty string.

## Reproduced bugs

- `tests/compiler_bugs/forward_map_struct_key.tin`: Tin segfaults when a struct declares a map whose struct key and
  struct value types are declared later in the package. The transaction manager avoids the compiler bug by
  declaring `LockMode`, `LockKey` and `LockHolder` before `Manager`.
- `tests/compiler_bugs/inline_value_struct_enum_const.tin`: Tin miscompiles an inline value-struct constructor used
  as an enum-variant struct field once two such locals are live (`plan.Expr.Const(plan.ConstExpr{Value:
  types.FromI64(types.Int4Oid, 1), ...})` reads back with `oid == 1` instead of 23). It is stack-layout dependent:
  construction through a helper that binds the datum to a local first is correct.
