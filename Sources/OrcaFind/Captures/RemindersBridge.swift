import AppKit
import EventKit

/// "Remind me Thursday" → a real item in Apple Reminders (syncs to iPhone), linking back to the capture.
/// Permission is asked the first time someone says "remind me", never up front.
enum RemindersBridge {
    private static let store = EKEventStore()

    static var isAllowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }

    static func requestAccess() async -> Bool {
        if isAllowed { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    /// Returns the reminder's identifier, or nil if access was refused or saving failed.
    static func add(title: String, notes: String, due: Date, link: URL) async -> String? {
        guard await requestAccess() else { return nil }
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        r.url = link
        guard let list = store.defaultCalendarForNewReminders() else { return nil }
        r.calendar = list
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        r.addAlarm(EKAlarm(absoluteDate: due))
        do {
            try store.save(r, commit: true)
            return r.calendarItemIdentifier
        } catch {
            NSLog("OrcaFind: could not save reminder: \(error)")
            return nil
        }
    }

    static func remove(_ id: String) {
        guard isAllowed, let item = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(item, commit: true)
    }

    static func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
