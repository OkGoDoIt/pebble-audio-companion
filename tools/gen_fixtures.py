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
MSG_PHONE_MEDIA_STATE = 0x08
MSG_MUSE_SETUP_OPEN = 0x09
MSG_MUSE_SETUP_CLOSE = 0x0A
MSG_MUSE_SETUP_TX = 0x0B
MSG_MUSE_SETUP_DISCONNECT = 0x0C
MSG_ASSISTANT_UPDATE = 0x0D
MSG_WATCH_ACTION = 0x0E

# Control message ids (watch -> phone)
MSG_AUTH_RESULT = 0x41
MSG_REVOKED = 0x42
MSG_ACK = 0x43
MSG_STATE_CHANGED = 0x44
MSG_ERROR = 0x45
MSG_PHONE_MEDIA_QUERY = 0x46
MSG_MUSE_SETUP_RX = 0x47
MSG_MUSE_SETUP_EVENT = 0x48
MSG_PTT_EVENT = 0x49
MSG_WATCH_ACTION_RESULT = 0x4A

# Data message ids (watch -> phone)
MSG_STREAM_START = 0x80
MSG_STREAM_DATA = 0x81
MSG_STREAM_GAP = 0x82
MSG_STREAM_STOP = 0x83
MSG_PTT_AUDIO = 0x84

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


def phone_media_state(token, flags) -> bytes:
    # flags: bit0 the phone could check, bit1 another app is playing audio, bit2 it is
    # non-mixable primary audio.
    return struct.pack("<BBB", MSG_PHONE_MEDIA_STATE, token, flags)


def phone_media_query() -> bytes:
    return struct.pack("<B", MSG_PHONE_MEDIA_QUERY)


# Muse gadget setup relay (Section 4.3)
MUSE_SETUP_TX_MAX_BYTES = 240
MUSE_SETUP_RX_MAX_BYTES = 249
MUSE_SETUP_RX_FLAG_MORE = 0x01


def muse_setup_open(token, window_secs, suffix: bytes, flags=0) -> bytes:
    assert len(suffix) == 6
    return struct.pack("<BBH", MSG_MUSE_SETUP_OPEN, token, window_secs) + suffix + struct.pack(
        "<B", flags
    )


def muse_setup_close(token, reason) -> bytes:
    return struct.pack("<BBB", MSG_MUSE_SETUP_CLOSE, token, reason)


def muse_setup_tx(token, data: bytes) -> bytes:
    return struct.pack("<BBB", MSG_MUSE_SETUP_TX, token, len(data)) + data


def muse_setup_disconnect(token, delay_ms) -> bytes:
    return struct.pack("<BBH", MSG_MUSE_SETUP_DISCONNECT, token, delay_ms)


def muse_setup_rx(seq, flags, data: bytes) -> bytes:
    return struct.pack("<BBBB", MSG_MUSE_SETUP_RX, seq, flags, len(data)) + data


def muse_setup_event(event, detail, mtu, seconds_left) -> bytes:
    return struct.pack("<BBBHH", MSG_MUSE_SETUP_EVENT, event, detail, mtu, seconds_left)


# Push-to-talk (Section 4.4) and watch actions (Section 4.5)


def ptt_event(turn, event, detail, frame_count=0, max_seconds=0) -> bytes:
    return struct.pack("<BBBBHH", MSG_PTT_EVENT, turn, event, detail, frame_count, max_seconds)


def ptt_audio(turn, first_frame, frames) -> bytes:
    out = struct.pack("<BBHB", MSG_PTT_AUDIO, turn, first_frame, len(frames))
    for f in frames:
        out += struct.pack("<H", len(f)) + f
    return out


def assistant_update(token, turn, kind, detail, text: bytes) -> bytes:
    return struct.pack("<BBBBBB", MSG_ASSISTANT_UPDATE, token, turn, kind, detail, len(text)) + text


def watch_action(token, action_id, flags, payload: bytes) -> bytes:
    return struct.pack("<BBBBB", MSG_WATCH_ACTION, token, action_id, flags, len(payload)) + payload


def watch_action_result(action_id, status, value, text: bytes = b"") -> bytes:
    out = struct.pack("<BBBB", MSG_WATCH_ACTION_RESULT, action_id, status, value)
    if text:
        out += struct.pack("<B", len(text)) + text
    return out


def wa_str(text: str) -> bytes:
    b = text.encode("utf-8")
    return struct.pack("<B", len(b)) + b


def wa_timer(seconds, label) -> bytes:
    return struct.pack("<BI", 1, seconds) + wa_str(label)


def wa_alarm(hour, minute, label) -> bytes:
    return struct.pack("<BBB", 2, hour, minute) + wa_str(label)


def wa_music(command) -> bytes:
    return struct.pack("<BB", 4, command)


def wa_quiet_time(on, minutes) -> bytes:
    return struct.pack("<BBH", 5, 1 if on else 0, minutes)


def wa_launch_app(name) -> bytes:
    return struct.pack("<B", 6) + wa_str(name)


def wa_find_watch(seconds) -> bytes:
    return struct.pack("<BB", 7, seconds)


def wa_health(metric, days) -> bytes:
    return struct.pack("<BBB", 8, metric, days)


def wa_notice(text) -> bytes:
    return struct.pack("<B", 9) + wa_str(text)


def wa_choose(timeout_s, question, options) -> bytes:
    out = struct.pack("<BH", 3, timeout_s) + wa_str(question) + struct.pack("<B", len(options))
    for o in options:
        out += wa_str(o)
    return out


CHOOSE_PAYLOAD = wa_choose(
    90,
    "Which table should I book for Friday night? Both are at Odd Duck; the earlier one is by the window, the later one outside.",
    ["7:00 PM, by the window", "8:30 PM, on the patio", "Either one is fine", "Neither, keep looking"],
)
assert len(CHOOSE_PAYLOAD) > 180 and len(CHOOSE_PAYLOAD) <= 512


# What the Muse app writes first, and a plausible gadget reply (Muse community pairing v5).
MUSE_GET_DEVICE_INFO = b'{"action":"get_device_info"}'
MUSE_DEVICE_INFO_REPLY = (
    b'{"type":"device_info","node_id":"F1A69C","version":"1.0.0","build_sha":"0000000",'
    b'"network_ready":true}'
)


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


def info(
    state,
    codec_bitmap,
    flags,
    fw_version_packed,
    send_backpressure_events=0,
    info_version=1,
    last_reboot_reason=0,
    fault_boots=0,
    error_reboots=0,
    stood_down=0,
    fault_pc=0,
    fault_lr=0,
) -> bytes:
    # send_backpressure_events occupies what was reserved1 (same 20 bytes, same info_version).
    # It is only a count when flags bit3 is set; older firmware leaves it zero.
    head = struct.pack(
        "<BBBBBBHIII",
        info_version,
        1,  # protocol_min
        1,  # protocol_max
        state,
        codec_bitmap,
        flags,
        0,  # reserved0
        0,  # watch_capabilities
        fw_version_packed,
        send_backpressure_events,
    )
    if info_version < 2:
        return head
    # info_version 2 appends the watch's last restart (32 bytes total): RebootReasonCode, the
    # fault-loop guard's consecutive-fault counter, lifetime fault count, whether the guard
    # stood down at this boot, and the newest trace entry's PC/LR. A v1 parser reads the first
    # 20 bytes and ignores the rest.
    return head + struct.pack(
        "<BBBBII",
        last_reboot_reason,
        fault_boots,
        error_reboots,
        stood_down,
        fault_pc,
        fault_lr,
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
        "info_v2_after_fault",
        info(
            state=0,
            codec_bitmap=0x01,
            flags=0b1001,
            fw_version_packed=(4 << 24) | (36 << 16) | 0,
            send_backpressure_events=7,
            info_version=2,
            last_reboot_reason=16,  # RebootReasonCode_Watchdog
            fault_boots=0,
            error_reboots=5,
            stood_down=1,
            fault_pc=0x1000ABCD,
            fault_lr=0x1000EF01,
        ),
        "info",
        "parse",
        {
            "info_version": 2, "service_state": 0, "flags": 9,
            "fw_version_packed": (4 << 24) | (36 << 16) | 0,
            "send_backpressure_events": 7,
        },
        "Info v2 after a watchdog restart that made the fault-loop guard stand down: 32 bytes, "
        "a v1 parser reads the first 20",
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
        "info_backpressure",
        info(
            state=3,
            codec_bitmap=0x01,
            flags=0b1011,
            fw_version_packed=(4 << 24) | (9 << 16) | 2,
            send_backpressure_events=1487,
        ),
        "info",
        "parse",
        {
            "info_version": 1, "protocol_min": 1, "protocol_max": 1,
            "service_state": 3, "codec_bitmap": 1, "flags": 11,
            "fw_version_packed": (4 << 24) | (9 << 16) | 2,
            "send_backpressure_events": 1487,
        },
        "Info read while streaming from firmware that reports send backpressure: flags bit3 set, "
        "1487 refused notifications in what used to be reserved1. Same 20 bytes as info_streaming, "
        "whose cleared bit3 means 'not reported' rather than 'never happened'",
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
        "phone_media_state_playing",
        phone_media_state(0x2E, 0x07),
        "control_in",
        "parse",
        {"request_token": 0x2E, "flags": 0x07},
        "Receiver reports another app on the phone is playing non-mixable audio",
    )
    add(
        "phone_media_state_idle",
        phone_media_state(0x2F, 0x01),
        "control_in",
        "parse",
        {"request_token": 0x2F, "flags": 0x01},
        "Receiver checked: nothing else on the phone is playing audio",
    )
    add(
        "phone_media_state_short",
        struct.pack("<BB", MSG_PHONE_MEDIA_STATE, 0x30),
        "control_in",
        "reject",
        {},
        "PHONE_MEDIA_STATE without its flags byte",
    )

    # ---- Control (phone -> watch): push-to-talk answers and watch actions ----
    heard = "What's the weather like in Austin this afternoon?".encode("utf-8")
    add(
        "assistant_update_heard",
        assistant_update(0x41, 7, 1, 0, heard),
        "control_in",
        "parse",
        {"request_token": 0x41, "turn": 7, "kind": 1, "detail": 0, "text_hex": heard.hex()},
        "What Muse heard, shown as 'You said' on the watch",
    )
    answer = "It's 72°F and sunny in Austin, with a light breeze from the south.".encode("utf-8")
    add(
        "assistant_update_answer",
        assistant_update(0x42, 7, 3, 0, answer),
        "control_in",
        "parse",
        {"request_token": 0x42, "turn": 7, "kind": 3, "detail": 0, "text_hex": answer.hex()},
        "A piece of the answer, appended on the watch (UTF-8, a multi-byte degree sign)",
    )
    add(
        "assistant_update_done",
        assistant_update(0x43, 7, 4, 0, b""),
        "control_in",
        "parse",
        {"request_token": 0x43, "turn": 7, "kind": 4, "detail": 0, "text_hex": ""},
        "The answer is complete",
    )
    add(
        "assistant_update_error",
        assistant_update(0x44, 8, 5, 1, b""),
        "control_in",
        "parse",
        {"request_token": 0x44, "turn": 8, "kind": 5, "detail": 1, "text_hex": ""},
        "The turn failed: the assistant isn't set up",
    )
    add(
        "assistant_update_too_long",
        assistant_update(0x45, 7, 3, 0, bytes(181)),
        "control_in",
        "reject",
        {},
        "ASSISTANT_UPDATE text of 181 bytes exceeds the 180-byte limit",
    )
    add(
        "assistant_update_turn_zero",
        assistant_update(0x46, 0, 3, 0, b"hi"),
        "control_in",
        "reject",
        {},
        "ASSISTANT_UPDATE for turn 0, which is never used",
    )
    add(
        "assistant_update_truncated",
        struct.pack("<BBBBBB", MSG_ASSISTANT_UPDATE, 0x47, 7, 3, 0, 40) + b"short",
        "control_in",
        "reject",
        {},
        "ASSISTANT_UPDATE length (40) overruns the 5 bytes present",
    )
    timer = wa_timer(600, "Pasta")
    restart = "1. 09:53 - your 1st voice note".encode("utf-8")
    add(
        "assistant_update_answer_restart",
        assistant_update(0x4F, 7, 6, 0, restart),
        "control_in",
        "parse",
        {"request_token": 0x4F, "turn": 7, "kind": 6, "detail": 0, "text_hex": restart.hex()},
        "The finished answer replaces what streamed",
    )
    add(
        "watch_action_timer",
        watch_action(0x48, 3, 0, timer),
        "control_in",
        "parse",
        {"request_token": 0x48, "action_id": 3, "flags": 0, "payload_hex": timer.hex()},
        "A ten-minute timer labelled Pasta, in one write",
    )
    alarm = wa_alarm(6, 30, "Flight")
    add(
        "watch_action_alarm",
        watch_action(0x49, 4, 0, alarm),
        "control_in",
        "parse",
        {"request_token": 0x49, "action_id": 4, "flags": 0, "payload_hex": alarm.hex()},
        "A one-off alarm at 6:30 labelled Flight",
    )
    first, rest = CHOOSE_PAYLOAD[:180], CHOOSE_PAYLOAD[180:]
    add(
        "watch_action_choose_first",
        watch_action(0x4A, 5, 1, first),
        "control_in",
        "parse",
        {"request_token": 0x4A, "action_id": 5, "flags": 1, "payload_hex": first.hex()},
        "First write of a choice whose payload is longer than one write; MORE set",
    )
    add(
        "watch_action_choose_last",
        watch_action(0x4B, 5, 0, rest),
        "control_in",
        "parse",
        {"request_token": 0x4B, "action_id": 5, "flags": 0, "payload_hex": rest.hex()},
        "Last write of the same choice: same action id, MORE clear",
    )
    for name, payload, note in [
        ("watch_action_music_next", wa_music(4), "Skip to the next track"),
        ("watch_action_music_now_playing", wa_music(8), "Ask what is playing; nothing changes"),
        ("watch_action_quiet_time", wa_quiet_time(True, 60), "Quiet Time on for an hour"),
        ("watch_action_launch_app", wa_launch_app("Workout"), "Open the watch app named Workout"),
        ("watch_action_find_watch", wa_find_watch(10), "Buzz and light up for ten seconds"),
        ("watch_action_health_steps", wa_health(1, 7), "Step counts for today and the six days before"),
        (
            "watch_action_notice",
            wa_notice("Open Pebble Audio on your iPhone to give it access to your calendar."),
            "A message from the receiver itself, shown on the watch",
        ),
    ]:
        add(
            name,
            watch_action(0x4E, 7, 0, payload),
            "control_in",
            "parse",
            {"request_token": 0x4E, "action_id": 7, "flags": 0, "payload_hex": payload.hex()},
            note,
        )
    add(
        "watch_action_id_zero",
        watch_action(0x4C, 0, 0, timer),
        "control_in",
        "reject",
        {},
        "WATCH_ACTION with action id 0, which is never used",
    )
    add(
        "watch_action_empty",
        watch_action(0x4D, 6, 0, b""),
        "control_in",
        "reject",
        {},
        "WATCH_ACTION with no payload",
    )

    # ---- Control (phone -> watch): Muse gadget setup relay ----
    add(
        "muse_setup_open",
        muse_setup_open(0x31, 300, b"F1A69C"),
        "control_in",
        "parse",
        {"request_token": 0x31, "window_secs": 300, "suffix": "F1A69C", "flags": 0},
        "App asks for a five-minute pairing window advertised as MuseGadgetF1A69C",
    )
    add(
        "muse_setup_open_short",
        muse_setup_open(0x32, 300, b"F1A69C")[:-1],
        "control_in",
        "reject",
        {},
        "MUSE_SETUP_OPEN without its flags byte",
    )
    add(
        "muse_setup_close_paired",
        muse_setup_close(0x33, 1),
        "control_in",
        "parse",
        {"request_token": 0x33, "reason": 1},
        "App finished pairing: the watch shows 'Paired with Muse' and closes the window",
    )
    add(
        "muse_setup_close_failed",
        muse_setup_close(0x34, 3),
        "control_in",
        "parse",
        {"request_token": 0x34, "reason": 3},
        "App gave up on the pairing",
    )
    add(
        "muse_setup_tx_device_info",
        muse_setup_tx(0x35, MUSE_DEVICE_INFO_REPLY),
        "control_in",
        "parse",
        {
            "request_token": 0x35,
            "length": len(MUSE_DEVICE_INFO_REPLY),
            "data_hex": MUSE_DEVICE_INFO_REPLY.hex(),
        },
        "One value for the watch to notify to the Muse app verbatim",
    )
    add(
        "muse_setup_tx_max",
        muse_setup_tx(0x36, bytes(range(MUSE_SETUP_TX_MAX_BYTES))),
        "control_in",
        "parse",
        {
            "request_token": 0x36,
            "length": MUSE_SETUP_TX_MAX_BYTES,
            "data_hex": bytes(range(MUSE_SETUP_TX_MAX_BYTES)).hex(),
        },
        "Largest MUSE_SETUP_TX value (240 bytes)",
    )
    add(
        "muse_setup_tx_too_long",
        muse_setup_tx(0x37, bytes(MUSE_SETUP_TX_MAX_BYTES + 1)),
        "control_in",
        "reject",
        {},
        "MUSE_SETUP_TX value of 241 bytes exceeds the 240-byte limit",
    )
    add(
        "muse_setup_tx_empty",
        muse_setup_tx(0x38, b""),
        "control_in",
        "reject",
        {},
        "MUSE_SETUP_TX with no value",
    )
    add(
        "muse_setup_tx_truncated",
        struct.pack("<BBB", MSG_MUSE_SETUP_TX, 0x39, 40) + bytes(10),
        "control_in",
        "reject",
        {},
        "MUSE_SETUP_TX length (40) overruns the 10 bytes present",
    )
    add(
        "muse_setup_disconnect",
        muse_setup_disconnect(0x3A, 250),
        "control_in",
        "parse",
        {"request_token": 0x3A, "delay_ms": 250},
        "App ends the Muse app's link after the pairing's last read",
    )
    add(
        "muse_setup_disconnect_short",
        struct.pack("<BBB", MSG_MUSE_SETUP_DISCONNECT, 0x3B, 250),
        "control_in",
        "reject",
        {},
        "MUSE_SETUP_DISCONNECT with half its delay",
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
        "phone_media_query",
        phone_media_query(),
        "control_out",
        "parse",
        {},
        "Watch asks the receiver whether the phone is actually playing audio",
    )
    add(
        "ptt_event_start",
        ptt_event(7, 1, 1, 0, 15),
        "control_out",
        "parse",
        {"turn": 7, "event": 1, "detail": 1, "frame_count": 0, "max_seconds": 15},
        "A Quick Launch hold confirmed a question; the watch records at most 15 s",
    )
    add(
        "ptt_event_end",
        ptt_event(7, 2, 1, 212, 0),
        "control_out",
        "parse",
        {"turn": 7, "event": 2, "detail": 1, "frame_count": 212, "max_seconds": 0},
        "Released after 212 frames (4.24 s)",
    )
    add(
        "ptt_event_cancel_too_short",
        ptt_event(9, 3, 1, 9, 0),
        "control_out",
        "parse",
        {"turn": 9, "event": 3, "detail": 1, "frame_count": 9, "max_seconds": 0},
        "Released right after the hold was confirmed: no question",
    )
    add(
        "ptt_event_short",
        ptt_event(7, 1, 1, 0, 15)[:-1],
        "control_out",
        "reject",
        {},
        "PTT_EVENT missing the last byte of max_seconds",
    )
    add(
        "watch_action_result_chosen",
        watch_action_result(5, 1, 1),
        "control_out",
        "parse",
        {"action_id": 5, "status": 1, "value": 1},
        "The wearer picked the second option",
    )
    add(
        "watch_action_result_declined",
        watch_action_result(5, 2, 0),
        "control_out",
        "parse",
        {"action_id": 5, "status": 2, "value": 0},
        "The wearer backed out of the choice",
    )
    now_playing = "Clair de lune\nDebussy".encode("utf-8")
    add(
        "watch_action_result_text",
        watch_action_result(6, 1, 0, now_playing),
        "control_out",
        "parse",
        {"action_id": 6, "status": 1, "value": 0, "text": now_playing.decode("utf-8")},
        "Done, with text: what is playing (title, then artist)",
    )
    add(
        "watch_action_result_text_truncated",
        watch_action_result(6, 1, 0, now_playing)[:-3],
        "control_out",
        "reject",
        {},
        "WATCH_ACTION_RESULT text length overruns the bytes present",
    )
    add(
        "muse_setup_rx_get_device_info",
        muse_setup_rx(0, 0, MUSE_GET_DEVICE_INFO),
        "control_out",
        "parse",
        {
            "seq": 0, "flags": 0, "length": len(MUSE_GET_DEVICE_INFO),
            "data_hex": MUSE_GET_DEVICE_INFO.hex(),
        },
        "The Muse app's first write, relayed whole",
    )
    _long_value = bytes((i * 7) & 0xFF for i in range(300))
    add(
        "muse_setup_rx_fragment_more",
        muse_setup_rx(1, MUSE_SETUP_RX_FLAG_MORE, _long_value[:MUSE_SETUP_RX_MAX_BYTES]),
        "control_out",
        "parse",
        {
            "seq": 1, "flags": 1, "length": MUSE_SETUP_RX_MAX_BYTES,
            "data_hex": _long_value[:MUSE_SETUP_RX_MAX_BYTES].hex(),
        },
        "First notification of a 300-byte value split at the 249-byte limit; MORE set",
    )
    add(
        "muse_setup_rx_fragment_last",
        muse_setup_rx(1, 0, _long_value[MUSE_SETUP_RX_MAX_BYTES:]),
        "control_out",
        "parse",
        {
            "seq": 1, "flags": 0, "length": 300 - MUSE_SETUP_RX_MAX_BYTES,
            "data_hex": _long_value[MUSE_SETUP_RX_MAX_BYTES:].hex(),
        },
        "Last notification of the same value: same seq, MORE clear",
    )
    add(
        "muse_setup_rx_truncated",
        struct.pack("<BBBB", MSG_MUSE_SETUP_RX, 2, 0, 28) + MUSE_GET_DEVICE_INFO[:10],
        "control_out",
        "reject",
        {},
        "MUSE_SETUP_RX length (28) overruns the 10 bytes present",
    )
    add(
        "muse_setup_event_opened",
        muse_setup_event(1, 0, 0, 300),
        "control_out",
        "parse",
        {"event": 1, "detail": 0, "mtu": 0, "seconds_left": 300},
        "The user said yes on the watch; it is advertising for five minutes",
    )
    add(
        "muse_setup_event_connected",
        muse_setup_event(2, 0, 256, 287),
        "control_out",
        "parse",
        {"event": 2, "detail": 0, "mtu": 256, "seconds_left": 287},
        "The Muse app connected with a 256-byte ATT MTU",
    )
    add(
        "muse_setup_event_closed_timeout",
        muse_setup_event(5, 4, 0, 0),
        "control_out",
        "parse",
        {"event": 5, "detail": 4, "mtu": 0, "seconds_left": 0},
        "The window ended without the Muse app connecting",
    )
    add(
        "muse_setup_event_rx_overflow",
        muse_setup_event(6, 2, 256, 120),
        "control_out",
        "parse",
        {"event": 6, "detail": 2, "mtu": 256, "seconds_left": 120},
        "Two writes were dropped before the values that follow this event",
    )
    add(
        "muse_setup_event_short",
        muse_setup_event(1, 0, 0, 300)[:-1],
        "control_out",
        "reject",
        {},
        "MUSE_SETUP_EVENT missing the last byte of seconds_left",
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
        "ptt_audio_2frames",
        ptt_audio(7, 0, [frame_payload(0, 25), frame_payload(1, 27)]),
        "data",
        "parse",
        {"turn": 7, "first_frame": 0, "frame_count": 2, "frame_lengths": [25, 27]},
        "The first two frames of a question, from the press",
    )
    add(
        "ptt_audio_truncated",
        struct.pack("<BBHB", MSG_PTT_AUDIO, 7, 2, 3) + struct.pack("<H", 25) + frame_payload(2, 25),
        "data",
        "reject",
        {},
        "PTT_AUDIO announcing 3 frames but carrying 1",
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
