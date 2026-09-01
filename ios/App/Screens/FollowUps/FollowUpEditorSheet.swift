import SwiftUI

/// Write or reword a follow-up.
///
/// System chrome rather than the app's custom sheet: this is a form with a Cancel and a Save,
/// which is exactly the shape iOS already has a convention for, and the convention includes the
/// keyboard behaviour, the Return key and the placement of the two buttons.
struct FollowUpEditorSheet: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var dueAt: Date?
    @FocusState private var focused: Bool
    let onSave: (String, Date?) -> Void

    init(title: String, text: String, dueAt: Date?, onSave: @escaping (String, Date?) -> Void) {
        self.title = title
        _text = State(initialValue: text)
        _dueAt = State(initialValue: dueAt)
        self.onSave = onSave
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        Copy.FollowUps.addPlaceholder, text: $text, axis: .vertical
                    )
                    .lineLimit(1...5)
                    .focused($focused)
                    .submitLabel(.done)
                }
                Section {
                    Toggle(Copy.FollowUps.due, isOn: hasDue)
                    if let due = dueAt {
                        DatePicker(
                            Copy.FollowUps.due,
                            selection: Binding(get: { due }, set: { dueAt = $0 }),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.save) {
                        onSave(trimmed, dueAt)
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { focused = true }
    }

    /// Turning the toggle on picks tomorrow, not today: a follow-up you are creating right now
    /// is almost never due in the hours you have left of the day you are creating it in.
    private var hasDue: Binding<Bool> {
        Binding(
            get: { dueAt != nil },
            set: { on in
                let calendar = Calendar.current
                dueAt =
                    on
                    ? calendar.date(
                        byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
                    : nil
            })
    }
}

/// Just the date, for the detail screen's Due row.
struct FollowUpDatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    private let hadDate: Bool
    let onPick: (Date?) -> Void

    init(date: Date?, onPick: @escaping (Date?) -> Void) {
        hadDate = date != nil
        _date = State(
            initialValue: date
                ?? Calendar.current.date(
                    byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                ?? Date())
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    Copy.FollowUps.due, selection: $date, displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                if hadDate {
                    Button(Copy.FollowUps.clearDue, role: .destructive) {
                        onPick(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle(Copy.FollowUps.due)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Copy.Common.done) {
                        onPick(Calendar.current.startOfDay(for: date))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
