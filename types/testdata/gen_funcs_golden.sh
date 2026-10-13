#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/../.." && pwd)
pg_bin=${PG_BIN:-/opt/homebrew/bin}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tingres-funcs.XXXXXX")
data="$scratch/data"
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)

cleanup() {
	"$pg_bin/pg_ctl" -D "$data" stop -m immediate >/dev/null 2>&1 || true
	python3 - "$scratch" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY
}
trap cleanup EXIT HUP INT TERM

"$pg_bin/initdb" -D "$data" -U "$(id -un)" --auth=trust --no-locale --encoding=UTF8 >/dev/null
"$pg_bin/pg_ctl" -D "$data" -o "-p $port -h 127.0.0.1" -l "$scratch/postgres.log" start >/dev/null

python3 - "$scratch/corpus.sql" <<'PY'
import sys

expressions = []
ops = ["+", "-", "*", "/", "%", "&", "|", "#"]
for left in range(1, 25):
    for right in range(1, 25):
        for op in ops:
            expressions.append(f"{left} {op} {right}")
        expressions.extend([
            f"{left} = {right}", f"{left} <> {right}", f"{left} < {right}",
            f"{left} <= {right}", f"{left} > {right}", f"{left} >= {right}",
        ])
        shift = right % 5
        expressions.append(f"{left} << {shift}")
        expressions.append(f"{left} >> {shift}")

expressions.extend([
    "((2 + 3) * 4) - 5",
    "abs(-5)",
    "greatest(1, 3, 2)",
    "least(1, 3, 2)",
    "coalesce(NULL::int4, 5)",
    "nullif(7, 7)",
    "pg_typeof(1)",
    "lower('HELLO')",
    "upper('hello')",
    "initcap('hello world')",
    "length('hello')",
    "char_length('héllo')",
    "octet_length('héllo')",
    "bit_length('abc')",
    "substr('abcdef', 2, 3)",
    "substring('abcdef', 4)",
    "left('abcdef', 2)",
    "right('abcdef', 2)",
    "replace('banana', 'na', 'X')",
    "translate('12345', '135', 'abc')",
    "repeat('xy', 3)",
    "split_part('a,b,c', ',', 2)",
    "lpad('hi', 5, 'xy')",
    "rpad('hi', 5, 'xy')",
    "reverse('héllo')",
    "ascii('A')",
    "chr(65)",
    "md5('abc')",
    "quote_ident('select')",
    "quote_literal('a''b')",
    "concat('a', NULL::text, 'b')",
    "concat_ws('-', 'a', NULL::text, 'b')",
    "format('%s:%I:%L', 'v', 'user', 'x')",
    "strpos('abc', 'bc')",
    "starts_with('abcdef', 'abc')",
    "'a' || 'b'",
    "'2'::int4 + 3",
    "1 + '2'",
    "true AND NULL::boolean",
    "false OR NULL::boolean",
    "NULL::boolean IS UNKNOWN",
    "NULL::int4 IS DISTINCT FROM 1",
    "1 / 0",
])

def sql_quote(value):
    return "'" + value.replace("'", "''") + "'"

sql = [
    "CREATE TEMP TABLE corpus (id integer, expr text, result text);",
]
rows = []
for i, expr in enumerate(expressions, 1):
    rows.append(f"({i}, {sql_quote(expr)}, NULL)")
sql.append("INSERT INTO corpus VALUES " + ",\n".join(rows) + ";")
sql.append(r"""DO $$
DECLARE
    item record;
    result_text text;
BEGIN
    FOR item IN SELECT id, expr FROM corpus ORDER BY id LOOP
        BEGIN
            EXECUTE 'SELECT (' || item.expr || ')::text' INTO result_text;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS result_text = MESSAGE_TEXT;
            result_text := 'ERROR: ' || result_text;
        END;
        UPDATE corpus SET result = result_text WHERE id = item.id;
    END LOOP;
END
$$;""")
sql.append("SELECT expr, COALESCE(result, 'NULL') FROM corpus ORDER BY id;")
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(sql) + "\n")
PY

"$pg_bin/psql" -XAtq -F "$(printf '\t')" -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$port" -U "$(id -un)" -d postgres -f "$scratch/corpus.sql" > "$scratch/raw.tsv"
python3 - "$scratch/raw.tsv" "$script_dir" <<'PY'
import sys

raw_path, output_dir = sys.argv[1:]
scalar = []
strings = []
with open(raw_path, encoding="utf-8") as source:
    for line in source:
        expression, expected = line.rstrip("\n").split("\t", 1)
        if "'" in expression or any(name + "(" in expression for name in ("lower", "upper", "initcap", "length", "char_length", "octet_length", "bit_length", "substr", "substring", "left", "right", "replace", "translate", "repeat", "split_part", "lpad", "rpad", "reverse", "ascii", "chr", "md5", "quote_ident", "quote_literal", "concat", "concat_ws", "format", "position", "strpos", "starts_with")):
            strings.append(expression + "\t" + expected)
        else:
            scalar.append(expression + "\t" + expected)
if len(scalar) + len(strings) < 500:
    raise SystemExit("golden corpus unexpectedly contains fewer than 500 expressions")
for name, lines in (("golden_funcs_scalar.txt", scalar), ("golden_funcs_strings.txt", strings)):
    with open(output_dir + "/" + name, "w", encoding="utf-8") as target:
        target.write("\n".join(lines) + "\n")
print(f"generated {len(scalar) + len(strings)} PostgreSQL expressions ({len(scalar)} scalar, {len(strings)} string)")
PY
