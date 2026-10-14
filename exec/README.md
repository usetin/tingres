# `exec` package

`exec` binds a parsed statement to a transaction, catalog, and executor, then sends rows
and completion tags through a `Sink`. The server creates one `Session` per connection and
implements `Sink` with its protocol connection (`server/session.tin`, `server/engine.tin`).

## Session constructor (exact arguments for `server`/`main.tin`)

```tin
import "../exec"

mut session = exec.NewSession(catalog, manager, user, database)
```

The four arguments, in order:

1. `catalog catalog.Catalog` — the catalog opened on the same store (`catalog.Open`).
2. `manager txn.Manager` — the transaction manager created for that store (`txn.NewManager`).
3. `user str` — the authenticated role name, e.g. `"postgres"`.
4. `db str` — the connected database name, e.g. `"postgres"`.

The constructor does not open or own the store, manager, or catalog; it copies the values,
and Tin value structs are references, so the catalog/manager the engine holds and the ones
the session uses are the same objects (shared xids, locks and catalog versions).

```tin
mut sink = exec.NewRecordSink()   // or the server's Sink implementation
try session.Simple(sql, mut sink)
```

`Simple` accepts one PostgreSQL simple-query message, including multiple semicolon-separated
statements (run as one implicit transaction unless the message contains `BEGIN`/`COMMIT`),
and emits each statement's rows and command tag to the supplied mutable `Sink`.

## Public API

```tin
fn NewSession(c catalog.Catalog, m txn.Manager, user str, db str) Session

// simple query
fn (s mut Session) Simple(sql str, out mut dyn Sink) !
fn (s Session) State() TxnState
fn (s Session) StatusChar() u8            // 'I', 'T', 'E'
fn (s Session) Cancel()
fn (s Session) ResetCancel()
fn (s Session) IsCanceled() bool

// extended query protocol
fn (s mut Session) Parse(name str, sql str, paramOids []u32) !
fn (s mut Session) Bind(portalName str, prepName str, params mut []types.Datum, resultFormats mut []i16) !
fn (s mut Session) BindBytes(portalName str, prepName str, paramFormats []i16, paramValues [][]u8, resultFormats []i16) !
fn (s mut Session) Describe(kind u8, name str) !Description
fn (s mut Session) Execute(portalName str, maxRows i64, out mut dyn Sink) !
fn (s mut Session) Close(targetType u8, name str) !
fn (s mut Session) Sync(out mut dyn Sink) !
fn (s mut Session) GetPreparedStatement(name str) ?PreparedStatement
fn (s mut Session) DropPreparedStatement(name str)
fn (s mut Session) DropAllPreparedStatements()

// GUCs
fn (s mut Session) SetGuc(name str, val str, local bool) !
fn (s mut Session) ResetGuc(name str) !
fn (s mut Session) ResetAllGucs() !
fn (s Session) GetGuc(name str) ?str
fn (s Session) Guc(name str) str
fn (s mut Session) SetConfig(name str, val str, isLocal bool) !str
fn (s Session) CurrentSetting(name str, missingOk bool) !str
fn (s Session) ParameterStatusList() []GucStatus
```

## Sink contract

`exec.Sink` (a `shape`) has: `RowDescription(cols []ColDesc, formats []i16)`,
`DataRow(r types.Row)`, `CommandComplete(tag str)`, `Notice(n Notice)`,
`CopyIn(format i8, columnFormats []i16)`, `CopyOut(format i8, columnFormats []i16)`,
`CopyData(d []u8)`, `CopyDone()`.

Exact command tags emitted, as PostgreSQL sends them: `SELECT n`, `INSERT 0 n`,
`UPDATE n`, `DELETE n`, `CREATE TABLE`, `DROP TABLE`, `CREATE INDEX`, `EXPLAIN`,
`BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, `SET`, `RESET`, `SHOW`,
`COPY n`, plus `CHECKPOINT`/`VACUUM`/`ANALYZE`/`PREPARE`/`EXECUTE`/`DEALLOCATE`/`DISCARD`.

## System functions

`exec/builtin_sys.tin` evaluates the session-dependent system-information functions the
planner's type registry does not know (`version()`, `current_database()`,
`current_schema()`, `current_user`/`session_user`, `pg_backend_pid()`,
`current_setting()`, `set_config()`, ...) for FROM-less `SELECT`s. A SELECT that also reads
a table, or calls one of these functions with a table column, still needs the functions in
the shared function registry; see the NEEDS-OTHER note below.

## Tests

`exec/e2e_test.tin` (`TestEndToEndOnRealStore`) is the end-to-end acceptance test: a
scripted session runs `CREATE TABLE`/`INSERT`/`SELECT` (`WHERE`, `ORDER BY`, `LIMIT`,
`GROUP BY`, join)/`UPDATE`/`DELETE`/`BEGIN`/`COMMIT`/`ROLLBACK`/`SET`/`SHOW` against
`store.Open` + `txn.NewManager` + `catalog.Open`, then closes and reopens the data
directory and checks the committed rows survived and a fresh session works.

## Deviations from ARCHITECTURE.md 2.7 and known gaps

- `Sink` methods take `out mut dyn Sink` rather than a bare `out Sink`, and `Simple`/
  `Parse`/`Bind`/`Execute` take `mut` receivers. This is the compiler's `mut`-parameter
  rule (see BUGS.md); the semantic contract is unchanged.
- `Explain` output is produced by `plan.ExplainPlan`; `EXPLAIN ANALYZE` reports the plan
  with actual rows/time placeholders, not measured execution counters.
- Catalog metadata is in memory (upstream `catalog`), so after a restart a user table
  cannot be resolved by name. `TestEndToEndOnRealStore` verifies durability at the heap
  relation level and that a fresh session can run SQL. See NEEDS-OTHER in BUGS.md.
- `ROLLBACK TO SAVEPOINT` undoes row writes by command id (exec tracks the command id at
  each savepoint and marks later tuples deleted); it cannot restore a row deleted before
  the savepoint. `txn.Manager` has no subtransaction/undo API yet. See NEEDS-OTHER.
