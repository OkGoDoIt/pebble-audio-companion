#!/usr/bin/env python3
"""Generate the golden protocol fixtures in spec/fixtures/.

This script is the authoritative encoder for the Audio Companion protocol
fixtures. Edit this script and re-run it; never hand-edit the .bin/.json
artifacts. See spec/audio-companion-protocol.md Section 9.

Usage: python3 tools/gen_fixtures.py [--check]
  --check  verify the on-disk fixtures match what this script generates
"""

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

FIXTURES_DIR = Path(__file__).resolve().parent.parent / "spec" / "fixtures"

PROTOCOL_VERSION = 1

# Control message ids (phone -> watch)
MSG_AUTH_REQUEST = 0x01
MSG_AUTH_REVOKE = 0x02
MSG_CHECKPOINT = 0x03
MSG_PAUSE_REQUEST = 0x04
MSG_RESUME_REQUEST = 0x05
MSG_RECEIVER_HEALTH = 0x06
MSG_ENABLE_REQUEST = 0x07

# Control message ids (watch -> phone)
MSG_AUTH_RESULT = 0x41
MSG_REVOKED = 0x42
MSG_ACK = 0x43
MSG_STATE_CHANGED = 0x44
MSG_ERROR = 0x45

# Data message ids (watch -> phone)
MSG_STREAM_START = 0x80
MSG_STREAM_DATA = 0x81
MSG_STREAM_GAP = 0x82
MSG_STREAM_STOP = 0x83

RECEIVER_ID = bytes(range(32))  # deterministic test receiver id 00..1f


def auth_request(proto_version, token, receiver_id, name: bytes) -> bytes:
    return (
        struct.pack("<BBB", MSG_AUTH_REQUEST, proto_version, token)
        + receiver_id
        + struct.pack("<B", len(name))
        + name
    )


def auth_revoke(token, receiver_id) -> bytes:
    return struct.pack("<BB", MSG_AUTH_REVOKE, token) + receiver_id


def checkpoint(token, stream_id, seq, sample_index, flags, free_kb) -> bytes:
    return struct.pack(
        "<BBIIQII", MSG_CHECKPOINT, token, stream_id, seq, sample_index, flags, free_kb
    )


def pause_request(token, reason) -> bytes:
    return struct.pack("<BBB", MSG_PAUSE_REQUEST, token, reason)


def resume_request(token) -> bytes:
    return struct.pack("<BB", MSG_RESUME_REQUEST, token)


def receiver_health(token, battery_pct, app_state, queue_depth) -> bytes:
    return struct.pack(
        "<BBBBI", MSG_RECEIVER_HEALTH, token, battery_pct, app_state, queue_depth
    )


def enable_request(token) -> bytes:
    return struct.pack("<BB", MSG_ENABLE_REQUEST, token)


def auth_result(token, status, granted) -> bytes:
    return struct.pack("<BBBB", MSG_AUTH_RESULT, token, status, granted)


def revoked(reason) -> bytes:
    return struct.pack("<BB", MSG_REVOKED, reason)


def ack(token, status) -> bytes:
    return struct.pack("<BBB", MSG_ACK, token, status)


def state_changed(state) -> bytes:
    return struct.pack("<BB", MSG_STATE_CHANGED, state)


def error_msg(code, detail) -> bytes:
    return struct.pack("<BBI", MSG_ERROR, code, detail)


def info(state, codec_bitmap, flags, fw_version_packed) -> bytes:
    return struct.pack(
        "<BBBBBBHIII",
        1,  # info_version
        1,  # protocol_min
        1,  # protocol_max
        state,
        codec_bitmap,
        flags,
        0,  # reserved0
        0,  # watch_capabilities
        fw_version_packed,
        0,  # reserved1
    )


def stream_start(
    stream_id,
    codec_id=0x01,
    channels=1,
    frame_samples=320,
    sample_rate_hz=16000,
    bit_rate_bps=9800,
    frame_duration_ms=20,
    start_time_ms=0,
    start_monotonic_ms=0,
    flags=0,
    protocol_version=PROTOCOL_VERSION,
) -> bytes:
    return struct.pack(
        "<BBIBBHIIHQQI",
        MSG_STREAM_START,
        protocol_version,
        stream_id,
        codec_id,
        channels,
        frame_samples,
        sample_rate_hz,
        bit_rate_bps,
        frame_duration_ms,
        start_time_ms,
        start_monotonic_ms,
        flags,
    )


def frame_payload(seq: int, length: int) -> bytes:
    """Deterministic pseudo-random frame payload for protocol-level fixtures."""
    out = bytearray()
    state = (seq * 2654435761) & 0xFFFFFFFF
    while len(out) < length:
        state = (state * 1103515245 + 12345) & 0xFFFFFFFF
        out.append((state >> 16) & 0xFF)
    return bytes(out)


def stream_data(stream_id, first_sequence, first_sample_index, frames, flags=0) -> bytes:
    msg = struct.pack(
        "<BIIQBH",
        MSG_STREAM_DATA,
        stream_id,
        first_sequence,
        first_sample_index,
        len(frames),
        flags,
    )
    for f in frames:
        msg += struct.pack("<H", len(f)) + f
    return msg


def stream_gap(stream_id, first_missing_seq, missing_count, first_missing_sample, reason, drop_counter) -> bytes:
    return struct.pack(
        "<BIIIQBI",
        MSG_STREAM_GAP,
        stream_id,
        first_missing_seq,
        missing_count,
        first_missing_sample,
        reason,
        drop_counter,
    )


def stream_stop(stream_id, reason, final_sequence, final_sample_index, crc=0) -> bytes:
    return struct.pack(
        "<BIBIQI", MSG_STREAM_STOP, stream_id, reason, final_sequence, final_sample_index, crc
    )


def build_fixtures():
    """Returns {name: (bytes, json_dict)}. json 'expect' is one of:
    'parse' (must parse), 'reject' (must be rejected as malformed),
    'ignore' (unknown id; must be skipped without error)."""
    fx = {}

    def add(name, data: bytes, channel, expect, fields=None, description=""):
        fx[name] = (
            data,
            {
                "name": name,
                "channel": channel,
                "expect": expect,
                "description": description,
                "size": len(data),
                "fields": fields or {},
            },
        )

    # ---- Info ----
    add(
        "info_streaming",
        info(state=3, codec_bitmap=0x01, flags=0b011, fw_version_packed=(4 << 24) | (9 << 16) | 2),
        "info",
        "parse",
        {
            "info_version": 1, "protocol_min": 1, "protocol_max": 1,
            "service_state": 3, "codec_bitmap": 1, "flags": 3,
            "fw_version_packed": (4 << 24) | (9 << 16) | 2,
        },
        "Info read while streaming: receiver bound + enabled, Speex codec, fw 4.9.2",
    )
    add(
        "info_disabled",
        info(state=0, codec_bitmap=0x01, flags=0, fw_version_packed=(4 << 24) | (9 << 16) | 2),
        "info",
        "parse",
        {"service_state": 0, "flags": 0},
        "Info read while the feature pref is off and no receiver is bound",
    )
    add(
        "info_truncated",
        info(state=3, codec_bitmap=0x01, flags=3, fw_version_packed=0)[:12],
        "info",
        "reject",
        {},
        "Info snapshot cut short mid-struct",
    )

    # ---- Control: phone -> watch ----
    name = "Audio Companion".encode()
    add(
        "auth_request",
        auth_request(1, 0x21, RECEIVER_ID, name),
        "control_in",
        "parse",
        {
            "proto_version": 1, "request_token": 0x21,
            "receiver_id_hex": RECEIVER_ID.hex(), "name": "Audio Companion",
        },
        "Nominal authorization request",
    )
    max_name = b"x" * 24
    add(
        "auth_request_max_name",
        auth_request(1, 0x22, RECEIVER_ID, max_name),
        "control_in",
        "parse",
        {"request_token": 0x22, "name": max_name.decode(), "name_len": 24},
        "Authorization request with maximum-length receiver name",
    )
    add(
        "auth_request_version_skew",
        auth_request(2, 0x23, RECEIVER_ID, name),
        "control_in",
        "parse",
        {"proto_version": 2, "request_token": 0x23},
        "Phone speaks a newer protocol; watch must still parse and grant min(2, watch_max)",
    )
    add(
        "auth_request_truncated_id",
        auth_request(1, 0x24, RECEIVER_ID, name)[:20],
        "control_in",
        "reject",
        {},
        "Authorization request cut inside receiver_id",
    )
    add(
        "auth_request_name_overrun",
        struct.pack("<BBB", MSG_AUTH_REQUEST, 1, 0x25) + RECEIVER_ID + struct.pack("<B", 30) + b"y" * 4,
        "control_in",
        "reject",
        {},
        "name_len (30) exceeds both the 24-byte limit and the actual payload",
    )
    add(
        "auth_revoke",
        auth_revoke(0x26, RECEIVER_ID),
        "control_in",
        "parse",
        {"request_token": 0x26, "receiver_id_hex": RECEIVER_ID.hex()},
        "Receiver revokes its own authorization",
    )
    add(
        "checkpoint",
        checkpoint(0x27, 0xA1B2C3D4, 4999, 1_600_000, 0, 870_400),
        "control_in",
        "parse",
        {
            "request_token": 0x27, "stream_id": 0xA1B2C3D4,
            "highest_contiguous_sequence_persisted": 4999,
            "persisted_sample_index": 1_600_000,
            "receiver_flags": 0, "free_storage_hint_kb": 870_400,
        },
        "Nominal checkpoint: 100 s of audio persisted, plenty of storage",
    )
    add(
        "checkpoint_boundary",
        checkpoint(0xFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0x3, 0),
        "control_in",
        "parse",
        {
            "request_token": 0xFF, "stream_id": 0xFFFFFFFF,
            "highest_contiguous_sequence_persisted": 0xFFFFFFFF,
            "persisted_sample_index": 0xFFFFFFFFFFFFFFFF,
            "receiver_flags": 3, "free_storage_hint_kb": 0,
        },
        "All-ones boundary values; locks u64 little-endian handling; both receiver flags set",
    )
    add(
        "checkpoint_v2_appended",
        checkpoint(0x28, 7, 10, 3200, 0, 1024) + struct.pack("<I", 0xDEADBEEF),
        "control_in",
        "parse",
        {
            "request_token": 0x28, "stream_id": 7,
            "highest_contiguous_sequence_persisted": 10,
            "persisted_sample_index": 3200,
            "receiver_flags": 0, "free_storage_hint_kb": 1024,
        },
        "Future-version checkpoint with appended field; v1 parser must accept and ignore the tail",
    )
    add(
        "checkpoint_truncated",
        checkpoint(0x29, 7, 10, 3200, 0, 1024)[:17],
        "control_in",
        "reject",
        {},
        "Checkpoint cut inside persisted_sample_index",
    )
    add(
        "pause_request",
        pause_request(0x2A, 1),
        "control_in",
        "parse",
        {"request_token": 0x2A, "reason": 1},
        "Receiver requests pause for low storage",
    )
    add(
        "resume_request",
        resume_request(0x2B),
        "control_in",
        "parse",
        {"request_token": 0x2B},
        "Receiver requests resume",
    )
    add(
        "receiver_health",
        receiver_health(0x2C, 76, 2, 130),
        "control_in",
        "parse",
        {"request_token": 0x2C, "battery_pct": 76, "app_state": 2, "queue_depth_frames": 130},
        "Health report from a backgrounded receiver",
    )
    add(
        "enable_request",
        enable_request(0x2D),
        "control_in",
        "parse",
        {"request_token": 0x2D},
        "Receiver asks the watch to prompt the user to enable Background Audio",
    )
    add(
        "control_unknown_id",
        struct.pack("<BB", 0x3F, 0x00),
        "control_in",
        "ignore",
        {},
        "Unknown phone->watch message id must be ignored",
    )
    add(
        "control_empty",
        b"",
        "control_in",
        "reject",
        {},
        "Empty control write",
    )

    # ---- Control: watch -> phone ----
    add(
        "auth_result_ok",
        auth_result(0x21, 0, 1),
        "control_out",
        "parse",
        {"request_token": 0x21, "status": 0, "granted_proto_version": 1},
        "Authorization granted at protocol version 1",
    )
    add(
        "auth_result_pending",
        auth_result(0x21, 1, 0),
        "control_out",
        "parse",
        {"request_token": 0x21, "status": 1},
        "Consent prompt shown on watch; final result follows asynchronously",
    )
    add(
        "auth_result_denied_mismatch",
        auth_result(0x21, 2, 0),
        "control_out",
        "parse",
        {"request_token": 0x21, "status": 2},
        "A different receiver is already bound; fail closed",
    )
    add(
        "revoked_user",
        revoked(1),
        "control_out",
        "parse",
        {"reason": 1},
        "User chose Forget Receiver on the watch",
    )
    add(
        "ack_ok",
        ack(0x27, 0),
        "control_out",
        "parse",
        {"request_token": 0x27, "status": 0},
        "Checkpoint acknowledged",
    )
    add(
        "state_changed_streaming",
        state_changed(3),
        "control_out",
        "parse",
        {"service_state": 3},
        "Service entered streaming state",
    )
    add(
        "state_changed_power_save",
        state_changed(8),
        "control_out",
        "parse",
        {"service_state": 8},
        "Service paused while the watch is saving power",
    )
    add(
        "error_malformed",
        error_msg(1, 0),
        "control_out",
        "parse",
        {"error_code": 1, "detail": 0},
        "Watch reports a malformed inbound message",
    )

    # ---- Data ----
    add(
        "stream_start",
        stream_start(
            stream_id=0x5EED0001,
            start_time_ms=1_781_000_000_000,
            start_monotonic_ms=86_400_123,
        ),
        "data",
        "parse",
        {
            "protocol_version": 1, "stream_id": 0x5EED0001, "codec_id": 1,
            "channels": 1, "frame_samples": 320, "sample_rate_hz": 16000,
            "bit_rate_bps": 9800, "frame_duration_ms": 20,
            "start_time_ms": 1_781_000_000_000, "start_monotonic_ms": 86_400_123,
            "flags": 0,
        },
        "Nominal Speex wideband stream start",
    )
    add(
        "stream_data_1frame",
        stream_data(0x5EED0001, 0, 0, [frame_payload(0, 25)]),
        "data",
        "parse",
        {"stream_id": 0x5EED0001, "first_sequence": 0, "first_sample_index": 0,
         "frame_count": 1, "frame_lengths": [25]},
        "First data message of a stream with one typical 25-byte Speex frame",
    )
    add(
        "stream_data_8frames",
        stream_data(
            0x5EED0001, 800, 256_000,
            [frame_payload(800 + i, 22 + i) for i in range(8)],
        ),
        "data",
        "parse",
        {"stream_id": 0x5EED0001, "first_sequence": 800, "first_sample_index": 256_000,
         "frame_count": 8, "frame_lengths": [22 + i for i in range(8)]},
        "Typical MTU-sized batch of 8 variable-length frames",
    )
    add(
        "stream_data_32frames",
        stream_data(
            0x5EED0001, 1000, 320_000,
            [frame_payload(1000 + i, 4) for i in range(32)],
        ),
        "data",
        "parse",
        {"stream_id": 0x5EED0001, "first_sequence": 1000, "first_sample_index": 320_000,
         "frame_count": 32, "frame_lengths": [4] * 32},
        "Maximum frame_count batch (32) of minimal frames",
    )
    add(
        "stream_data_max_frame_bytes",
        stream_data(0x5EED0001, 42, 13_440, [frame_payload(42, 200)]),
        "data",
        "parse",
        {"frame_count": 1, "frame_lengths": [200]},
        "Single frame at MAX_ENCODED_FRAME_BYTES (200)",
    )
    add(
        "stream_data_truncated_header",
        stream_data(0x5EED0001, 0, 0, [frame_payload(0, 25)])[:15],
        "data",
        "reject",
        {},
        "Data message cut inside the 20-byte header",
    )
    add(
        "stream_data_truncated_frame",
        stream_data(0x5EED0001, 0, 0, [frame_payload(0, 25)])[:30],
        "data",
        "reject",
        {},
        "Data message cut inside the first frame payload",
    )
    add(
        "stream_data_frame_too_long",
        stream_data(0x5EED0001, 0, 0, [frame_payload(0, 201)]),
        "data",
        "reject",
        {},
        "Frame length 201 exceeds MAX_ENCODED_FRAME_BYTES",
    )
    add(
        "stream_data_zero_frames",
        stream_data(0x5EED0001, 0, 0, []),
        "data",
        "reject",
        {},
        "frame_count of zero is invalid",
    )
    gap_reasons = {
        1: "spool_overflow", 2: "mic_conflict", 3: "user_disabled",
        4: "low_battery", 5: "codec_error", 6: "transport_reset",
        7: "power_save", 8: "silence_suppressed",
    }
    for reason, label in gap_reasons.items():
        add(
            f"stream_gap_{label}",
            stream_gap(0x5EED0001, 5000 + reason, 250, 1_600_000 + reason * 320, reason, 250),
            "data",
            "parse",
            {"stream_id": 0x5EED0001, "first_missing_sequence": 5000 + reason,
             "missing_frame_count": 250,
             "first_missing_sample_index": 1_600_000 + reason * 320,
             "reason": reason, "watch_drop_counter": 250},
            f"Gap with reason {label}",
        )
    add(
        "stream_gap_unknown_count",
        stream_gap(0x5EED0001, 7000, 0, 2_240_000, 2, 250),
        "data",
        "parse",
        {"missing_frame_count": 0, "reason": 2},
        "Elapsed-time-only gap: missing_frame_count 0 means unknown",
    )
    add(
        "stream_stop_user_disabled",
        stream_stop(0x5EED0001, 1, 9999, 3_200_000),
        "data",
        "parse",
        {"stream_id": 0x5EED0001, "reason": 1, "final_sequence": 9999,
         "final_sample_index": 3_200_000, "counters_crc_or_zero": 0},
        "Stream stopped because the user disabled the feature",
    )
    add(
        "stream_stop_shutdown",
        stream_stop(0x5EED0001, 4, 12000, 3_840_000),
        "data",
        "parse",
        {"reason": 4},
        "Stream stopped because the watch is shutting down",
    )
    add(
        "data_unknown_id",
        struct.pack("<B", 0x9F) + b"\x00" * 8,
        "data",
        "ignore",
        {},
        "Unknown data message id must be ignored",
    )

    return fx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    fixtures = build_fixtures()
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)

    mismatches = []
    for name, (data, meta) in sorted(fixtures.items()):
        bin_path = FIXTURES_DIR / f"{name}.bin"
        json_path = FIXTURES_DIR / f"{name}.json"
        json_text = json.dumps(meta, indent=2, sort_keys=True) + "\n"
        if args.check:
            if not bin_path.exists() or bin_path.read_bytes() != data:
                mismatches.append(str(bin_path))
            if not json_path.exists() or json_path.read_text() != json_text:
                mismatches.append(str(json_path))
        else:
            bin_path.write_bytes(data)
            json_path.write_text(json_text)

    if args.check:
        expected = {f"{n}{ext}" for n in fixtures for ext in (".bin", ".json")}
        for p in FIXTURES_DIR.iterdir():
            if p.name not in expected and p.suffix in (".bin", ".json") and not p.name.startswith("speex_"):
                mismatches.append(f"unexpected: {p}")
        if mismatches:
            print("Fixture mismatch:\n" + "\n".join(mismatches))
            return 1
        print(f"{len(fixtures)} fixtures verified OK")
        return 0

    digest = hashlib.sha256()
    for name, (data, _) in sorted(fixtures.items()):
        digest.update(name.encode() + b"\0" + data)
    print(f"wrote {len(fixtures)} fixtures to {FIXTURES_DIR}")
    print(f"fixture set sha256: {digest.hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
