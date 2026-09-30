import SwiftUI
import UIKit

/// The jump-to-date sheet (plan 5.7, 7.12): a month calendar in a medium sheet. Days with
/// recordings carry a dot; days outside the recorded range are disabled. Picking a day closes
/// the sheet and shows that date at the current level. On the Week level a whole week is
/// picked (`UICalendarSelectionWeekOfYear`, iOS 18+, so available on the iOS 26 target).
struct JumpCalendarSheet: View {
    let firstDateKey: String
    let todayDateKey: String
    let recordedDays: Set<String>
    let level: HistoryLevel
    let selectedDateKey: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                JumpCalendar(
                    firstDateKey: firstDateKey, todayDateKey: todayDateKey,
                    recordedDays: recordedDays, selectsWeeks: level == .week,
                    selectedDateKey: selectedDateKey
                ) { key in
                    dismiss()
                    onPick(key)
                }
                .padding(.horizontal, 8)
            }
            .background(Tokens.surface)
            .navigationTitle(Copy.History.jumpToDate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// `UICalendarView`, bridged. Dates cross the bridge as day keys ("YYYY-MM-DD") read in the
/// device's calendar: a key already is a calendar date (the zone was applied when it was made).
struct JumpCalendar: UIViewRepresentable {
    let firstDateKey: String
    let todayDateKey: String
    let recordedDays: Set<String>
    let selectsWeeks: Bool
    let selectedDateKey: String
    let onPick: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICalendarView {
        let view = UICalendarView()
        let calendar = Calendar.current
        view.calendar = calendar
        view.locale = .current
        view.fontDesign = .default
        view.tintColor = UIColor(Tokens.tint)
        view.delegate = context.coordinator
        if let first = Self.date(firstDateKey, calendar), let today = Self.date(todayDateKey, calendar) {
            view.availableDateRange = DateInterval(start: calendar.startOfDay(for: first), end: today)
        }
        let selected = Self.components(selectedDateKey)
        if selectsWeeks {
            let selection = UICalendarSelectionWeekOfYear(delegate: context.coordinator)
            view.selectionBehavior = selection
            if let date = Self.date(selectedDateKey, calendar) {
                // After it is attached: the view resolves the week in its own calendar.
                var week = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
                week.calendar = calendar
                selection.setSelected(week, animated: false)
            }
        } else {
            let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
            selection.setSelected(selected, animated: false)
            view.selectionBehavior = selection
        }
        view.visibleDateComponents = selected
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UICalendarView, context: Context) {
        context.coordinator.parent = self
    }

    // MARK: Keys and dates

    static func components(_ key: String) -> DateComponents {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return DateComponents() }
        return DateComponents(calendar: .current, year: parts[0], month: parts[1], day: parts[2])
    }

    static func date(_ key: String, _ calendar: Calendar) -> Date? {
        var components = components(key)
        components.hour = 12
        return calendar.date(from: components)
    }

    static func key(_ components: DateComponents) -> String? {
        guard let year = components.year, let month = components.month, let day = components.day
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    @MainActor
    final class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate,
        UICalendarSelectionWeekOfYearDelegate
    {
        var parent: JumpCalendar

        init(_ parent: JumpCalendar) { self.parent = parent }

        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents)
            -> UICalendarView.Decoration?
        {
            guard let key = JumpCalendar.key(dateComponents), parent.recordedDays.contains(key)
            else { return nil }
            return .default(color: UIColor(Tokens.tint), size: .small)
        }

        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            guard let dateComponents, let key = JumpCalendar.key(dateComponents) else { return }
            parent.onPick(key)
        }

        func week(
            ofYearSelection selection: UICalendarSelectionWeekOfYear,
            didSelectWeekOfYear weekOfYearComponents: DateComponents?
        ) {
            guard var components = weekOfYearComponents else { return }
            let calendar = Calendar.current
            components.calendar = calendar
            components.weekday = calendar.firstWeekday
            guard let date = calendar.date(from: components) else { return }
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            guard let key = JumpCalendar.key(day) else { return }
            // A week that starts before the first recording opens at its first recorded day.
            parent.onPick(max(key, parent.firstDateKey))
        }
    }
}
