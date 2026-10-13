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

## Reproduced bugs in other tingres packages

- `parse`: the lexer's `Token.Pos` is not a character offset. `parse/lexer.tin` initialises `charPos = 1` and then
  adds only `countCharacters(sql, previousByte, BytePos)` (the whitespace gap) per token, never the token length,
  so `Pos` is a token-gap ordinal (for `SELECT foo FROM users` the `foo` token reports `Pos == 2`). `plan/`
  therefore cannot produce PostgreSQL-compatible error positions (`PgError.Position`) and emits analyzer errors
  with position 0. Fix: `charPos = 1 + countCharacters(sql, 0, tokens[i].BytePos)`. Blocked: PostgreSQL-exact
  error positions from `plan/analyze.tin`.
