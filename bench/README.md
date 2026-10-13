# tingres benchmark client

`main.tin` is a Tin load generator. It uses the Tin `postgres` client, which sends
parameterized statements through PostgreSQL's extended query protocol and reuses a
connection per worker.

```sh
tin build bench/main.tin -o bin/server/tingres-bench
bin/server/tingres-bench --addr 127.0.0.1:5432 --user postgres --database postgres --mode select --clients 16 --duration 30
```

The `select` mode repeatedly runs `SELECT $1::int4`. The `tpcb` mode runs a parameterized
transaction over the standard `pgbench` tables. Initialize those tables on both servers
with the PostgreSQL 17 `pgbench -i` command before running that mode.

For publishable comparisons, build and run this client on Linux against tingres and real
PostgreSQL 17 on the same machine, interleave the runs, and report medians, ratio, machine,
CPU, kernel and Go version. macOS runs are smoke checks only; do not publish their rates.
