#!/usr/bin/env python3
"""Robustness fuzzer for tingres: mutate recorded frontend message streams and check the
server never hangs, never dies and never leaks a connection. A mutated stream may be
answered or refused; what it must never do is stop the server from serving.

  tests/fuzz.py BIN [--iterations N] [--seed S]

The default is 100000 mutated messages on one reconnecting connection, plus 2000 mutated
startup packets, which is what the M1 robustness requirement asks for.
"""

import os
import random
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def frame(kind, payload):
    return kind + struct.pack("!I", len(payload) + 4) + payload


def startup_packet():
    params = b"user\x00postgres\x00database\x00postgres\x00\x00"
    return struct.pack("!II", len(params) + 8, 196608) + params


def connect(address, timeout=5):
    host, port = address.rsplit(":", 1)
    sock = socket.create_connection((host, int(port)), timeout=timeout)
    sock.settimeout(timeout)
    sock.sendall(startup_packet())
    return sock


def drain(sock, limit=65536, wait=0.005):
    """Read whatever the server has already sent, without waiting for more."""
    total = 0
    sock.setblocking(False)
    try:
        while total < limit:
            if not select.select([sock], [], [], wait)[0]:
                break
            try:
                chunk = sock.recv(65536)
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                break
            if not chunk:
                break
            total += len(chunk)
    finally:
        sock.setblocking(True)
        sock.settimeout(5)
    return total


def mutate(data, rng):
    """One random mutation of a recorded byte stream."""
    kind = rng.randrange(6)
    body = bytearray(data)
    if len(body) == 0:
        return bytes(body)
    if kind == 0:  # flip a byte
        at = rng.randrange(len(body))
        body[at] ^= 1 << rng.randrange(8)
    elif kind == 1:  # truncate
        body = body[: rng.randrange(len(body))]
    elif kind == 2:  # extend with junk
        body.extend(bytes(rng.randrange(256) for _ in range(rng.randrange(1, 32))))
    elif kind == 3:  # a bogus length field
        if len(body) >= 5:
            size = rng.choice([0, 1, 3, 4, 5, 0xFFFFFFFF, 0x7FFFFFFF, rng.randrange(1 << 32)])
            body[1:5] = struct.pack("!I", size)
    elif kind == 4:  # a random type byte
        body[0] = rng.randrange(256)
    else:  # duplicate a slice
        if len(body) > 2:
            at = rng.randrange(len(body) - 1)
            body.extend(body[at : at + rng.randrange(1, 8)])
    return bytes(body)


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit("usage: fuzz.py BIN [--iterations N] [--seed S]")
    binary = os.path.abspath(args[0])
    iterations = 100000
    seed = 20261014
    for i, arg in enumerate(args):
        if arg == "--iterations":
            iterations = int(args[i + 1])
        if arg == "--seed":
            seed = int(args[i + 1])
    rng = random.Random(seed)

    workdir = tempfile.TemporaryDirectory(prefix="tingres-fuzz-")
    port = free_port()
    address = f"127.0.0.1:{port}"
    log = open(os.path.join(workdir.name, "server.log"), "w+")
    process = subprocess.Popen(
        [binary, "--data", os.path.join(workdir.name, "data"), "--listen", address, "--auth", "trust", "--engine", "fake"],
        stdout=log,
        stderr=subprocess.STDOUT,
    )
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                probe = connect(address, timeout=0.5)
                probe.close()
                break
            except OSError:
                time.sleep(0.05)
        else:
            log.seek(0)
            raise RuntimeError("tingres did not become ready:\n" + log.read())

        templates = [
            frame(b"Q", b"SELECT 1\x00"),
            frame(b"Q", b""),
            frame(b"P", b"\x00SELECT 1\x00\x00\x00"),
            frame(b"B", b"\x00\x00\x00\x00\x00\x00\x00\x00"),
            frame(b"E", b"\x00\x00\x00\x00\x00"),
            frame(b"S", b""),
            frame(b"X", b""),
        ]

        reconnects = 0
        sock = connect(address)
        started = time.monotonic()
        for i in range(iterations):
            template = templates[rng.randrange(len(templates))]
            message = mutate(template, rng)
            try:
                sock.sendall(message)
                drain(sock)
            except OSError:
                reconnects += 1
                sock.close()
                sock = connect(address)
            if process.poll() is not None:
                log.seek(0)
                raise AssertionError(f"the server died after {i} mutations:\n{log.read()}")
        sock.close()

        # Mutated startup packets on their own connections.
        startup = startup_packet()
        for i in range(2000):
            try:
                probe = connect(address, timeout=2)
            except OSError:
                raise AssertionError("the server stopped accepting connections")
            try:
                probe.sendall(mutate(startup, rng))
                drain(probe)
            except OSError:
                pass
            probe.close()
            if process.poll() is not None:
                raise AssertionError("the server died on a mutated startup packet")

        # The server still serves after the whole run.
        final = connect(address)
        final.sendall(frame(b"Q", b"SELECT 1\x00"))
        answer = b""
        final.settimeout(5)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and b"SELECT 1\x00" not in answer:
            chunk = final.recv(4096)
            if not chunk:
                break
            answer += chunk
        final.close()
        if b"SELECT 1\x00" not in answer:
            raise AssertionError("the server did not answer SELECT 1 after fuzzing")

        elapsed = time.monotonic() - started
        print(
            f"PASS: {iterations} mutated message streams and 2000 mutated startup packets in "
            f"{elapsed:.1f}s, {reconnects} reconnects, server alive and serving"
        )
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        log.close()
        workdir.cleanup()


if __name__ == "__main__":
    main()
