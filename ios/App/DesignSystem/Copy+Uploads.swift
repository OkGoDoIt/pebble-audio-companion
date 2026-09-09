import Foundation

// Strings for the upload-network setting. An extension on `Copy` — still the one approved
// catalog — in its own file because `Copy.swift` is a large shared surface and this is a
// self-contained vocabulary.
//
// Vocabulary rules that apply here:
// - Never "background URLSession", "cellular access" or "constrained network". The person is
//   deciding whether this app may spend their data plan; that is the only idea on screen.
// - The footer names real, measured numbers. A vague "may use significant data" is an excuse, not
//   information, and this is a product where the person is entitled to know exactly what it costs
//   them. Both numbers are measured on this user's own library. Uncompressed WAV is 115 MB per
//   hour of audio (32,000 B/s at 16 kHz — 141 MB/day, 12.38 GB over 88 days). The watch's own
//   Speex frames repackaged are a deterministic 4.08% of that: **4.7 MB per hour**. FLAC — the
//   fallback rung for a provider that cannot read them — measured 29-34% on four real segments,
//   mean 31%: **about 35 MB per hour**, and content-dependent because it actually compresses.
//   Both are stated, because which one applies depends on the provider and the person should not
//   be told only the flattering half. See `OggSpeex` and `CloudUploadFormatPreference`.
// - The reassurance is the load-bearing half: on Wi-Fi Only nothing is dropped, only delayed.
//   Without that sentence the setting reads as a choice between data and transcripts, which
//   would be false and would push people to the expensive answer for the wrong reason.

extension Copy.Settings.TranscriptionAI {
    static let uploadNetwork = "Upload Audio"
    static let uploadNetworkFooter =
        "Cloud transcription sends each recording to your provider — about 5 MB per hour of audio, "
        + "or around 35 MB if your provider needs it re-encoded. On Wi-Fi Only, recordings wait "
        + "for Wi-Fi instead. Nothing is lost while they wait."
}
