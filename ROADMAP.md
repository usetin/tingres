# Roadmap

Milestones are vertical slices; each ends with a `psql` session that works and a test that proves it.

## M0: skeleton (this commit)
Repository, architecture, package contracts, build and test commands.

## M1: first query over psql
- `proto`: startup, `trust` and `scram-sha-256` auth, simple query, errors, `ReadyForQuery`, `Terminate`, SSL request refusal.
- `parse`: `CREATE TABLE`, `INSERT ... VALUES`, `SELECT cols FROM t WHERE expr ORDER BY LIMIT`, `DROP TABLE`, `BEGIN/COMMIT/ROLLBACK`, `SET/SHOW`, `SELECT 1`.
- `types`: bool, int2/4/8, float4/8, text, varchar, numeric (arbitrary precision), date, timestamp(tz), uuid, bytea; arithmetic, comparison, string functions.
- `store`: 8 KiB pages, buffer pool, heap, WAL with crash recovery, checkpoint.
- `txn`: xids, snapshots, read committed, visibility, row/table locks.
- `catalog`: bootstrap of `pg_class`, `pg_attribute`, `pg_type`, `pg_namespace`; `psql \dt` works.
- `exec`/`plan`: seq scan, filter, project, sort, limit, insert/update/delete.
- `server`: listen, accept, sessions; `tingres --data DIR --listen ADDR`.
Exit: `psql -c 'create table t(a int, b text); insert into t values (1,''x''); select * from t;'` returns the row, survives `kill -9`.

## M2: a real database
B-tree indexes and unique/primary-key/foreign-key/check/not-null constraints, joins (nested loop, hash, merge), aggregation,
`GROUP BY/HAVING`, subqueries, CTEs (recursive), window functions, set operations, `UPDATE ... RETURNING`, `ON CONFLICT`,
extended query protocol with binary formats (drivers: pgx, psycopg, JDBC, the Tin `postgres` package), prepared statements.

## M3: operations
Repeatable read and serializable (SSI), vacuum and autovacuum, `EXPLAIN (ANALYZE)`, `ANALYZE` statistics driving the optimizer,
`COPY`, views, sequences, `information_schema`, roles and `GRANT`, TLS, `pg_stat_*`.

## M4: breadth and speed
JSON/JSONB, arrays, ranges, full-text search, triggers and PL/Tin functions, partitioning, streaming replication,
`pg_dump`/`pg_restore` compatibility, benchmark parity with PostgreSQL on pgbench (Linux).
