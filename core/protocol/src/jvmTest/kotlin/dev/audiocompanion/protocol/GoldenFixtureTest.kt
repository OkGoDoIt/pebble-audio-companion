package dev.audiocompanion.protocol

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Runs every golden fixture in spec/fixtures/ against the decoder/encoder.
 * The fixtures are normative (spec Section 9): if this test disagrees with a fixture,
 * the Kotlin implementation is wrong.
 */
class GoldenFixtureTest {

    private val fixturesDir: File = findFixturesDir()

    private fun findFixturesDir(): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        while (dir != null) {
            val candidate = File(dir, "spec/fixtures")
            if (candidate.isDirectory) return candidate
            dir = dir.parentFile
        }
        fail("Could not locate spec/fixtures above ${System.getProperty("user.dir")}")
    }

    private fun loadFixtures(): List<Pair<JsonObject, ByteArray>> {
        // speex_* are codec fixtures (real encoded frames), not protocol-message fixtures.
        val jsonFiles = fixturesDir
            .listFiles { f -> f.extension == "json" && !f.name.startsWith("speex_") }
            ?.sortedBy { it.name }
            ?: fail("No fixtures found in $fixturesDir")
        assertTrue(jsonFiles.size >= 44, "expected at least 44 fixtures, found ${jsonFiles.size}")
        return jsonFiles.map { jsonFile ->
            val meta = Json.parseToJsonElement(jsonFile.readText()).jsonObject
            val bin = File(fixturesDir, jsonFile.nameWithoutExtension + ".bin").readBytes()
            meta to bin
        }
    }

    private fun decode(channel: String, bytes: ByteArray): DecodeResult = when (channel) {
        "info" -> AudioCompanionProtocol.decodeInfo(bytes)
        "control_in" -> AudioCompanionProtocol.decodeControlIn(bytes)
        "control_out" -> AudioCompanionProtocol.decodeControlOut(bytes)
        "data" -> AudioCompanionProtocol.decodeData(bytes)
        else -> fail("unknown fixture channel: $channel")
    }

    @Test
    fun allFixturesBehaveAsSpecified() {
        var parsed = 0
        var rejected = 0
        var ignored = 0
        for ((meta, bin) in loadFixtures()) {
            val name = meta.str("name")
            val expect = meta.str("expect")
            val channel = meta.str("channel")
            assertEquals(bin.size, meta.str("size").toInt(), "$name: .bin size vs json size")
            val result = decode(channel, bin)
            when (expect) {
                "parse" -> {
                    val decoded = assertIs<DecodeResult.Decoded>(
                        result, "$name: expected parse, got $result"
                    )
                    verifyReEncode(name, decoded.message, bin)
                    verifyFields(name, decoded.message, meta["fields"]!!.jsonObject)
                    parsed++
                }
                "reject" -> {
                    assertIs<DecodeResult.Malformed>(result, "$name: expected reject, got $result")
                    rejected++
                }
                "ignore" -> {
                    assertIs<DecodeResult.UnknownMessage>(result, "$name: expected ignore, got $result")
                    ignored++
                }
                else -> fail("$name: unknown expect '$expect'")
            }
        }
        // Sanity: the v1 fixture set has all three classes well represented.
        assertTrue(parsed >= 30, "parsed=$parsed")
        assertTrue(rejected >= 8, "rejected=$rejected")
        assertEquals(2, ignored)
    }

    private fun verifyReEncode(name: String, message: AudioCompanionMessage, bin: ByteArray) {
        val encoded = message.encode()
        if (name.endsWith("_v2_appended")) {
            // Future-version fixture: our v1 encoder must reproduce the v1 prefix exactly.
            assertTrue(encoded.size < bin.size, "$name: v1 encoding should be shorter than appended fixture")
            assertEquals(
                bin.copyOfRange(0, encoded.size).toHex(), encoded.toHex(),
                "$name: re-encoded v1 prefix mismatch"
            )
        } else {
            assertEquals(bin.toHex(), encoded.toHex(), "$name: re-encoded bytes mismatch")
        }
    }

    /** Asserts every field value in the fixture json against the decoded message. */
    private fun verifyFields(name: String, message: AudioCompanionMessage, fields: JsonObject) {
        val actual = extractFields(message)
        for ((key, expected) in fields) {
            val actualValue = actual[key] ?: fail("$name: decoded ${message::class.simpleName} has no field '$key'")
            val expectedValue = when (expected) {
                is JsonArray -> expected.jsonArray.map { it.jsonPrimitive.content }.toString()
                else -> expected.jsonPrimitive.content
            }
            assertEquals(expectedValue, actualValue, "$name: field '$key'")
        }
    }

    private fun extractFields(message: AudioCompanionMessage): Map<String, String> = when (message) {
        is InfoSnapshot -> mapOf(
            "info_version" to message.infoVersion.toString(),
            "protocol_min" to message.protocolMin.toString(),
            "protocol_max" to message.protocolMax.toString(),
            "service_state" to message.serviceStateRaw.toString(),
            "codec_bitmap" to message.codecBitmap.toString(),
            "flags" to message.flags.toString(),
            "fw_version_packed" to message.fwVersionPacked.toString(),
        )
        is AuthRequest -> mapOf(
            "proto_version" to message.protoVersion.toString(),
            "request_token" to message.requestToken.toString(),
            "receiver_id_hex" to message.receiverId.toHex(),
            "name" to message.name,
            "name_len" to message.name.encodeToByteArray().size.toString(),
        )
        is AuthRevoke -> mapOf(
            "request_token" to message.requestToken.toString(),
            "receiver_id_hex" to message.receiverId.toHex(),
        )
        is Checkpoint -> mapOf(
            "request_token" to message.requestToken.toString(),
            "stream_id" to message.streamId.toString(),
            "highest_contiguous_sequence_persisted" to message.highestContiguousSequencePersisted.toString(),
            "persisted_sample_index" to message.persistedSampleIndex.toString(),
            "receiver_flags" to message.receiverFlags.toString(),
            "free_storage_hint_kb" to message.freeStorageHintKb.toString(),
        )
        is PauseRequest -> mapOf(
            "request_token" to message.requestToken.toString(),
            "reason" to message.reasonRaw.toString(),
        )
        is ResumeRequest -> mapOf(
            "request_token" to message.requestToken.toString(),
        )
        is EnableRequest -> mapOf(
            "request_token" to message.requestToken.toString(),
        )
        is ReceiverHealth -> mapOf(
            "request_token" to message.requestToken.toString(),
            "battery_pct" to message.batteryPct.toString(),
            "app_state" to message.appStateRaw.toString(),
            "queue_depth_frames" to message.queueDepthFrames.toString(),
        )
        is AuthResult -> mapOf(
            "request_token" to message.requestToken.toString(),
            "status" to message.statusRaw.toString(),
            "granted_proto_version" to message.grantedProtoVersion.toString(),
        )
        is Revoked -> mapOf(
            "reason" to message.reasonRaw.toString(),
        )
        is Ack -> mapOf(
            "request_token" to message.requestToken.toString(),
            "status" to message.statusRaw.toString(),
        )
        is StateChanged -> mapOf(
            "service_state" to message.serviceStateRaw.toString(),
        )
        is ErrorMessage -> mapOf(
            "error_code" to message.errorCodeRaw.toString(),
            "detail" to message.detail.toString(),
        )
        is StreamStart -> mapOf(
            "protocol_version" to message.protocolVersion.toString(),
            "stream_id" to message.streamId.toString(),
            "codec_id" to message.codecIdRaw.toString(),
            "channels" to message.channels.toString(),
            "frame_samples" to message.frameSamples.toString(),
            "sample_rate_hz" to message.sampleRateHz.toString(),
            "bit_rate_bps" to message.bitRateBps.toString(),
            "frame_duration_ms" to message.frameDurationMs.toString(),
            "start_time_ms" to message.startTimeMs.toString(),
            "start_monotonic_ms" to message.startMonotonicMs.toString(),
            "flags" to message.flags.toString(),
        )
        is StreamData -> mapOf(
            "stream_id" to message.streamId.toString(),
            "first_sequence" to message.firstSequence.toString(),
            "first_sample_index" to message.firstSampleIndex.toString(),
            "frame_count" to message.frameCount.toString(),
            "frame_lengths" to message.frames.map { it.size.toString() }.toString(),
            "flags" to message.flags.toString(),
        )
        is StreamGap -> mapOf(
            "stream_id" to message.streamId.toString(),
            "first_missing_sequence" to message.firstMissingSequence.toString(),
            "missing_frame_count" to message.missingFrameCount.toString(),
            "first_missing_sample_index" to message.firstMissingSampleIndex.toString(),
            "reason" to message.reasonRaw.toString(),
            "watch_drop_counter" to message.watchDropCounter.toString(),
        )
        is StreamStop -> mapOf(
            "stream_id" to message.streamId.toString(),
            "reason" to message.reasonRaw.toString(),
            "final_sequence" to message.finalSequence.toString(),
            "final_sample_index" to message.finalSampleIndex.toString(),
            "counters_crc_or_zero" to message.countersCrcOrZero.toString(),
        )
    }

    private fun JsonObject.str(key: String): String = this[key]!!.jsonPrimitive.content

    private fun ByteArray.toHex(): String = joinToString("") { b ->
        (b.toInt() and 0xFF).toString(16).padStart(2, '0')
    }
}
