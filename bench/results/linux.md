Machine: unknown | CPU: unknown | cores: 1 | kernel: unknown | PostgreSQL 17 | tingres commit: abc | run date: 2026-10-14
Medians of interleaved runs (>= 5 rounds), fsync on. Ratio > 1.0x means tingres is faster.
Machine-reported values below are pending until the Linux workflow runs.

| benchmark | tingres | PostgreSQL 17 | ratio | status |
|---|---:|---:|---:|---|
| pgbench select-only, 1 client (tps) | — | — | — | pending |
| pgbench select-only, 16 clients (tps) | — | — | — | pending |
| pgbench select-only, 64 clients (tps) | — | — | — | pending |
| pgbench tpcb-like, 16 clients (tps) | — | — | — | pending |
| primary-key point lookup, p50 / p99 latency | — | — | — | pending |
| scan + aggregate over 10M rows (TPC-H Q1 shape) | — | — | — | pending |
| bulk insert via COPY (rows/s) | — | — | — | pending |
| single-row INSERT with fsync commit (commits/s, 16 clients) | — | — | — | pending |
| connection setup + first query (connections/s) | — | — | — | pending |
| SQL parse throughput, simple statements (statements/s) | — | — | — | pending |
