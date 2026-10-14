# The PostgreSQL regression suite: where tingres stands

This is the triage of the last full run, not a wish list. Regenerate the data with:

```sh
PGSRC=$PWD/../tingres-pgsrc/pg TEST_TIMEOUT=10 tests/pgregress.sh   # or: make regress
```

It writes `tests/results/pgregress.tsv` (`name<TAB>pass|fail|timeout`), the server's own output in
`tests/results/actual/NAME.out`, and a unified diff against PostgreSQL in `tests/results/diffs/NAME.diff`.
`make stats` then puts the numbers into README.md.

## The last run

Commit `cb5cf71`, 2026-10-14, Darwin arm64, PostgreSQL 17.11 expected files:

```text
PGREGRESS 0 225      (0 pass, 205 fail, 20 timeout)
```

The suite is now meaningful: it connects (it used to be refused the `regression` database), it runs under
`pg_regress`'s own environment (`PGTZ`, `PGDATESTYLE`, `\getenv` variables), and a test that hangs is
recorded as `timeout` instead of wedging the run.

## Why tests fail (census of the 205 diffs)

Read the first few lines of a diff and it is almost always one of these, in this order of leverage:

1. **`test_setup` never completed**, so the shared tables do not exist: 1031 x `relation "..." does not
   exist` across the suite. `test_setup` COPYs `onek` from a file, and `COPY ... FROM '<file>'` hangs the
   connection today. Fixing COPY turns that cascade off. (owner: the COPY work)
2. **Errors carry no position**, so psql prints `psql:FILE:LINE: ERROR:` instead of PostgreSQL's
   `LINE n: ...` + caret line: 192 of 225 tests. `parse` computes `Pos` as a token-gap ordinal; it must be
   the 1-based character offset (`charPos = 1 + countCharacters(sql, 0, tokens[i].BytePos)`), and every
   analyzed error must set `PgError.Position`. (owner: parse/plan - see BUGS.md)
3. **Typed literals `TYPE 'text'` are not evaluated**: `SELECT bool 't'` returns the text `bool 't'`
   instead of `t`. This breaks every value-type test (`boolean`, `char`, `int2`/`int4`/`int8`, `float4`,
   `float8`, `numeric`, `text`, ...). (owner: types/plan)
4. **Error wording and quoting differ**: `invalid input syntax for type integer: "'34.5'"` (the SQL quotes
   are kept) where PostgreSQL prints `"34.5"`. 150 + 150 + 89 + 79 such errors. (owner: types/plan)
5. **Unknown GUCs are rejected**: 774 x `unrecognized configuration parameter "..."`. PostgreSQL accepts
   every standard GUC (and the suite `SET`s `enable_seqscan`, `work_mem`, `DateStyle`, `client_min_messages`,
   `allow_in_place_tablespaces`, ...). Accept every standard name; ignore the ones that do not apply.
   (owner: exec/guc)
6. **Dollar-quoted strings are not lexed**: 180 x `unterminated dollar-quoted string`, so every function
   body, trigger and DO block in the suite fails. (owner: parse)
7. **Missing functions**, in volume order: `numrange`, `int4range`, `pg_input_is_valid`,
   `to_timestamp`, `ts_lexize`, `jsonb_path_query_tz`, ... (owner: types, in volume order)
8. **`current transaction is aborted`** (1257, concentrated in the tests that open a transaction) - check
   the per-statement implicit transaction, and that `ROLLBACK`/`COMMIT` reset the state. (owner: exec/txn)

## Hangs (never acceptable)

20 tests time out: `triggers inherit vacuum roleattributes subselect update brin privileges rowsecurity
identity create_table_like psql stats_ext publication foreign_key window partition_join partition_prune
indexing partition_aggregate`. A statement that stops the server answering is a bug of the same severity
as a wrong answer. Each one needs a minimal repro in BUGS.md and a fix; `COPY ... FROM '<file>'` is the
known one.
