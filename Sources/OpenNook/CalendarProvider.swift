import Foundation
import EventKit
import AppKit

final class CalendarProvider: ObservableObject {
    struct Event: Identifiable, Equatable {
        var id: String
        var title: String
        var startDate: Date
        var endDate: Date
        var isAllDay: Bool
        var meetingURL: URL? = nil
        var calendarColorHex: UInt32? = nil
        var isReminder: Bool = false
        var isCompleted: Bool = false

        var timeLabel: String {
            if isReminder {
                if isAllDay { return "Reminders" }
                return "Due \(Format.clock(from: startDate))"
            }
            if isAllDay { return "All day" }
            return "\(Format.clock(from: startDate))–\(Format.clock(from: endDate))"
        }

        var isHappeningNow: Bool {
            guard !isReminder else { return false }
            let now = Date()
            return now >= startDate && now <= endDate
        }

        var startsSoonLabel: String? {
            guard !isReminder, !isAllDay else { return nil }
            let diff = startDate.timeIntervalSinceNow
            if diff > 0 && diff <= 900 {
                let mins = max(1, Int(ceil(diff / 60)))
                return "in \(mins)m"
            }
            return nil
        }
    }

    static let shared = CalendarProvider()

    @Published var events: [Event] = []
    @Published var reminders: [Event] = []
    @Published var selectedDayOffset: Int = 0 // -1...4 relative to today
    @Published var authorized = false
    @Published var remindersAuthorized = false
    @Published var hasFetchedInitial = false

    private let store = EKEventStore()
    private let queryQueue = DispatchQueue(label: "com.opennook.eventkit", qos: .userInitiated)

    init() {
        checkExistingAuthorization()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: store
        )
    }

    @objc private func eventStoreChanged() {
        loadEvents(forDayOffset: selectedDayOffset)
    }

    func checkExistingAuthorization() {
        let eventStatus = EKEventStore.authorizationStatus(for: .event)
        let remStatus = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14.0, *) {
            authorized = (eventStatus == .fullAccess)
            remindersAuthorized = (remStatus == .fullAccess)
        } else {
            authorized = (eventStatus == .authorized)
            remindersAuthorized = (remStatus == .authorized)
        }
        if authorized || remindersAuthorized {
            hasFetchedInitial = true
            loadEvents(forDayOffset: selectedDayOffset)
        }
    }

    func requestAccessAndLoad() {
        hasFetchedInitial = true
        let hasPlist = Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil
            || Bundle.main.object(forInfoDictionaryKey: "NSCalendarsUsageDescription") != nil
        guard hasPlist else { return }

        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.authorized = granted
                    self?.loadEvents(forDayOffset: self?.selectedDayOffset ?? 0)
                }
            }
            store.requestFullAccessToReminders { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.remindersAuthorized = granted
                    self?.loadEvents(forDayOffset: self?.selectedDayOffset ?? 0)
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.authorized = granted
                    self?.loadEvents(forDayOffset: self?.selectedDayOffset ?? 0)
                }
            }
            store.requestAccess(to: .reminder) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    self?.remindersAuthorized = granted
                    self?.loadEvents(forDayOffset: self?.selectedDayOffset ?? 0)
                }
            }
        }
    }

    func selectDayOffset(_ offset: Int) {
        selectedDayOffset = offset
        loadEvents(forDayOffset: offset)
    }

    func loadTodayEvents() {
        loadEvents(forDayOffset: selectedDayOffset)
    }

    func loadEvents(forDayOffset offset: Int) {
        let isEventAuth = authorized
        let isRemAuth = remindersAuthorized
        guard isEventAuth || isRemAuth else { return }

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            let cal = Calendar.current
            let baseToday = cal.startOfDay(for: Date())
            guard let targetDayStart = cal.date(byAdding: .day, value: offset, to: baseToday),
                  let targetDayEnd = cal.date(byAdding: .day, value: 1, to: targetDayStart) else { return }

            var calendarEvents: [Event] = []
            if isEventAuth {
                let predicate = self.store.predicateForEvents(withStart: targetDayStart, end: targetDayEnd, calendars: nil)
                let now = Date()
                let ekEvents = self.store.events(matching: predicate)
                    .filter { offset != 0 || $0.endDate > now || $0.isAllDay }
                    .sorted { $0.startDate < $1.startDate }
                    .prefix(6)

                calendarEvents = ekEvents.map { ek in
                    let meetingURL = ek.url ?? ek.notes.flatMap { CalendarProvider.extractMeetingURL(from: $0) }
                        ?? ek.location.flatMap { CalendarProvider.extractMeetingURL(from: $0) }
                    return Event(
                        id: ek.eventIdentifier ?? UUID().uuidString,
                        title: ek.title.isEmpty ? "(no title)" : ek.title,
                        startDate: ek.startDate,
                        endDate: ek.endDate,
                        isAllDay: ek.isAllDay,
                        meetingURL: meetingURL,
                        isReminder: false,
                        isCompleted: false
                    )
                }
            }

            if isRemAuth {
                // Pass ending: nil so ALL incomplete Apple Reminders (including undated desktop widget items
                // like "DL Case Study", "BPM Mini project", "IOT Report", etc.) are fetched!
                let remPredicate = self.store.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: nil
                )
                self.store.fetchReminders(matching: remPredicate) { [weak self] ekReminders in
                    let mappedReminders: [Event] = (ekReminders ?? []).prefix(15).map { rem in
                        let due = rem.dueDateComponents.flatMap { cal.date(from: $0) } ?? targetDayStart
                        return Event(
                            id: rem.calendarItemIdentifier,
                            title: rem.title.isEmpty ? "Reminder" : rem.title,
                            startDate: due,
                            endDate: due,
                            isAllDay: rem.dueDateComponents?.hour == nil,
                            meetingURL: rem.notes.flatMap { CalendarProvider.extractMeetingURL(from: $0) },
                            isReminder: true,
                            isCompleted: rem.isCompleted
                        )
                    }
                    DispatchQueue.main.async {
                        self?.reminders = mappedReminders
                        self?.events = calendarEvents
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.events = calendarEvents
                }
            }
        }
    }

    func toggleReminderCompletion(_ id: String) {
        guard remindersAuthorized else { return }
        // Optimistic immediate UI update so click responds on the exact frame
        if let idx = reminders.firstIndex(where: { $0.id == id }) {
            reminders[idx].isCompleted.toggle()
        }
        queryQueue.async { [weak self] in
            guard let self = self,
                  let item = self.store.calendarItem(withIdentifier: id) as? EKReminder else { return }
            item.isCompleted.toggle()
            try? self.store.save(item, commit: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.loadEvents(forDayOffset: self.selectedDayOffset)
            }
        }
    }

    func createReminder(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, remindersAuthorized else { return }
        queryQueue.async { [weak self] in
            guard let self = self else { return }
            let reminder = EKReminder(eventStore: self.store)
            reminder.title = trimmed
            reminder.calendar = self.store.defaultCalendarForNewReminders()
            try? self.store.save(reminder, commit: true)
            DispatchQueue.main.async {
                self.loadEvents(forDayOffset: self.selectedDayOffset)
            }
        }
    }

    static func extractMeetingURL(from text: String) -> URL? {
        let pattern = #"(https?:\/\/(?:[a-zA-Z0-9-]+\.)?(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|webex\.com|whereby\.com|meet\.jit\.si)[^\s"'>]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return URL(string: String(text[range]))
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.open(url)
        }
    }

    func openRemindersApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.open(url)
        }
    }
}
