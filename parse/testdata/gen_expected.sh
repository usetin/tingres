#!/usr/bin/env bash
# Generates parse/testdata/invalid_expected.txt from parse/testdata/invalid.sql using a real
# PostgreSQL 17 instance. invalid.sql entries are separated by lines containing only @@, so a
# single entry may span multiple lines. Each output line is TAB separated:
#   <position>\t<sqlstate>\t<message>
# where position is PostgreSQL's ErrorResponse P field (1-based character offset), or -1 with
# sqlstate ACCEPTED when PostgreSQL accepts the statement (the corpus should not contain those).
#
# The generator talks the v3 wire protocol directly (simple Query) and reads every message up to
# ReadyForQuery, so it does not depend on psql's prose formatting and never desynchronises.
set -euo pipefail

export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_BIN="${PG_BIN:-/opt/homebrew/bin}"
export SCRATCH_DIR="$(mktemp -d -t pg17_expected_XXXXXX)"
PORT="$(( 55000 + RANDOM % 2000 ))"

cleanup() {
    if [ -d "$SCRATCH_DIR" ]; then
        "$PG_BIN/pg_ctl" -D "$SCRATCH_DIR/data" -m immediate stop >/dev/null 2>&1 || true
        rm -rf "$SCRATCH_DIR"
    fi
}
trap cleanup EXIT INT TERM

echo "==> Initializing PostgreSQL 17 scratch instance at $SCRATCH_DIR"
"$PG_BIN/initdb" -D "$SCRATCH_DIR/data" --no-locale -E UTF8 -A trust >/dev/null

echo "==> Starting PostgreSQL 17 on port $PORT"
"$PG_BIN/postgres" -D "$SCRATCH_DIR/data" -p "$PORT" -k "$SCRATCH_DIR" >"$SCRATCH_DIR/postgres.log" 2>&1 &
for i in {1..50}; do
    if "$PG_BIN/pg_isready" -p "$PORT" -h "$SCRATCH_DIR" >/dev/null 2>&1; then break; fi
    sleep 0.1
done

echo "==> Setting up schema fixtures for valid statements"
"$PG_BIN/psql" -p "$PORT" -h "$SCRATCH_DIR" -d postgres -q << 'SQL'
CREATE TABLE t (
    id int PRIMARY KEY,
    a int,
    b int,
    c int,
    d timestamp DEFAULT CURRENT_TIMESTAMP,
    s text,
    tags text[],
    arr int[],
    val numeric,
    name text,
    score float,
    data jsonb
);
CREATE TABLE other (id int PRIMARY KEY, val int, x int, y text);
CREATE TABLE t1 (id int PRIMARY KEY, a int, b int);
CREATE TABLE t2 (id int PRIMARY KEY, a int, b int);
CREATE TABLE nums (n int PRIMARY KEY);
CREATE ROLE alice;
CREATE ROLE bob;
CREATE SCHEMA myschema;
CREATE TYPE mood AS ENUM ('happy', 'sad');
CREATE SEQUENCE s;
CREATE VIEW v AS SELECT 1 AS x;
CREATE PROCEDURE proc(a int, b int) LANGUAGE sql AS $$ SELECT 1; $$;
SQL

echo "==> Verifying valid.sql against PostgreSQL 17"
"$PG_BIN/psql" -X -p "$PORT" -h "$SCRATCH_DIR" -d postgres -f "$SCRIPT_DIR/valid.sql" >"$SCRATCH_DIR/valid.log" 2>&1 || true

echo "==> Capturing PostgreSQL 17 error fields (position, sqlstate, message) for invalid.sql"
PYTHONPATH="$SCRIPT_DIR" SCRATCH_DIR="$SCRATCH_DIR" SCRIPT_DIR="$SCRIPT_DIR" PORT="$PORT" python3 - << 'PYEOF'
import os, socket, struct, getpass, sys

port = int(os.environ["PORT"])
sock_dir = os.environ["SCRATCH_DIR"]
script_dir = os.environ["SCRIPT_DIR"]

def recvall(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed")
        buf.extend(chunk)
    return bytes(buf)

def read_message(sock):
    t = recvall(sock, 1)
    l = struct.unpack("!I", recvall(sock, 4))[0]
    body = recvall(sock, l - 4)
    return t, body

def parse_error_body(body):
    fields = {}
    i = 0
    while i < len(body):
        code = chr(body[i])
        i += 1
        if code == "\0":
            break
        end = body.find(b"\0", i)
        if end < 0:
            break
        fields[code] = body[i:end].decode("utf-8", errors="replace")
        i = end + 1
    return fields

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(f"{sock_dir}/.s.PGSQL.{port}")
user = getpass.getuser().encode()
params = b"user\0" + user + b"\0database\0postgres\0\0"
sock.sendall(struct.pack("!II", 8 + len(params), 196608) + params)
while True:
    t, body = read_message(sock)
    if t == b"Z":
        break
    if t == b"E":
        print("Startup error:", parse_error_body(body), file=sys.stderr)
        sys.exit(1)

with open(f"{script_dir}/invalid.sql") as f:
    raw = f.read()
entries = [e for e in raw.split("\n@@\n")]
if entries and entries[-1].endswith("\n"):
    entries[-1] = entries[-1][:-1]

def run(sql):
    q = sql.encode("utf-8")
    sock.sendall(b"Q" + struct.pack("!I", 4 + len(q) + 1) + q + b"\0")
    err = None
    while True:
        t, body = read_message(sock)
        if t == b"E":
            err = parse_error_body(body)
        if t == b"Z":
            break
    return err

rows = []
for sql in entries:
    if sql.strip() == "":
        continue
    err = run(sql)
    if err is None:
        rows.append("-1\tACCEPTED\t")
        continue
    pos = err.get("P", "-1")
    code = err.get("C", "42601")
    msg = err.get("M", "syntax error")
    rows.append(f"{pos}\t{code}\t{msg}")

with open(f"{script_dir}/invalid_expected.txt", "w") as f:
    for row in rows:
        f.write(row + "\n")
print(f"Generated expected errors for {len(rows)} invalid statements.")
PYEOF

echo "==> Done. Results written to $SCRIPT_DIR/invalid_expected.txt"
