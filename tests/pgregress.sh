#!/bin/sh
# Runs PostgreSQL 17's own regression suite (src/test/regress, the parallel_schedule list) against tingres,
# the way pg_regress does: psql -a -q per test, output compared to expected/NAME.out with diff -w.
# Writes tests/results/pgregress.tsv (name<TAB>pass|fail) and prints "PGREGRESS <passed> <total>".
#
#   PGSRC=/path/to/postgres-checkout (src/test/regress present; a sparse REL_17_STABLE clone is enough)
#   TINGRES=bin/tingres  PSQL=psql  TEST_TIMEOUT=60
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PGSRC=${PGSRC:-$ROOT/../tingres-pgsrc/pg}
REG=$PGSRC/src/test/regress
TINGRES=${TINGRES:-$ROOT/bin/server/tingres}
PSQL=${PSQL:-psql}
TEST_TIMEOUT=${TEST_TIMEOUT:-60}
OUT=$ROOT/tests/results
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tingres-regress.XXXXXX")
mkdir -p "$OUT"
: >"$OUT/pgregress.tsv"

[ -f "$REG/parallel_schedule" ] || { echo "PGREGRESS 0 0 (no suite at $REG)"; exit 2; }
TESTS=$(awk '/^test:/{for(i=2;i<=NF;i++) print $i}' "$REG/parallel_schedule")
TOTAL=$(echo "$TESTS" | wc -l | tr -d ' ')

PORT=$(perl -MIO::Socket::INET -e '$s=IO::Socket::INET->new(Listen=>1,LocalAddr=>"127.0.0.1",LocalPort=>0); print $s->sockport')
"$TINGRES" --data "$TMP/data" --listen "127.0.0.1:$PORT" --auth trust >"$TMP/server.log" 2>&1 &
SERVER=$!
cleanup() { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

up=0
for i in $(seq 1 50); do
	if "$PSQL" -X -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -Atqc 'select 1' >/dev/null 2>&1; then up=1; break; fi
	sleep 0.1
done
[ "$up" = 1 ] && "$PSQL" -X -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -qc 'create database regression' >/dev/null 2>&1

PASSED=0
for t in $TESTS; do
	res=fail
	if [ "$up" = 1 ] && [ -f "$REG/sql/$t.sql" ] && [ -f "$REG/expected/$t.out" ]; then
		perl -e 'alarm shift; exec @ARGV' "$TEST_TIMEOUT" "$PSQL" -X -a -q -h 127.0.0.1 -p "$PORT" -U postgres -d regression \
			-v abs_srcdir="$REG" -v abs_builddir="$TMP" -v libdir="$TMP" -v dlsuffix=.so -v regresslib="$TMP/regress.so" \
			-f "$REG/sql/$t.sql" >"$TMP/$t.out" 2>&1
		if diff -w -q "$REG/expected/$t.out" "$TMP/$t.out" >/dev/null 2>&1; then res=pass; PASSED=$((PASSED + 1)); fi
	fi
	printf '%s\t%s\n' "$t" "$res" >>"$OUT/pgregress.tsv"
done
echo "PGREGRESS $PASSED $TOTAL"
