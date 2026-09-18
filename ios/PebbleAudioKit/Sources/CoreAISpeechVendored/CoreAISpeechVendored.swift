import Foundation

// The one declaration in this module that exists on every platform.
//
// Everything else is under `#if canImport(CoreAI)`: the framework ships in the iOS 27 device SDK
// and the macOS 27 SDK but NOT in the iPhoneSimulator SDK, so on a simulator this module is
// empty and the engine that wraps it reports `isSupported == false`. This flag lets a caller
// (and a test) state which of the two worlds it is in without repeating the condition.

public enum CoreAISpeechVendoredModule {
    /// True when the vendored Core AI speech code was compiled into this build.
    public static var isCompiledIn: Bool {
        #if canImport(CoreAI)
            return true
        #else
            return false
        #endif
    }
}
