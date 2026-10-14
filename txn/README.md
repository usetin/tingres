# txn

Transactions for tingres: xid allocation, the two-bit commit log, MVCC visibility,
snapshots, tuple/relation locks, and the global xmin horizon.

## Durability

`txn.NewManager(s mut store.Store)` registers the WAL record kinds (`xid reserve`, `commit`,
`abort`, `clog page`), creates the `xact` heap, and replays it:

- xids are reserved in blocks of 256; the next-xid watermark is logged and written to the
  `xact` heap, so recovery restarts above every reserved (not just used) xid;
- the clog is two bits per xid (`InProgress`, `SubCommitted`, `Committed`, `Aborted`),
  kept in 64-byte pages that are WAL-logged and redone from WAL;
- `Commit` writes the clog outcome and a commit record, then `store.Sync(lsn)` (group
  commit) before returning; `Abort` logs an abort record;
- after a crash, every xid that was in progress at the crash is aborted during
  `NewManager`.

## Visibility

`VisibleTuple`/`HeapTupleVisible`/`TupleHeaderVisible` implement PostgreSQL's
`HeapTupleSatisfiesMVCC` over `store.TupleHeader` (or plain header fields):

- xmin frozen/committed/invalid hint bits, own-transaction cmin/cmax, xmax
  invalid/lock-only/committed/in-progress, and the snapshot xip set and xmin/xmax
  horizon;
- hint bits are persisted with `store.SetHint` once final;
- `HeapTupleSatisfiesDirty`/`SatisfiesUpdate` give the executor's
  Ok/Invisible/SelfModified/Updated/BeingModified(xid) result for the write path;
- `Snapshot(t)` is per statement for read committed and stable for repeatable read;
  serializable currently has repeatable-read semantics.

`CertifyPageAllVisible` caches full-page visibility, and `GlobalXmin` is the oldest xid
retained by any active transaction or registered snapshot.

## Locks

`LockRelation`/`LockTuple` implement PostgreSQL's eight relation lock modes and four tuple
lock modes with the conflict matrices. A conflicting request joins that relation's FIFO
wait queue and waits (via `tide.Sleep`, so the core serves other tasks); earlier conflicting
waiters go first, and a transaction may upgrade its own mode when no other holder conflicts.
`LockXid` waits for another transaction to finish. `Commit`/`Abort` release all held locks.

`SetLockTimeout(ns)` makes a wait fail with `55P03`, `SetDeadlockTimeout(ns)` runs a
wait-for-graph check that fails the transaction closing a cycle with `40P01` and a
PostgreSQL-style `DETAIL`, and `Cancel(xid)` wakes a waiter with `57014`.

## Savepoints and subtransactions

`Savepoint` allocates a subtransaction xid; writes inside it are stamped with that xid
(`Txn.WriteXid`), and `Snapshot.Xids` makes the transaction's own xids visible under the
cmin/cmax rule. `RollbackTo` aborts the subtransaction and restarts the savepoint with a
fresh subxid, so its tuples become invisible and locks/snapshots it took are released;
`Release` marks the subtransaction `SubCommitted`, which the parent's `Commit` promotes to
`Committed` (and `Abort` to `Aborted`). Recovery aborts every `SubCommitted` xid, since its
parent had not committed at the crash.

## Public API

```tin
fn NewManager(s mut store.Store) !Manager
fn (m mut Manager) Begin(iso Isolation) !Txn
fn (t Txn) Xid() u32
fn (t Txn) CommandID() u32
fn (t mut Txn) CommandCounterIncrement()
fn (m Manager) NextXid() u32
fn (m Manager) Snapshot(t Txn) Snapshot
fn (m mut Manager) AcquireSnapshot(t Txn) SnapshotHandle
fn (m mut Manager) ReleaseSnapshot(h SnapshotHandle)
fn (m Manager) GlobalXmin() u32
fn (m mut Manager) Commit(t mut Txn) !
fn (m mut Manager) Abort(t mut Txn) !
fn (m mut Manager) Savepoint(t mut Txn, name str) !
fn (m mut Manager) RollbackTo(t mut Txn, name str) !
fn (m mut Manager) Release(t mut Txn, name str) !
fn (t Txn) WriteXid() u32
fn (t Txn) Subxids() []u32
fn (m mut Manager) LockRelation(t Txn, rel u32, mode LockMode) !
fn (m mut Manager) TryLockRelation(t Txn, rel u32, mode LockMode) bool
fn (m mut Manager) LockTuple(t Txn, rel u32, page u32, slot u16, mode TupleLock) !
fn (m mut Manager) LockXid(t Txn, xid u32) !
fn (m mut Manager) SetLockTimeout(ns i64)
fn (m mut Manager) SetDeadlockTimeout(ns i64)
fn (m mut Manager) Cancel(xid u32)
fn (m Manager) State(xid u32) XidState

fn (m Manager) Visible(snap Snapshot, h store.TupleHeader) bool
fn (m Manager) VisibleHeader(snap Snapshot, h TupleHeader) bool
fn (m Manager) HeapTupleSatisfiesMVCC(snap Snapshot, h store.TupleHeader) bool
fn (m Manager) HeapTupleVisible(snap Snapshot, rel store.RelId, h store.TupleHeader, tid store.Tid) bool
fn (m Manager) TupleHeaderVisible(snap Snapshot, rel store.RelId, xmin u32, xmax u32, cid u32, infomask u16, tid store.Tid) bool
fn (m mut Manager) VisibleTuple(snap Snapshot, rel store.RelId, tuple store.HeapTuple) bool
fn (m Manager) HeapTupleSatisfiesDirty(t Txn, h store.TupleHeader) TupleCheck
fn (m Manager) HeapTupleSatisfiesUpdate(t Txn, h store.TupleHeader) TupleCheck
fn (m mut Manager) HeapInsert(t Txn, rel store.RelId, payload []u8) !store.Tid
fn (m mut Manager) HeapDelete(t Txn, rel store.RelId, tid store.Tid) !
fn (m mut Manager) CertifyPageAllVisible(rel store.RelId, page u32)
fn (m mut Manager) InvalidatePageVisibility(rel store.RelId, page u32)

fn (m mut Manager) LockRelation(t Txn, rel u32, mode LockMode) !
fn (m mut Manager) TryLockRelation(t Txn, rel u32, mode LockMode) bool
fn (m mut Manager) LockTuple(t Txn, rel u32, page u32, slot u16, mode TupleLock) !
```

## Tests

`tin test txn` — snapshot/MVCC rule table, page visibility, delete visibility, relation
and tuple locks, lock wait wakeup, deadlock victim selection, lock timeout/cancel, xid
locks, isolation snapshots, hint bits, dirty/update results, snapshot registry and global
xmin, durable commit/abort and xid reservation, two-bit clog, savepoints/subtransactions,
crash recovery aborts in-flight tuples (17 tests).

## Known gaps

- Locks wait with polling (`tide.Sleep`), not a direct wakeup channel, and the deadlock
  detector runs only after `deadlock_timeout` (no cross-core lock relay yet).
- Savepoints/subtransactions are implemented for visibility, locks and recovery, but the
  store stamps the subxid as xmin (PostgreSQL instead keeps the parent xid and a combo
  cmin); observable rollback/commit behaviour matches.
- `Vacuum(rel, opts)` and clog truncation are not implemented (the store has no prune
  hook yet).
- Serializable behaves as repeatable read (no SSI).
