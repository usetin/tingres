#!/usr/bin/env python3
"""Exercise concurrent PostgreSQL startup/query traffic against a built tingres."""

import concurrent.futures
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def exact(sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise EOFError("server closed a protocol connection early")
        data.extend(chunk)
    return bytes(data)


def message(sock):
    kind = exact(sock, 1)
    size = struct.unpack("!I", exact(sock, 4))[0]
    if size < 4:
        raise AssertionError(f"invalid backend message length {size}")
    return kind, exact(sock, size - 4)


def fields(payload):
    result = {}
    at = 0
    while at < len(payload) and payload[at] != 0:
        tag = chr(payload[at])
        end = payload.index(0, at + 1)
        result[tag] = payload[at + 1 : end].decode("utf-8", "replace")
        at = end + 1
    return result


class Client:
    def __init__(self, address, timeout=15):
        host, port_text = address.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port_text)), timeout=timeout)
        self.sock.settimeout(timeout)
        params = b"user\0postgres\0database\0postgres\0\0"
        startup = struct.pack("!II", len(params) + 8, 196608) + params
        self.sock.sendall(startup)
        while True:
            kind, payload = message(self.sock)
            if kind == b"E":
                error = fields(payload)
                self.sock.close()
                raise RuntimeError(f"startup rejected: {error}")
            if kind == b"Z":
                break

    def query_one(self):
        query = b"select 1\0"
        self.sock.sendall(b"Q" + struct.pack("!I", len(query) + 4) + query)
        saw_row = False
        saw_complete = False
        while True:
            kind, payload = message(self.sock)
            if kind == b"D":
                saw_row = payload.endswith(b"\0\0\0\x011")
            elif kind == b"C":
                saw_complete = payload == b"SELECT 1\0"
            elif kind == b"E":
                raise RuntimeError(f"query failed: {fields(payload)}")
            elif kind == b"Z":
                break
        if not saw_row or not saw_complete:
            raise AssertionError("SELECT 1 did not return its row and command tag")

    def close(self):
        try:
            self.sock.sendall(b"X\0\0\0\x04")
        except OSError:
            pass
        self.sock.close()


def wait_ready(address, process, log):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        try:
            c = Client(address, timeout=0.25)
            c.close()
            return
        except (OSError, EOFError, RuntimeError):
            time.sleep(0.05)
    log.flush()
    log.seek(0)
    raise RuntimeError("tingres did not become ready:\n" + log.read())


def launch(binary, directory, max_connections):
    listen_port = port()
    address = f"127.0.0.1:{listen_port}"
    log = tempfile.TemporaryFile(mode="w+")
    process = subprocess.Popen(
        [
            binary,
            "--data",
            os.path.join(directory, "data"),
            "--listen",
            address,
            "--auth",
            "trust",
            "--max-connections",
            str(max_connections),
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        wait_ready(address, process, log)
    except Exception:
        stop(process, log)
        raise
    return process, address, log


def stop(process, log):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    log.close()


def concurrency_run(binary):
    with tempfile.TemporaryDirectory(prefix="tingres-concurrency-") as directory:
        process, address, log = launch(binary, directory, 256)
        slow = Client(address)
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=200) as pool:
                futures = [pool.submit(query_client, address) for _ in range(200)]
                for future in futures:
                    future.result(timeout=30)
        finally:
            slow.close()
            stop(process, log)


def query_client(address):
    client = Client(address)
    try:
        client.query_one()
    finally:
        client.close()


def max_connection_run(binary):
    with tempfile.TemporaryDirectory(prefix="tingres-max-conns-") as directory:
        process, address, log = launch(binary, directory, 1)
        first = Client(address)
        second = None
        try:
            try:
                second = Client(address)
            except RuntimeError as error:
                if "'C': '53300'" not in str(error):
                    raise
            else:
                raise AssertionError("connection above --max-connections was accepted")
        finally:
            if second is not None:
                second.close()
            first.close()
            stop(process, log)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: concurrency.py PATH_TO_TINGRES")
    binary = os.path.abspath(sys.argv[1])
    concurrency_run(binary)
    max_connection_run(binary)
    print("PASS: 200 concurrent queries, idle-session isolation, and SQLSTATE 53300")


if __name__ == "__main__":
    main()
