import Foundation
import Testing
@testable import WireProtocol

/// Runs every golden fixture in Fixtures/ (copied from spec/fixtures/) against the
/// decoder/encoder. The fixtures are normative (spec Section 9): if this test disagrees with a
/// fixture, the Swift implementation is wrong.
/// Port of `core/protocol/src/jvmTest/.../GoldenFixtureTest.kt`.
@Suite struct GoldenFixtureTest {

    struct FixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func fixturesDir() throws -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            throw FixtureError("Bundle.module has no resourceURL")
        }
        let dir = resourceURL.appendingPathComponent("Fixtures", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw FixtureError("Fixtures directory missing at \(dir.path)")
        }
        return dir
    }

    private func loadFixtures() throws -> [(meta: [String: Any], bin: [UInt8])] {
        let dir = try fixturesDir()
        // speex_* are codec fixtures (real encoded frames), not protocol-message fixtures.
        let jsonFiles = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("speex_") }
            .sorted()
        try #require(jsonFiles.count >= 44, "expected at least 44 fixtures, found \(jsonFiles.count)")
        return try jsonFiles.map { jsonName in
            let jsonURL = dir.appendingPathComponent(jsonName)
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL))
            guard let meta = object as? [String: Any] else {
                throw FixtureError("\(jsonName): top-level JSON is not an object")
            }
            let binName = String(jsonName.dropLast(".json".count)) + ".bin"
            let bin = try [UInt8](Data(contentsOf: dir.appendingPathComponent(binName)))
            return (meta, bin)
        }
    }

    private func decode(channel: String, bytes: [UInt8]) throws -> DecodeResult {
        switch channel {
        case "info": return AudioCompanionProtocol.decodeInfo(bytes)
        case "control_in": return AudioCompanionProtocol.decodeControlIn(bytes)
        case "control_out": return AudioCompanionProtocol.decodeControlOut(bytes)
        case "data": return AudioCompanionProtocol.decodeData(bytes)
        default: throw FixtureError("unknown fixture channel: \(channel)")
        }
    }

    @Test func allFixturesBehaveAsSpecified() throws {
        var parsed = 0
        var rejected = 0
        var ignored = 0
        for (meta, bin) in try loadFixtures() {
            let name = try str(meta, "name")
            let expect = try str(meta, "expect")
            let channel = try str(meta, "channel")
            let expectedSize = try #require(Int(try str(meta, "size")), "\(name): non-integer size")
            #expect(bin.count == expectedSize, "\(name): .bin size vs json size")
            let result = try decode(channel: channel, bytes: bin)
            switch expect {
            case "parse":
                guard case .decoded(let message) = result else {
                    Issue.record("\(name): expected parse, got \(result)")
                    continue
                }
                verifyReEncode(name, message, bin)
                guard let fields = meta["fields"] as? [String: Any] else {
                    Issue.record("\(name): fixture json has no 'fields' object")
                    continue
                }
                verifyFields(name, message, fields)
                parsed += 1
            case "reject":
                guard case .malformed = result else {
                    Issue.record("\(name): expected reject, got \(result)")
                    continue
                }
                rejected += 1
            case "ignore":
                guard case .unknownMessage = result else {
                    Issue.record("\(name): expected ignore, got \(result)")
                    continue
                }
                ignored += 1
            default:
                throw FixtureError("\(name): unknown expect '\(expect)'")
            }
        }
        // Sanity: the v1 fixture set has all three classes well represented.
        #expect(parsed >= 30, "parsed=\(parsed)")
        #expect(rejected >= 8, "rejected=\(rejected)")
        #expect(ignored == 2, "ignored=\(ignored)")
    }

    private func verifyReEncode(_ name: String, _ message: AudioCompanionMessage, _ bin: [UInt8]) {
        let encoded = message.encode()
        if name.hasSuffix("_v2_appended") {
            // Future-version fixture: our v1 encoder must reproduce the v1 prefix exactly.
            #expect(encoded.count < bin.count, "\(name): v1 encoding should be shorter than appended fixture")
            #expect(
                hex(Array(bin.prefix(encoded.count))) == hex(encoded),
                "\(name): re-encoded v1 prefix mismatch"
            )
        } else {
            #expect(hex(bin) == hex(encoded), "\(name): re-encoded bytes mismatch")
        }
    }

    /// Asserts every field value in the fixture json against the decoded message.
    private func verifyFields(_ name: String, _ message: AudioCompanionMessage, _ fields: [String: Any]) {
        let actual = extractFields(message)
        for (key, expected) in fields {
            guard let actualValue = actual[key] else {
                Issue.record("\(name): decoded \(type(of: message)) has no field '\(key)'")
                continue
            }
            let expectedValue: String
            if let array = expected as? [Any] {
                expectedValue = "[" + array.map { jsonContent($0) }.joined(separator: ", ") + "]"
            } else {
                expectedValue = jsonContent(expected)
            }
            #expect(expectedValue == actualValue, "\(name): field '\(key)'")
        }
    }

    private func extractFields(_ message: AudioCompanionMessage) -> [String: String] {
        switch message {
        case let m as InfoSnapshot:
            return [
                "info_version": String(m.infoVersion),
                "protocol_min": String(m.protocolMin),
                "protocol_max": String(m.protocolMax),
                "service_state": String(m.serviceStateRaw),
                "codec_bitmap": String(m.codecBitmap),
                "flags": String(m.flags),
                "fw_version_packed": String(m.fwVersionPacked),
            ]
        case let m as AuthRequest:
            return [
                "proto_version": String(m.protoVersion),
                "request_token": String(m.requestToken),
                "receiver_id_hex": hex(m.receiverId),
                "name": m.name,
                "name_len": String(m.name.utf8.count),
            ]
        case let m as AuthRevoke:
            return [
                "request_token": String(m.requestToken),
                "receiver_id_hex": hex(m.receiverId),
            ]
        case let m as Checkpoint:
            return [
                "request_token": String(m.requestToken),
                "stream_id": String(m.streamId),
                "highest_contiguous_sequence_persisted": String(m.highestContiguousSequencePersisted),
                "persisted_sample_index": String(m.persistedSampleIndex),
                "receiver_flags": String(m.receiverFlags),
                "free_storage_hint_kb": String(m.freeStorageHintKb),
            ]
        case let m as PauseRequest:
            return [
                "request_token": String(m.requestToken),
                "reason": String(m.reasonRaw),
            ]
        case let m as ResumeRequest:
            return [
                "request_token": String(m.requestToken),
            ]
        case let m as EnableRequest:
            return [
                "request_token": String(m.requestToken),
            ]
        case let m as ReceiverHealth:
            return [
                "request_token": String(m.requestToken),
                "battery_pct": String(m.batteryPct),
                "app_state": String(m.appStateRaw),
                "queue_depth_frames": String(m.queueDepthFrames),
            ]
        case let m as AuthResult:
            return [
                "request_token": String(m.requestToken),
                "status": String(m.statusRaw),
                "granted_proto_version": String(m.grantedProtoVersion),
            ]
        case let m as Revoked:
            return [
                "reason": String(m.reasonRaw),
            ]
        case let m as Ack:
            return [
                "request_token": String(m.requestToken),
                "status": String(m.statusRaw),
            ]
        case let m as StateChanged:
            return [
                "service_state": String(m.serviceStateRaw),
            ]
        case let m as ErrorMessage:
            return [
                "error_code": String(m.errorCodeRaw),
                "detail": String(m.detail),
            ]
        case let m as StreamStart:
            return [
                "protocol_version": String(m.protocolVersion),
                "stream_id": String(m.streamId),
                "codec_id": String(m.codecIdRaw),
                "channels": String(m.channels),
                "frame_samples": String(m.frameSamples),
                "sample_rate_hz": String(m.sampleRateHz),
                "bit_rate_bps": String(m.bitRateBps),
                "frame_duration_ms": String(m.frameDurationMs),
                "start_time_ms": String(m.startTimeMs),
                "start_monotonic_ms": String(m.startMonotonicMs),
                "flags": String(m.flags),
            ]
        case let m as StreamData:
            return [
                "stream_id": String(m.streamId),
                "first_sequence": String(m.firstSequence),
                "first_sample_index": String(m.firstSampleIndex),
                "frame_count": String(m.frameCount),
                "frame_lengths": "[" + m.frames.map { String($0.count) }.joined(separator: ", ") + "]",
                "flags": String(m.flags),
            ]
        case let m as StreamGap:
            return [
                "stream_id": String(m.streamId),
                "first_missing_sequence": String(m.firstMissingSequence),
                "missing_frame_count": String(m.missingFrameCount),
                "first_missing_sample_index": String(m.firstMissingSampleIndex),
                "reason": String(m.reasonRaw),
                "watch_drop_counter": String(m.watchDropCounter),
            ]
        case let m as StreamStop:
            return [
                "stream_id": String(m.streamId),
                "reason": String(m.reasonRaw),
                "final_sequence": String(m.finalSequence),
                "final_sample_index": String(m.finalSampleIndex),
                "counters_crc_or_zero": String(m.countersCrcOrZero),
            ]
        default:
            return [:]
        }
    }

    /// Mirrors kotlinx `jsonPrimitive.content`: the primitive's literal content as a string.
    private func jsonContent(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return "\(value)"
    }

    private func str(_ meta: [String: Any], _ key: String) throws -> String {
        guard let value = meta[key] else { throw FixtureError("fixture json missing '\(key)'") }
        return jsonContent(value)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
