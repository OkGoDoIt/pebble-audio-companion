import CompanionRuntime
import Receiver
import SwiftUI

/// Settings · Muse: pair the watch with Meta's Muse assistant, then try it.
///
/// Laid out like every opt-in that sends something off the phone (docs/privacy-model.md §4):
/// what it does, exactly what goes to Meta, then the button that starts it. Everything setting
/// Muse up happens here, the SDK token included. The watch does the Bluetooth half of pairing;
/// this screen walks through the steps one heading at a time.
struct SettingsMuseScreen: View {
    @State private var model = MuseScreenModel()
    @State private var confirmForget = false
    @State private var question = ""
    @FocusState private var askFocused: Bool

    var body: some View {
        SettingsScroll {
            content
        }
        .navigationTitle(Copy.Muse.title)
        // Each follows one of the service's values while the screen is up, and ends with it.
        .task { await model.followPairing() }
        .task { await model.followPairedName() }
        .task { await model.followToken() }
    }

    @ViewBuilder
    private var content: some View {
        if model.pairing.isActive {
            stateCard
            ListCard {
                TintActionRow(title: Copy.Muse.cancel, action: model.cancel)
            }
        } else if model.isPaired {
            // Is it working, then try it, then what it sends (read once), then the way out.
            stateCard
            askSection
            whatGoesCard
            forgetCard
        } else if model.hasToken {
            stateCard
            whatGoesCard
            ListCard {
                tokenRow
                TintActionRow(title: pairTitle, action: model.pair)
            }
        } else {
            // First step: the token, typed or pasted right here; then what pairing sends.
            stateCard
            VStack(alignment: .leading, spacing: Tokens.blockGap) {
                SettingsSectionHeader(title: Copy.Muse.tokenHeader)
                ListCard {
                    MuseTokenEntry(model: model)
                    Link(destination: Self.tokenPage) {
                        HStack {
                            Text(Copy.Muse.tokenGet)
                                .font(AppFont.callout)
                                .foregroundStyle(Tokens.tint)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Tokens.meta)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            whatGoesCard
        }
    }

    /// Where Muse developers make SDK tokens.
    static let tokenPage = URL(string: "https://gadgets.muse.ai/settings/sdk-tokens")!

    private var tokenRow: some View {
        SettingsPushRow(title: Copy.Muse.tokenRow, value: Copy.Muse.tokenAdded) {
            MuseTokenScreen(model: model)
        }
    }

    // MARK: State

    private var stateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    StatusDot(color: state.dot, size: .lifecycle)
                    Text(state.heading)
                        .font(AppFont.cardHead)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = state.line {
                    Text(line)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(3)
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
        }
        .accessibilityElement(children: .combine)
    }

    private struct StateText {
        let heading: String
        let line: String?
        let dot: Color
    }

    private var state: StateText {
        switch model.pairing {
        case .starting:
            return StateText(heading: Copy.Muse.startingTitle, line: nil, dot: Tokens.tint)
        case .confirmOnWatch:
            return StateText(heading: Copy.Muse.confirmTitle, line: Copy.Muse.confirmLine, dot: Tokens.tint)
        case .waitingForMuse(let name, _):
            return StateText(heading: Copy.Muse.addTitle, line: Copy.Muse.addLine(name), dot: Tokens.tint)
        case .museConnected:
            return StateText(heading: Copy.Muse.connectedTitle, line: Copy.Muse.connectedLine, dot: Tokens.tint)
        case .failed(let failure):
            return StateText(heading: failure.title, line: failure.line, dot: Tokens.attention)
        case .idle, .paired:
            if let name = model.pairedName {
                return StateText(heading: Copy.Muse.pairedTitle, line: Copy.Muse.pairedLine(name), dot: Tokens.good)
            }
            if !model.hasToken {
                return StateText(heading: Copy.Muse.notSetUpTitle, line: Copy.Muse.notSetUpLine, dot: Tokens.neutralDot)
            }
            return StateText(heading: Copy.Muse.notPairedTitle, line: Copy.Muse.notPairedLine, dot: Tokens.neutralDot)
        }
    }

    private var pairTitle: String {
        if case .failed = model.pairing { return Copy.Muse.tryAgain }
        return Copy.Muse.pair
    }

    // MARK: What goes to Meta

    private var whatGoesCard: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.Muse.whatGoesHeader)
            ListCard {
                ForEach([Copy.Muse.questionsLine, Copy.Muse.trainingLine], id: \.self) { line in
                    Text(line)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.secondaryBody)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: Forget

    private var forgetCard: some View {
        ListCard {
            tokenRow
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

    // MARK: Asking

    private var askSection: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
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

/// The SDK token field: paste or type it, then Save. Used on the Muse screen before the first
/// pairing and on the token screen to replace it.
private struct MuseTokenEntry: View {
    let model: MuseScreenModel
    var onSaved: () -> Void = {}
    @State private var token = ""

    var body: some View {
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

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        model.setToken(trimmed)
        token = ""
        onSaved()
    }
}

/// Settings · Muse · SDK token: replace or remove the token once one is saved.
private struct MuseTokenScreen: View {
    let model: MuseScreenModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsScroll {
            ListCard {
                MuseTokenEntry(model: model) { dismiss() }
                Link(destination: SettingsMuseScreen.tokenPage) {
                    HStack {
                        Text(Copy.Muse.tokenGet)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.tint)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Tokens.meta)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
            case "notsetup": hasToken = false
            case "notpaired": break
            case "confirm": pairing = .confirmOnWatch
            case "waiting": apply(.waitingForMuse(gadgetName: name, secondsLeft: 243))
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
