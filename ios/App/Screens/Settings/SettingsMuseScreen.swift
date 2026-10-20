import CompanionRuntime
import Receiver
import SwiftUI
import UIKit
import WireProtocol

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
        .task { await model.followPreferences() }
        .task { await model.followLastQuestion() }
    }

    @ViewBuilder
    private var content: some View {
        if model.pairing.isActive {
            pairingCard
        } else if let name = model.pairedName {
            MuseCard(dot: Tokens.good, headline: Copy.Muse.pairedTitle, line: Copy.Muse.pairedLine(name)) {}
            watchAskCard
            askSection
            dataSourcesSection
            watchActionsSection
            watchQuestionsSection
            whatGoesSection
            manageCard
        } else if !model.hasToken {
            introCard(showingNeeds: true)
            tokenStepCard
        } else {
            // Already started: what it is for stays, what it takes has been met.
            introCard(showingNeeds: false)
            pairStepCard
            ListCard { tokenRow }
        }
    }

    // MARK: Before setting up

    /// What Muse is for and what setting it up takes, so someone can decide it is worth it
    /// before starting. Shown until the watch is paired.
    private func introCard(showingNeeds: Bool) -> some View {
        let fromWatch = MuseGadgetService.asksFromWatch
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: fromWatch ? "applewatch.radiowaves.left.and.right" : "sparkles")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Tokens.tint.opacity(0.12)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Copy.Muse.introTitle(fromWatch: fromWatch))
                            .font(AppFont.headline)
                            .foregroundStyle(Tokens.label)
                        Text(Copy.Muse.introLine(fromWatch: fromWatch))
                            .font(AppFont.subBody)
                            .foregroundStyle(Tokens.secondaryBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showingNeeds {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Copy.Muse.needsHeader)
                            .font(AppFont.footnote.weight(.semibold))
                            .foregroundStyle(Tokens.label)
                        needRow("iphone", Copy.Muse.needsMuseApp)
                        needRow("key", Copy.Muse.needsToken)
                        needRow("clock", Copy.Muse.needsTime)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func needRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tokens.meta)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(AppFont.footnote)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
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

    /// How to ask from the watch, until a question has been asked; then what Muse heard last,
    /// which is how someone checks it understood them.
    private var watchAskCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Tokens.tint)
                        .accessibilityHidden(true)
                    Text(Copy.Muse.watchAskTitle)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                }
                if let last = model.lastQuestion {
                    lastQuestionView(last)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        howToRow(1, Copy.Muse.watchAskStepSettings)
                        howToRow(2, Copy.Muse.watchAskStepPick)
                        howToRow(3, Copy.Muse.watchAskStepHold)
                    }
                    Text(Copy.Muse.watchAskInApp)
                        .font(AppFont.footnote)
                        .foregroundStyle(Tokens.meta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func howToRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(AppFont.footnote.weight(.semibold))
                .foregroundStyle(Tokens.tint)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Tokens.tint.opacity(0.12)))
                .accessibilityHidden(true)
            Text(text)
                .font(AppFont.subBody)
                .foregroundStyle(Tokens.secondaryBody)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func lastQuestionView(_ last: MusePushToTalk.QuestionReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(Copy.Muse.lastQuestionHeader) · \(last.askedAt.formatted(.relative(presentation: .named)))")
            .font(AppFont.footnote)
            .foregroundStyle(Tokens.meta)
            if let heard = last.heard, !heard.isEmpty {
                Text(Copy.Muse.heard(heard))
                    .font(AppFont.callout)
                    .foregroundStyle(Tokens.label)
                    .fixedSize(horizontal: false, vertical: true)
            } else if last.problem != .didNotCatch {
                Text(Copy.Muse.heardNothing)
                    .font(AppFont.subBody)
                    .foregroundStyle(Tokens.secondaryBody)
            }
            HStack(spacing: 6) {
                StatusDot(color: last.answered ? Tokens.good : Tokens.attention, size: .status)
                Text(last.problem.map(Copy.Muse.lastQuestionProblem) ?? Copy.Muse.answered)
                    .font(AppFont.footnote)
                    .foregroundStyle(Tokens.secondaryBody)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// D7a, D7c-D7e: each source Ask first, Allowed or Off; Calendar and Reminders also need
    /// iOS's permission, asked for here, never in the middle of a question.
    private var dataSourcesSection: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.Muse.seeHeader)
            ListCard {
                sourceRow(.conversations, Copy.Muse.seeConversations, subtitle: Copy.Muse.seeConversationsSubtitle)
                sourceRow(.health, Copy.Muse.seeHealth)
                sourceRow(.calendar, Copy.Muse.seeCalendar, phone: model.calendarPermission)
                sourceRow(.reminders, Copy.Muse.seeReminders, phone: model.remindersPermission)
                sourceRow(.followUps, Copy.Muse.seeFollowUps)
            }
            SettingsFooter(text: Copy.Muse.seeFooter)
        }
        .onAppear { model.refreshPhonePermissions() }
    }

    private func sourceRow(
        _ source: MuseDataSource, _ title: String, subtitle: String? = nil,
        phone: MuseScreenModel.PhonePermission = .granted
    ) -> some View {
        let access = model.preferences.access(source)
        // iOS said no: the row says so whatever Muse is set to, and offers the way to fix it.
        let refused = access != .off && phone == .refused
        // Set to Allowed by hand but iOS hasn't been asked (the request was dismissed).
        let notAsked = access == .allowed && phone == .notAsked
        return VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                ChoiceScreen(
                    title: title,
                    options: [
                        .init(value: MuseAccess.ask, label: Copy.Muse.accessAsk),
                        .init(value: MuseAccess.allowed, label: Copy.Muse.accessAllowed),
                        .init(value: MuseAccess.off, label: Copy.Muse.accessOff),
                    ],
                    selection: Binding(get: { model.preferences.access(source) }, set: { model.setAccess(source, $0) }),
                    footer: Copy.Muse.accessAskFooter)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.label)
                        if let subtitle {
                            Text(subtitle)
                                .font(AppFont.footnote)
                                .foregroundStyle(Tokens.meta)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 10)
                    Text(refused ? Copy.Muse.noPhoneAccess : accessLabel(access))
                        .font(AppFont.subBody)
                        .foregroundStyle(refused ? Tokens.attention : Tokens.meta)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tokens.chevron)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            if refused || notAsked {
                Button(refused ? Copy.Muse.openSettings : Copy.Muse.allowAccess) {
                    if refused {
                        model.openSystemSettings()
                    } else {
                        model.requestPhoneAccess(source)
                    }
                }
                .buttonStyle(.smallBordered)
            }
        }
    }

    private func accessLabel(_ access: MuseAccess) -> String {
        switch access {
        case .ask: return Copy.Muse.accessAsk
        case .allowed: return Copy.Muse.accessAllowed
        case .off: return Copy.Muse.accessOff
        }
    }

    /// D7b: one switch per action, on once paired.
    private var watchActionsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.Muse.actionsHeader)
            ListCard {
                actionToggle(.timer, Copy.Muse.actionTimer)
                actionToggle(.alarm, Copy.Muse.actionAlarm)
                actionToggle(.choice, Copy.Muse.actionChoice)
                actionToggle(.music, Copy.Muse.actionMusic)
                actionToggle(.quietTime, Copy.Muse.actionQuietTime)
                actionToggle(.launchApp, Copy.Muse.actionLaunchApp)
                actionToggle(.findWatch, Copy.Muse.actionFindWatch)
                actionToggle(.recording, Copy.Muse.actionRecording)
            }
            SettingsFooter(text: Copy.Muse.actionsFooter)
        }
    }

    private func actionToggle(_ kind: MuseWatchActionKind, _ title: String) -> some View {
        Toggle(isOn: Binding(
            get: { model.preferences.watchActions.contains(kind) },
            set: { on in model.setAction(kind, on: on) }
        )) {
            Text(title)
                .font(AppFont.callout)
                .foregroundStyle(Tokens.label)
        }
        .tint(Tokens.tint)
    }

    private var watchQuestionsSection: some View {
        VStack(alignment: .leading, spacing: Tokens.blockGap) {
            SettingsSectionHeader(title: Copy.Muse.questionsHeader)
            ListCard {
                SettingsPushRow(
                    title: Copy.Muse.chatRow,
                    value: model.preferences.chatPlace == .watchChat ? Copy.Muse.chatWatch : Copy.Muse.chatMain
                ) {
                    ChoiceScreen(
                        title: Copy.Muse.chatRow,
                        options: [
                            .init(value: MuseChatPlace.watchChat, label: Copy.Muse.chatWatch),
                            .init(value: MuseChatPlace.mainChat, label: Copy.Muse.chatMain),
                        ],
                        selection: Binding(
                            get: { model.preferences.chatPlace },
                            set: { model.setChatPlace($0) }),
                        footer: Copy.Muse.chatFooter)
                }
                SettingsPushRow(title: Copy.Muse.levelRow, value: levelLabel(model.preferences.voiceLevel)) {
                    ChoiceScreen(
                        title: Copy.Muse.levelRow,
                        options: [.init(value: MuseVoiceLevel.automatic, label: Copy.Muse.levelAutomatic)]
                            + stride(from: 0, through: MuseVoiceLevel.fixedRange.upperBound, by: 6).map {
                                .init(value: MuseVoiceLevel.fixed(gainDB: $0), label: Copy.Muse.levelFixed($0))
                            },
                        selection: Binding(
                            get: { model.preferences.voiceLevel },
                            set: { model.setVoiceLevel($0) }),
                        footer: levelFooter)
                }
            }
        }
    }

    private func levelLabel(_ level: MuseVoiceLevel) -> String {
        switch level {
        case .automatic: return Copy.Muse.levelAutomatic
        case .fixed(let gain): return Copy.Muse.levelFixed(gain)
        }
    }

    /// What Automatic does, and what the last question needed, so a fixed level is chosen
    /// from evidence.
    private var levelFooter: String {
        guard let gain = model.lastQuestion?.level?.gainDB else { return Copy.Muse.levelFooterAutomatic }
        return Copy.Muse.levelFooterAutomatic + " " + Copy.Muse.levelLast(Int(gain.rounded()))
    }

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

/// Diagnostics · Voice level check: the next question from the watch is also sent at four
/// levels, and what Muse heard at each is shown side by side. A tool for choosing the automatic
/// target with real questions, not a setting.
struct MuseLevelCheckScreen: View {
    @State private var check: MusePushToTalk.LevelCheck?

    var body: some View {
        SettingsScroll {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(headline)
                        .font(AppFont.headline)
                        .foregroundStyle(Tokens.label)
                    Text(Copy.Muse.levelCheckLine)
                        .font(AppFont.subBody)
                        .foregroundStyle(Tokens.secondaryBody)
                        .fixedSize(horizontal: false, vertical: true)
                    if check == nil || check?.phase == .done || check?.phase == .failed {
                        Button(Copy.Muse.levelCheckStart) { MuseComposition.armLevelCheck() }
                            .buttonStyle(.inCardFilled)
                            .padding(.top, 2)
                    } else if check?.phase == .waiting {
                        Button(Copy.Muse.levelCheckCancel) { MuseComposition.cancelLevelCheck() }
                            .buttonStyle(.smallBordered)
                    } else {
                        ProgressView(
                            value: Double(check?.results.count ?? 0),
                            total: Double(MusePushToTalk.levelCheckTargets.count))
                            .tint(Tokens.tint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let check, !check.results.isEmpty {
                ListCard {
                    ForEach(check.results, id: \.targetDBFS) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Copy.Muse.levelCheckResultTitle(
                                target: Int(result.targetDBFS), gain: Int(result.gainDB.rounded()),
                                automatic: result.targetDBFS == MusePushToTalk.automaticTargetDBFS))
                                .font(AppFont.footnote.weight(.semibold))
                                .foregroundStyle(Tokens.label)
                            Text(result.heard.map(Copy.Muse.heard) ?? Copy.Muse.heardNothing)
                                .font(AppFont.subBody)
                                .foregroundStyle(result.heard == nil ? Tokens.meta : Tokens.secondaryBody)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let speech = check.speechLevelDBFS {
                    SettingsFooter(text: Copy.Muse.levelCheckSpeech(Int(speech.rounded())))
                }
            }
        }
        .navigationTitle(Copy.Muse.levelCheckTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let checks = MuseComposition.levelCheck else { return }
            for await value in checks.stream() { check = value }
        }
    }

    private var headline: String {
        switch check?.phase {
        case .waiting?: return Copy.Muse.levelCheckWaiting
        case .running?: return Copy.Muse.levelCheckRunning
        case .done?: return Copy.Muse.levelCheckDone
        case .failed?: return Copy.Muse.levelCheckFailed
        case nil: return Copy.Muse.levelCheckIdle
        }
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
    private(set) var preferences = MusePreferences()
    private(set) var lastQuestion: MusePushToTalk.QuestionReport?

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
            case "spoken":
                pairedName = name
                lastQuestion = MusePushToTalk.QuestionReport(
                    askedAt: Date().addingTimeInterval(-95), seconds: 2.4, missingFrames: 0,
                    level: nil, heard: "what's the weather in Austin this afternoon", answered: true,
                    problem: nil)
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

    func followPreferences() async {
        guard !previewing else { return }
        for await value in MuseComposition.preferences.current.stream() { preferences = value }
    }

    func followLastQuestion() async {
        guard !previewing, let reports = MuseComposition.lastQuestion else { return }
        for await report in reports.stream() { lastQuestion = report }
    }

    func setAction(_ kind: MuseWatchActionKind, on: Bool) {
        guard !previewing else {
            if on { preferences.watchActions.insert(kind) } else { preferences.watchActions.remove(kind) }
            return
        }
        MuseComposition.preferences.update {
            if on { $0.watchActions.insert(kind) } else { $0.watchActions.remove(kind) }
        }
    }

    func setChatPlace(_ place: MuseChatPlace) {
        guard !previewing else { preferences.chatPlace = place; return }
        MuseComposition.preferences.update { $0.chatPlace = place }
    }

    enum PhonePermission: Equatable { case granted, notAsked, refused }

    private(set) var calendarPermission: PhonePermission = .granted
    private(set) var remindersPermission: PhonePermission = .granted

    func refreshPhonePermissions() {
        guard !previewing else { return }
        calendarPermission = MuseEventKitSource.calendarAuthorized ? .granted : (MuseEventKitSource.calendarRefused ? .refused : .notAsked)
        remindersPermission = MuseEventKitSource.remindersAuthorized ? .granted : (MuseEventKitSource.remindersRefused ? .refused : .notAsked)
    }

    func setAccess(_ source: MuseDataSource, _ access: MuseAccess) {
        if previewing {
            preferences.dataAccess[source] = access
            return
        }
        MuseComposition.preferences.update { $0.dataAccess[source] = access }
        // Set to Allowed by hand: iOS's own permission is asked right then, while the screen is
        // up. Ask first never asks iOS up front; that waits until Muse first wants the source
        // (docs/privacy-model.md, D7d).
        if access == .allowed, source == .calendar || source == .reminders {
            requestPhoneAccess(source)
        }
    }

    func requestPhoneAccess(_ source: MuseDataSource) {
        Task {
            let events = MuseComposition.eventKit
            switch source {
            case .calendar: _ = await events.requestCalendar()
            case .reminders: _ = await events.requestReminders()
            default: break
            }
            refreshPhonePermissions()
        }
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    func setVoiceLevel(_ level: MuseVoiceLevel) {
        guard !previewing else { preferences.voiceLevel = level; return }
        MuseComposition.preferences.update { $0.voiceLevel = level }
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
