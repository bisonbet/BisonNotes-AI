//
//  SystemIntegrationManager.swift
//  Audio Journal
//
//  Handles integration with system Reminders and Calendar apps
//

import Foundation
import EventKit
import SwiftUI

// MARK: - System Integration Manager

@MainActor
class SystemIntegrationManager: NSObject, ObservableObject {
    
    @Published var isAuthorized = false
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var showingError = false
    
    private let eventStore = EKEventStore()
    
    override init() {
        super.init()
        checkAuthorizationStatus()
    }
    
    // MARK: - Authorization
    
    func checkAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        isAuthorized = authorizationStatus == .fullAccess
    }
    
    func requestAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            await MainActor.run {
                self.isAuthorized = granted
                self.authorizationStatus = granted ? .fullAccess : .denied
            }
            return granted
        } catch {
            await MainActor.run {
                self.lastError = "Failed to request calendar access: \(error.localizedDescription)"
                self.showingError = true
            }
            return false
        }
    }
    
    func requestReminderAccess() async -> Bool {
        do {
            let granted = try await eventStore.requestFullAccessToReminders()
            await MainActor.run {
                self.isAuthorized = granted
            }
            return granted
        } catch {
            await MainActor.run {
                self.lastError = "Failed to request reminder access: \(error.localizedDescription)"
                self.showingError = true
            }
            return false
        }
    }
    
    // MARK: - Task Integration
    
    func addTaskToReminders(_ task: TaskItem, recordingName: String) async -> Bool {
        if !isAuthorized {
            if !(await requestReminderAccess()) {
                return false
            }
        }
        
        await MainActor.run {
            isProcessing = true
        }
        
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = task.text
        reminder.notes = "Created from Audio Journal recording: \(recordingName)"
        reminder.priority = task.priority.ekPriority
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        
        // Set due date if available
        if let timeRef = task.timeReference, let dueDate = parseDateFromTimeReference(timeRef) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }
        
        // Add category tag
        reminder.addTag(task.category.rawValue)
        
        do {
            try eventStore.save(reminder, commit: true)
            
            await MainActor.run {
                isProcessing = false
            }
            return true
            
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = "Failed to add reminder: \(error.localizedDescription)"
                showingError = true
            }
            return false
        }
    }
    
    func addTaskToCalendar(_ task: TaskItem, recordingName: String) async -> Bool {
        if !isAuthorized {
            if !(await requestAccess()) {
                return false
            }
        }
        
        await MainActor.run {
            isProcessing = true
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = task.text
        event.notes = "Created from Audio Journal recording: \(recordingName)"
        event.calendar = eventStore.defaultCalendarForNewEvents
        
        // Set start and end times
        let now = Date()
        var startDate = now
        var endDate = Calendar.current.date(byAdding: .hour, value: 1, to: now) ?? now
        
        if let timeRef = task.timeReference, let dueDate = parseDateFromTimeReference(timeRef) {
            startDate = dueDate
            endDate = Calendar.current.date(byAdding: .hour, value: 1, to: dueDate) ?? dueDate
        }
        
        event.startDate = startDate
        event.endDate = endDate
        
        // Set alarm
        let alarm = EKAlarm(relativeOffset: -900) // 15 minutes before
        event.addAlarm(alarm)
        
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            
            await MainActor.run {
                isProcessing = false
            }
            return true
            
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = "Failed to add calendar event: \(error.localizedDescription)"
                showingError = true
            }
            return false
        }
    }
    
    // MARK: - Reminder Integration
    
    func addReminderToReminders(_ reminder: ReminderItem, recordingName: String) async -> Bool {
        if !isAuthorized {
            if !(await requestReminderAccess()) {
                return false
            }
        }
        
        await MainActor.run {
            isProcessing = true
        }
        
        let ekReminder = EKReminder(eventStore: eventStore)
        ekReminder.title = reminder.text
        ekReminder.notes = "Created from Audio Journal recording: \(recordingName)"
        ekReminder.priority = reminder.urgency.ekPriority
        ekReminder.calendar = eventStore.defaultCalendarForNewReminders()
        
        // Set due date if available
        if let dueDate = reminder.timeReference.parsedDate {
            ekReminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        } else if let relativeTime = reminder.timeReference.relativeTime {
            // Try to parse relative time
            if let relativeDate = parseRelativeTime(relativeTime) {
                ekReminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: relativeDate)
            }
        }
        
        // Add urgency tag
        ekReminder.addTag(reminder.urgency.rawValue)
        
        do {
            try eventStore.save(ekReminder, commit: true)
            
            await MainActor.run {
                isProcessing = false
            }
            return true
            
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = "Failed to add reminder: \(error.localizedDescription)"
                showingError = true
            }
            return false
        }
    }
    
    func addReminderToCalendar(_ reminder: ReminderItem, recordingName: String) async -> Bool {
        if !isAuthorized {
            if !(await requestAccess()) {
                return false
            }
        }
        
        await MainActor.run {
            isProcessing = true
        }
        
        let event = EKEvent(eventStore: eventStore)
        event.title = reminder.text
        event.notes = "Created from Audio Journal recording: \(recordingName)"
        event.calendar = eventStore.defaultCalendarForNewEvents
        
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
        
        event.startDate = startDate
        event.endDate = endDate
        
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
        
        let alarm = EKAlarm(relativeOffset: alarmOffset)
        event.addAlarm(alarm)
        
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            
            await MainActor.run {
                isProcessing = false
            }
            return true
            
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = "Failed to add calendar event: \(error.localizedDescription)"
                showingError = true
            }
            return false
        }
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

extension EKReminder {
    func addTag(_ tag: String) {
        // Note: EKReminder doesn't have a direct tag property in older iOS versions
        // This is a placeholder for future implementation
        // In newer iOS versions, you might use categories or other metadata
    }
} 