import SwiftUI

/// M1 gate: every reusable component rendered in every state, in one scrollable screen
/// (companion to `TokenGallery`).
struct ComponentGallery: View {
    @State private var selectedOption = 1
    @State private var renamingChip = true
    @State private var snackbar: SnackbarItem?
    @State private var tappedSpan: String = "tap the strip"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusCards
                onboardingFailures
                lifecycleCards
                cards
                chips
                dotsAndBadges
                buttons
                waveform
                coverage
                rows
                sheetChrome
                snackbarSection
            }
            .padding(Tokens.screenMargin)
        }
        .background(Tokens.ground)
        .navigationTitle("Components")
        .snackbar(item: $snackbar)
    }

    // MARK: Status cards — the approved families, exact copy

    private var statusCards: some View {
        section("Status card families") {
            StatusCard(
                dotColor: Tokens.good,
                headline: Copy.Status.recording,
                line: Copy.Status.recordingLine(device: "Pebble Time 2")
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Status.paused,
                line: Copy.Status.pausedLine,
                action: .init(title: Copy.Status.resume, style: .filled) {}
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Status.reconnecting,
                line: Copy.Status.reconnectingLine,
                action: .init(title: Copy.Status.findWatch, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.destructive,
                headline: Copy.Status.bluetoothOff,
                line: Copy.Status.bluetoothOffLine,
                action: .init(title: Copy.Status.openSettings, style: .filled) {}
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Status.notRecording,
                line: Copy.Status.notRecordingLine,
                action: .init(title: Copy.Status.startRecording, style: .filled) {}
            )
            StatusCard(
                dotColor: Tokens.tint,
                headline: Copy.Status.confirmOnWatch,
                line: Copy.Status.confirmOnWatchLine
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Status.transcriptsOff,
                line: Copy.Status.transcriptsOffLine,
                action: .init(title: Copy.Status.setUpTranscripts, style: .filled) {}
            )
        }
    }

    private var onboardingFailures: some View {
        section("Onboarding failure branches") {
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Onboarding.Failure.noPebbleFound,
                line: Copy.Onboarding.Failure.noPebbleFoundLine,
                action: .init(title: Copy.Common.tryAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Onboarding.Failure.cantSendAudio,
                line: Copy.Onboarding.Failure.cantSendAudioLine,
                action: .init(title: Copy.Onboarding.Failure.firmwareGuide, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Onboarding.Failure.declined,
                line: Copy.Onboarding.Failure.declinedLine,
                action: .init(title: Copy.Common.tryAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.attention,
                headline: Copy.Onboarding.Failure.boundElsewhere,
                line: Copy.Onboarding.Failure.boundElsewhereLine,
                action: .init(title: Copy.Common.tryAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.neutralDot,
                headline: Copy.Onboarding.Failure.noAnswer,
                line: Copy.Onboarding.Failure.noAnswerLine,
                action: .init(title: Copy.Onboarding.Failure.askAgain, style: .bordered) {}
            )
            StatusCard(
                dotColor: Tokens.destructive,
                headline: Copy.Onboarding.Failure.bluetoothDenied,
                line: Copy.Onboarding.Failure.bluetoothDeniedLine,
                action: .init(title: Copy.Status.openSettings, style: .bordered) {}
            )
        }
    }

    private var lifecycleCards: some View {
        section("Conversation lifecycle") {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusDot(color: Tokens.captured, size: .lifecycle)
                        Text(Copy.Conversation.capturedWaiting)
                            .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    }
                    Text(Copy.Conversation.queueLine("3rd"))
                        .font(AppFont.caption).foregroundStyle(Tokens.tertiary)
                    Button(Copy.Conversation.transcribeNow) {}.buttonStyle(.smallBordered)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusDot(color: Tokens.tint, size: .lifecycle)
                        Text(Copy.Conversation.transcribing)
                            .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    }
                    ProgressView(value: 0.55).tint(Tokens.tint)
                    Text(
                        Copy.Conversation.transcribingLine(
                            provider: "Soniox", remaining: "a minute"
                        )
                    )
                    .font(AppFont.caption).foregroundStyle(Tokens.tertiary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusDot(color: Tokens.attention, size: .lifecycle)
                        Text(Copy.Conversation.didntFinish)
                            .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    }
                    Text(Copy.Conversation.didntFinishLine)
                        .font(AppFont.caption).foregroundStyle(Tokens.tertiary)
                    Button(Copy.Conversation.retryNow) {}.buttonStyle(.smallBordered)
                }
            }
        }
    }

    // MARK: Cards

    private var cards: some View {
        section("Cards") {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Content card").font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    Text("Padding 14/16, radius 12, surface background.")
                        .font(AppFont.subBody).foregroundStyle(Tokens.tertiary)
                }
            }
            ListCard {
                SettingsRow(title: "List card row", value: "value") {}
                SettingsRow(title: "Hairlines between rows", showsChevron: false)
                SettingsRow(title: "Never after the last", showsChevron: false)
            }
            OptionCard(
                title: Copy.Onboarding.inCloudTitle,
                subtitle: Copy.Onboarding.inCloudBody,
                isSelected: selectedOption == 1
            ) { selectedOption = 1 }
            OptionCard(
                title: Copy.Onboarding.laterTitle,
                subtitle: Copy.Onboarding.laterBody,
                isSelected: selectedOption == 2
            ) { selectedOption = 2 }
        }
    }

    // MARK: Chips

    private var chips: some View {
        section("Chips") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(text: "travel", count: 12) {}
                    FilterChip(text: "work", count: 8) {}
                    FilterChip(text: Copy.Library.moreTags) {}
                }
            }
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                TagChip(text: "work")
                TagChip(text: "planning")
                TagChip(text: "money", style: .onGround)
                Text("(gray · gray · on-ground)")
                    .font(AppFont.micro).foregroundStyle(Tokens.faint)
            }
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                EditableTagChip(text: "work", onRemove: {})
                EditableTagChip(text: "planning", isRenaming: renamingChip)
                    .onTapGesture { renamingChip.toggle() }
                EditableTagChip(text: "money", onRemove: {})
            }
            FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                SuggestionChip(name: "budget") {}
                SuggestionChip(name: "evening") {}
                SuggestionChip(name: "family") {}
            }
            FlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                ActionPill(title: Copy.Conversation.ask, systemImage: "sparkles", style: .filled) {}
                ActionPill(title: Copy.Conversation.notes) {}
                ActionPill(title: Copy.Conversation.followUps) {}
            }
        }
    }

    // MARK: Dots & badges

    private var dotsAndBadges: some View {
        section("Dots & badges") {
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.good, size: .status)
                    StatusDot(color: Tokens.attention, size: .status)
                    StatusDot(color: Tokens.destructive, size: .status)
                    StatusDot(color: Tokens.neutralDot, size: .status)
                    StatusDot(color: Tokens.tint, size: .status)
                }
                Text("10pt").font(AppFont.micro).foregroundStyle(Tokens.faint)
                HStack(spacing: 8) {
                    StatusDot(color: Tokens.captured, size: .lifecycle)
                    StatusDot(color: Tokens.attention, size: .lifecycle)
                }
                Text("8pt").font(AppFont.micro).foregroundStyle(Tokens.faint)
                StatusDot(color: Tokens.quiet, size: .legend)
                Text("7pt").font(AppFont.micro).foregroundStyle(Tokens.faint)
            }
            HStack(spacing: 10) {
                LiveBadge()
                Text("App redesign session").font(AppFont.rowTitle)
                    .foregroundStyle(Tokens.label)
            }
        }
    }

    // MARK: Buttons

    private var buttons: some View {
        section("Buttons") {
            Button(Copy.Onboarding.connectButton) {}.buttonStyle(.primaryFilled)
            Button(Copy.Status.resume) {}.buttonStyle(.inCardFilled)
            Button(Copy.Status.findWatch) {}.buttonStyle(.borderedTint)
            HStack {
                Button(Copy.Conversation.retryNow) {}.buttonStyle(.smallBordered)
                Button(Copy.Settings.TranscriptionAI.testConnection) {}
                    .buttonStyle(.smallBordered)
            }
            HStack(spacing: 10) {
                TransportButton(title: Copy.Live.pause, systemImage: "pause.fill") {}
                TransportButton(title: Copy.Live.stop, systemImage: "stop.fill", role: .stop) {}
            }
            HStack(spacing: 20) {
                CirclePlayButton {}
                CirclePlayButton(isPlaying: true) {}
                CircleSendButton {}
            }
        }
    }

    // MARK: Waveform

    private var waveform: some View {
        section("Live-minute waveform") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    WaveformView(slots: .sampleLiveMinute)
                    WaveformLegend()
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    WaveformView(
                        slots: (0..<WaveformView.slotCount).map {
                            if $0 % 17 == 4 { return WaveformBar(amplitude: 0, state: .missing) }
                            return WaveformBar(amplitude: 0, state: $0 < 40 ? .quiet : .skipped)
                        }
                    )
                    WaveformLegend(showPaused: true)
                }
            }
        }
    }

    // MARK: Coverage

    private var coverage: some View {
        section("Day coverage strip") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            coverageHeadline
                            Spacer()
                            coverageMissing
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            coverageHeadline
                            coverageMissing
                        }
                    }
                    CoverageStrip(spans: .sampleDay) { span in
                        tappedSpan = String(describing: span.kind)
                    }
                    Text("Tapped: \(tappedSpan)")
                        .font(AppFont.micro).foregroundStyle(Tokens.faint)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Day with a pause (striped)")
                        .font(AppFont.cardHead).foregroundStyle(Tokens.label)
                    CoverageStrip(spans: .sampleDayWithPause, showAxis: false)
                }
            }
        }
    }

    private var coverageHeadline: some View {
        Text(Copy.Today.recorded("4 hr 12 min"))
            .font(AppFont.cardHead).foregroundStyle(Tokens.label)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var coverageMissing: some View {
        Text(Copy.Today.missing("1 min"))
            .font(AppFont.speaker).foregroundStyle(Tokens.missing)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rows

    private var rows: some View {
        section("Rows") {
            ListCard {
                SettingsRow(
                    title: Copy.Settings.TranscriptionAI.mode,
                    value: Copy.Settings.TranscriptionAI.cloudFirst
                ) {}
                SettingsRow(
                    title: Copy.Settings.Storage.keepAudio,
                    value: Copy.Settings.Storage.keepDays(30)
                ) {}
                SettingsRow(
                    title: Copy.Settings.Watch.watchReports,
                    value: Copy.Status.recording,
                    showsChevron: false
                )
            }
            ListCard {
                DestructiveRow(title: Copy.Settings.Storage.deleteAll) {}
            }
        }
    }

    // MARK: Sheet chrome

    private var sheetChrome: some View {
        section("Sheet chrome") {
            Card {
                VStack(spacing: 12) {
                    SheetGrabber()
                    SheetTitleRow(title: Copy.Tags.title) {
                        Button(Copy.Common.done) {}
                            .font(AppFont.headline)
                            .foregroundStyle(Tokens.tint)
                    }
                    SheetTitleRow(title: Copy.Ask.title) {
                        FilterChip(text: "\(Copy.Ask.scopeLastDays(2)) ⌄") {}
                    }
                }
            }
        }
    }

    // MARK: Snackbar

    private var snackbarSection: some View {
        section("Snackbar") {
            Button("Delete a conversation") {
                snackbar = SnackbarItem(
                    message: Copy.Conversation.deleted,
                    actionTitle: Copy.Common.undo,
                    action: {}
                )
            }
            .buttonStyle(.borderedTint)
        }
    }

    // MARK: Helpers

    private func section(
        _ title: String, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(AppFont.sectionHeader)
                .foregroundStyle(Tokens.meta)
                .kerning(0.4)
            content()
        }
    }
}

#Preview {
    NavigationStack { ComponentGallery() }
}
