import AppDB
import SwiftUI

/// A permanent, named entry point: even a mark without any recording has a home.
struct MarkedMomentsEntry: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MomentsModel()

    var body: some View {
        Button { router.push(.markedMoments) } label: {
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "pin.fill").foregroundStyle(Tokens.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Marked moments").font(AppFont.headline).foregroundStyle(Tokens.label)
                        Text(model.error != nil ? "Open your saved moments"
                             : model.moments.isEmpty ? "Mark something on your watch to find it here"
                             : "\(model.moments.count) saved · Return to what mattered")
                            .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Tokens.chevron)
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: scenePhase) { if scenePhase == .active { await model.observe() } }
    }
}

struct MarkedMomentsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MomentsModel()
    @State private var selected: Moment?
    @State private var query = ""
    @State private var refresh = 0

    private var filtered: [Moment] {
        guard !query.isEmpty else { return model.moments }
        return model.moments.filter { $0.note.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("The moments you wanted to come back to.")
                    .font(AppFont.subBody).foregroundStyle(Tokens.meta)
                if let error = model.error {
                    Text(error).foregroundStyle(Tokens.meta)
                    Button("Try again") { refresh += 1 }
                } else if model.loaded, model.moments.isEmpty {
                    ContentUnavailableView("Keep a moment", systemImage: "pin",
                        description: Text("On your Pebble, assign Mark Moment to a Quick Launch button. Hold it when something matters. Your saved marks will appear here, even before a transcript is ready."))
                } else if filtered.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
                ForEach(filtered) { moment in
                    MomentRow(moment: moment, source: model.source, refresh: refresh) {
                        selected = moment
                    }
                }
            }
            .padding(Tokens.screenMargin)
        }
        .background(Tokens.ground)
        .navigationTitle("Marked moments")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search your notes")
        .refreshable { refresh += 1 }
        .task(id: "\(scenePhase)-\(refresh)") {
            if scenePhase == .active { await model.observe() }
        }
        .sheet(item: $selected) { moment in
            MomentDetailSheet(moment: model.moments.first(where: { $0.id == moment.id }) ?? moment, source: model.source)
        }
    }
}

struct MomentRow: View {
    let moment: Moment
    let source: any MomentsDataSource
    let refreshToken: Int
    let open: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var context: MarkedMomentContext?

    init(moment: Moment, source: any MomentsDataSource, refresh: Int,
         initialContext: MarkedMomentContext? = nil, open: @escaping () -> Void) {
        self.moment = moment; self.source = source; self.refreshToken = refresh; self.open = open
        _context = State(initialValue: initialContext)
    }

    var body: some View {
        Button(action: open) {
            Card {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(momentDate(moment), systemImage: "pin.fill")
                            .font(AppFont.footnote).foregroundStyle(Tokens.tint)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tokens.chevron)
                    }
                    if !moment.note.isEmpty {
                        Text(moment.note).font(AppFont.headline).foregroundStyle(Tokens.label).lineLimit(3)
                    }
                    if let context, !context.quote.isEmpty {
                        Text(context.quote).font(AppFont.subBody).foregroundStyle(Tokens.label).lineLimit(3)
                    } else {
                        Text(context?.status ?? "Loading context…")
                            .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    }
                    if let title = context?.title {
                        Text(title).font(AppFont.footnote).foregroundStyle(Tokens.meta).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .task(id: "\(scenePhase)-\(refreshToken)-\(moment.reviewState)") {
            guard scenePhase == .active else { return }
            do { context = try await source.context(for: moment) }
            catch { context = MarkedMomentContext(status: "Couldn't load the recording. Open to try again.") }
        }
    }
}

private func momentDate(_ moment: Moment) -> String {
    Date(timeIntervalSince1970: Double(moment.wallMs) / 1000)
        .formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
}

struct MomentDetailSheet: View {
    let moment: Moment
    let source: any MomentsDataSource
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var context: MarkedMomentContext?
    @State private var note: String
    @State private var savedNote: String
    @State private var error: String?
    @State private var busy = false
    @State private var confirmingDelete = false
    @State private var reminderText = ""
    @State private var showingReminder = false
    @State private var showingNote = false
    @State private var addedReminders: Set<String> = []

    init(moment: Moment, source: any MomentsDataSource, initialContext: MarkedMomentContext? = nil) {
        self.moment = moment
        self.source = source
        _context = State(initialValue: initialContext)
        _note = State(initialValue: moment.note)
        _savedNote = State(initialValue: moment.note)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                detailContent
            }
            .background(Tokens.ground)
            .navigationTitle("Marked moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.disabled(busy || note != savedNote)
            } }
            .interactiveDismissDisabled(busy || note != savedNote)
            .task(id: moment.reviewState) {
                do { context = try await source.context(for: moment) }
                catch { context = MarkedMomentContext(status: "Couldn't load the recording. Close and reopen to try again.") }
            }
            .confirmationDialog("Delete this mark?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete mark", role: .destructive) {
                    busy = true
                    Task {
                        do { try await source.remove(id: moment.id); dismiss() }
                        catch { self.error = "Couldn't delete the mark. Try again." }
                        busy = false
                    }
                }
            } message: { Text("The recording and any reminders will stay.") }
            .sheet(isPresented: $showingReminder) { reminderSheet }
            .sheet(isPresented: $showingNote) { noteSheet }
        }
    }

    var detailContent: some View {
                VStack(alignment: .leading, spacing: 20) {
                    Label(momentDate(moment), systemImage: "pin.fill")
                        .font(AppFont.headline).foregroundStyle(Tokens.tint)
                    if let context {
                        if let title = context.title { Text(title).font(AppFont.headline) }
                        Text(context.status).font(AppFont.footnote).foregroundStyle(Tokens.meta)
                        if !context.quote.isEmpty {
                            Card { Text(context.quote).font(AppFont.subBody).textSelection(.enabled) }
                        }
                        if let target = context.playbackTarget ?? context.target {
                            Button("Open recording here", systemImage: "play.circle") {
                                dismiss()
                                router.push(.conversation(id: target.conversationId,
                                    atMs: target.mediaOffsetMs, focus: target.focus))
                            }.buttonStyle(.borderedProminent).disabled(busy || note != savedNote)
                        }
                    } else { ProgressView("Loading context") }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your note").font(AppFont.headline)
                        Button { showingNote = true } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(note.isEmpty ? "What made this worth keeping?" : note)
                                    .foregroundStyle(note.isEmpty ? Tokens.meta : Tokens.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "square.and.pencil").foregroundStyle(Tokens.tint)
                            }.font(AppFont.subBody).padding(12)
                                .background(Tokens.pillFill, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)

                    }
                    aiReview
                    Button("Write a reminder", systemImage: "checklist") {
                        reminderText = !note.isEmpty ? note : String((context?.quote ?? "").prefix(500))
                        showingReminder = true
                    }.disabled(busy)
                    Text("Marking saves this time and your note. Recordings follow your audio retention settings.")
                        .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    if let error { Text(error).font(AppFont.footnote).foregroundStyle(Tokens.meta) }
                    Button("Delete mark", role: .destructive) { confirmingDelete = true }.disabled(busy)
                }.padding(Tokens.screenMargin)
    }

    private func saveNote() {
        busy = true
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do { try await source.saveNote(id: moment.id, note: text); note = text; savedNote = text; error = nil; showingNote = false }
            catch { self.error = "Couldn't save your note. Your text is still here; try again." }
            busy = false
        }
    }

    @ViewBuilder private var aiReview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("A closer look", systemImage: "sparkles").font(AppFont.headline)
            if let review = moment.review {
                Text(review.summary).font(AppFont.subBody)
                if review.suggestions.isEmpty {
                    Text("No action suggested. This moment is saved for you.")
                        .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                }
                ForEach(Array(review.suggestions.enumerated()), id: \.offset) { _, suggestion in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(suggestion.text).font(AppFont.subBody)
                            if suggestion.kind == "reminder" {
                                Button(addedReminders.contains(suggestion.text) ? "Reminder added" : "Make a reminder", systemImage: "checklist") {
                                    reminderText = suggestion.text; showingReminder = true
                                }.disabled(busy || addedReminders.contains(suggestion.text))
                            } else {
                                Button("Explore with Ask", systemImage: "sparkle.magnifyingglass") {
                                    dismiss()
                                    router.navigate(to: .ask(
                                        scope: context?.target.map { "conversation:\($0.conversationId)" } ?? "everything",
                                        query: suggestion.text))
                                }.disabled(busy || note != savedNote)
                            }
                        }
                    }
                }
                Text("AI suggestions · Nothing is added or acted on until you choose.")
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(moment.wasRecording == false || moment.reviewState == "no_speech" ? "No nearby speech to review."
                    : moment.reviewState == "unavailable" ? "The source recording was removed. Your mark and note are still here."
                    : moment.reviewState == "retry" ? "AI review couldn't finish. It will try again; your moment is saved."
                    : "AI will look for useful next steps when the nearby transcript and your chosen AI are available.")
                    .font(AppFont.footnote).foregroundStyle(Tokens.meta)
            }
        }
    }

    private var noteSheet: some View {
        NavigationStack {
            Form {
                TextField("What made this worth keeping?", text: $note, axis: .vertical)
                    .lineLimit(3...12)
                    .onChange(of: note) { _, text in if text.count > 2_000 { note = String(text.prefix(2_000)) } }
                if let error { Text(error).font(.footnote) }
            }
            .navigationTitle("Your note")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(busy || note != savedNote)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { note = savedNote; showingNote = false }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { saveNote() }.disabled(busy) }
            }
        }
    }

    private var reminderSheet: some View {
        NavigationStack {
            Form {
                TextField("What do you want to remember?", text: $reminderText, axis: .vertical).lineLimit(3...8)
                Text("Added to your chosen reminders home, with a link back to this moment.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).font(.footnote) }
            }
            .navigationTitle("Make a reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingReminder = false }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        busy = true
                        Task {
                            do {
                                _ = try await source.makeReminder(for: moment,
                                    text: reminderText.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
                                addedReminders.insert(reminderText.trimmingCharacters(in: .whitespacesAndNewlines))
                                showingReminder = false; error = nil
                            } catch { self.error = "Couldn't add the reminder. Try again." }
                            busy = false
                        }
                    }.disabled(busy || reminderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }
}
