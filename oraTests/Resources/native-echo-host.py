#!/usr/bin/env python3
"""Fixture Native Messaging Host for integration tests.

Speaks Chrome's stdio protocol (native-endian uint32 length + UTF-8 JSON) and
echoes every message back as {"echo": <message>, "origin": <argv[1]>}.
A message {"exit": true} makes the host exit on its own (self-exit path).
A message {"close_stdin": true} makes the host close its stdin but keep
running (acks with {"stdin_closed": true}) — the browser's next write then
hits a closed pipe read end while the process is still alive.
"""
import json
import os
import struct
import sys
import time


def read_message():
    raw_length = sys.stdin.buffer.read(4)
    if len(raw_length) < 4:
        return None
    (length,) = struct.unpack("=I", raw_length)
    payload = sys.stdin.buffer.read(length)
    if len(payload) < length:
        return None
    return json.loads(payload.decode("utf-8"))


def write_message(message):
    payload = json.dumps(message).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("=I", len(payload)))
    sys.stdout.buffer.write(payload)
    sys.stdout.buffer.flush()


def main():
    origin = sys.argv[1] if len(sys.argv) > 1 else ""
    while True:
        message = read_message()
        if message is None:
            break
        if isinstance(message, dict) and message.get("exit"):
            break
        if isinstance(message, dict) and message.get("close_stdin"):
            os.close(0)
            write_message({"stdin_closed": True})
            time.sleep(30)
            break
        write_message({"echo": message, "origin": origin})


if __name__ == "__main__":
    main()
