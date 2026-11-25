import SwiftUI
import Transcription

/// Settings · Transcription & AI → **On this iPhone** (pushed).
///
/// Which engine transcribes on the phone. Two rows for almost everyone: the Pebble model and Apple
/// Speech, each with a bar for how much quiet conversation it catches. Choosing one that is not
/// here starts getting it, and the engine in use keeps transcribing until it is ready.
struct SettingsLocalModelScreen: View {
    @Environment(AppSettings.self) private var settings

    private var model: LocalModelManaging { SettingsDataSources.current.localModel }

    @State private var removeTarget: LocalModelOption?
    @State private var openRow: String?

    var body: some View {
        SettingsScroll {
            ListCard(rowVerticalPadding: 0, rowHorizontalPadding: 0) {
                ForEach(model.listed) { option in
                    row(option)
                }
            }
            // Anchored to the card that raises it. Attached to `SettingsScroll` the source rect is
            // the whole screen and iOS 26 places the panel against the top of it, far from the row.
            .confirmationDialog(
                removeTarget.map { Copy.OnThisIPhone.removeTitle($0.displayName) } ?? "",
                isPresented: Binding(
                    get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: removeTarget
            ) { target in
                Button(Copy.OnThisIPhone.remove, role: .destructive) { remove(target) }
            } message: { target in
                if let size = target.sizeText {
                    Text(Copy.Settings.TranscriptionAI.removeModelNote(size))
                }
            }

            SettingsFooter(text: Copy.OnThisIPhone.footer)
        }
        .navigationTitle(Copy.Settings.TranscriptionAI.localModel)
        .navigationBarTitleDisplayMode(.inline)
        // Re-reading install state is the only thing opening this screen does.
        .task { model.refresh() }
        .onChange(of: model.state(for: settings.shownLocalTranscriptionModelId)) {
            settings.adoptPendingLocalModel(state: model.state(for:))
        }
        #if DEBUG
            .onAppear {
                // Screenshots: a state that is on its way is on its way because it was chosen.
                let shown = model.state(for: ParakeetModelCatalog.watchModelId)
                if UserDefaults.standard.string(forKey: "localmodel.state") != nil {
                    settings.pendingLocalTranscriptionModelId =
                        shown == .installed ? nil : ParakeetModelCatalog.watchModelId
                    settings.localTranscriptionModelId =
                        shown == .installed
                        ? ParakeetModelCatalog.watchModelId : LocalModelCatalog.appleSpeechId
                }
            }
        #endif
    }

    private func row(_ option: LocalModelOption) -> some View {
        let state = model.state(for: option.id)
        // Apple Speech is the system's and the floor under everything else: nothing to remove.
        let removable = option.isDownloadable && state == .installed
        return SwipeRow(
            rowID: option.id,
            trailing: removable
                ? [
                    SwipeAction(
                        id: "remove", title: Copy.OnThisIPhone.remove, systemImage: "trash",
                        tint: Tokens.destructive
                    ) { removeTarget = option }
                ] : [],
            openRow: $openRow
        ) {
            LocalModelRow(
                option: option,
                state: state,
                isInUse: option.id == inUseId,
                choose: { choose(option) },
                overCellular: { model.downloadOverCellular(option.id) },
                cancel: { cancel(option) }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .contextMenu {
            if removable {
                Button(role: .destructive) {
                    removeTarget = option
                } label: {
                    Label(Copy.OnThisIPhone.remove, systemImage: "trash")
                }
            }
        }
    }

    /// The row with the check: the engine in use. A persisted choice that names no row (a language
    /// tag from the old app) is Apple Speech.
    private var inUseId: String {
        let id = settings.localTranscriptionModelId
        return model.model(id) == nil ? LocalModelCatalog.appleSpeechId : id
    }

    private func choose(_ option: LocalModelOption) {
        let state = model.state(for: option.id)
        if state == .installed {
            settings.pendingLocalTranscriptionModelId = nil
            settings.localTranscriptionModelId = option.id
            return
        }
        guard !state.isBusy else { return }
        if option.isDownloadable { settings.pendingLocalTranscriptionModelId = option.id }
        model.download(option.id)
    }

    private func cancel(_ option: LocalModelOption) {
        if settings.pendingLocalTranscriptionModelId == option.id {
            settings.pendingLocalTranscriptionModelId = nil
        }
        model.cancelDownload(option.id)
    }

    private func remove(_ option: LocalModelOption) {
        Haptics.destructiveConfirmed()
        if settings.localTranscriptionModelId == option.id {
            settings.localTranscriptionModelId = LocalModelCatalog.appleSpeechId
        }
        model.delete(option.id)
        openRow = nil
        removeTarget = nil
    }
}

// MARK: - Model row

/// Name, what it is, how much it catches, and whatever the engine is doing — with real progress and
/// a Cancel while something is moving.
private struct LocalModelRow: View {
    let option: LocalModelOption
    let state: LocalModelState
    let isInUse: Bool
    let choose: () -> Void
    let overCellular: () -> Void
    let cancel: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        layout {
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(option.displayName)
                            .font(AppFont.callout)
                            .foregroundStyle(Tokens.label)
                        if typeSize.isAccessibilitySize { check }
                    }
                    Text(detail)
                        .font(AppFont.footnote)
                        .foregroundStyle(state == .failed ? Tokens.attention : Tokens.tertiary)
                        .multilineTextAlignment(.leading)
                    if case .downloading(let progress) = state {
                        ProgressView(value: progress).tint(Tokens.tint).padding(.top, 5)
                    } else if let hearing = option.hearing {
                        HearingBar(level: hearing).padding(.top, 5)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .unavailable)
            // Busy rows do nothing, but a disabled button would grey out the progress it shows.
            .allowsHitTesting(!state.isBusy)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isInUse ? .isSelected : [])
            .accessibilityAddTraits(.isButton)

            accessory
        }
    }

    /// One line: what it costs and covers, or what is happening to it.
    private var detail: String {
        switch state {
        case .waitingForWiFi: return Copy.OnThisIPhone.waitingForWiFi
        case .downloading(let progress):
            return Copy.OnThisIPhone.downloaded(progress, of: option.downloadBytes ?? 0)
        case .installing, .preparing: return Copy.OnThisIPhone.settingUp
        case .failed: return Copy.OnThisIPhone.failed
        case .needsSpace(let free):
            return Copy.OnThisIPhone.needsSpace(
                (option.downloadBytes ?? 0) * 2 + 200_000_000, free: free)
        case .unavailable where option.isDownloadable: return Copy.OnThisIPhone.cannotRunHere
        case .unavailable: return Copy.OnThisIPhone.noSystemModel
        case .notInstalled, .installed:
            let facts = option.isOffered ? option.description : option.shortLabel
            return [option.sizeText ?? option.shortLabel, facts]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch state {
        case .notInstalled:
            Button(Copy.OnThisIPhone.get, action: choose).buttonStyle(.smallBordered)
                .accessibilityLabel(Copy.OnThisIPhone.getLabel(option.displayName))
        case .waitingForWiFi:
            Button(Copy.OnThisIPhone.useCellular, action: overCellular).buttonStyle(.smallBordered)
        case .downloading:
            Button(Copy.Common.cancel, action: cancel)
                .font(AppFont.smallButton)
                .foregroundStyle(Tokens.tint)
                .buttonStyle(.plain)
                .frame(minHeight: 44)
        case .installing, .preparing:
            ProgressView()
        case .failed:
            Button(Copy.Common.tryAgain, action: choose).buttonStyle(.smallBordered)
        case .needsSpace:
            NavigationLink(Copy.OnThisIPhone.storage) { SettingsStorageScreen() }
                .buttonStyle(.smallBordered)
        case .installed:
            if !typeSize.isAccessibilitySize { check }
        case .unavailable:
            EmptyView()
        }
    }

    /// Beside the name at accessibility sizes, where the row stacks and a check on its own line
    /// would belong to nothing.
    @ViewBuilder
    private var check: some View {
        if isInUse {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Tokens.tint)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        var parts = [option.displayName, detail]
        if let hearing = option.hearing { parts.append(Copy.OnThisIPhone.hearing(hearing)) }
        if isInUse { parts.append(Copy.Settings.TranscriptionAI.inUse) }
        return parts.joined(separator: ", ")
    }
}

/// How much quiet conversation an engine catches, as five segments.
private struct HearingBar: View {
    let level: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { step in
                Capsule()
                    .fill(step <= level ? Tokens.tint : Tokens.track)
                    .frame(height: 6)
            }
        }
        .frame(maxWidth: 220)
        .accessibilityHidden(true)
    }
}

#Preview("On this iPhone") {
    NavigationStack {
        SettingsLocalModelScreen()
    }
    .environment(AppSettings())
    .tint(Tokens.tint)
}
