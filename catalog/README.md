# catalog

Transactional PostgreSQL catalog for tingres: `pg_catalog` system relations stored in
real `store` heaps, relation/DDL metadata, sequences, views, enums, statistics and the
`information_schema` view definitions.

Reference is PostgreSQL 17; type oids, relation oids, namespace oids and column sets are
the real ones.

## Design

`catalog.Open` creates the system heaps once on an empty data directory and seeds them
from `catalog/seed.tin` (generated from a live PostgreSQL 17 by `catalog/gen/gen_pgrows.py`):

- `pg_namespace`, `pg_class`, `pg_attribute`, `pg_type`, `pg_proc`, `pg_index`,
  `pg_constraint`, `pg_attrdef`, `pg_depend`, `pg_database`, `pg_authid`, `pg_roles`,
  `pg_sequence` with their real PostgreSQL oids and column sets;
- namespaces `pg_catalog` (11), `pg_toast` (99), `public` (2200) and
  `information_schema`; database `postgres`; the `postgres` superuser; every builtin
  type (`pg_type`) and the builtins the `types` package registers (`pg_proc`);
- tingres-private `pg_rewrite`, `pg_enum`, `pg_statistic`.

The generated seed is written into a private `pg_seed` heap packed a few rows per tuple
(the M1 store scans page 0 on every insert and thrashes under a small buffer pool). The
decoded row cache merges the packed seed with the relation heaps, so user DDL writes one
real tuple per catalog row and everything survives a reopen.

Visibility is full MVCC over the tuple headers (`txn.Manager.TupleHeaderVisible`): a
catalog change is invisible in its own command, visible after `CommandCounterIncrement`,
visible to later transactions after `Commit`, and gone after `Abort`. `catalog.Version()`
increments on every change so prepared plans can be invalidated.

## Public API

```tin
fn Open(s mut store.Store, m txn.Manager) !Catalog
fn (c Catalog)  LookupTable(t txn.Txn, schema str, name str) ?Table   // honours search_path
fn (c Catalog)  LookupTableOid(t txn.Txn, oid Oid) ?Table
fn (c Catalog)  LookupNamespace(t txn.Txn, schema str) Oid
fn (c Catalog)  SystemTable(name str) ?Table                           // pg_catalog relation
fn (c Catalog)  LookupType(name str) ?Oid
fn (c Catalog)  SearchPath(t txn.Txn) []str
fn (c mut Catalog) SetSearchPath(t txn.Txn, path []str)
fn (c Catalog)  Version() u64

fn (c mut Catalog) CreateTable(t txn.Txn, def TableDef) !Table
fn (c mut Catalog) DropTable(t txn.Txn, tbl Table, cascade bool) !
fn (c mut Catalog) CreateIndex(t txn.Txn, def IndexDef) !Index
fn (c mut Catalog) DropIndex(t txn.Txn, indexOid u32) !
fn (c mut Catalog) CreateSchema(t txn.Txn, name str) !Oid
fn (c mut Catalog) DropSchema(t txn.Txn, name str, cascade bool) !
fn (c mut Catalog) CreateSequence(t txn.Txn, def SequenceDef) !Table
fn (c mut Catalog) Nextval(t txn.Txn, seq Table) !i64
fn (c mut Catalog) Currval(seq Table) !i64
fn (c mut Catalog) Setval(t txn.Txn, seq Table, value i64) !
fn (c mut Catalog) CreateView(t txn.Txn, def ViewDef) !Table
fn (c Catalog)  ViewQuery(t txn.Txn, tbl Table) ?str
fn (c mut Catalog) CreateEnum(t txn.Txn, schema str, name str, labels []str) !Oid
fn (c Catalog)  EnumLabels(t txn.Txn, typeOid Oid) []str
fn (c mut Catalog) Truncate(t txn.Txn, tbl Table) !
fn (c mut Catalog) AnalyzeTable(t txn.Txn, tbl Table) !
fn (c Catalog)  ColumnStatistics(t txn.Txn, tableOid Oid) []ColumnStat
fn (c Catalog)  Statistic(t txn.Txn, tableOid Oid, attnum i16) ?f64
fn (c Catalog)  InformationSchemaView(t txn.Txn, name str) ?str
fn (c mut Catalog) AlterTableAddColumn(t txn.Txn, tbl Table, def ColumnDef) !Column
fn (c mut Catalog) AlterTableDropColumn(t txn.Txn, tbl Table, name str, cascade bool) !
fn (c mut Catalog) AlterTableRenameColumn(t txn.Txn, tbl Table, oldName str, newName str) !
fn (c mut Catalog) AlterTableRename(t txn.Txn, tbl Table, newName str) !
fn (c mut Catalog) AlterTableSetNotNull(t txn.Txn, tbl Table, name str, notnull bool) !
fn (c mut Catalog) AlterTableSetDefault(t txn.Txn, tbl Table, name str, expr str) !
```

`Table` carries `Oid`, `Schema`, `Name`, `Cols []Column`, `Rel` (relfilenode), `Indexes`,
`System`, `Owner`, `Kind`, `RowType`, `RelTuples f64` and `RelPages i32` (from
`pg_class`). `Column` carries `Name`, `Type`, `Typmod`, `Number`, `Nullable`,
`HasDefault`, `DefaultText`, `Identity`, `Generated`, `Collation`.

For the planner, `Index` carries `Unique`, `Primary`, `Cols []i16` and
`Keys []IndexKey` where `IndexKey{Attnum i16, Desc bool, NullsFirst bool}` is the ordered
key list (`IndexDef` takes the same `Keys`; empty `Keys` means every `Cols` entry
ascending, nulls last). Per-column statistics are `ColumnStat{Attnum, Inherit, NullFrac,
Width, Distinct, Kind, Numbers []f64, Values []str}`, the shape of a `pg_statistic` slot,
with the most-common values in `Values` and their frequencies in `Numbers`; `AnalyzeTable`
computes `stanullfrac`/`stawidth`/`stadistinct` and `ColumnStatistics` reads the slots
back.
`Table.Rel`/`Column.Number` are the attnums/relfilenodes the executor and planner use.

Errors use PostgreSQL SQLSTATEs: `42P01`, `42P07`, `42701`, `42703`, `42P06`, `3F000`,
`2BP01`, `42501`, `55000`, `42602`.

## Tests

`tin test catalog` — bootstrap oids/column sets; golden differential of the seeded
`pg_type`/`pg_namespace` rows against PostgreSQL 17; transactional DDL (same-command
hiding, cross-transaction visibility, abort restores); reopen persistence; SQLSTATEs;
sequences; ALTER TABLE; indexes and schemas; the planner surface (index keys, reltuples,
pg_statistic slots); the built-in information_schema views (10 tests).

## information_schema

`informationSchemaViews()` registers `tables`, `columns`, `schemata`,
`table_constraints` and `key_column_usage` as real `pg_class`/`pg_attribute` view rows with
their SQL text in `pg_rewrite`; `InformationSchemaView(t, name)` returns the stored
definition. The executor does not run these definitions yet.


## Known gaps

- The B-tree itself is an M1 store stub, so `CreateIndex` records `pg_class`/`pg_index`
  rows but no index pages are built yet.
- `pg_statistic` uses tingres's own column names, not PostgreSQL's full set.
- `Truncate` recreates the heap rather than truncating in place; `DropTable` keeps the
  relation file (no deferred unlink).
- Scanner/planner cache invalidation is by `Version()`; cross-core catalog instances are
  not synchronised (single-core M1).
- `information_schema` views are stored definitions only; the executor does not run their
  SQL yet.
