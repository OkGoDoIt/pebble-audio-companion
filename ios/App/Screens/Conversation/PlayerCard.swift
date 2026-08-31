import SwiftUI

/// The conversation player card (mockup 2.6): 44pt play, scrubber with the amber missing
/// ticks, timecodes, and the 1× speed pill cycling 1 → 1.5 → 2. Backed by `PlayerModel`,
/// which drives the real decoder-backed engine when the conversation has stored audio and
/// falls back to a simulated scrub only in the mock/demo world, which has none.
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
                // Every gap, not just the first: loss is never summarized away.
                ForEach(Array(model.missingTicks.enumerated()), id: \.offset) { _, tick in
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
    var missingTicks: [Double] = []

    /// The decoder-backed engine over the conversation's stored frames. Nil in the mock and
    /// preview worlds, where `ticker` stands in for it.
    private var engine: (any ConversationPlayback)?
    private var configuredId: String?
    private var observation: Task<Void, Never>?
    private var ticker: Task<Void, Never>?

    var speedLabel: String {
        switch speed {
        case 1.5: return "1.5×"
        case 2: return "2×"
        default: return "1×"
        }
    }

    /// Idempotent per conversation: the screen reloads its display after every rename, tag
    /// edit and retranscribe, and playback must not restart under the user each time.
    func configure(
        _ display: PlayerDisplay, atMs: Int64?, id: String,
        engine: (any ConversationPlayback)? = nil
    ) {
        missingTicks = display.missingTickFractions
        guard configuredId != id else {
            if durationMs == 0 { durationMs = display.durationMs }
            return
        }
        stop()
        configuredId = id
        self.engine = engine
        durationMs = engine.map { $0.durationMs > 0 ? $0.durationMs : display.durationMs }
            ?? display.durationMs
        positionMs = min(atMs ?? display.initialPositionMs, durationMs)
        if let engine {
            engine.setSpeed(speed)
            // Seed the engine BEFORE subscribing: its first update carries the engine's own
            // position, which would otherwise immediately overwrite the deep link's `?t=`
            // (or the display's initial position) with zero.
            engine.seek(toMs: positionMs)
            observe(engine)
        }
    }

    private func observe(_ engine: any ConversationPlayback) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await update in engine.progress() {
                guard let self, !Task.isCancelled else { return }
                self.playing = update.playing
                self.positionMs = update.positionMs
                if update.durationMs > 0 { self.durationMs = update.durationMs }
            }
        }
    }

    func togglePlay() {
        playing ? pause() : play()
    }

    func play() {
        guard durationMs > 0 else { return }
        if positionMs >= durationMs { positionMs = 0 }
        playing = true
        if let engine {
            engine.play(fromMs: positionMs)
        } else {
            simulate()
        }
    }

    func pause() {
        playing = false
        ticker?.cancel()
        ticker = nil
        engine?.pause()
    }

    /// Leaving the screen has to end the audio — a conversation that keeps playing from a
    /// screen the user popped is the kind of thing this app can never do.
    func stop() {
        playing = false
        ticker?.cancel()
        ticker = nil
        observation?.cancel()
        observation = nil
        engine?.stop()
    }

    /// 1× → 1.5× → 2× → 1× (mockup 2.6).
    func cycleSpeed() {
        switch speed {
        case 1: speed = 1.5
        case 1.5: speed = 2
        default: speed = 1
        }
        engine?.setSpeed(speed)
    }

    func seek(fraction: Double) {
        seek(positionMs: Int64(fraction * Double(durationMs)))
    }

    func seek(positionMs: Int64) {
        let clamped = min(max(positionMs, 0), durationMs)
        self.positionMs = clamped
        engine?.seek(toMs: clamped)
    }

    /// The demo/preview stand-in: no audio exists in the mock world, so the scrubber moves on
    /// its own to show the card working. Never used against real recordings.
    private func simulate() {
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
}

#Preview("Player") {
    PlayerCard(model: {
        let model = PlayerModel()
        model.configure(
            PlayerDisplay(
                durationMs: 18 * 60_000 + 12_000,
                initialPositionMs: 4 * 60_000 + 1_000,
                missingTickFractions: [0.61]),
            atMs: nil, id: "preview")
        return model
    }())
    .padding(Tokens.screenMargin)
    .background(Tokens.ground)
}
