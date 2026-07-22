#!/usr/bin/env python3
"""Protocol smoke test for the Magic Voice STT sidecar.

Boots sidecar.py directly, streams a WAV through the
JSONLines streaming protocol (start_stream / audio_chunk / finish_stream /
cancel_stream), and asserts that a non-empty transcript comes back. Exits non-zero on any
protocol violation, so it can gate CI and catch regressions in the
Swift <-> sidecar contract.

Usage:
    python3 scripts/smoke_sidecar.py [path/to/16k-mono-f32.wav]

Without an argument it synthesizes a short silent clip and only asserts the
protocol shape (started -> done), not transcript content.
"""

from __future__ import annotations

import base64
import json
import select
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SIDECAR_DIR = REPO_ROOT / "sidecar"
CHUNK_SECONDS = 0.5
SAMPLE_RATE = 16_000
BOOT_TIMEOUT = 300  # first run may download the model
DONE_TIMEOUT = 120


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def load_float32_samples(path: Path) -> bytes:
    # Python's wave module rejects IEEE-float WAVs (format tag 3), which is
    # exactly what the app records, so parse the RIFF chunks directly.
    blob = path.read_bytes()
    if blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        fail(f"{path} is not a RIFF/WAVE file")

    offset = 12
    data = None
    while offset + 8 <= len(blob):
        chunk_id = blob[offset:offset + 4]
        chunk_size = struct.unpack_from("<I", blob, offset + 4)[0]
        body = blob[offset + 8:offset + 8 + chunk_size]
        if chunk_id == b"fmt ":
            format_tag, channels, sample_rate = struct.unpack_from("<HHI", body, 0)
            bits_per_sample = struct.unpack_from("<H", body, 14)[0]
            if format_tag != 3 or bits_per_sample != 32:
                fail(f"{path} is not 32-bit float (format {format_tag}, {bits_per_sample}-bit)")
            if channels != 1:
                fail(f"{path} is not mono")
            if sample_rate != SAMPLE_RATE:
                fail(f"{path} is not {SAMPLE_RATE} Hz")
        elif chunk_id == b"data":
            data = body
        offset += 8 + chunk_size + (chunk_size & 1)

    if data is None:
        fail(f"{path} has no data chunk")
        raise AssertionError("unreachable")
    return data


def synthesize_silence(seconds: float = 2.0) -> bytes:
    return struct.pack(f"<{int(SAMPLE_RATE * seconds)}f", *([0.0] * int(SAMPLE_RATE * seconds)))


def read_event(process: subprocess.Popen, timeout: float) -> dict:
    assert process.stdout is not None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        ready, _, _ = select.select([process.stdout], [], [], min(remaining, 1.0))
        if not ready:
            if process.poll() is not None:
                fail(f"sidecar exited early with code {process.returncode}")
            continue
        line = process.stdout.readline()
        if not line:
            fail("sidecar closed stdout unexpectedly")
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            fail(f"sidecar emitted non-JSON line: {line!r}")
    fail(f"timed out after {timeout}s waiting for sidecar event")
    raise AssertionError("unreachable")


def send(process: subprocess.Popen, message: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def assert_no_event(process: subprocess.Popen, timeout: float) -> None:
    assert process.stdout is not None
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if ready:
        line = process.stdout.readline().strip()
        fail(f"cancelled stream emitted a later event: {line!r}")
    if process.poll() is not None:
        fail(f"sidecar exited after cancel_stream with code {process.returncode}")


def main() -> int:
    if len(sys.argv) > 1:
        wav_path = Path(sys.argv[1])
        samples = load_float32_samples(wav_path)
        expect_text = True
        print(f"Streaming fixture: {wav_path} ({len(samples) // 4} samples)")
    else:
        samples = synthesize_silence()
        expect_text = False
        print("No fixture WAV given; streaming 2s of silence (protocol-shape check only)")

    process = subprocess.Popen(
        ["uv", "run", "python", "sidecar.py", "--language", "auto"],
        cwd=SIDECAR_DIR,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=open("/tmp/smoke_sidecar_stderr.log", "w"),
        text=True,
    )

    try:
        event = read_event(process, BOOT_TIMEOUT)
        if event.get("type") != "status" or event.get("state") != "booted":
            fail(f"expected booted status, got {event}")
        print("booted ok")

        send(process, {"type": "ping"})
        event = read_event(process, 5)
        if event.get("type") != "pong":
            fail(f"expected pong, got {event}")
        print("readiness ping ok")

        cancelled_request_id = "smoke-cancelled"
        send(process, {"type": "start_stream", "request_id": cancelled_request_id})
        while True:
            event = read_event(process, BOOT_TIMEOUT)
            if event.get("type") == "started":
                break
            if event.get("type") == "status":
                print(f"status: {event.get('state')}")
                continue
            fail(f"expected cancelled stream to start, got {event}")
        send(process, {"type": "cancel_stream", "request_id": cancelled_request_id})
        send(process, {"type": "finish_stream", "request_id": cancelled_request_id})
        send(process, {
            "type": "audio_chunk",
            "request_id": cancelled_request_id,
            "data": base64.b64encode(samples[:4]).decode(),
        })
        assert_no_event(process, 1.0)
        print("cancel_stream suppressed later events ok")

        request_id = "smoke-test"
        send(process, {"type": "start_stream", "request_id": request_id})

        # The model loads lazily on the first stream; allow status events first.
        while True:
            event = read_event(process, BOOT_TIMEOUT)
            if event.get("type") == "started":
                break
            if event.get("type") == "status":
                print(f"status: {event.get('state')}")
                continue
            fail(f"expected started event, got {event}")
        print("stream started ok")

        chunk_bytes = int(SAMPLE_RATE * CHUNK_SECONDS) * 4
        for offset in range(0, len(samples), chunk_bytes):
            send(process, {
                "type": "audio_chunk",
                "request_id": request_id,
                "data": base64.b64encode(samples[offset:offset + chunk_bytes]).decode(),
            })
        send(process, {"type": "finish_stream", "request_id": request_id})

        transcript = ""
        chunks_seen = 0
        while True:
            event = read_event(process, DONE_TIMEOUT)
            event_type = event.get("type")
            if event_type == "chunk":
                chunks_seen += 1
                transcript = event.get("transcript") or transcript + (event.get("text") or "")
            elif event_type == "done":
                transcript = event.get("text") or transcript
                break
            elif event_type == "error":
                fail(f"sidecar error: {event.get('message')}")

        print(f"done: {chunks_seen} chunk events, transcript: {transcript!r}")
        if expect_text and not transcript.strip():
            fail("expected a non-empty transcript from the fixture WAV")

        send(process, {"type": "shutdown"})
        print("PASS")
        return 0
    finally:
        if process.poll() is None:
            process.terminate()


if __name__ == "__main__":
    sys.exit(main())
