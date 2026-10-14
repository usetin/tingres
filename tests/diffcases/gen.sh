#!/bin/sh
# Generates tests/diffcases/*.sql: the directory the differential runner (tests/diff.sh)
# replays on a scratch PostgreSQL and on tingres and compares line by line. Every case is a
# statement the conformance engine answers with the same *values* PostgreSQL answers with;
# a case that cannot match yet is listed in tests/known_diffs.txt with its reason, and the
# runner fails on a difference that is in neither group.
#
#   tests/diffcases/gen.sh          rewrite the corpus
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
rm -f "$DIR"/*.sql

write() {
	printf '%s\n' "$2" >"$DIR/$1.sql"
}

i=0
# integer and float literals, plain and cast
for value in 0 1 -1 42 -42 2147483647 -2147483648 1000000 7 999 123456789; do
	i=$((i + 1))
	write "int_$i" "SELECT $value;"
done
# A cast binds tighter than unary minus in PostgreSQL, so only non-negative literals are cast.
for value in 0 1 42 2147483647 1000000 7 999 123456789; do
	i=$((i + 1))
	write "int4_cast_$i" "SELECT $value::int4;"
done
for value in 0.5 -0.25 3.14159 1e10 2.5 100.0; do
	i=$((i + 1))
	write "float_$i" "SELECT $value;"
done
for value in 1 42 -7; do
	i=$((i + 1))
	write "int8_cast_$i" "SELECT '$value'::int8;"
done
for value in 1 42 -7; do
	i=$((i + 1))
	write "int4_text_$i" "SELECT '$value'::int4;"
done
for value in 1.5 2.25; do
	i=$((i + 1))
	write "float8_cast_$i" "SELECT '$value'::float8;"
done
for value in 1 42; do
	i=$((i + 1))
	write "numeric_cast_$i" "SELECT '$value'::numeric;"
done

# strings, aliases and quoting
write str_plain "SELECT 'hello';"
write str_empty "SELECT '';"
write str_quote "SELECT 'it''s';"
write str_unicode "SELECT 'héllo wörld';"
write str_alias "SELECT 'value' AS answer;"
write str_multi "SELECT 'a' AS x, 'b' AS y, 'c' AS z;"
write str_digits "SELECT '0123';"
write str_spaces "SELECT 'a  b';"
write str_newline_literal "SELECT 'line';"
write str_escaped_quote "SELECT 'don''t';"

# several statements in one simple query
write multi_two "SELECT 1; SELECT 2;"
write multi_three "SELECT 1; SELECT 2; SELECT 3;"
write multi_alias "SELECT 1 AS a; SELECT 'x' AS b;"
write multi_empty_middle "SELECT 1;;SELECT 2;"
write multi_semicolon_only ";"
write multi_trailing "SELECT 7;"
write multi_tabs "SELECT 1;\tSELECT 2;"
write multi_mixed "SELECT 1; SELECT 'two'; SELECT 3.5;"

# transaction control and session settings produce no rows in -At mode
write txn_begin_commit "BEGIN; SELECT 1; COMMIT;"
write txn_rollback "BEGIN; SELECT 1; ROLLBACK;"
write txn_start "START TRANSACTION; SELECT 2; COMMIT;"
write txn_end "BEGIN; SELECT 3; END;"
write txn_abort "BEGIN; SELECT 4; ABORT;"
write guc_set "SET search_path = public;"
write guc_set_then_select "SET search_path = public; SELECT 1;"
write guc_reset "RESET search_path;"
write guc_set_client_encoding "SET client_encoding = 'UTF8';"
write guc_set_datestyle "SET datestyle = 'ISO, MDY';"
write show_search_path "SHOW search_path;"
write show_timezone "SHOW timezone;"
write show_datestyle "SHOW datestyle;"
write show_intervalstyle "SHOW intervalstyle;"
write show_client_encoding "SHOW client_encoding;"
write show_standard_conforming "SHOW standard_conforming_strings;"
write show_server_encoding "SHOW server_encoding;"
write show_integer_datetimes "SHOW integer_datetimes;"
write show_is_superuser "SHOW is_superuser;"
write show_extra_float_digits "SHOW extra_float_digits;"

# value functions
write fn_current_user "SELECT current_user;"
write fn_session_user "SELECT session_user;"
write fn_current_database "SELECT current_database();"
write fn_current_schema "SELECT current_schema();"
write fn_current_setting "SELECT current_setting('search_path');"
write fn_pg_backend_pid_is_int "SELECT pg_backend_pid() > 0;"
write fn_generate_series_1 "SELECT generate_series(1, 5);"
write fn_generate_series_2 "SELECT generate_series(0, 0);"
write fn_generate_series_3 "SELECT generate_series(-2, 2);"
write fn_generate_series_multi "SELECT generate_series(1, 3) AS n, 'x' AS label;"
write fn_generate_series_empty "SELECT generate_series(1, 0);"

# COPY TO STDOUT
write copy_text "COPY (SELECT 1) TO STDOUT;"
write copy_text_two "COPY (SELECT 1, 2) TO STDOUT;"
write copy_csv "COPY (SELECT 1, 'a') TO STDOUT WITH CSV;"
write copy_csv_header "COPY (SELECT 1, 'a') TO STDOUT WITH (FORMAT csv, HEADER);"
write copy_series "COPY (SELECT generate_series(1, 3)) TO STDOUT;"
write copy_string "COPY (SELECT 'text') TO STDOUT;"

# literals in a result set with several columns
write row_three "SELECT 1, 2, 3;"
write row_mixed "SELECT 1, 'two', 3.5;"
write row_alias_mixed "SELECT 1 AS a, 'b' AS b, true AS c;"
write row_bool_true "SELECT true;"
write row_bool_false "SELECT false;"
write row_bool_alias "SELECT true AS yes, false AS no;"

# empty and whitespace-only queries
write empty_space "   "
write empty_newline "SELECT 1;
"
write empty_comment_only "-- just a comment"
write empty_semicolons ";;;"

ls "$DIR"/*.sql | wc -l | tr -d ' ' | xargs echo "diffcases written:"
