import CompanionRuntime
import Receiver
import SwiftUI

/// Settings · Muse: pair the watch with Meta's Muse assistant, then try it.
///
/// The watch does the Bluetooth half of pairing: the Muse app finds it as a new device while this
/// screen walks through the steps, one heading and one line at a time.
struct SettingsMuseScreen: View {
    @State private var model = MuseScreenModel()
    @State private var confirmForget = false
    @State private var question = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        SettingsScroll {
            statusCard
            if model.isPaired && !model.pairing.isActive {
                askSection
            } else {
                setupCard
            }
            if model.isPaired && !model.pairing.isActive {
                ListCard {
                    DestructiveRow(title: Copy.Muse.forget) { confirmForget = true }
                }
                .confirmationDialog(Copy.Muse.forgetTitle, isPresented: $confirmForget, titleVisibility: .visible) {
                    Button(Copy.Muse.forgetConfirm, role: .destructive) {
                        Haptics.destructiveConfirmed()
                        model.forget()
                    }
                } message: {
                    Text(Copy.Muse.forgetMessage)
                }
            }
        }
        .navigationTitle(Copy.Muse.title)
        // Each follows one of the service's values while the screen is up, and ends with it.
        .task { await model.followPairing() }
        .task { await model.followPairedName() }
        .task { await model.followToken() }
    }

    // MARK: Status

    private var statusCard: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    if let line = status.line {
                        Text(line)
                            .font(AppFont.subBody)
                            .foregroundStyle(Tokens.secondaryBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let deadline = model.windowDeadline, case .waitingForMuse = model.pairing {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = max(0, Int(deadline.timeIntervalSince(context.date)))
                            VStack(alignment: .leading, spacing: 6) {
                                ProgressView(value: Double(left), total: Double(MuseGadgetService.windowSeconds))
                                    .tint(Tokens.tint)
                                Text(Copy.Muse.timeLeft(left))
                                    .font(AppFont.footnote)
                                    .foregroundStyle(Tokens.meta)
                                    .monospacedDigit()
                            }
                            .padding(.top, 6)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        ZStack {
            Circle().fill(status.tone.opacity(0.14))
            if model.pairing.isActive {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(status.tone)
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }

    private struct Status {
        let title: String
        let line: String?
        let symbol: String
        let tone: Color
    }

    private var status: Status {
        switch model.pairing {
        case .starting:
            return Status(title: Copy.Muse.startingTitle, line: nil, symbol: "applewatch", tone: Tokens.tint)
        case .confirmOnWatch:
            return Status(title: Copy.Muse.confirmTitle, line: Copy.Muse.confirmLine, symbol: "applewatch", tone: Tokens.tint)
        case .waitingForMuse(let name, _):
            return Status(title: Copy.Muse.addTitle, line: Copy.Muse.addLine(name), symbol: "plus.circle", tone: Tokens.tint)
        case .museConnected:
            return Status(title: Copy.Muse.connectedTitle, line: Copy.Muse.connectedLine, symbol: "link", tone: Tokens.tint)
        case .failed(let failure):
            return Status(title: failure.title, line: failure.line, symbol: "exclamationmark", tone: Tokens.attention)
        case .idle, .paired:
            if let name = model.pairedName {
                return Status(title: Copy.Muse.pairedTitle, line: Copy.Muse.pairedLine(name), symbol: "checkmark", tone: Tokens.good)
            }
            return Status(title: Copy.Muse.notPairedTitle, line: Copy.Muse.notPairedLine, symbol: "sparkles", tone: Tokens.meta)
        }
    }

    // MARK: Setup

    private var setupCard: some View {
        ListCard {
            // Settled before a window opens; nothing to look at while one is.
            if !model.pairing.isActive {
                SettingsPushRow(
                    title: Copy.Muse.tokenRow,
                    value: model.hasToken ? Copy.Muse.tokenAdded : Copy.Muse.tokenMissing,
                    valueColor: model.hasToken ? Tokens.meta : Tokens.attention
                ) {
                    MuseTokenScreen(model: model)
                }
            }
            if model.pairing.isActive {
                TintActionRow(title: Copy.Muse.cancel, action: model.cancel)
            } else if model.hasToken {
                TintActionRow(title: pairTitle, action: model.pair)
            } else {
                Text(Copy.Muse.tokenNeeded)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.meta)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pairTitle: String {
        if case .failed = model.pairing { return Copy.Muse.tryAgain }
        return Copy.Muse.pair
    }

    // MARK: Asking

    @ViewBuilder
    private var askSection: some View {
        SettingsSectionHeader(title: Copy.Muse.askHeader)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField(Copy.Muse.askPlaceholder, text: $question, axis: .vertical)
                        .font(AppFont.callout)
                        .lineLimit(1...4)
                        .focused($askFocused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? Tokens.tint : Tokens.meta.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel(Copy.Muse.askSend)
                }
                answerView
            }
        }
    }

    @ViewBuilder
    private var answerView: some View {
        switch model.ask {
        case .idle:
            EmptyView()
        case .asking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(Copy.Muse.asking)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.meta)
            }
        case .answered(let text, let complete):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !complete {
                    Text(Copy.Muse.askIncomplete)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
            }
        case .failed:
            Text(Copy.Muse.askFailed)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.attention)
        }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.ask != .asking
    }

    private func send() {
        guard canSend else { return }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        askFocused = false
        model.send(text)
    }
}

/// Settings · Muse · Gadget token.
private struct MuseTokenScreen: View {
    let model: MuseScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        SettingsScroll {
            ListCard {
                HStack(spacing: 10) {
                    SecureField(Copy.Muse.tokenPlaceholder, text: $token)
                        .font(AppFont.callout)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { token = first }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.capsule)
                }
                TintActionRow(title: Copy.Muse.tokenSave, action: save)
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.5 : 1)
            }
            if model.hasToken {
                ListCard {
                    DestructiveRow(title: Copy.Muse.tokenRemove) {
                        model.setToken(nil)
                        dismiss()
                    }
                }
            }
            SettingsFooter(text: Copy.Muse.tokenFooter)
        }
        .navigationTitle(Copy.Muse.tokenTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.setToken(trimmed)
        token = ""
        dismiss()
    }
}

// MARK: - Model

@MainActor
@Observable
final class MuseScreenModel {
    enum AskState: Equatable {
        case idle
        case asking
        case answered(String, complete: Bool)
        case failed
    }

    private(set) var pairing: MuseGadgetService.PairingState = .idle
    private(set) var pairedName: String?
    private(set) var hasToken = false
    /// When the watch's window closes, while one is open.
    private(set) var windowDeadline: Date?
    private(set) var ask: AskState = .idle

    var isPaired: Bool { pairedName != nil }

    /// `-muse.preview <state>` shows one state without a watch, for reviewing the screen in the
    /// Simulator. DEBUG builds only.
    private var previewing = false

    init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-muse.preview"), index + 1 < args.count {
            previewing = true
            hasToken = true
            let name = "MuseGadgetF1A69C"
            switch args[index + 1] {
            case "confirm": pairing = .confirmOnWatch
            case "waiting":
                apply(.waitingForMuse(gadgetName: name, secondsLeft: 243))
            case "connected": pairing = .museConnected(gadgetName: name)
            case "timedout": pairing = .failed(.timedOut)
            case "answered":
                pairedName = name
                ask = .answered("It's 72°F and sunny in Austin right now, with a light breeze from the south.", complete: true)
            default: pairedName = name
            }
        }
        #endif
    }

    private var service: MuseGadgetService? { previewing ? nil : MuseComposition.service }

    func followPairing() async {
        guard let service else { return }
        for await state in service.pairing.stream() { apply(state) }
    }

    func followPairedName() async {
        guard let service else { return }
        for await name in service.pairedName.stream() { pairedName = name }
    }

    func followToken() async {
        guard let service else { return }
        for await has in service.hasSDKToken.stream() { hasToken = has }
    }

    private func apply(_ state: MuseGadgetService.PairingState) {
        if case .waitingForMuse(_, let secondsLeft) = state {
            windowDeadline = Date().addingTimeInterval(TimeInterval(secondsLeft))
        } else if !state.isActive {
            windowDeadline = nil
        }
        pairing = state
    }

    func pair() {
        guard let service else { return }
        Task { await service.startPairing() }
    }

    func cancel() {
        guard let service else { return }
        Task { await service.cancelPairing() }
    }

    func forget() {
        guard let service else { return }
        ask = .idle
        Task { await service.forget() }
    }

    func setToken(_ token: String?) {
        guard let service else { return }
        Task { await service.setSDKToken(token) }
    }

    func send(_ message: String) {
        guard let service, ask != .asking else { return }
        ask = .asking
        Task {
            do {
                let answer = try await service.ask(message, trace: { AppRuntimeLog.shared.record("muse  ask: \($0)") })
                let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ask = text.isEmpty ? .failed : .answered(text, complete: answer.complete)
            } catch {
                AppRuntimeLog.shared.record("muse  ask failed: \(error)")
                ask = .failed
            }
        }
    }
}

extension MuseGadgetService.PairingFailure {
    var title: String {
        switch self {
        case .watchNotConnected: return Copy.Muse.watchNotConnectedTitle
        case .watchNeedsUpdate: return Copy.Muse.watchNeedsUpdateTitle
        case .timedOut: return Copy.Muse.timedOutTitle
        case .didNotFinish: return Copy.Muse.didNotFinishTitle
        case .couldNotStart: return Copy.Muse.couldNotStartTitle
        }
    }

    var line: String {
        switch self {
        case .watchNotConnected: return Copy.Muse.watchNotConnectedLine
        case .watchNeedsUpdate: return Copy.Muse.watchNeedsUpdateLine
        case .timedOut: return Copy.Muse.timedOutLine
        case .didNotFinish: return Copy.Muse.didNotFinishLine
        case .couldNotStart: return Copy.Muse.couldNotStartLine
        }
    }
}

#Preview("Muse") {
    NavigationStack {
        SettingsMuseScreen()
    }
    .tint(Tokens.tint)
}
