#!/usr/bin/env python3
"""Protocol conformance tests for tingres, speaking the PostgreSQL v3 wire protocol
directly so the extended protocol, COPY, cancellation and shutdown are covered without a
driver in the way. The SQL used here is the conformance engine's subset; the point is the
protocol, not the SQL.
"""

import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

# --- wire helpers -----------------------------------------------------------


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("server closed the connection early")
        data.extend(chunk)
    return bytes(data)


def message(sock):
    kind = exact(sock, 1)
    size = struct.unpack("!I", exact(sock, 4))[0]
    if size < 4:
        raise AssertionError(f"invalid backend message length {size}")
    return kind, exact(sock, size - 4)


def fields(payload):
    out = {}
    at = 0
    while at < len(payload) and payload[at] != 0:
        tag = chr(payload[at])
        end = payload.index(0, at + 1)
        out[tag] = payload[at + 1 : end].decode("utf-8", "replace")
        at = end + 1
    return out


def frame(kind, payload):
    return kind + struct.pack("!I", len(payload) + 4) + payload


def cstring(text):
    return text.encode() + b"\x00"


STARTUP_PARAMS = b"user\x00postgres\x00database\x00postgres\x00\x00"


class Client:
    """One frontend connection."""

    def __init__(self, address, user="postgres", database="postgres", password=None, timeout=15):
        host, port = address.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port)), timeout=timeout)
        self.sock.settimeout(timeout)
        self.pid = 0
        self.secret = 0
        self.parameters = {}
        params = b"user\x00" + user.encode() + b"\x00database\x00" + database.encode() + b"\x00\x00"
        self.sock.sendall(struct.pack("!II", len(params) + 8, 196608) + params)
        self._authenticate(password)

    def _authenticate(self, password):
        while True:
            kind, payload = message(self.sock)
            if kind == b"R":
                code = struct.unpack("!I", payload[:4])[0]
                if code == 0:
                    continue
                if code == 3:  # cleartext
                    self.sock.sendall(frame(b"p", cstring(password or "")))
                    continue
                raise AssertionError(f"unsupported authentication request {code}")
            if kind == b"E":
                raise RuntimeError(f"startup rejected: {fields(payload)}")
            if kind == b"S":
                name, at = self._cstring(payload, 0)
                value, _ = self._cstring(payload, at)
                self.parameters[name] = value
                continue
            if kind == b"K":
                self.pid, self.secret = struct.unpack("!II", payload)
                continue
            if kind == b"Z":
                self.status = payload[0:1]
                return
            raise AssertionError(f"unexpected startup message {kind!r}")

    @staticmethod
    def _cstring(payload, at):
        end = payload.index(0, at)
        return payload[at:end].decode("utf-8", "replace"), end + 1

    def send(self, *frames):
        self.sock.sendall(b"".join(frames))

    def simple(self, sql):
        """Run a simple query, returning (messages, error)."""
        self.send(frame(b"Q", cstring(sql)))
        return self.collect()

    def collect(self, stop=b"Z"):
        """Read messages until stop (default ReadyForQuery); returns (list, error)."""
        out = []
        error = None
        while True:
            try:
                kind, payload = message(self.sock)
            except (EOFError, OSError):
                # The server closed the connection: keep whatever it sent before that.
                return out, error
            if kind == b"E":
                error = fields(payload)
            elif kind == b"N":
                out.append(("N", fields(payload)))
            elif kind == b"T":
                out.append(("T", self._row_description(payload)))
            elif kind == b"D":
                out.append(("D", self._data_row(payload)))
            elif kind == b"C":
                out.append(("C", payload[:-1].decode()))
            elif kind == b"S":
                name, at = self._cstring(payload, 0)
                value, _ = self._cstring(payload, at)
                out.append(("S", (name, value)))
            elif kind == b"K":
                self.pid, self.secret = struct.unpack("!II", payload)
            elif kind == b"1":
                out.append(("ParseComplete", None))
            elif kind == b"2":
                out.append(("BindComplete", None))
            elif kind == b"3":
                out.append(("CloseComplete", None))
            elif kind == b"n":
                out.append(("NoData", None))
            elif kind == b"s":
                out.append(("PortalSuspended", None))
            elif kind == b"t":
                count = struct.unpack("!H", payload[:2])[0]
                out.append(("ParameterDescription", list(struct.unpack(f"!{count}I", payload[2 : 2 + count * 4]))))
            elif kind == b"I":
                out.append(("EmptyQueryResponse", None))
            elif kind == b"G":
                out.append(("CopyInResponse", payload))
            elif kind == b"H":
                out.append(("CopyOutResponse", payload))
            elif kind == b"d":
                out.append(("CopyData", payload))
            elif kind == b"c":
                out.append(("CopyDone", None))
            elif kind == b"v":
                minor, count = struct.unpack("!II", payload[:8])
                out.append(("NegotiateProtocolVersion", (minor, count)))
            elif kind == stop:
                out.append((stop.decode(), payload))
                return out, error
            else:
                raise AssertionError(f"unexpected backend message {kind!r} {payload!r}")

    @staticmethod
    def _row_description(payload):
        count = struct.unpack("!H", payload[:2])[0]
        at = 2
        cols = []
        for _ in range(count):
            end = payload.index(0, at)
            name = payload[at:end].decode()
            at = end + 1
            table, attno, oid, size, mod, fmt = struct.unpack("!IHIhih", payload[at : at + 18])
            at += 18
            cols.append((name, oid, size, mod, fmt))
        return cols

    @staticmethod
    def _data_row(payload):
        count = struct.unpack("!H", payload[:2])[0]
        at = 2
        values = []
        for _ in range(count):
            size = struct.unpack("!i", payload[at : at + 4])[0]
            at += 4
            if size == -1:
                values.append(None)
                continue
            values.append(payload[at : at + size])
            at += size
        return values

    def close(self):
        try:
            self.sock.sendall(frame(b"X", b""))
        except OSError:
            pass
        self.sock.close()


def parse(name, sql, oids=()):
    payload = cstring(name) + cstring(sql) + struct.pack("!H", len(oids))
    for oid in oids:
        payload += struct.pack("!I", oid)
    return frame(b"P", payload)


def bind(portal, statement, values=(), formats=(), result_formats=()):
    payload = cstring(portal) + cstring(statement)
    payload += struct.pack("!H", len(formats)) + b"".join(struct.pack("!h", f) for f in formats)
    payload += struct.pack("!H", len(values))
    for value in values:
        if value is None:
            payload += struct.pack("!i", -1)
        else:
            payload += struct.pack("!i", len(value)) + value
    payload += struct.pack("!H", len(result_formats)) + b"".join(struct.pack("!h", f) for f in result_formats)
    return frame(b"B", payload)


def describe(kind, name):
    return frame(b"D", kind + cstring(name))


def execute(portal, max_rows=0):
    return frame(b"E", cstring(portal) + struct.pack("!I", max_rows))


def close_message(kind, name):
    return frame(b"C", kind + cstring(name))


SYNC = frame(b"S", b"")
FLUSH = frame(b"H", b"")


# --- server harness ---------------------------------------------------------


class Server:
    def __init__(self, binary, auth="trust", password="secret", extra=(), engine="fake", hba=None):
        self.dir = tempfile.TemporaryDirectory(prefix="tingres-protocol-")
        self.port = free_port()
        self.address = f"127.0.0.1:{self.port}"
        self.log = open(os.path.join(self.dir.name, "server.log"), "w+")
        data = os.path.join(self.dir.name, "data")
        os.makedirs(data, exist_ok=True)
        if hba is not None:
            with open(os.path.join(data, "pg_hba.conf"), "w") as handle:
                handle.write(hba)
        cmd = [
            binary,
            "--data",
            data,
            "--listen",
            self.address,
            "--auth",
            auth,
            "--engine",
            engine,
        ]
        cmd.extend(extra)
        cmd.extend(["--password", password])
        self.process = subprocess.Popen(cmd, stdout=self.log, stderr=subprocess.STDOUT)
        self.wait_ready()

    def wait_ready(self):
        """The server is ready once it answers a startup packet at all (any authentication
        request counts: the probe has no password)."""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                break
            try:
                probe = socket.create_connection(("127.0.0.1", self.port), timeout=0.5)
                probe.settimeout(0.5)
                probe.sendall(struct.pack("!II", len(STARTUP_PARAMS) + 8, 196608) + STARTUP_PARAMS)
                if probe.recv(4096):
                    probe.close()
                    return
                probe.close()
            except OSError:
                pass
            time.sleep(0.05)
        self.log.seek(0)
        raise RuntimeError("tingres did not become ready:\n" + self.log.read())

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.log.close()
        self.dir.cleanup()


def check(name, condition, detail=""):
    if not condition:
        raise AssertionError(f"{name}: {detail}")
    print(f"ok: {name}")


# --- the tests --------------------------------------------------------------

REPORTED = [
    "server_version",
    "server_encoding",
    "client_encoding",
    "application_name",
    "DateStyle",
    "IntervalStyle",
    "TimeZone",
    "integer_datetimes",
    "standard_conforming_strings",
    "scram_iterations",
    "in_hot_standby",
    "is_superuser",
    "session_authorization",
    "default_transaction_read_only",
    "default_transaction_deferrable",
]


def test_startup(address):
    client = Client(address)
    for name in REPORTED:
        check(f"ParameterStatus {name}", name in client.parameters, str(sorted(client.parameters)))
    check("BackendKeyData has a pid", client.pid != 0)
    check("server_version looks like PostgreSQL", client.parameters["server_version"].startswith("17"))
    client.close()


def test_simple(address):
    client = Client(address)
    out, err = client.simple("SELECT 1; SELECT 2")
    tags = [value for kind, value in out if kind == "C"]
    check("multi-statement Query gives one result per statement", tags == ["SELECT 1", "SELECT 1"], str(out))
    check("no error in a multi-statement Query", err is None, str(err))

    out, err = client.simple(";")
    check("empty query answers EmptyQueryResponse", ("EmptyQueryResponse", None) in out, str(out))

    out, err = client.simple("SELECT 1; SELECT 2 FROM t; SELECT 3")
    tags = [value for kind, value in out if kind == "C"]
    check("an error aborts the rest of a simple query", tags == ["SELECT 1"], str(out))
    check("the error carries 0A000", err is not None and err["C"] == "0A000", str(err))
    check("ReadyForQuery follows the error", out[-1][0] == "Z", str(out))
    client.close()


def test_transaction_status(address):
    client = Client(address)
    out, _ = client.simple("BEGIN")
    check("BEGIN reports T", out[-1][1] == b"T", str(out))
    out, _ = client.simple("COMMIT")
    check("COMMIT reports I", out[-1][1] == b"I", str(out))
    out, _ = client.simple("BEGIN; BEGIN")
    check("a repeated BEGIN is a NOTICE", any(kind == "N" for kind, _ in out), str(out))
    out, _ = client.simple("ROLLBACK")
    check("ROLLBACK reports I", out[-1][1] == b"I", str(out))
    client.close()


def test_extended(address):
    client = Client(address)
    client.send(parse("stmt", "SELECT $1::int4", [23]), describe(b"S", "stmt"), SYNC)
    out, err = client.collect()
    check("Parse answers ParseComplete", ("ParseComplete", None) in out, str(out))
    check("Describe answers ParameterDescription", any(kind == "ParameterDescription" for kind, _ in out), str(out))
    check("Describe answers RowDescription", any(kind == "T" for kind, _ in out), str(out))
    check("no error in Parse/Describe", err is None, str(err))

    client.send(bind("portal", "stmt", [b"42"]), describe(b"P", "portal"), execute("portal"), SYNC)
    out, err = client.collect()
    rows = [value for kind, value in out if kind == "D"]
    check("Bind/Execute returns the bound parameter", rows == [[b"42"]], str(out))
    check("Bind answers BindComplete", ("BindComplete", None) in out, str(out))
    check("Execute answers CommandComplete", ("C", "SELECT 1") in out, str(out))
    check("no error in Bind/Execute", err is None, str(err))

    # Pipelining: every message of the cycle in one write.
    client.send(parse("p2", "SELECT 7", []), bind("c2", "p2"), describe(b"P", "c2"), execute("c2"), SYNC)
    out, err = client.collect()
    order = [kind for kind, _ in out]
    check("pipelined cycle arrives in order", order[:3] == ["ParseComplete", "BindComplete", "T"], str(order))
    check("pipelined cycle ends with ReadyForQuery", order[-1] == "Z", str(order))

    # Close, and the unnamed statement lifetime.
    client.send(close_message(b"S", "stmt"), close_message(b"P", "portal"), SYNC)
    out, _ = client.collect()
    check("Close answers CloseComplete twice", [k for k, _ in out].count("CloseComplete") == 2, str(out))
    client.send(parse("", "SELECT 9", []), bind("", ""), execute(""), SYNC)
    out, err = client.collect()
    check("the unnamed statement works", ("C", "SELECT 1") in out and err is None, str(out))
    client.close()


def test_error_skip_until_sync(address):
    client = Client(address)
    client.send(parse("bad", "SELECT 1 +", []), bind("b", "bad"), execute("b"), SYNC)
    out, err = client.collect()
    kinds = [kind for kind, _ in out]
    check("an extended-protocol error is reported", err is not None and err["C"] == "0A000", str(err))
    check("messages after the error are skipped until Sync", kinds == ["Z"], str(kinds))

    # The connection is usable again after Sync.
    out, err = client.simple("SELECT 1")
    check("the connection recovers after Sync", err is None and ("C", "SELECT 1") in out, str(out))
    client.close()


def test_describe_errors(address):
    client = Client(address)
    client.send(describe(b"S", "missing"), SYNC)
    out, err = client.collect()
    check("Describe of a missing statement is 26000", err is not None and err["C"] == "26000", str(err))
    client.send(execute("missing"), SYNC)
    out, err = client.collect()
    check("Execute of a missing portal is 34000", err is not None and err["C"] == "34000", str(err))
    client.close()


def test_protocol_violation(address):
    client = Client(address)
    client.send(frame(b"Z", b""))  # not a frontend message type
    try:
        out, err = client.collect()
    except EOFError:
        out, err = [], None
    check("an unknown message type is 08P01", err is not None and err["C"] == "08P01", str(err) + str(out))
    # PostgreSQL closes the connection after a protocol violation.
    try:
        client.sock.settimeout(2)
        rest = client.sock.recv(1)
    except OSError:
        rest = b""
    check("the connection closes after a protocol violation", rest == b"", repr(rest))
    client.sock.close()


def test_negotiate_protocol_version(address):
    sock = socket.create_connection(("127.0.0.1", int(address.rsplit(":", 1)[1])), timeout=5)
    params = b"user\x00postgres\x00_pq_.future\x001\x00\x00"
    sock.sendall(struct.pack("!II", len(params) + 8, 196610) + params)
    kind, payload = message(sock)
    check("protocol 3.2 gets NegotiateProtocolVersion", kind == b"v", repr(kind))
    minor, count = struct.unpack("!II", payload[:8])
    check("the negotiated minor version is 0", minor == 0, str(minor))
    check("the unsupported _pq_ option is listed", count == 1 and payload[8:].startswith(b"_pq_.future"), repr(payload))
    sock.close()


def test_copy_out(address):
    client = Client(address)
    client.send(parse("cp", "COPY (SELECT 1) TO STDOUT", []), bind("cpp", "cp"), describe(b"P", "cpp"), execute("cpp"), SYNC)
    out, err = client.collect()
    kinds = [kind for kind, _ in out]
    check("COPY TO STDOUT answers NoData on Describe", "NoData" in kinds, str(kinds))
    check("COPY TO STDOUT streams CopyOutResponse and CopyDone", "CopyOutResponse" in kinds and "CopyDone" in kinds, str(kinds))
    data = [value for kind, value in out if kind == "CopyData"]
    check("COPY TO STDOUT streams the row", data == [b"1\n"], repr(data))
    check("COPY TO STDOUT ends with a tag", ("C", "COPY 1") in out, str(out))
    check("no error in COPY TO", err is None, str(err))
    client.close()


def test_cancel(address):
    """A CancelRequest must reach the running statement and raise 57014."""
    client = Client(address)
    client.sock.settimeout(20)
    client.send(frame(b"Q", cstring("SELECT pg_sleep(5)")))
    time.sleep(0.4)
    cancel = socket.create_connection(("127.0.0.1", int(address.rsplit(":", 1)[1])), timeout=5)
    cancel.sendall(struct.pack("!III", 16, 80877102, client.pid) + struct.pack("!I", client.secret))
    cancel.close()
    started = time.monotonic()
    out, err = client.collect()
    elapsed = time.monotonic() - started
    check("a cancelled statement raises 57014", err is not None and err["C"] == "57014", str(err))
    check("cancellation stops the statement early", elapsed < 4.0, f"{elapsed:.2f}s")
    out, err = client.simple("SELECT 1")
    check("the session works after a cancellation", err is None and ("C", "SELECT 1") in out, str(out))
    client.close()


def test_wrong_cancel_secret(address):
    client = Client(address)
    client.sock.settimeout(20)
    client.send(frame(b"Q", cstring("SELECT pg_sleep(2)")))
    time.sleep(0.3)
    cancel = socket.create_connection(("127.0.0.1", int(address.rsplit(":", 1)[1])), timeout=5)
    cancel.sendall(struct.pack("!III", 16, 80877102, client.pid) + struct.pack("!I", 12345))
    cancel.close()
    out, err = client.collect()
    check("a cancel with a wrong secret is ignored", err is None and ("C", "SELECT 1") in out, str(err))
    client.close()


def test_max_connections(address):
    server = Server(sys.argv[1], extra=["--max-connections", "1"])
    try:
        first = Client(server.address)
        try:
            Client(server.address)
            raise AssertionError("a connection above --max-connections was accepted")
        except RuntimeError as error:
            check("--max-connections answers 53300", "'C': '53300'" in str(error), str(error))
        first.close()
    finally:
        server.stop()


def test_auth(binary):
    """trust, password, md5 and scram-sha-256 through psql, plus pg_hba.conf rules."""
    psql = os.environ.get("PSQL", "/opt/homebrew/bin/psql")
    if not os.path.exists(psql):
        print("skip: psql not found, authentication not tested")
        return
    for method in ["trust", "password", "md5", "scram-sha-256"]:
        server = Server(binary, auth=method)
        try:
            env = dict(os.environ)
            env["PGPASSWORD"] = "secret" if method != "trust" else ""
            env["PGSSLMODE"] = "disable"
            ok = subprocess.run(
                [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=disable", "-XAtc", "SELECT 1"],
                capture_output=True,
                env=env,
                timeout=20,
            )
            check(f"psql connects with {method} auth", ok.returncode == 0 and ok.stdout.strip() == b"1", ok.stderr.decode())
            if method != "trust":
                env["PGPASSWORD"] = "wrong"
                bad = subprocess.run(
                    [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=disable", "-XAtc", "SELECT 1"],
                    capture_output=True,
                    env=env,
                    timeout=20,
                )
                check(f"{method} auth rejects a wrong password", bad.returncode != 0, bad.stdout.decode())
        finally:
            server.stop()

    # pg_hba.conf decides the method per rule, and an unmatched connection is refused.
    server = Server(binary, auth="trust", hba="host all all 127.0.0.1/32 md5\n")
    try:
        env = dict(os.environ)
        env["PGPASSWORD"] = "secret"
        out = subprocess.run(
            [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=disable", "-XAtc", "SELECT 1"],
            capture_output=True,
            env=env,
            timeout=20,
        )
        check("pg_hba md5 rule accepts the right password", out.returncode == 0 and out.stdout.strip() == b"1", out.stderr.decode())
        env["PGPASSWORD"] = ""
        out = subprocess.run(
            [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=disable", "-XAtc", "SELECT 1"],
            capture_output=True,
            env=env,
            timeout=20,
        )
        check("pg_hba md5 rule rejects a missing password", out.returncode != 0, out.stdout.decode())
        out = subprocess.run(
            [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=disable", "-XAtc", "SELECT 1"],
            capture_output=True,
            env=env,
            timeout=20,
        )
        check("a connection with no matching pg_hba rule is refused", out.returncode != 0, out.stdout.decode())
    finally:
        server.stop()
    # A rule for another network leaves the connection unmatched.
    server = Server(binary, auth="trust", hba="host all all 10.0.0.0/8 trust\n")
    try:
        env = dict(os.environ)
        env["PGPASSWORD"] = "secret"
        out = subprocess.run(
            [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=disable", "-XAtc", "SELECT 1"],
            capture_output=True,
            env=env,
            timeout=20,
        )
        check("a rule for another network leaves 127.0.0.1 unmatched", out.returncode != 0, out.stdout.decode())
    finally:
        server.stop()


def test_tls(binary):
    psql = os.environ.get("PSQL", "/opt/homebrew/bin/psql")
    openssl = "/opt/homebrew/bin/openssl"
    if not os.path.exists(psql) or not os.path.exists(openssl):
        print("skip: psql or openssl not found, TLS not tested")
        return
    workdir = tempfile.mkdtemp(prefix="tingres-tls-")
    cert = os.path.join(workdir, "cert.pem")
    key = os.path.join(workdir, "key.pem")
    subprocess.run(
        [openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost"],
        capture_output=True,
        check=True,
    )
    server = Server(binary, extra=["--tls-cert", cert, "--tls-key", key])
    try:
        out = subprocess.run(
            [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=require", "-XAtc", "SELECT 1"],
            capture_output=True,
            timeout=20,
        )
        check("psql connects with sslmode=require", out.returncode == 0 and out.stdout.strip() == b"1", out.stderr.decode())
        out = subprocess.run(
            [psql, f"host=127.0.0.1 port={server.port} user=postgres dbname=postgres sslmode=require", "-XAtc", "SELECT 1"],
            capture_output=True,
            timeout=20,
        )
        check("a TLS connection reports no error", b"error" not in out.stderr.lower(), out.stderr.decode())
    finally:
        server.stop()


def test_shutdown(binary):
    marker_dir = tempfile.mkdtemp(prefix="tingres-shutdown-")
    marker = os.path.join(marker_dir, "stop")
    server = Server(binary, extra=["--shutdown-file", marker])
    try:
        client = Client(server.address)
        open(marker, "w").close()
        time.sleep(1.5)  # the accept loop notices the marker on its liveness tick
        # The next message sees the shutdown and answers 57P01.
        out, err = client.simple("SELECT 1")
        check("a session sees the shutdown as 57P01", err is not None and err["C"] == "57P01", str(err))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and server.process.poll() is None:
            time.sleep(0.1)
        check("the server exits 0 on shutdown", server.process.poll() == 0, str(server.process.poll()))
    finally:
        server.stop()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: protocol.py PATH_TO_TINGRES")
    binary = os.path.abspath(sys.argv[1])
    server = Server(binary)
    try:
        test_startup(server.address)
        test_simple(server.address)
        test_transaction_status(server.address)
        test_extended(server.address)
        test_error_skip_until_sync(server.address)
        test_describe_errors(server.address)
        test_protocol_violation(server.address)
        test_negotiate_protocol_version(server.address)
        test_copy_out(server.address)
        test_cancel(server.address)
        test_wrong_cancel_secret(server.address)
    finally:
        server.stop()
    test_max_connections(binary)
    test_auth(binary)
    test_tls(binary)
    test_shutdown(binary)
    print("PASS: protocol conformance (simple, extended, COPY, cancel, shutdown, auth, TLS)")


if __name__ == "__main__":
    main()
