# tingres architecture

PostgreSQL in Tin. Goals, in order: **wire and SQL compatibility** (real clients and drivers work unchanged),
**durability and MVCC correctness**, **speed** (Linux is production; never quote macOS numbers), small dependency
surface (only the Tin standard library and `packages/wire`-style Tin packages from the Tin checkout).

Reference for behaviour is a real PostgreSQL 17 (`postgres`, `psql` are installed on the dev machine). When in doubt,
do what PostgreSQL does and say so in a test.

## 1. Layers and packages

Each package is a directory of `.tin` files at the repository root, imported as `import "./name"` from `main.tin`
and from other packages as `import "../name"`. (A local package must not share a name with a Tin std or `packages/`
package: `wire`, `postgres`, `column`, `pack`, `link` ... are taken, hence `proto`, `parse`, `store`.)

```text
                     main.tin           flags, config, start server
                        |
   proto  <------  server  ------>  session (one per connection)
  (wire v3)           |
                      v
   parse  ---->  plan  (analyze + optimize)  ---->  exec  (executor, DML, utility commands)
                      |                               |
                      v                               v
                   catalog  <-------------------   txn  (xids, snapshots, locks)
                      |                               |
                      +--------------> store <--------+     store = pages, buffers, heap, btree, WAL
                                         ^
                       types (Datum, type OIDs, casts, builtin functions) is imported by everyone
```

| package | owns | imports |
|---|---|---|
| `types` | `Datum`, type OIDs, text/binary in/out, casts, operators, builtin functions | std only |
| `parse` | lexer, parser, AST for the PostgreSQL dialect, AST deparser | `types` |
| `store` | page layout, buffer pool, heap relations, B-tree, WAL, recovery, checkpoint, free-space map | `types` |
| `txn` | xids, commit log, snapshots, MVCC visibility, lock manager, deadlock detection, vacuum | `store` |
| `catalog` | `pg_catalog` tables as Tin structs, name resolution, DDL effects, `information_schema` views | `types`, `store`, `txn` |
| `plan` | semantic analysis (binding, type resolution), logical plan, cost-based optimizer, `EXPLAIN` | `parse`, `catalog`, `types` |
| `exec` | executor nodes, expression evaluation, DML, DDL/utility execution, COPY, prepared statements | `plan`, `catalog`, `txn`, `store`, `types` |
| `proto` | frontend/backend protocol v3: message framing, startup, SSL request, SCRAM-SHA-256/md5/trust, simple and extended query, COPY sub-protocol, cancel, errors/notices | `types` |
| `server` | listener on tide/lanes, sessions, connection and memory limits, config, signals | `proto`, `exec`, `txn` |
| `tests` | differential tests against a real PostgreSQL; protocol conformance; crash-recovery tests | everything |

## 2. Contracts between packages

These names are fixed. The owner of a package may add to its API freely; changing or removing a name below is done
in this file first, in the PR/commit that needs it, and announced to the other owners. Signatures are written in
Tin (strict, edition 1; see the Tin primer). Nothing below is a full implementation guide: it is what the neighbours
may rely on.

### 2.1 `types`

```tin
type Oid = u32                                  // pg_type oids are the real PostgreSQL ones: bool 16, bytea 17, int8 20,
                                                // int2 21, int4 23, text 25, oid 26, json 114, float4 700, float8 701,
                                                // varchar 1043, date 1082, time 1083, timestamp 1114, timestamptz 1184,
                                                // interval 1186, numeric 1700, uuid 2950, jsonb 3802, arrays per pg_type
type Datum value struct { ... }                 // one SQL value; Null is a Datum; cheap to copy; owner picks layout
fn Null() Datum
fn IsNull(d Datum) bool
fn FromI64(oid Oid, v i64) Datum                // int2/int4/int8/oid
fn FromF64(oid Oid, v f64) Datum
fn FromBool(v bool) Datum
fn FromStr(oid Oid, v str) Datum                // text/varchar/bpchar/name/json/uuid text form
fn FromBytes(oid Oid, v []u8) Datum
fn (d Datum) Oid() Oid
fn Compare(a Datum, b Datum) i64                // total order within a type; NULLs sort last; used by btree and ORDER BY
fn Parse(oid Oid, text str) !Datum              // text input function (PostgreSQL syntax: '2024-01-02', '{1,2}', ...)
fn (d Datum) Text() str                         // text output function
fn EncodeBinary(d Datum, out []u8)              // binary send format for the wire; appends
fn DecodeBinary(oid Oid, b []u8) !Datum
fn Cast(d Datum, to Oid) !Datum                 // explicit cast rules of PostgreSQL
fn CanCast(from Oid, to Oid, implicit bool) bool
type Func struct { name str, args []Oid, ret Oid, strict bool, call fn([]Datum) !Datum, ... }
fn LookupFunc(name str, args []Oid) ?Func       // builtin scalar functions and operators (operators are funcs named "+")
type Agg struct { ... }                         // builtin aggregates: init/step/final over Datum; count, sum, avg, min, max, string_agg, array_agg, bool_and ...
fn LookupAgg(name str, args []Oid) ?Agg
type Row = []Datum
fn EncodeRow(types []Oid, r Row, out []u8)      // heap tuple payload format (fixed + varlena, null bitmap)
fn DecodeRow(types []Oid, b []u8) !Row
```

### 2.2 `parse`

```tin
type Stmt dyn                                   // AST statements: Select, Insert, Update, Delete, CreateTable, AlterTable,
                                                // DropStmt, CreateIndex, Begin/Commit/Rollback/Savepoint, Set/Show,
                                                // Explain, Copy, Prepare/Execute/Deallocate, Truncate, Vacuum, CreateView, ...
fn Parse(sql str) ![]Stmt                       // one simple-query string may hold many statements; error carries 1-based
                                                // position (`ParseError.pos`) so the server sends the PostgreSQL `P` field
fn ParseExpr(sql str) !Expr
fn Deparse(s Stmt) str                          // round-trips through Parse; used by tests and `pg_get_viewdef`
```

Parameters are `$1..$n`; the AST keeps them as `Param{n}`. The grammar is PostgreSQL's (gram.y) in scope order given in
ROADMAP.md; unsupported syntax is a clean `0A000 feature_not_supported` error with a position, never a crash.

### 2.3 `store`

```tin
type RelId = u32                                // relation file id (pg_class.relfilenode)
type PageNo = u32
type Tid struct { page PageNo, slot u16 }       // (block, line pointer)
type Store struct { ... }
fn Open(dir str, opts Options) !Store           // runs crash recovery before returning
fn (s Store) Close() !
// heap
fn (s Store) CreateHeap(rel RelId) !
fn (s Store) DropRel(rel RelId) !
fn (s Store) HeapInsert(x XidCtx, rel RelId, payload []u8) !Tid          // writes the tuple header (xmin = x.xid, cmin = x.cid)
fn (s Store) HeapDelete(x XidCtx, rel RelId, t Tid) !                    // sets xmax; visibility is txn's job
fn (s Store) HeapFetch(rel RelId, t Tid, out []u8) !HeapTuple
fn (s Store) HeapScan(rel RelId) HeapScan       // sequential; yields every tuple version with its header, MVCC filter is the caller's
// btree
fn (s Store) CreateIndex(rel RelId, unique bool) !
fn (s Store) IndexInsert(rel RelId, key []u8, t Tid) !                   // key bytes are memcmp-ordered (types.IndexKey)
fn (s Store) IndexSeek(rel RelId, lo []u8, hi []u8, flags u32) IndexScan // range scan, forward/backward
// wal
type Lsn = u64
fn (s Store) Checkpoint() !
fn (s Store) Sync(lsn Lsn) !                                              // group commit: flush the log up to lsn
type XidCtx struct { xid u32, cid u32 }
```

On-disk format is tingres's own (not PostgreSQL-compatible binary files); logical compatibility only. 8 KiB pages,
a `PageHeader` with LSN and checksum, slotted line pointers, tuple header `{xmin, xmax, cid, infomask, ctid}`.
`Store` is safe to share between lanes (the owner documents the locking and the `no-await-while-latched` rule).

### 2.4 `txn`

```tin
type Manager struct { ... }
type Txn struct { xid u32, ... }
type Snapshot struct { xmin u32, xmax u32, xip []u32, cid u32 }
fn NewManager(s Store) !Manager
fn (m Manager) Begin(iso Isolation) Txn         // read committed, repeatable read, serializable
fn (m Manager) Snapshot(t Txn) Snapshot         // per statement for read committed
fn (m Manager) Commit(t Txn) !                  // WAL commit record + group commit
fn (m Manager) Abort(t Txn)
fn (m Manager) Visible(snap Snapshot, h store.TupleHeader) bool          // the MVCC rules, hint bits included
fn (m Manager) LockRelation(t Txn, rel RelId, mode LockMode) !           // waits; DeadlockDetected / lock_timeout faults
fn (m Manager) LockTuple(t Txn, rel RelId, tid Tid, mode TupleLock) !    // FOR UPDATE / FOR SHARE / write conflicts
fn (m Manager) Savepoint(t Txn, name str) !
fn (m Manager) Vacuum(rel RelId, opts VacuumOpts) !
```

### 2.5 `catalog`

```tin
type Catalog struct { ... }
fn Open(s Store, m txn.Manager) !Catalog        // bootstraps pg_catalog on an empty data dir
type Table struct { oid Oid, schema str, name str, cols []Column, rel RelId, indexes []Index, ... }
fn (c Catalog) LookupTable(t Txn, schema str, name str) ?Table      // honours search_path via SearchPath(t)
fn (c Catalog) CreateTable(t Txn, def TableDef) !Table
fn (c Catalog) DropTable(t Txn, tbl Table, cascade bool) !
fn (c Catalog) CreateIndex(t Txn, def IndexDef) !Index
fn (c Catalog) LookupType(name str) ?Oid
fn (c Catalog) SystemTable(name str) ?Table                         // pg_class, pg_attribute, pg_type, ... are real tables
```

Catalog changes are transactional (MVCC on the catalog heaps) and invalidate plan caches by version counter.

### 2.6 `plan`

```tin
type Plan dyn                                    // physical plan tree: SeqScan, IndexScan, Filter, Project, NestLoop, HashJoin,
                                                 // MergeJoin, Sort, Agg, Limit, SetOp, CTE, Values, ModifyTable ...
type Prepared struct { stmt parse.Stmt, paramTypes []Oid, resultCols []ColDesc, plan Plan, catalogVersion u64 }
fn Prepare(c catalog.Catalog, t Txn, s parse.Stmt, paramTypes []Oid) !Prepared   // analyze + optimize
fn Explain(p Prepared, analyze bool) []str
type ColDesc struct { name str, oid Oid, typmod i32, tableOid Oid, attno i16 }   // RowDescription needs exactly these
```

### 2.7 `exec`

```tin
type Session struct { ... }                      // per connection: current txn, GUCs (search_path, DateStyle, ...), prepared stmts, portals
fn NewSession(c catalog.Catalog, m txn.Manager, user str, db str) Session
fn (s Session) Simple(sql str, out Sink) !       // runs every statement in `sql`, one result set each
fn (s Session) Parse(name str, sql str, paramOids []Oid) !                 // extended protocol
fn (s Session) Bind(portal str, stmt str, params []Param, resultFormats []i16) !
fn (s Session) Execute(portal str, maxRows i64, out Sink) !
fn (s Session) Describe(kind u8, name str) !Description
fn (s Session) Cancel()                           // safe from another lane
type Sink shape {
	RowDescription(cols []plan.ColDesc, formats []i16)
	DataRow(r types.Row)
	CommandComplete(tag str)                       // "SELECT 5", "INSERT 0 1", ...
	Notice(n Notice)
	CopyIn(format i8, columnFormats []i16)
	CopyOut(format i8, columnFormats []i16)
	CopyData(d []u8)
	CopyDone()
}
```

`proto` knows nothing about SQL and `exec` knows nothing about bytes on the socket; `server` binds a `proto` connection to
an `exec.Session` through `Sink`.

### 2.8 `proto`

```tin
type Conn struct { ... }
fn Accept(sock Socket, cfg Config) !Conn         // startup, SSL/GSS refusal or TLS, authentication
fn (c Conn) Next() !Message                      // Query, Parse, Bind, Describe, Execute, Sync, Flush, Close, CopyData, Terminate ...
fn (c Conn) Send...(...)                         // one method per backend message; buffered, flushed on ReadyForQuery
type ErrorFields struct { severity str, code str, message str, detail str, hint str, position i32, ... }
```

## 3. Cross-cutting rules

- **Errors** are PostgreSQL errors: every fault that reaches the client carries a SQLSTATE (`23505 unique_violation`,
  `42P01 undefined_table`, ...). `types.PgError{code, message, detail, hint, position}` is the one error type
  across packages; `fault.Is` sentinels for the ones callers branch on.
- **No cgo, no libc, no Go.** Everything is Tin and the Tin std library. Sockets, timers, files via `tide`, `io`, `fs`, `task`.
- **Concurrency model:** one lane (core) per N connections, sessions are tasks; shared structures (buffer pool, lock
  table, catalog caches) are sharded and latched; no latch is held across a wait. Document each in the owning package's
  header comment.
- **Memory:** per-statement arenas for plan and executor temporaries (`arena { }`), buffer pool is one preallocated
  region; no per-row heap allocation on the scan path.
- **Tests** live next to the code as `*_test.tin` (`tin test .`) and in `tests/` for cross-package ones. A test is never weakened
  or deleted to get green; an unsupported feature is a documented, tested error, not a skipped test.
- **Compiler bugs:** do not work around them silently and do not touch the Tin checkout. Write a minimal repro file
  under `tests/compiler_bugs/NAME.tin`, note it in `BUGS.md`, work around it, and keep going.
- **Benchmarks** are Linux only (`bench/`), against real PostgreSQL on the same machine, medians with the ratio.
- **Format** with `tin fmt -w`. Style: match the neighbouring code; comments say why, not what.

## 4. Performance is the product

Tin exists for speed, so tingres must beat PostgreSQL by a wide margin on the same Linux machine, not just match it.
This is a design constraint on every package, checked by benchmarks, not a slogan.

Where the advantage has to come from (PostgreSQL's known costs, and our answer):

| PostgreSQL cost | tingres design |
|---|---|
| process per connection, shared-memory IPC, LWLock/spinlock traffic | one task per connection on a lane (core); shared structures sharded per lane; no latch held across a wait |
| tuple-at-a-time interpreter, `Datum` boxing and function-call overhead per expression | expressions compiled once per plan to straight-line closures/bytecode over unboxed values; typed fast paths (int4/int8/float8/text) with no NULL checks when a column is NOT NULL; batch (vector of 1k rows) operators for scans, filters, hash joins and aggregates |
| per-row `palloc`, `MemoryContext` churn | per-statement arenas (`arena { }`), rows are slices into pinned pages until they must be copied; no per-row heap allocation on the scan path |
| 24-byte tuple header, MVCC visibility check per tuple | hint bits set early; page-level "all visible" bit so scans skip the clog and the snapshot test; compact header |
| plan and parse on every simple query | parse-tree/plan cache keyed by normalized text and catalog version; extended protocol skips re-planning |
| WAL: one fsync per commit unless grouped, full-page writes after checkpoint | group commit with an io_uring/fdatasync batch on Linux, a WAL ring in memory, `full_page_writes` only when the page is torn-risky (checksum + double-write alternative evaluated) |
| B-tree: pointer chasing, per-key `memcmp` through a comparator | memcmp-ordered key bytes (types.IndexKey), prefix compression, SIMD-friendly in-page search, right-sized pages, no comparator indirection |
| syscalls per IO | batched positional IO, io_uring where available (Linux), readahead for sequential scans |

Rules:
- Every hot path gets a benchmark in `bench/` from the day it is written (`BenchmarkXxx` or a pgbench-style script), and a
  regression is a failed check, not a note.
- Linux numbers only (arm64 and x86-64), tingres vs real PostgreSQL 17 on the same machine in the same run, interleaved,
  medians with the ratio, machine/CPU/kernel stated. Never quote macOS numbers. Targets to publish once measured:
  pgbench select-only, tpcb-like, point lookups by PK, scan+aggregate (TPC-H Q1/Q6 shape), bulk insert and COPY, 1..N clients.
- When a design choice trades speed for compatibility, compatibility of observable behaviour wins and the speed is
  recovered under the hood (plan cache, fast paths), never by changing results.
- Durability is not traded away to win a benchmark: `fsync` stays on in every published number; a faster-than-fsync
  mode (`synchronous_commit=off`) is compared only against PostgreSQL's equivalent setting.
