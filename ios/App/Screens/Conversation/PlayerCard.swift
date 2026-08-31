import SwiftUI

/// The conversation player card (mockup 2.6): 44pt play, scrubber with the amber missing
/// tick, timecodes, and the 1× speed pill cycling 1 → 1.5 → 2. Backed by `PlayerModel`, a
/// display-side stand-in with the same surface as `SegmentPlaybackController` so the runtime
/// can swap the real decoder-backed controller in later.
struct PlayerCard: View {
    @Bindable var model: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            CirclePlayButton(isPlaying: model.playing) {
                model.togglePlay()
            }

            VStack(spacing: 6) {
                scrubber
                HStack {
                    Text(TimeFmt.timecode(model.positionMs))
                    Spacer()
                    Text(TimeFmt.timecode(model.durationMs))
                }
                .font(AppFont.micro)
                .foregroundStyle(Tokens.meta)
            }

            Button {
                model.cycleSpeed()
            } label: {
                Text(model.speedLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.tint)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Tokens.tintBorder))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playback speed \(model.speedLabel)")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.cardRadius))
        .accessibilityElement(children: .contain)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = model.durationMs > 0
                ? CGFloat(model.positionMs) / CGFloat(model.durationMs) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.fieldFill).frame(height: 4)
                Capsule().fill(Tokens.tint)
                    .frame(width: max(4, width * min(fraction, 1)), height: 4)
                if let tick = model.missingTickFraction {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Tokens.missing)
                        .frame(width: 3, height: 6)
                        .offset(x: width * CGFloat(tick) - 1.5)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 8)
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / max(width, 1), 0), 1)
                        model.seek(fraction: Double(fraction))
                    }
            )
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            "\(TimeFmt.timecode(model.positionMs)) of \(TimeFmt.timecode(model.durationMs))")
        .accessibilityAdjustableAction { direction in
            let step = model.durationMs / 20
            switch direction {
            case .increment: model.seek(positionMs: model.positionMs + step)
            case .decrement: model.seek(positionMs: model.positionMs - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class PlayerModel {
    var playing = false
    var positionMs: Int64 = 0
    var durationMs: Int64 = 0
    var speed: Double = 1
    var missingTickFraction: Double?

    private var ticker: Task<Void, Never>?

    var speedLabel: String {
        switch speed {
        case 1.5: return "1.5×"
        case 2: return "2×"
        default: return "1×"
        }
    }

    func configure(_ display: PlayerDisplay, atMs: Int64?) {
        durationMs = display.durationMs
        positionMs = min(atMs ?? display.initialPositionMs, display.durationMs)
        missingTickFraction = display.missingTickFraction
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    func play() {
        guard durationMs > 0 else { return }
        if positionMs >= durationMs { positionMs = 0 }
        playing = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while let self, self.playing, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, self.playing else { return }
                self.positionMs += Int64(250 * self.speed)
                if self.positionMs >= self.durationMs {
                    self.positionMs = self.durationMs
                    self.pause()
                }
            }
        }
    }

    func pause() {
        playing = false
        ticker?.cancel()
        ticker = nil
    }

    /// 1× → 1.5× → 2× → 1× (mockup 2.6).
    func cycleSpeed() {
        switch speed {
        case 1: speed = 1.5
        case 1.5: speed = 2
        default: speed = 1
        }
    }

    func seek(fraction: Double) {
        seek(positionMs: Int64(fraction * Double(durationMs)))
    }

    func seek(positionMs: Int64) {
        self.positionMs = min(max(positionMs, 0), durationMs)
    }
}

#Preview("Player") {
    PlayerCard(model: {
        let model = PlayerModel()
        model.configure(
            PlayerDisplay(
                durationMs: 18 * 60_000 + 12_000,
                initialPositionMs: 4 * 60_000 + 1_000,
                missingTickFraction: 0.61),
            atMs: nil)
        return model
    }())
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
