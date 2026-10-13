#!/usr/bin/env bash
set -euo pipefail

export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PG_BIN="/opt/homebrew/bin"
export SCRATCH_DIR="$(mktemp -d -t pg17_expected_XXXXXX)"
PORT=55433

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
PG_PID=$!

# Wait for postgres to be ready
for i in {1..30}; do
    if "$PG_BIN/pg_isready" -p "$PORT" -h "$SCRATCH_DIR" >/dev/null 2>&1; then
        break
    fi
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
"$PG_BIN/psql" -p "$PORT" -h "$SCRATCH_DIR" -d postgres -f "$SCRIPT_DIR/valid.sql" >"$SCRATCH_DIR/valid.log" 2>&1 || true

echo "==> Extracting exact PostgreSQL 17 error messages and positions for invalid.sql"
python3 - << 'PYEOF'
import socket, struct, getpass, sys, os

port = 55433
sock_dir = os.environ.get("SCRATCH_DIR")
script_dir = os.environ.get("SCRIPT_DIR")

def recvall(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk: raise EOFError()
        buf.extend(chunk)
    return bytes(buf)

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(f"{sock_dir}/.s.PGSQL.{port}")
user = getpass.getuser().encode()
params = b"user\0" + user + b"\0database\0postgres\0\0"
sock.sendall(struct.pack("!II", 8 + len(params), 196608) + params)

while True:
    t = recvall(sock, 1)
    l = struct.unpack("!I", recvall(sock, 4))[0]
    body = recvall(sock, l - 4)
    if t == b"Z": break
    if t == b"E":
        print("Startup error:", body)
        sys.exit(1)

with open(f"{script_dir}/invalid.sql") as f:
    lines = [line.rstrip("\r\n") for line in f if line.strip()]

expected_rows = []
for sql in lines:
    q = sql.encode("utf-8")
    sock.sendall(b"Q" + struct.pack("!I", 4 + len(q) + 1) + q + b"\0")
    
    t = recvall(sock, 1)
    l = struct.unpack("!I", recvall(sock, 4))[0]
    payload = recvall(sock, l - 4)
    
    fields = {}
    i = 0
    while i < len(payload):
        code = chr(payload[i])
        i += 1
        if code == "\0": break
        end = payload.find(b"\0", i)
        val = payload[i:end].decode("utf-8", errors="replace")
        fields[code] = val
        i = end + 1
        
    # Read until ReadyForQuery (Z)
    while t != b"Z":
        t = recvall(sock, 1)
        l = struct.unpack("!I", recvall(sock, 4))[0]
        body = recvall(sock, l - 4)
        
    pos = fields.get("P", "0")
    code = fields.get("C", "42601")
    msg = fields.get("M", "syntax error")
    expected_rows.append(f"{pos}|{code}|{msg}")

with open(f"{script_dir}/invalid_expected.txt", "w") as f:
    for row in expected_rows:
        f.write(row + "\n")

print(f"Generated expected errors for {len(expected_rows)} invalid queries.")
PYEOF

echo "==> Done. Results written to $SCRIPT_DIR/invalid_expected.txt"
