import Foundation

// Settings · Transcription & AI · Local model — the Core AI entry (iOS 27). `Copy.swift` is the
// approved catalog and stays as it is; this adds one namespace beside it.
//
// The one rule: the row must never invite an action the phone cannot complete. On iOS 26 the
// Core AI model cannot run at all, so its row says so and is not selectable, and the notice
// above the list — which for any other missing model says "tap it to download" — says what
// would actually change things instead.

extension Copy {
    enum CoreAI {
        /// Row state on a phone that cannot run it (iOS 26, or no Core AI in this build). Same
        /// register as the other lowercase row states ("not installed", "finishing up").
        static let needsIOS27 = "needs iOS 27"

        /// The fallback notice when the SELECTED model is the Core AI one and this phone cannot
        /// run it, e.g. "Parakeet TDT 0.6B · Core AI needs iOS 27 on an iPhone, so Apple Speech
        /// is transcribing. Choose another model to change that."
        static func unavailableNotice(_ name: String) -> String {
            "\(name) needs iOS 27 on an iPhone, so Apple Speech is transcribing. "
                + "Choose another model to change that."
        }

        /// Under the description of a model nothing is hosted for yet: how it actually gets
        /// onto the phone. Names the exact Files path because there is no button to press.
        static func importHint(_ id: String) -> String {
            "Not downloadable yet. To try it, put \(id).zip in Files › On My iPhone › "
                + "Pebble Audio › models-inbox and choose the model."
        }

        /// Debug-only row on the local-model screen: the quiet-audio boost experiment
        /// (`ParakeetQuietAudioBoost`). Never shipped as a setting.
        static let debugBoostTitle = "Debug: boost quiet audio for local models"
        static let debugBoostSubtitle =
            "Peak-normalizes each chunk to −3 dBFS before the local engine hears it. "
            + "An experiment; affects new transcriptions only."
    }
}
