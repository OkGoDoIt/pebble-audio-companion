// Copyright 2026 Apple Inc.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause
// Vendored into PebbleAudioKit from apple/coreai-models @ 1ff17c3 (2026-09-17); the changes
// against upstream are listed in ../VENDORING.md.

#if canImport(CoreAI)
import Foundation

// MARK: - Duration Time Conversions

/// Convenience conversions from `Duration` to floating-point time units, shared
/// across the package's command-line tools and profiling code for elapsed-time reporting.
///
/// Example usage:
/// ```swift
/// let start = ContinuousClock.now
/// // ... do work ...
/// let elapsed = (ContinuousClock.now - start).inSeconds
/// print("Elapsed: \(elapsed)s")
/// ```
@available(iOS 27, macOS 27, *)
extension Duration {
    /// Duration in seconds as a `Double`.
    package var inSeconds: Double {
        let (secs, attoseconds) = components
        return Double(secs) + Double(attoseconds) / 1e18
    }

    /// Duration in milliseconds as a `Double`.
    package var inMilliseconds: Double {
        inSeconds * 1000.0
    }
}
#endif
