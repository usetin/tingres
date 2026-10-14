# `store`

`store` owns 8 KiB relation pages, the shared buffer pool, heap tuples, B-tree indexes, WAL,
checkpoints, and crash recovery. The on-disk format is tingres-specific. `Store` is core-local;
route cross-core requests through `relay`. Page latches protect synchronous byte access only and
must not be held across a wait, await, or another page load.

## Public API

### Open and lifecycle

- `Open(dir str, opts Options) !Store` creates or opens a data directory and replays valid WAL
  before returning.
- `Options{BufferPages: n}` selects the buffer-pool frame count. Otherwise
  `SharedBuffersBytes` selects a byte capacity; the default is 16 MiB. `WalRingBytes` is retained
  for compatibility and is currently unused. `SyncOnWrite` requests syncing after each append.
- `(s mut Store) Close() !` flushes pages and writes a clean shutdown record/control file.
- `(s mut Store) Checkpoint() !` flushes dirty buffers and writes a checkpoint/control file.
- `(s Store) CurrentLsn() Lsn` returns the current end position of the WAL stream.
- `(s Store) RedoLsn() Lsn` returns the recovery start position.

### Heap

- `(s mut Store) CreateHeap(rel RelId) !` creates a heap relation.
- `(s mut Store) DropRel(rel RelId) !` logs and removes a relation.
- `(s mut Store) HeapInsert(x XidCtx, rel RelId, payload []u8) !Tid` inserts a tuple version.
- `(s mut Store) HeapFetch(rel RelId, tid Tid, out []u8) !HeapTuple` fetches a tuple; `out` is
  currently unused.
- `(s mut Store) HeapDelete(x XidCtx, rel RelId, tid Tid) !` sets its `xmax` and command id.
- `(s mut Store) SetHint(rel RelId, tid Tid, bits u16) !` WAL-logs hint bits.
- `(s mut Store) HeapScan(rel RelId) HeapScan` returns physical tuple versions; call
  `(scan mut HeapScan) Next() (HeapTuple, bool)` until `false`.
- `(s mut Store) Prune(rel RelId, deadHorizon u32) !` removes versions whose nonzero `xmax` is
  below the supplied horizon.
- `(s mut Store) SetPageAllVisible(rel RelId, block PageNo, value bool) !` and
  `(s mut Store) PageAllVisible(rel RelId, block PageNo) !bool` manage/read the page visibility bit.

`HeapTuple` exposes `Header`, `Tid`, and `Payload`. `TupleHeader` accessors are `Xmin`, `Xmax`,
`Cid`, `Infomask`, and `Ctid`. `Tid` is constructed with `NewTid(page, slot)` and read using
`Page()` and `Slot()`. `NewXidCtx(xid, cid)` constructs a write identity, read with `Xid()` and
`Cid()`.

### B-tree

- `(s mut Store) CreateIndex(rel RelId, unique bool) !` creates an index relation.
- `(s mut Store) IndexInsert(rel RelId, key []u8, tid Tid) !` inserts a key/TID pair. Keys compare
  lexicographically as unsigned bytes; duplicate keys and TIDs are permitted.
- `(s mut Store) IndexLookupExact(rel RelId, key []u8) ![]Tid` returns matching TIDs, including
  entries for dead tuples.
- `(s mut Store) IndexDelete(rel RelId, key []u8, tid Tid) !` removes one matching pair.
- `(s mut Store) IndexSeek(rel RelId, lo []u8, hi []u8, flags u32) IndexScan` builds a range scan.
  Bounds are inclusive unless `IndexLoExclusive` / `IndexHiExclusive` is set. Use
  `IndexLoUnbounded`, `IndexHiUnbounded`, and `IndexBackward` as needed. Read `Error()` and then
  call `(scan mut IndexScan) Next() (IndexItem, bool)`. `IndexItem` accessors are `Key()` and
  `Tid()`.

### WAL extension

- `(s mut Store) Sync(lsn Lsn) !` flushes and syncs WAL through the requested LSN; concurrent
  callers may share a sync batch.
- `(s mut Store) RegisterRecordKind(kind u8, name str) !` reserves a kind (16 or greater).
- `(s mut Store) RegisterRecordKindRedo(kind u8, name str, redo fn(rel u32, block u32, slot u16, body []u8) !) !`
  also registers a recovery callback.
- `(s mut Store) LogRecord(kind u8, payload []u8) !Lsn` appends a registered record.
- `(s mut Store) ReplayRegistered() !` replays the WAL for registered callbacks.

`PageSize` is 8192 bytes. Buffer pages are preallocated and evicted by clock sweep. Dirty pages
are written only after syncing through their page LSN. The package currently uses the available Tin
file APIs for replacement-file positional writes; see `BUGS.md` for portability/performance gaps.

## Known limits

The current scans materialize results in memory. The index's `unique` option is stored but uniqueness
is enforced by the caller. There is no page free-space map beyond a per-relation insert hint, no
parallel cross-core buffer-pool access, and no concurrent mutation guarantee for a single `Store`;
lifecycle and checkpoint operations require quiescent mutations. Page writes still go through a
replacement-file rewrite because Tin has no positional write API (`BUGS.md`); a checkpoint writes
each relation once, and a large buffer pool avoids the rewrite on reads. On a platform without
`fdatasync`, every WAL sync is a full `fsync`, so the group-commit and durability numbers are
fsync-bound.

## Tests and benchmarks

`tin test store` runs the page, buffer-pool, heap, B-tree, randomized-model, concurrency and
crash-recovery suites. `TestBufferPoolEvictsAcrossThousandPages` forces clock-sweep eviction through
a 16-frame pool and checks WAL-before-data; `TestRandomizedHeapVersusModel` and
`TestBtreeVersusSortedModel` replay tens of thousands of seeded operations against in-memory models;
`TestConcurrentHeapAndBtreeTasks` inserts from several tasks into one heap and one index;
`TestCrashTruncatesAtEveryRecordBoundary` and `TestCrashTruncatesAtRandomOffsets` reopen copies of
the data directory with the WAL cut at every record boundary and at random byte offsets, requiring
the heap and B-tree to agree on a committed prefix. `tin test -bench store` prints heap insert,
sequential scan, B-tree insert, point lookup and group-commit throughput.
