//
//  SystemIntegrationManager.swift
//  Audio Journal
//
//  Handles integration with system Reminders and Calendar apps
//

import Foundation
import EventKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - System Integration Manager

enum SystemIntegrationDestination: Equatable {
    case reminders
    case calendar
    case googleCalendar
}

struct CalendarEventDraft: Identifiable {
    let id = UUID()
    let eventStore: EKEventStore
    let event: EKEvent
}

@MainActor
final class SystemIntegrationManager: NSObject, ObservableObject {

    @Published private(set) var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published private(set) var isProcessing = false
    @Published var lastError: String?

    private let eventStore = EKEventStore()

    /// Whether the Google Calendar app is installed on this device
    var isGoogleCalendarInstalled: Bool {
        guard let url = URL(string: "googlecalendar://") else { return false }
        return PlatformApp.canOpen(url)
    }

    override init() {
        super.init()
        checkAuthorizationStatus()
    }

    // MARK: - Authorization

    func checkAuthorizationStatus() {
        calendarAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        reminderAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    private var hasCalendarWriteAccess: Bool {
        calendarAuthorizationStatus == .fullAccess || calendarAuthorizationStatus == .writeOnly
    }

    private var hasReminderAccess: Bool {
        reminderAuthorizationStatus == .fullAccess
    }

    func requestCalendarAccess() async -> Bool {
        checkAuthorizationStatus()

        if hasCalendarWriteAccess {
            return true
        }

        guard calendarAuthorizationStatus == .notDetermined else {
            setError("Calendar access is unavailable. Enable calendar access for BisonNotes in Settings and try again.")
            return false
        }

        do {
            let granted = try await eventStore.requestWriteOnlyAccessToEvents()
            checkAuthorizationStatus()

            guard granted && hasCalendarWriteAccess else {
                setError("Calendar access is required to create an event.")
                return false
            }

            return granted
        } catch {
            setError("Failed to request calendar access: \(error.localizedDescription)")
            return false
        }
    }

    func requestReminderAccess() async -> Bool {
        checkAuthorizationStatus()

        if hasReminderAccess {
            return true
        }

        guard reminderAuthorizationStatus == .notDetermined else {
            setError("Reminders access is unavailable. Enable reminders access for BisonNotes in Settings and try again.")
            return false
        }

        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            checkAuthorizationStatus()

            guard granted && hasReminderAccess else {
                setError("Reminders access is required to create a reminder.")
                return false
            }

            return granted
        } catch {
            setError("Failed to request reminder access: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Task Integration

    func addTaskToReminders(_ task: TaskItem, recordingName: String) async -> Bool {
        guard await requestReminderAccess() else {
            return false
        }

        isProcessing = true
        defer { isProcessing = false }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = task.text
        reminder.notes = "Created from BisonNotes AI recording: \(recordingName)"
        reminder.priority = task.priority.ekPriority
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            setError("No writable Reminders list is available. Add or enable a Reminders list and try again.")
            return false
        }
        reminder.calendar = calendar

        // Set due date if available
        if let timeRef = task.timeReference, let dueDate = parseDateFromTimeReference(timeRef) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        do {
            try eventStore.save(reminder, commit: true)
            return true

        } catch {
            setError("Failed to add reminder: \(error.localizedDescription)")
            return false
        }
    }

    func prepareTaskCalendarEvent(_ task: TaskItem, recordingName: String) async -> CalendarEventDraft? {
        // Set start and end times
        let now = Date()
        var startDate = now
        var endDate = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now

        if let timeRef = task.timeReference, let dueDate = parseDateFromTimeReference(timeRef) {
            startDate = dueDate
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: dueDate) ?? dueDate
        }

        return await prepareCalendarEvent(
            title: task.text,
            recordingName: recordingName,
            startDate: startDate,
            endDate: endDate,
            alarmOffset: -900
        )
    }

    // MARK: - Reminder Integration

    func addReminderToReminders(_ reminder: ReminderItem, recordingName: String) async -> Bool {
        guard await requestReminderAccess() else {
            return false
        }

        isProcessing = true
        defer { isProcessing = false }

        let ekReminder = EKReminder(eventStore: eventStore)
        ekReminder.title = reminder.text
        ekReminder.notes = "Created from BisonNotes AI recording: \(recordingName)"
        ekReminder.priority = reminder.urgency.ekPriority
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            setError("No writable Reminders list is available. Add or enable a Reminders list and try again.")
            return false
        }
        ekReminder.calendar = calendar

        // Set due date if available
        if let dueDate = reminder.timeReference.parsedDate {
            ekReminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        } else if let relativeTime = reminder.timeReference.relativeTime {
            // Try to parse relative time
            if let relativeDate = parseRelativeTime(relativeTime) {
                ekReminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: relativeDate)
            }
        }

        do {
            try eventStore.save(ekReminder, commit: true)
            return true

        } catch {
            setError("Failed to add reminder: \(error.localizedDescription)")
            return false
        }
    }

    func prepareReminderCalendarEvent(_ reminder: ReminderItem, recordingName: String) async -> CalendarEventDraft? {
        // Set start and end times
        let now = Date()
        var startDate = now
        var endDate = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now

        if let dueDate = reminder.timeReference.parsedDate {
            startDate = dueDate
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: dueDate) ?? dueDate
        } else if let relativeTime = reminder.timeReference.relativeTime {
            if let relativeDate = parseRelativeTime(relativeTime) {
                startDate = relativeDate
                endDate = Calendar.current.date(byAdding: .hour, value: 1, to: relativeDate) ?? relativeDate
            }
        }

        // Set alarm based on urgency
        let alarmOffset: TimeInterval
        switch reminder.urgency {
        case .immediate:
            alarmOffset = -300 // 5 minutes before
        case .today:
            alarmOffset = -900 // 15 minutes before
        case .thisWeek:
            alarmOffset = -3600 // 1 hour before
        case .later:
            alarmOffset = -86400 // 1 day before
        }

        return await prepareCalendarEvent(
            title: reminder.text,
            recordingName: recordingName,
            startDate: startDate,
            endDate: endDate,
            alarmOffset: alarmOffset
        )
    }

    // MARK: - Calendar Event Preparation

    private func prepareCalendarEvent(
        title: String,
        recordingName: String,
        startDate: Date,
        endDate: Date,
        alarmOffset: TimeInterval
    ) async -> CalendarEventDraft? {
        guard await requestCalendarAccess() else {
            return nil
        }

        isProcessing = true
        defer { isProcessing = false }

        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            setError("No writable calendar is available. Add or enable a calendar and try again.")
            return nil
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.notes = "Created from BisonNotes AI recording: \(recordingName)"
        event.calendar = calendar
        event.startDate = startDate
        event.endDate = endDate
        event.addAlarm(EKAlarm(relativeOffset: alarmOffset))

        return CalendarEventDraft(eventStore: eventStore, event: event)
    }

    private func setError(_ message: String) {
        lastError = message
    }

    // MARK: - Google Calendar Integration

    /// Opens a task in Google Calendar using the web URL fallback.
    /// If the Google Calendar app is installed it will handle the link;
    /// otherwise Safari opens the pre-filled event creation page.
    func addTaskToGoogleCalendar(_ task: TaskItem, recordingName: String) {
        var startDate = Date()
        var endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate

        if let timeRef = task.timeReference, let parsed = parseDateFromTimeReference(timeRef) {
            startDate = parsed
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: parsed) ?? parsed
        }

        let details = "Created from BisonNotes AI recording: \(recordingName)"
        openGoogleCalendarURL(title: task.text, details: details, startDate: startDate, endDate: endDate)
    }

    /// Opens a reminder in Google Calendar using the web URL fallback.
    func addReminderToGoogleCalendar(_ reminder: ReminderItem, recordingName: String) {
        var startDate = Date()
        var endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate

        if let parsed = reminder.timeReference.parsedDate {
            startDate = parsed
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: parsed) ?? parsed
        } else if let relativeTime = reminder.timeReference.relativeTime,
                  let parsed = parseRelativeTime(relativeTime) {
            startDate = parsed
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: parsed) ?? parsed
        }

        let details = "Created from BisonNotes AI recording: \(recordingName)"
        openGoogleCalendarURL(title: reminder.text, details: details, startDate: startDate, endDate: endDate)
    }

    /// Builds a Google Calendar event creation URL and opens it.
    private func openGoogleCalendarURL(title: String, details: String, startDate: Date, endDate: Date) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone.current

        let startString = formatter.string(from: startDate)
        let endString = formatter.string(from: endDate)

        var components = URLComponents(string: "https://calendar.google.com/calendar/render")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: title),
            URLQueryItem(name: "dates", value: "\(startString)/\(endString)"),
            URLQueryItem(name: "details", value: details),
            URLQueryItem(name: "sf", value: "true")
        ]

        guard let url = components.url else {
            setError("Failed to build Google Calendar URL.")
            return
        }

        PlatformApp.open(url)
    }

    // MARK: - Helper Methods

    private func parseDateFromTimeReference(_ timeRef: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        // Try different date formats
        let formats = [
            "MMM dd, yyyy",
            "MM/dd/yyyy",
            "yyyy-MM-dd",
            "dd/MM/yyyy",
            "MM-dd-yyyy"
        ]

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: timeRef) {
                return date
            }
        }

        return nil
    }

    private func parseRelativeTime(_ relativeTime: String) -> Date? {
        let lowercased = relativeTime.lowercased()
        let now = Date()
        let calendar = Calendar.current

        if lowercased.contains("today") {
            return calendar.startOfDay(for: now)
        } else if lowercased.contains("tomorrow") {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        } else if lowercased.contains("next week") {
            return calendar.date(byAdding: .weekOfYear, value: 1, to: now)
        } else if lowercased.contains("next month") {
            return calendar.date(byAdding: .month, value: 1, to: now)
        }

        return nil
    }
}

// MARK: - Extensions

extension TaskItem.Priority {
    var ekPriority: Int {
        switch self {
        case .high: return 1
        case .medium: return 5
        case .low: return 9
        }
    }
}

extension ReminderItem.Urgency {
    var ekPriority: Int {
        switch self {
        case .immediate: return 1
        case .today: return 3
        case .thisWeek: return 5
        case .later: return 9
        }
    }
}
