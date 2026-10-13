#!/bin/sh
set -eu

# Generates types/testdata/golden_numeric.txt and golden_datetime.txt from a
# real PostgreSQL 17. Each line is "<expression>\t<result>" where <result> is
# psql's text output, "NULL", or "ERROR: <message>" for a failed expression.
# The expressions only use the subset understood by types/golden_types_test.tin.
#
# Usage: types/testdata/gen_types_golden.sh
# PG_BIN overrides the directory holding initdb/pg_ctl/psql (default /opt/homebrew/bin).

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pg_bin=${PG_BIN:-/opt/homebrew/bin}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tingres-types.XXXXXX")
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

numeric = []
datetime = []

def add(bucket, expr):
    bucket.append(expr)

# --- numeric: literals and literal typing ---
integers = ["0", "1", "-1", "2", "7", "42", "100", "-999", "32767", "-32768",
            "2147483647", "-2147483648", "9223372036854775807"]
decimals = ["0.0", "1.5", "-1.5", "1.50", "1.500", "0.001", "-0.001", ".5", "-.5",
            "12345678901234567890.5", "0.0000000001", "1000000000000.000"]
exponents = ["1e2", "1e-2", "-2.0e+4", "1.5e-3", "5E+3", "2.5e0"]
for v in integers + decimals + exponents:
    add(numeric, v)

# --- numeric: casts ---
casts = [
    "'12.340'::numeric", "'1e3'::numeric", "123::numeric", "-7::numeric",
    "'0.00'::numeric", "'abc'::numeric", "'12x'::numeric", "' 1'::numeric",
    "1.5::numeric(4,2)", "'123.456'::numeric(5,2)", "'999.99'::numeric(4,2)",
    "'0.005'::numeric(2,2)", "1.5::numeric(2,2)", "1::numeric::int4",
    "1.9::numeric::int4", "-1.9::numeric::int4", "1.5::numeric::float8",
    "1.5::numeric::float4", "100::numeric::int2", "40000::numeric::int2",
    "1e10::numeric::int4", "1e20::numeric::int8", "'32768'::int2", "'40000'::int2",
    "'9999999999'::int4", "'99999999999999999999'::int8", "'abc'::int4",
    "32767::int2", "32768::int4::int2", "100::int4::numeric", "-100::int8::numeric",
    "100::int4::float4", "100::int4::float8", "1.5::numeric::text",
    "1e20::float8", "1e-5::float8", "0.1::float4", "100.0::float8",
    "1e15::float8", "1e16::float8", "123456789.0::float8", "3.4028235e38::float4",
    "1.1754944e-38::float4", "'Infinity'::float8", "'-Infinity'::float8",
    "'NaN'::float8", "'-0'::float8", "1.0::float8::numeric", "0.1::float8::numeric",
    "1.9::float8::int4", "2.5::float8::int4", "-2.5::numeric::int4",
    "(-1.5)::float8", "'-2.5'::float8", "(-1e10)::float8", "(-0.5)::float4",
    "'-1.2345678901234567'::float8", "123456789012345.0::float8", "0.000123::float8",
    "(-3.4028235e38)::float4", "1e-4::float8", "1e-6::float8", "(-1.1754944e-38)::float4",
]
for e in casts:
    add(numeric, e)

# --- numeric: arithmetic over a value set ---
values = ["1", "2", "3", "7", "-2", "0.5", "1.5", "-2.25", "10", "0.001"]
for a in values:
    for b in values:
        for op in ["+", "-", "*", "/", "%"]:
            add(numeric, f"{a} {op} {b}")
        for op in ["=", "<>", "<"]:
            add(numeric, f"{a} {op} {b}")

# --- numeric: functions ---
for v in ["1", "2", "3", "10", "0.25", "2.5", "-3.75", "0", "100", "1e10"]:
    add(numeric, f"abs(({v})::numeric)")
    add(numeric, f"sign(({v})::numeric)")
    add(numeric, f"ceil(({v})::numeric)")
    add(numeric, f"floor(({v})::numeric)")
    add(numeric, f"round(({v})::numeric)")
    add(numeric, f"trunc(({v})::numeric)")
for v in ["1.2345", "-1.2345", "2.5", "-2.5", "1.005", "9.995"]:
    for s in ["0", "1", "2"]:
        add(numeric, f"round(({v})::numeric, {s})")
        add(numeric, f"trunc(({v})::numeric, {s})")
for a in ["10", "10.5", "-10.5", "7.5"]:
    for b in ["3", "2.5", "-3"]:
        add(numeric, f"mod(({a})::numeric, ({b})::numeric)")
for v in ["0", "1", "2", "4", "10", "0.25", "0.04", "0.5", "1e8", "1e-8"]:
    add(numeric, f"sqrt(({v})::numeric)")
for v in ["0", "1", "2", "-1", "0.5", "10", "-10"]:
    add(numeric, f"exp(({v})::numeric)")
for v in ["1", "2", "10", "100", "0.5", "0.1", "1000000"]:
    add(numeric, f"ln(({v})::numeric)")
for a, b in [("2", "3"), ("2", "10"), ("2", "-1"), ("9", "0.5"), ("2.5", "3"),
             ("0.5", "2"), ("10", "2"), ("3", "4")]:
    add(numeric, f"power(({a})::numeric, ({b})::numeric)")
for e in ["100000000000000000000::numeric / 7::numeric",
          "100000000000000000000::numeric % 7::numeric",
          "div(100000000000000000000::numeric, 7::numeric)",
          "(-100000000000000000000::numeric) / 7::numeric",
          "1::numeric / 100000000000000000000::numeric",
          "0.1::numeric + 0.2::numeric", "99999999999999999999::numeric + 1::numeric",
          "1e100::numeric", "1e-30::numeric", "2::numeric ^ 10::numeric",
          "mod(1.5::numeric, 0.7::numeric)", "3.7::numeric % 1.2::numeric"]:
    add(numeric, e)
for e in ["1::numeric/0", "1::numeric%0", "0::numeric - 0::numeric", "(-0)::numeric",
          "'NaN'::numeric + 1::numeric", "'Infinity'::numeric - 1::numeric"]:
    add(numeric, e)

# --- datetime: date ---
date_literals = [
    "'2024-01-31'::date", "'0001-01-01'::date", "'9999-12-31'::date",
    "'2024-02-29'::date", "'2023-02-29'::date", "'2024-13-01'::date",
    "'infinity'::date", "'-infinity'::date", "'epoch'::date",
    "'Jan 31, 2024'::date", "'01/31/2024'::date",
    "'2024-01-31'::text::date", "'abc'::date", "'2024-1-1'::date",
]
for e in date_literals:
    add(datetime, e)

# --- datetime: time / timetz ---
time_literals = [
    "'12:34:56'::time", "'12:34:56.789'::time", "'12:34:56.789000'::time",
    "'24:00:00'::time", "'00:00:00'::time", "'25:00:00'::time", "'12:30'::time",
    "'12:34:56.789+02'::timetz", "'12:34:56+00'::timetz", "'12:34:56-05:30'::timetz",
    "'12:34:56+02:00'::timetz",
]
for e in time_literals:
    add(datetime, e)

# --- datetime: timestamp / timestamptz ---
timestamp_literals = [
    "'2024-01-31 12:34:56'::timestamp", "'2024-01-31T12:34:56'::timestamp",
    "'2024-01-31 12:34:56.789'::timestamp", "'2024-01-31 12:34:56.789123'::timestamp",
    "'2000-01-01 00:00:00'::timestamp", "'1970-01-01 00:00:00'::timestamp",
    "'infinity'::timestamp", "'-infinity'::timestamp", "'epoch'::timestamp",
    "'2024-01-31 12:34:56+02'::timestamptz", "'2024-01-31 12:34:56Z'::timestamptz",
    "'2024-06-30 12:00:00'::timestamptz", "'2024-01-31 12:34:56.789+05:45'::timestamptz",
    "'bogus'::timestamp", "'2024-02-30 00:00:00'::timestamp",
]
for e in timestamp_literals:
    add(datetime, e)

# --- datetime: interval forms ---
interval_literals = [
    "'1 day 2 hours'::interval", "'-1 day 2 hours'::interval", "'1 year 2 mons'::interval",
    "'-1 year'::interval", "'14 mons'::interval", "'1 mon 15 days'::interval",
    "'1.5 years'::interval", "'1.5 mons'::interval", "'1.5 weeks'::interval",
    "'2.5 days'::interval", "'1.5 hours'::interval", "'1.5 minutes'::interval",
    "'1.5 seconds'::interval", "'-0.5 hours'::interval", "'0'::interval",
    "'1-2'::interval", "'2-3'::interval", "'@ 5 min'::interval",
    "'P1Y2M3DT4H5M6S'::interval", "'P1D'::interval", "'PT1H'::interval",
    "'2 days 3 hours 4 minutes 5 seconds'::interval", "'-2 days -3 hours'::interval",
    "'1 day -2 hours'::interval", "'1 year 2 mons 3 days 04:05:06.789'::interval",
    "'1 xyz'::interval", "'13 days'::interval", "'50 hours'::interval",
]
for e in interval_literals:
    add(datetime, e)

# --- datetime: casts between temporal types ---
temporal_casts = [
    "'2024-01-31'::date::timestamp", "'2024-01-31'::date::timestamptz",
    "'2024-01-31 12:00:00'::timestamp::date", "'2024-01-31 12:00:00'::timestamp::time",
    "'2024-01-31 12:00:00'::timestamp::timestamptz",
    "'2024-01-31 12:00:00+02'::timestamptz::timestamp",
    "'2024-01-31 12:00:00+02'::timestamptz::date",
    "'2024-01-31 12:00:00+02'::timestamptz::time",
    "'12:34:56'::time::timetz", "'12:34:56+02'::timetz::time",
    "'2024-01-31'::date::text", "'2024-01-31 12:00:00'::timestamp::text",
    "'1 day'::interval::text",
]
for e in temporal_casts:
    add(datetime, e)

# --- datetime: comparisons ---
dates = ["'2024-01-31'::date", "'2024-02-01'::date", "'2023-01-31'::date", "'2024-01-31'::date"]
timestamps = ["'2024-01-31 12:00:00'::timestamp", "'2024-01-31 13:00:00'::timestamp",
              "'2024-01-01 00:00:00'::timestamp"]
intervals = ["'1 day'::interval", "'2 days'::interval", "'-1 day'::interval"]
for i, a in enumerate(dates):
    for b in dates:
        for op in ["=", "<>", "<", "<=", ">", ">="]:
            add(datetime, f"{a} {op} {b}")
for a in timestamps:
    for b in timestamps:
        for op in ["<", "=", ">"]:
            add(datetime, f"{a} {op} {b}")
for a in intervals:
    for b in intervals:
        for op in ["<", "=", ">"]:
            add(datetime, f"{a} {op} {b}")

# --- datetime: arithmetic ---
for d in ["'2024-01-31'::date", "'2024-02-28'::date"]:
    for n in ["1", "-1", "30", "365"]:
        add(datetime, f"{d} + {n}")
        add(datetime, f"{d} - {n}")
add(datetime, "'2024-01-31'::date - '2024-01-01'::date")
for a, b in [("'2024-01-01 01:02:03'::timestamp", "'2024-01-02 03:04:05'::timestamp"),
             ("'2024-03-01 00:00:00'::timestamp", "'2024-01-31 12:00:00'::timestamp")]:
    add(datetime, f"{a} - {b}")
    add(datetime, f"{b} - {a}")
for ts in ["'2024-01-31 12:00:00'::timestamp", "'2024-02-29 12:00:00'::timestamp"]:
    for iv in ["'1 month'::interval", "'1 day'::interval", "'2 hours 30 minutes'::interval",
               "'-1 day'::interval"]:
        add(datetime, f"{ts} + {iv}")
        add(datetime, f"{ts} - {iv}")
for a in ["'1 day'::interval", "'1 month'::interval"]:
    for b in ["'2 hours'::interval", "'-1 day'::interval"]:
        add(datetime, f"{a} + {b}")
        add(datetime, f"{a} - {b}")
add(datetime, "-'1 day'::interval")
add(datetime, "-'1 month 2 days'::interval")

# --- datetime: date_part ---
part_sources = [
    "'2024-02-29'::date", "'2024-05-15'::date",
    "'2024-01-01 00:00:56.789'::timestamp", "'2024-07-04 13:14:15.123456'::timestamp",
    "'12:34:56.789'::time",
]
fields = ["year", "month", "day", "hour", "minute", "quarter", "dow", "isodow",
          "decade", "century", "millennium"]
for src in part_sources:
    for f in fields:
        add(datetime, f"date_part('{f}', {src})")
for src in ["'2024-01-01 00:00:56.789'::timestamp", "'2024-07-04 13:14:15.123456'::timestamp",
            "'12:34:56.789'::time"]:
    for f in ["second", "milliseconds", "microseconds", "epoch"]:
        add(datetime, f"date_part('{f}', {src})")

# --- datetime: date_trunc ---
for src in ["'2024-05-15 12:34:56.789'::timestamp", "'2024-01-01 00:00:00'::timestamp"]:
    for f in ["year", "quarter", "month", "week", "day", "hour", "minute", "second"]:
        add(datetime, f"date_trunc('{f}', {src})")

# --- datetime: age ---
ages = [
    ("'2024-03-01'::timestamp", "'2024-01-31'::timestamp"),
    ("'2024-01-31'::timestamp", "'2024-03-01'::timestamp"),
    ("'2024-02-29'::timestamp", "'2024-01-31'::timestamp"),
    ("'2024-01-01 01:02:03'::timestamp", "'2023-12-31 23:00:00'::timestamp"),
]
for a, b in ages:
    add(datetime, f"age({a}, {b})")

# --- datetime: make_date / make_timestamp ---
makers = [
    "make_date(2024, 1, 31)", "make_date(2024, 2, 29)", "make_date(2024, 13, 1)",
    "make_date(2024, 2, 30)", "make_date(2000, 12, 31)",
    "make_timestamp(2024, 1, 31, 12, 34, 56.789::float8)",
    "make_timestamp(2024, 2, 29, 0, 0, 0)",
]
for e in makers:
    add(datetime, e)

# --- datetime: to_char ---
char_cases = [
    ("'2024-01-31 12:34:56.789'::timestamp", "YYYY-MM-DD HH24:MI:SS.MS"),
    ("'2024-01-31 12:34:56.789'::timestamp", "HH12:MI:SS AM"),
    ("'2024-01-31 00:00:00'::timestamp", "HH12:MI AM"),
    ("'2024-01-31 12:34:56.789'::timestamp", "Mon DD, YYYY"),
    ("'2024-01-31 12:34:56.789'::timestamp", "Month"),
    ("'2024-01-31 12:34:56.789'::timestamp", "Day"),
    ("'2024-01-31 12:34:56.789'::timestamp", "Dy"),
    ("'2024-01-31 12:34:56.789'::timestamp", "HH24:MI:SS.US"),
    ("'2024-01-31'::date", "YYYY-MM-DD"),
    ("'2024-01-31'::date", "D"),
    ("'2024-07-04 23:59:59'::timestamp", "YYYY-MM-DD HH12:MI:SS AM"),
]
for src, pat in char_cases:
    add(datetime, f"to_char({src}, '{pat}')")

if len(numeric) < 300:
    raise SystemExit(f"numeric corpus too small: {len(numeric)}")
if len(datetime) < 300:
    raise SystemExit(f"datetime corpus too small: {len(datetime)}")

def sql_quote(value):
    return "'" + value.replace("'", "''") + "'"

def emit(bucket, name):
    sql = ["CREATE TEMP TABLE corpus (id integer, expr text, result text);"]
    rows = [f"({i}, {sql_quote(e)}, NULL)" for i, e in enumerate(bucket, 1)]
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
    return "\n".join(sql) + "\n"

open(sys.argv[1] + ".numeric", "w", encoding="utf-8").write(emit(numeric, "numeric"))
open(sys.argv[1] + ".datetime", "w", encoding="utf-8").write(emit(datetime, "datetime"))
print(f"numeric={len(numeric)} datetime={len(datetime)}")
PY

psql_run() {
	"$pg_bin/psql" -XAtq -F "$(printf '\t')" -v ON_ERROR_STOP=1 \
		-h 127.0.0.1 -p "$port" -U "$(id -un)" -d postgres \
		-c "SET TimeZone='UTC'" -c "SET DateStyle='ISO, MDY'" -f "$1"
}

psql_run "$scratch/corpus.sql.numeric" > "$scratch/numeric.tsv"
psql_run "$scratch/corpus.sql.datetime" > "$scratch/datetime.tsv"

python3 - "$scratch" "$script_dir" <<'PY'
import sys

scratch, output_dir = sys.argv[1:]
for name in ("numeric", "datetime"):
    lines = []
    with open(f"{scratch}/{name}.tsv", encoding="utf-8") as source:
        for line in source:
            line = line.rstrip("\n")
            if not line:
                continue
            expression, expected = line.split("\t", 1)
            lines.append(expression + "\t" + expected)
    if len(lines) < 300:
        raise SystemExit(f"{name} golden corpus has only {len(lines)} lines")
    with open(f"{output_dir}/golden_{name}.txt", "w", encoding="utf-8") as target:
        target.write("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} {name} expressions")
PY
