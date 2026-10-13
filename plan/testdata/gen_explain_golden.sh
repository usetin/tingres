#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pg_bin=${PG_BIN:-/opt/homebrew/bin}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tingres-explain.XXXXXX")
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

python3 - "$script_dir" "$pg_bin" "$port" <<'PY'
import sys, subprocess

out_dir, pg_bin, port = sys.argv[1:4]

setup_sql = """
CREATE TABLE users (id int PRIMARY KEY, name text, age int);
CREATE TABLE orders (id int PRIMARY KEY, user_id int, amount double precision);
CREATE TABLE products (id int PRIMARY KEY, title text, price double precision);
INSERT INTO users VALUES (1, 'Alice', 30), (2, 'Bob', 25), (3, 'Charlie', 40);
INSERT INTO orders VALUES (101, 1, 99.5), (102, 1, 150.0), (103, 2, 25.0);
INSERT INTO products VALUES (201, 'Book', 15.0), (202, 'Phone', 500.0);
ANALYZE users;
ANALYZE orders;
ANALYZE products;
"""
subprocess.run([f"{pg_bin}/psql", "-h", "127.0.0.1", "-p", port, "-U", subprocess.getoutput("id -un"), "-d", "postgres", "-c", setup_sql], check=True, stdout=subprocess.DEVNULL)

explain_queries = []
# Scans & filters
explain_queries.append("SELECT * FROM users")
explain_queries.append("SELECT id, name FROM users")
explain_queries.append("SELECT * FROM orders")
explain_queries.append("SELECT * FROM products")
explain_queries.append("SELECT * FROM users WHERE age > 21")
explain_queries.append("SELECT * FROM users WHERE age < 30")
explain_queries.append("SELECT * FROM users WHERE age >= 25")
explain_queries.append("SELECT * FROM users WHERE age <= 40")
explain_queries.append("SELECT * FROM users WHERE age = 30")
explain_queries.append("SELECT * FROM users WHERE age <> 30")
explain_queries.append("SELECT * FROM users WHERE name = 'Alice'")
explain_queries.append("SELECT * FROM users WHERE age > 20 AND age < 50")
explain_queries.append("SELECT * FROM users WHERE age < 20 OR age > 30")
explain_queries.append("SELECT * FROM users WHERE NOT age = 30")
explain_queries.append("SELECT * FROM users WHERE name IS NULL")
explain_queries.append("SELECT * FROM users WHERE name IS NOT NULL")
explain_queries.append("SELECT * FROM orders WHERE amount > 50.0")
explain_queries.append("SELECT * FROM orders WHERE amount < 200.0")
explain_queries.append("SELECT * FROM products WHERE price > 20.0")
explain_queries.append("SELECT * FROM products WHERE price <= 500.0")

# Index point lookups
explain_queries.append("SELECT * FROM users WHERE id = 1")
explain_queries.append("SELECT * FROM users WHERE id = 2")
explain_queries.append("SELECT name FROM users WHERE id = 1")
explain_queries.append("SELECT age FROM users WHERE id = 2")
explain_queries.append("SELECT * FROM orders WHERE id = 101")
explain_queries.append("SELECT * FROM orders WHERE id = 102")
explain_queries.append("SELECT * FROM products WHERE id = 201")
explain_queries.append("SELECT * FROM products WHERE id = 202")
explain_queries.append("SELECT id FROM users WHERE id = 3")
explain_queries.append("SELECT title, price FROM products WHERE id = 201")

# Joins
explain_queries.append("SELECT * FROM users JOIN orders ON users.id = orders.user_id")
explain_queries.append("SELECT users.name, orders.amount FROM users JOIN orders ON users.id = orders.user_id")
explain_queries.append("SELECT * FROM users u JOIN orders o ON u.id = o.user_id")
explain_queries.append("SELECT u.name, o.amount FROM users u JOIN orders o ON u.id = o.user_id WHERE u.age > 20")
explain_queries.append("SELECT u.name, o.amount FROM users u JOIN orders o ON u.id = o.user_id WHERE o.amount > 50.0")
explain_queries.append("SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id")
explain_queries.append("SELECT * FROM orders RIGHT JOIN users ON users.id = orders.user_id")
explain_queries.append("SELECT * FROM users CROSS JOIN products")
explain_queries.append("SELECT * FROM users u, orders o WHERE u.id = o.user_id")
explain_queries.append("SELECT u.name, p.title FROM users u CROSS JOIN products p WHERE u.id = 1")
for i in range(1, 16):
    explain_queries.append(f"SELECT u.name, o.amount FROM users u JOIN orders o ON u.id = o.user_id WHERE u.age >= {18 + i}")

# Aggregates & Group By
explain_queries.append("SELECT count(*) FROM users")
explain_queries.append("SELECT count(id) FROM users")
explain_queries.append("SELECT sum(age) FROM users")
explain_queries.append("SELECT avg(age) FROM users")
explain_queries.append("SELECT min(age) FROM users")
explain_queries.append("SELECT max(age) FROM users")
explain_queries.append("SELECT age, count(*) FROM users GROUP BY age")
explain_queries.append("SELECT age, count(id) FROM users GROUP BY age")
explain_queries.append("SELECT age, sum(id) FROM users GROUP BY age")
explain_queries.append("SELECT user_id, count(*), sum(amount) FROM orders GROUP BY user_id")
explain_queries.append("SELECT age, count(*) FROM users GROUP BY age HAVING count(*) > 0")
explain_queries.append("SELECT user_id, sum(amount) FROM orders GROUP BY user_id HAVING sum(amount) > 100.0")
for i in range(1, 9):
    explain_queries.append(f"SELECT age, max(id) FROM users WHERE age > {15 + i} GROUP BY age")

# Sort and Top-N Limit
explain_queries.append("SELECT * FROM users ORDER BY age")
explain_queries.append("SELECT * FROM users ORDER BY age DESC")
explain_queries.append("SELECT * FROM users ORDER BY name ASC")
explain_queries.append("SELECT * FROM users ORDER BY age, name")
explain_queries.append("SELECT * FROM users ORDER BY age LIMIT 1")
explain_queries.append("SELECT * FROM users ORDER BY age LIMIT 5")
explain_queries.append("SELECT * FROM users ORDER BY age DESC LIMIT 2")
explain_queries.append("SELECT * FROM orders ORDER BY amount DESC LIMIT 3")
explain_queries.append("SELECT * FROM products ORDER BY price LIMIT 2")
explain_queries.append("SELECT id, name FROM users ORDER BY name LIMIT 10")
explain_queries.append("SELECT * FROM users LIMIT 5")
explain_queries.append("SELECT * FROM users LIMIT 10 OFFSET 5")
explain_queries.append("SELECT * FROM orders LIMIT 2 OFFSET 1")
explain_queries.append("SELECT name FROM users ORDER BY id LIMIT 3")
explain_queries.append("SELECT * FROM users ORDER BY id DESC LIMIT 5")

# DML
explain_queries.append("INSERT INTO users VALUES (10, 'Dave', 28)")
explain_queries.append("INSERT INTO users (id, name) VALUES (11, 'Eve')")
explain_queries.append("INSERT INTO orders VALUES (104, 1, 75.0)")
explain_queries.append("INSERT INTO products VALUES (203, 'Watch', 120.0)")
explain_queries.append("UPDATE users SET age = 35 WHERE id = 1")
explain_queries.append("UPDATE users SET name = 'Bobby' WHERE id = 2")
explain_queries.append("UPDATE orders SET amount = 120.0 WHERE id = 101")
explain_queries.append("DELETE FROM users WHERE id = 3")
explain_queries.append("DELETE FROM orders WHERE id = 103")
explain_queries.append("DELETE FROM products WHERE id = 202")

golden_explain_rows = []
for q in explain_queries:
    res = subprocess.run([f"{pg_bin}/psql", "-XAtq", "-h", "127.0.0.1", "-p", port, "-U", subprocess.getoutput("id -un"), "-d", "postgres", "-c", f"EXPLAIN (COSTS OFF) {q}"], stdout=subprocess.PIPE, text=True)
    lines = [line.strip() for line in res.stdout.strip().split("\n") if line.strip()]
    root = lines[0] if lines else "Result"
    node_kind = root
    for prefix in ["Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Heap Scan", "Hash Join", "Nested Loop", "Merge Join", "Sort", "Limit", "HashAggregate", "GroupAggregate", "Aggregate", "Insert", "Update", "Delete", "Result", "Values Scan"]:
        if root.startswith(prefix):
            node_kind = prefix
            break
    golden_explain_rows.append(f"{q}\t{node_kind}\t{root}")

with open(f"{out_dir}/golden_explain.tsv", "w") as f:
    f.write("\n".join(golden_explain_rows) + "\n")
print(f"Generated {len(golden_explain_rows)} explain goldens in {out_dir}/golden_explain.tsv")
PY

chmod +x "$script_dir/gen_explain_golden.sh"
