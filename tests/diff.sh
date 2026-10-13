#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PG_BIN=${PG_BIN:-/opt/homebrew/bin}
POSTGRES=${POSTGRES:-$PG_BIN/postgres}
INITDB=${INITDB:-$PG_BIN/initdb}
PSQL=${PSQL:-$PG_BIN/psql}
TINGRES=${TINGRES:-$ROOT/bin/server/tingres}
CLIENT_PROBE=${CLIENT_PROBE:-$ROOT/bin/server/client_probe}
SQL_FILE=${1:-$ROOT/tests/smoke.sql}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/tingres-diff.XXXXXX")
PGDATA=$TMP/pgdata

free_ports() {
	python3 -c 'import socket; a=socket.socket(); b=socket.socket(); a.bind(("127.0.0.1", 0)); b.bind(("127.0.0.1", 0)); print(a.getsockname()[1]); print(b.getsockname()[1]); a.close(); b.close()'
}

set -- $(free_ports)
PGPORT=$1
TINPORT=$2
"$INITDB" -D "$PGDATA" -A trust -U postgres >"$TMP/initdb.log" 2>&1
"$POSTGRES" -D "$PGDATA" -h 127.0.0.1 -p "$PGPORT" >"$TMP/postgres.log" 2>&1 &
PGPID=$!
TINGRES_PASSWORD=secret "$TINGRES" --data "$TMP/tingres-data" --listen "127.0.0.1:$TINPORT" --auth scram-sha-256 --password secret >"$TMP/tingres.log" 2>&1 &
TINPID=$!
cleanup() {
	kill "$TINPID" "$PGPID" 2>/dev/null || true
	wait "$TINPID" "$PGPID" 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

ready=0
for i in $(seq 1 100); do
	if "$PSQL" "host=127.0.0.1 port=$PGPORT user=postgres dbname=postgres sslmode=disable" -XAtqc 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
	sleep 0.1
done
if [ "$ready" -ne 1 ]; then cat "$TMP/postgres.log" >&2; exit 1; fi

ready=0
for i in $(seq 1 100); do
	if PGPASSWORD=secret "$PSQL" "host=127.0.0.1 port=$TINPORT user=postgres dbname=postgres sslmode=prefer" -XAtqc 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
	sleep 0.1
done
if [ "$ready" -ne 1 ]; then cat "$TMP/tingres.log" >&2; exit 1; fi

"$PSQL" "host=127.0.0.1 port=$PGPORT user=postgres dbname=postgres sslmode=disable" -XAtf "$SQL_FILE" | sed 's/[[:space:]]*$//' >"$TMP/postgres.out"
PGPASSWORD=secret "$PSQL" "host=127.0.0.1 port=$TINPORT user=postgres dbname=postgres sslmode=prefer" -XAtf "$SQL_FILE" | sed 's/[[:space:]]*$//' >"$TMP/tingres.out"
diff -u "$TMP/postgres.out" "$TMP/tingres.out"
if PGPASSWORD=secret "$PSQL" "host=127.0.0.1 port=$TINPORT user=postgres dbname=postgres sslmode=prefer" -XAtqc 'SELECT 2' -v VERBOSITY=verbose >"$TMP/unsupported.out" 2>"$TMP/unsupported.err"; then
	echo "unsupported query unexpectedly succeeded" >&2
	exit 1
fi
grep -q '0A000' "$TMP/unsupported.err"
if PGPASSWORD=wrong "$PSQL" "host=127.0.0.1 port=$TINPORT user=postgres dbname=postgres sslmode=prefer" -XAtqc 'SELECT 1' -v VERBOSITY=verbose >"$TMP/auth.out" 2>"$TMP/auth.err"; then
	echo "invalid SCRAM password unexpectedly succeeded" >&2
	exit 1
fi
grep -q 'password authentication failed' "$TMP/auth.err"
TINGRES_ADDR="127.0.0.1:$TINPORT" TINGRES_PASSWORD=secret "$CLIENT_PROBE" >"$TMP/client.out"
test "$(cat "$TMP/client.out")" = "1"
cat "$TMP/tingres.out"
