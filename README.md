# tingres

PostgreSQL, written entirely in [Tin](https://github.com/usetin). One static binary that speaks the PostgreSQL
frontend/backend protocol (v3), parses the PostgreSQL SQL dialect, stores data in a page-based MVCC heap with a
write-ahead log, and runs on Linux arm64 and x86-64 (macOS arm64 is for development only).

`psql`, `pg_dump`-less drivers and ORMs connect to it as to any PostgreSQL server.

Status: in construction. The design and the package contracts are in [ARCHITECTURE.md](ARCHITECTURE.md); the
milestone list is in [ROADMAP.md](ROADMAP.md).

```sh
make build            # needs a Tin checkout: make TIN=/path/to/tin/tin
bin/tingres --data ./data --listen 127.0.0.1:5433
psql -h 127.0.0.1 -p 5433 -U tin postgres
```

Correctness is judged against a real PostgreSQL: `tests/` holds differential tests that run the same script on both
servers and compare the results.
