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
- NEEDS-TIN: positional file writes (`quarry.WriteAt(path, off, data)` backed by `pwrite`) and a durable
  data-only sync (`quarry.DataSync(path)` backed by `fdatasync`) for `store/file.tin`. Tin exposes `quarry.Sync`
  and positional `quarry.ReadAt` only through `tin2/sysprim`, with no `WriteAt`/`fdatasync` API. Until then
  `store` rewrites a relation through a synced replacement file, which copies the whole relation on every page
  write and is far too costly for a database buffer pool. Blocked file: `store/file.tin`.
- NEEDS-TIN: fix the inline value-struct-in-enum-literal miscompile (repro
  `tests/compiler_bugs/inline_value_struct_enum_const.tin`, expected `a 23 1` / `b 23 2`). Blocked:
  `plan/analyze.tin` and `plan/planner.tin` constant construction (worked around by always materialising the
  datum into a local first).
- NEEDS-TIN: a package-level `const` with a composite value crashes the compiler with
  `index out of range [-1] with length 0` in `check_const_value` (repro `tests/compiler_bugs/const_slice_str.tin`,
  `const xs = []str{"a"}`). Use a function returning the value or a package-level `let` meanwhile; the catalog seed
  is a function. Blocked file: `catalog/seed.tin`.
- NEEDS-TIN: value-struct stack aliasing. Two locals copied from the same struct (`mut ctxA = c.Ctx; ctxA.Row = a`
  then `mut ctxB = c.Ctx; ctxB.Row = b`) and passed to a `mut`-receiver call can both read the second slice:
  `exec.SortCursor.compare` returned 0 for rows 10 and 30, so ORDER BY never reordered. Observed only in the full
  exec package (a stand-alone version of the same shape prints the correct `-20`), so there is no minimal repro
  yet. Worked around in `exec/operators.tin` by precomputing sort keys per row. Blocked file:
  `exec/operators.tin` (`SortCursor`).

## Missing in other packages (NEEDS-OTHER), worked around inside `exec`

- NEEDS-OTHER: catalog: persist and recover user-table/index metadata and relation OIDs across `catalog.Open`.
  The `Catalog.tables`/`Catalog.names` maps (and the OID/relation counters) are rebuilt empty on reopen, so after
  a restart `exec` cannot resolve a table by name, cannot rebuild a `catalog.Table` for an already-existing
  relation, and a new `CREATE TABLE` can pick a relation id that collides with a recovered one. Blocked:
  `exec.TestEndToEndOnRealStore` verifies durability by scanning the recovered heap relation directly; a real
  restart-with-catalog path needs catalog persistence.
- NEEDS-OTHER: txn: subtransaction / undo support for `ROLLBACK TO SAVEPOINT`. `txn.Manager` has no savepoint API
  and no way to restore a tuple deleted before a savepoint, so `exec.Session` tracks the command id at each
  SAVEPOINT and marks only the tuples written after it deleted. A row deleted before the savepoint stays deleted
  across `ROLLBACK TO`. Blocked file: `exec/session.tin` (`rollbackSavepointData`).
- NEEDS-OTHER: types/plan: a way to add session-dependent system functions (`version`, `current_database`,
  `current_schema`, `current_setting`, `pg_backend_pid`, `pg_table_is_visible`, `format_type`, ...) to the shared
  function registry, or planner support that defers them to exec. Other packages can only read the `let`
  `types.builtinFuncRegistry` (immutable), so `exec/builtin_sys.tin` can only serve FROM-less SELECTs; psql's
  `\d`/`\l`/`\dn` queries mix these functions with `pg_catalog` columns. Blocked files: `exec/builtin_sys.tin`,
  `exec/session.tin` (`trySystemSelect`).
- NEEDS-OTHER: plan: `analyzeLiteral` keeps a string literal's SQL spelling (including the surrounding and doubled
  single quotes) in the constant datum, so a text constant holds `'a'` instead of `a`. `exec` decodes string
  constants in `normalizeConst` until the analyzer decodes the lexer token itself. Blocked files:
  `exec/expr.tin` (`normalizeConst`).
- NEEDS-OTHER: plan: UPDATE/DELETE modify plans do not carry tuple identity (TID). `planUpdate` wraps the target
  scan in a `Project` that replaces SET columns, so the original row no longer matches the stored tuple; exec walks
  the `Project`'s input and re-matches the old row instead. A ctid output (or the scan's TID) would make
  UPDATE/DELETE exact under concurrent writes and duplicates. Blocked file: `exec/dml.tin` (`ExecuteModifyTable`).

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
- `tests/compiler_bugs/inline_value_struct_enum_const.tin`: Tin miscompiles an inline value-struct constructor
  used as an enum-variant struct field once two such locals are live
  (`plan.Expr.Const(plan.ConstExpr{Value: types.FromI64(types.Int4Oid, 1), ...})` reads back with `oid == 1`
  instead of 23). It is stack-layout dependent: construction through a helper that binds the datum to a local
  first is correct. All constant construction in `plan/` goes through `mkConstExpr`/`mkInt4Const`/`mkBoolConst`/
  `mkStrConst`/`mkNullConst` to avoid it.
- `tests/compiler_bugs/const_slice_str.tin`: a package-level `const` whose value is a composite (for example
  `const xs = []str{"a"}`) crashes the compiler with `index out of range [-1] with length 0` in
  `check_const_value`. `catalog/seed.tin` therefore returns its generated seed from a function.

## Reproduced bugs in other tingres packages

- `parse`: the lexer's `Token.Pos` is not a character offset. `parse/lexer.tin` initialises `charPos = 1` and then
  adds only `countCharacters(sql, previousByte, BytePos)` (the whitespace gap) per token, never the token length,
  so `Pos` is a token-gap ordinal (for `SELECT foo FROM users` the `foo` token reports `Pos == 2`). `plan/`
  therefore cannot produce PostgreSQL-compatible error positions (`PgError.Position`) and emits analyzer errors
  with position 0. Fix: `charPos = 1 + countCharacters(sql, 0, tokens[i].BytePos)`. Blocked: PostgreSQL-exact
  error positions from `plan/analyze.tin`.

## Sibling-package blockers found from the server

- `exec` is not end to end: `Simple("SELECT 1")` answers with the command tag `OK` instead
  of `SELECT 1`, so `tingres --engine auto` keeps choosing the conformance engine (the probe
  in `server/engine.tin` checks exactly that tag). `store -> txn -> catalog -> exec` itself
  works across queries: `tin run tests/repro/two_transactions.tin` finishes both of them.
  Owner: the exec agent.
- `exec.Session.BindBytes` trips E701 (`paramValues`/`resultFormats`); the server decodes Bind
  parameters itself (see above).
- Handing the engine to a connection task is blocked by three compiler rules at once:
  as a parameter of the task's function it is E312 ("stores request memory into its mut
  parameter"), as a global it is E310 (the engine is long-lived; `keep()` would deep-copy
  the store and split it from the one the WAL gate belongs to, and assigning it from `main`
  trips E310 too), and through a captured function literal it is E703 for a mut parameter.
  `server/session.tin` therefore wraps the session in a `dyn QuerySession` shape (dyn calls
  are not region-checked, which is what makes the session loop compile at all), and the
  engine global stays nil so `--engine real` answers 58000 instead of silently misbehaving.
  A session factory passed as a function value is the intended fix; it currently makes
  exec's own E312 errors (`FunctionScanCursor.Next`, `LockRowsCursor.Next`) surface, so it
  waits for exec to compile cleanly.
