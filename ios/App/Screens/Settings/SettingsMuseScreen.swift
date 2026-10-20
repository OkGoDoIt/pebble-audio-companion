import CompanionRuntime
import Receiver
import SwiftUI

/// Settings · Muse: set Muse up, pair the watch, then ask it things.
///
/// Built around what the person is doing, one step at a time. The top card always says where
/// they are and holds the one thing to do next, as a filled button (the app's status-card
/// rule: filled resolves the state). Setting up is two steps: the SDK token, then pairing.
/// Pairing happens partly on the watch and partly in the Muse app, so while it runs the card is
/// a checklist that says exactly what to do and where. Before anything goes to Meta, the card
/// says what goes (docs/privacy-model.md §4). Once paired, asking comes first; managing the
/// token and forgetting Muse sit at the bottom.
struct SettingsMuseScreen: View {
    @State private var model = MuseScreenModel()
    @State private var confirmForget = false
    @State private var question = ""
    @State private var tokenText = ""
    @FocusState private var askFocused: Bool

    /// Where Muse developers make SDK tokens.
    static let tokenPage = URL(string: "https://gadgets.muse.ai/settings/sdk-tokens")!

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
            pairingCard
        } else if let name = model.pairedName {
            MuseCard(dot: Tokens.good, headline: Copy.Muse.pairedTitle, line: Copy.Muse.pairedLine(name)) {}
            askSection
            whatGoesSection
            manageCard
        } else if !model.hasToken {
            tokenStepCard
        } else {
            pairStepCard
            ListCard { tokenRow }
        }
    }

    // MARK: Step 1: the SDK token

    private var tokenStepCard: some View {
        MuseCard(
            step: Copy.Muse.step(1, of: 2), dot: Tokens.neutralDot,
            headline: Copy.Muse.tokenStepTitle, line: Copy.Muse.tokenStepLine
        ) {
            Link(destination: Self.tokenPage) {
                HStack(spacing: 4) {
                    Text(Copy.Muse.tokenGet)
                    Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                }
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.tint)
            }
            HStack(spacing: 10) {
                SecureField(Copy.Muse.tokenPlaceholder, text: $tokenText)
                    .font(AppFont.callout)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(saveToken)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.fieldFill))
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { tokenText = first }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
            }
            Button(Copy.Muse.tokenSave, action: saveToken)
                .buttonStyle(.inCardFilled)
                .disabled(trimmedToken.isEmpty)
                .opacity(trimmedToken.isEmpty ? 0.5 : 1)
                .padding(.top, 2)
        }
    }

    private var trimmedToken: String { tokenText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveToken() {
        guard !trimmedToken.isEmpty else { return }
        model.setToken(trimmedToken)
        tokenText = ""
    }

    // MARK: Step 2: pairing

    private var pairStepCard: some View {
        let failure: MuseGadgetService.PairingFailure? = {
            if case .failed(let failure) = model.pairing { return failure }
            return nil
        }()
        return MuseCard(
            step: Copy.Muse.step(2, of: 2),
            dot: failure == nil ? Tokens.neutralDot : Tokens.attention,
            headline: failure?.title ?? Copy.Muse.pairStepTitle,
            line: failure?.line ?? Copy.Muse.pairStepLine
        ) {
            // What goes to Meta, said right where the person decides.
            VStack(alignment: .leading, spacing: 6) {
                Text(Copy.Muse.whatGoesHeader)
                    .font(AppFont.footnote.weight(.semibold))
                    .foregroundStyle(Tokens.label)
                Text(Copy.Muse.questionsLine)
                Text(Copy.Muse.trainingLine)
            }
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.secondaryBody)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Tokens.ground))
            Button(failure == nil ? Copy.Muse.pair : Copy.Muse.tryAgain, action: model.pair)
                .buttonStyle(.inCardFilled)
                .padding(.top, 2)
        }
    }

    // MARK: Pairing in progress

    private enum StepState { case done, current, upcoming }

    /// 1 allow on the watch, 2 add in Muse, 3 finish.
    private var currentStep: Int {
        switch model.pairing {
        case .waitingForMuse: return 2
        case .museConnected: return 3
        default: return 1
        }
    }

    private func stepState(_ index: Int) -> StepState {
        index < currentStep ? .done : (index == currentStep ? .current : .upcoming)
    }

    private var pairingCard: some View {
        MuseCard(dot: Tokens.tint, headline: Copy.Muse.pairingTitle) {
            VStack(alignment: .leading, spacing: 14) {
                stepRow(
                    title: Copy.Muse.allowStep,
                    detail: model.pairing == .starting ? nil : Copy.Muse.allowDetail,
                    state: stepState(1))
                stepRow(title: Copy.Muse.addStep, detail: addDetail, state: stepState(2)) {
                    countdown
                }
                stepRow(title: Copy.Muse.finishStep, detail: Copy.Muse.finishDetail, state: stepState(3))
            }
            .padding(.top, 4)
            // The next step happens on the watch or in Muse, so nothing here is primary; leaving
            // is a small helper, not a competing button.
            Button(Copy.Muse.cancel, action: model.cancel)
                .buttonStyle(.smallBordered)
        }
    }

    private var addDetail: String? {
        switch model.pairing {
        case .waitingForMuse(let name, _), .museConnected(let name): return Copy.Muse.addDetail(name)
        default: return nil
        }
    }

    @ViewBuilder
    private var countdown: some View {
        if let deadline = model.windowDeadline, case .waitingForMuse = model.pairing {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(deadline.timeIntervalSince(context.date)))
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(left), total: Double(MuseGadgetService.windowSeconds))
                        .tint(Tokens.tint)
                    Text(Copy.Muse.timeLeft(left))
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .monospacedDigit()
                }
                .padding(.top, 4)
            }
        }
    }

    private func stepRow<Extra: View>(
        title: String, detail: String?, state: StepState,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Tokens.good)
                case .current:
                    ProgressView().controlSize(.small)
                case .upcoming:
                    Image(systemName: "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Tokens.meta.opacity(0.5))
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(state == .current ? AppFont.cardHead : AppFont.subBody)
                    .foregroundStyle(state == .upcoming ? Tokens.meta : Tokens.label)
                if state == .current {
                    if let detail {
                        Text(detail)
                            .font(AppFont.subBody)
                            .foregroundStyle(Tokens.secondaryBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    extra()
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Paired

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

    /// Read once, below what the person came to do.
    private var whatGoesSection: some View {
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

    private var tokenRow: some View {
        SettingsPushRow(title: Copy.Muse.tokenRow, value: Copy.Muse.tokenAdded) {
            MuseTokenScreen(model: model)
        }
    }

    private var manageCard: some View {
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
}

/// The app's status-card shell (`StatusCard`: dot, headline, one calm line, then the action),
/// with room for what a step needs between the line and its action. An optional step caption
/// sits above, so a two-step setup always says how far along it is.
private struct MuseCard<Content: View>: View {
    var step: String? = nil
    let dot: Color
    let headline: String
    var line: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if let step {
                    Text(step)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                }
                HStack(spacing: 8) {
                    StatusDot(color: dot, size: .status)
                    Text(headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if let line {
                    Text(line)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Settings · Muse · SDK token: replace or remove the token once one is saved.
private struct MuseTokenScreen: View {
    let model: MuseScreenModel
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""

    var body: some View {
        SettingsScroll {
            Card {
                VStack(alignment: .leading, spacing: 10) {
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
                    Link(destination: SettingsMuseScreen.tokenPage) {
                        HStack(spacing: 4) {
                            Text(Copy.Muse.tokenGet)
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        }
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.tint)
                    }
                    Button(Copy.Muse.tokenSave, action: save)
                        .buttonStyle(.inCardFilled)
                        .disabled(trimmed.isEmpty)
                        .opacity(trimmed.isEmpty ? 0.5 : 1)
                        .padding(.top, 2)
                }
            }
            ListCard {
                DestructiveRow(title: Copy.Muse.tokenRemove) {
                    model.setToken(nil)
                    dismiss()
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

/// The Muse row on the Settings root, saying "Paired" once it is.
struct MuseSettingsRow: View {
    @State private var model = MuseScreenModel()

    var body: some View {
        SettingsPushRow(
            title: Copy.Muse.rowTitle,
            value: model.isPaired ? Copy.Muse.rowPaired : Copy.Muse.rowNotSetUp,
            valueColor: model.isPaired ? Tokens.good : Tokens.meta
        ) {
            SettingsMuseScreen()
        }
        .task { await model.followPairedName() }
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
            case "starting": pairing = .starting
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
