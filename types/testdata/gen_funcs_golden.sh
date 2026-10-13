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

python3 - "$scratch/corpus.sql" "$scratch/extras.txt" <<'PY'
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

extras = [
    "1.5::numeric + 2",
    "1.5::numeric * 2",
    "1.50::numeric + 2.5",
    "7.5::numeric / 2",
    "5.5::numeric % 2",
    "1.0::numeric / 3",
    "2.50::numeric % 0.7",
    "-7.5::numeric / 2",
    "7.5::numeric % -2",
    "0.001::numeric / 3",
    "0.0::numeric / 0.5",
    "1.5::numeric % 0.4",
    "0.00000001::numeric / 3",
    "mod(5.5::numeric, 2::numeric)",
    "div(5.5::numeric, 2::numeric)",
    "-5.5::numeric % 2",
    "1.5::numeric = 1.50",
    "1.5::numeric < 2::numeric",
    "round(1.5::numeric)",
    "round(-1.5::numeric)",
    "round(1.55::numeric, 1)",
    "trunc(1.99::numeric)",
    "trunc(2.55::numeric, 1)",
    "ceil(1.2::numeric)",
    "floor(-1.2::numeric)",
    "sign(-3.5::numeric)",
    "abs(-1.5::numeric)",
    "to_hex(255)",
    "to_hex(-1::int4)",
    "to_hex(-1::int8)",
    "1.5::numeric / 0",
    "1::int2 + 32767::int2",
    "chr(0)",
    "chr(-1)",
    "chr(1114112)",
    "chr(55296)",
    "split_part('a,b', ',', 0)",
    "decode('zz', 'hex')",
    "decode('!!', 'base64')",
    "encode('\\x01'::bytea, 'nope')",
    "format('%s')",
    "format('%d', 1)",
    "format('%')",
    "lpad('hi', 5)",
    "rpad('hi', 5)",
    "trim('  x  ')",
    "left('abc', -1)",
    "right('abc', -1)",
    "substring('abcdef', 2, 3)",
    "split_part('a,b,c', ',', -1)",
    "btrim('  x  ')",
    "ltrim('xxabc', 'x')",
    "rtrim('abcxx', 'x')",
    "quote_ident('')",
    "quote_ident('A')",
    "overlay('abcdef', 'XY', 3)",
    "get_byte('\\x0102'::bytea, 0)",
    "get_byte('\\x0102'::bytea, 5)",
    "set_byte('\\x0102'::bytea, 1, 255)",
    "set_byte('\\x01'::bytea, 0, 256)",
    "get_bit('\\x01'::bytea, 0)",
    "get_bit('\\x80'::bytea, 0)",
    "get_bit('\\x0102'::bytea, 16)",
    "set_bit('\\x00'::bytea, 3, 1)",
    "set_bit('\\xff'::bytea, 0, 0)",
    "md5('\\x00ff'::bytea)",
    "md5('\\x'::bytea)",
    "sha256('\\x'::bytea)",
    "length('\\x0102'::bytea)",
    "octet_length('\\x0102'::bytea)",
    "substring('\\x01020304'::bytea, 2, 2)",
    "'\\x0102'::bytea || '\\x03'::bytea",
    "'abc' LIKE 'a%'",
    "'abc' ILIKE 'A%'",
    "'abc' NOT LIKE 'x%'",
    "'abc123' SIMILAR TO 'abc%'",
    "'abc' ~ '^a'",
    "'abc' ~* '^A'",
    "'abc' !~ '^b'",
    "regexp_replace('foobarbaz', 'b', 'X', 'g')",
    "regexp_replace('foobar', '(o+)', '<\\1>')",
    "regexp_replace('a1 b2', '[0-9]', 'X')",
    "regexp_match('foobar', 'o')",
    "regexp_match('foobar', '(o)(o)')",
    "regexp_match('foobar', '(o)?x')",
    "regexp_match('foobar', 'O', 'i')",
    "regexp_match('foobar', 'O', 'c')",
    "regexp_match('foobar', 'o', 'g')",
    "regexp_matches('foobarbequebaz', '(b.)(.*)', 'g')",
    "regexp_split_to_array('the quick brown', '\\s+')",
    "regexp_split_to_array('a,b,,c', ',')",
    "regexp_split_to_array('abc', '')",
    "regexp_split_to_array('', 'x')",
    "regexp_like('abc', 'b')",
    "regexp_like('abc', 'B', 'i')",
    "substring('foobar', 'o(b)')",
    "regexp_match('a', 'a', 'z')",
    "'2024-01-02'::date < '2024-01-03'::date",
    "'2024-01-02 10:00'::timestamp <= '2024-01-03'::timestamp",
    "'10:00'::time < '12:00'::time",
    "'1 day'::interval < '2 days'::interval",
    "sqrt(2::float8)",
    "power(2::float8, 10)",
    "round(2.5::float8)",
    "round(3.5::float8)",
    "trunc(1.99::float8)",
    "ceil(1.2::float8)",
    "floor(-1.2::float8)",
    "log(100::float8)",
    "ln(1::float8)",
    "exp(0::float8)",
    "sin(0::float8)",
    "cos(0::float8)",
    "pi()",
    "degrees(pi())",
    "radians(180::float8)",
]
extra_exprs = set(extras)
expressions.extend(extras)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(extras) + "\n")


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
python3 - "$scratch/raw.tsv" "$script_dir" "$scratch/extras.txt" <<'PY'
import sys

raw_path, output_dir, extras_path = sys.argv[1:]
extra_exprs = set(open(extras_path, encoding="utf-8").read().split("\n"))
scalar = []
strings = []
extras = []
with open(raw_path, encoding="utf-8") as source:
    for line in source:
        expression, expected = line.rstrip("\n").split("\t", 1)
        if expression in extra_exprs:
            extras.append(expression + "\t" + expected)
        elif "'" in expression or any(name + "(" in expression for name in ("lower", "upper", "initcap", "length", "char_length", "octet_length", "bit_length", "substr", "substring", "left", "right", "replace", "translate", "repeat", "split_part", "lpad", "rpad", "reverse", "ascii", "chr", "md5", "quote_ident", "quote_literal", "concat", "concat_ws", "format", "position", "strpos", "starts_with")):
            strings.append(expression + "\t" + expected)
        else:
            scalar.append(expression + "\t" + expected)
if len(scalar) + len(strings) + len(extras) < 500:
    raise SystemExit("golden corpus unexpectedly contains fewer than 500 expressions")
for name, lines in (("golden_funcs_scalar.txt", scalar), ("golden_funcs_strings.txt", strings), ("golden_funcs_extras.txt", extras)):
    with open(output_dir + "/" + name, "w", encoding="utf-8") as target:
        target.write("\n".join(lines) + "\n")
print(f"generated {len(scalar) + len(strings) + len(extras)} PostgreSQL expressions ({len(scalar)} scalar, {len(strings)} string, {len(extras)} extras)")
PY
