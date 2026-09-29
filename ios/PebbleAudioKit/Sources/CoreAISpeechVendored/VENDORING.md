# CoreAISpeechVendored

A vendored copy of the `CoreAISpeech` library from
[apple/coreai-models](https://github.com/apple/coreai-models) (BSD-3-Clause, see `LICENSE`),
taken at commit `1ff17c3080f28dc7f6f85b20c5cb6e95bc7d36a4` (2026-09-17), plus the five
`CoreAIShared` files it depends on. It runs Parakeet TDT bundles exported by that repo's
`export.py` on Apple's Core AI runtime.

## Why a copy and not a dependency

The upstream package declares `platforms: [.iOS("27.0"), .macOS("27.0")]`; this kit deploys to
iOS 26 / macOS 26, and SwiftPM refuses a dependency whose floor is higher than the dependent's.
The upstream package also pulls in swift-transformers, whose only use inside `CoreAISpeech` is
tokenizer *decoding* (id → piece).

## Changes against upstream (every one is marked `Vendoring change` / `Vendoring addition` in
## the source)

Mechanical, applied to every vendored file:

- The whole file body sits inside `#if canImport(CoreAI)` … `#endif`. `CoreAI.framework` is in
  the iOS 27 device SDK and the macOS 27 SDK but absent from the iPhoneSimulator SDK, so on a
  simulator this module compiles to (almost) nothing and the wrapping engine reports
  unsupported.
- Every top-level declaration carries `@available(iOS 27, macOS 27, *)`, matching the
  availability of every Core AI type it touches (`AIModel`, `NDArray`, `InferenceFunction`, …
  are all `@available(macOS 27.0, iOS 27.0, …)` in the SDK's swiftinterface).
- `import CoreAIShared` and `import Tokenizers` are dropped (one module now; no
  swift-transformers).
- A two-line provenance note after the license header.

By hand:

- `SpeechRecognitionBundle.tokenizer` is a `ParakeetTokenizer?` (our `Tokenizer/
  ParakeetTokenizer.swift`, NOT vendored) instead of swift-transformers' `(any Tokenizer)?`.
  `loadParakeetTokenizer` builds it from `processor/tokenizer.json`. The Whisper tokenizer
  loader returns nil and the macOS-only `huggingFaceCacheSnapshot` helper it used is removed: a
  Whisper bundle still loads but `detokenize` throws `SpeechError.missingTokenizer`. The app
  only installs Parakeet bundles.
- `SpeechRecognitionModel.detokenize` calls `ParakeetTokenizer.decode(tokens:)` (comment only;
  the call shape is the same).
- `SpeechRecognitionModel.cancelStream()` (in `StreamingSession.swift`) is new: it drops a
  running session with `CancellationError` instead of flushing the tail, which is what a
  cancelled transcription needs.
- `SpeechRecognitionModel.init(resourcesAt:decoderOptions:)` and
  `SpeechRecognitionBundle.init(at:decoderOptions:)` take a `SpecializationOptions` for a Parakeet
  TDT bundle's `decoder_step` and `joint` graphs (the encoder keeps the default). Upstream loads
  all three with the default. The app passes `.cpuOnly`: those graphs run dozens of times per
  second of audio, and on a phone each Neural Engine dispatch cost more than the work (see
  `CoreAIParakeetEngine.decoderOnCPU`). Default argument, so every upstream call site is
  unchanged.

Not copied: `FunctionMap`, `NpyArray`, `ModelStructure`, `ResourceManaging`,
`ModelIONameResolver`, `FileSize`, the Video/Image/Text helpers, and every CLI tool — none is
referenced by `CoreAISpeech`.

## Correctness check

`Tests/CoreAISpeechVendoredTests` transcribes real watch recordings through this copy and
asserts the text is byte-identical to what the upstream `speech-recognizer` CLI (with
swift-transformers) produced for the same bundle. Environment variables:

- `PEBBLE_COREAI_BUNDLE` — a `--streaming` export directory (required for the suite to run).
- `PEBBLE_COREAI_FIXTURES` — a directory with `wavs/<name>.wav` and
  `results/<prefix><name>.hyp.txt` (+ `.out` for the segment timestamps); required.
- `PEBBLE_COREAI_HYP_PREFIX` — the streaming results prefix, default `f16stream_`.
- `PEBBLE_COREAI_STATIC_BUNDLE` / `PEBBLE_COREAI_STATIC_HYP_PREFIX` (default `f16s45_`) — a
  static export and its offline CLI outputs, for the engine's offline path; optional.
- `PEBBLE_COREAI_ARCHIVE` — the zip that is pushed to a phone, for the end-to-end inbox install
  test (our ZIP reader, wrapper hoist, real prepare pass); optional.

Without the required variables the suite records a skip, so plain `swift test` stays green.
The DSP loops are slow in a Debug build (the 900 s clip takes minutes); the numbers are the
same, only the wait differs.

## Re-vendoring

Copy the same files from a newer upstream, re-run the mechanical steps (the annotation is
one `@available` line before every column-0 declaration and its attributes), re-apply the
hand edits above, and re-run the correctness check with the CLI output from the same
upstream commit.
