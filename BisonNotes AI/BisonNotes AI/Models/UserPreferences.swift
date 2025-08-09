//
//  UserPreferences.swift
//  BisonNotes AI
//
//  Created by Claude Code on 8/8/25.
//

import Foundation

/// Enum for time format preferences
enum TimeFormat: String, CaseIterable, Identifiable {
    case twentyFourHour = "24h"
    case twelveHour = "12h"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .twentyFourHour:
            return "24-Hour Time"
        case .twelveHour:
            return "12-Hour Time"
        }
    }
    
    var description: String {
        switch self {
        case .twentyFourHour:
            return "Shows time as 14:30"
        case .twelveHour:
            return "Shows time as 2:30 PM"
        }
    }
}

/// Manages user preferences for the app
class UserPreferences: ObservableObject {
    static let shared = UserPreferences()
    
    @Published var timeFormat: TimeFormat {
        didSet {
            UserDefaults.standard.set(timeFormat.rawValue, forKey: Keys.timeFormat)
        }
    }
    
    private enum Keys {
        static let timeFormat = "user_preference_time_format"
    }
    
    private init() {
        // Load time format preference, defaulting to 24-hour
        if let savedTimeFormat = UserDefaults.standard.string(forKey: Keys.timeFormat),
           let timeFormat = TimeFormat(rawValue: savedTimeFormat) {
            self.timeFormat = timeFormat
        } else {
            self.timeFormat = .twentyFourHour // Default to 24-hour time
        }
    }
    
    /// Creates a DateFormatter configured with the user's preferred time format
    func createDateFormatter(dateStyle: DateFormatter.Style = .medium, includeTime: Bool = true) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        
        if includeTime {
            formatter.timeStyle = .short
            
            // Force the locale to show time in the preferred format
            switch timeFormat {
            case .twentyFourHour:
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.setLocalizedDateFormatFromTemplate("HH:mm")
            case .twelveHour:
                formatter.locale = Locale(identifier: "en_US")
                formatter.setLocalizedDateFormatFromTemplate("h:mm a")
            }
            
            // Update the date format to include both date and time in the preferred format
            switch dateStyle {
            case .none:
                // Time only
                break
            case .short:
                // Short date + time
                formatter.setLocalizedDateFormatFromTemplate(timeFormat == .twentyFourHour ? "M/d/yy HH:mm" : "M/d/yy h:mm a")
            case .medium:
                // Medium date + time
                formatter.setLocalizedDateFormatFromTemplate(timeFormat == .twentyFourHour ? "MMM d, yyyy HH:mm" : "MMM d, yyyy h:mm a")
            case .long:
                // Long date + time
                formatter.setLocalizedDateFormatFromTemplate(timeFormat == .twentyFourHour ? "MMMM d, yyyy HH:mm" : "MMMM d, yyyy h:mm a")
            case .full:
                // Full date + time
                formatter.setLocalizedDateFormatFromTemplate(timeFormat == .twentyFourHour ? "EEEE, MMMM d, yyyy HH:mm" : "EEEE, MMMM d, yyyy h:mm a")
            @unknown default:
                break
            }
        } else {
            formatter.timeStyle = .none
        }
        
        return formatter
    }
    
    /// Convenience method to format a date with user preferences
    func formatDate(_ date: Date, dateStyle: DateFormatter.Style = .medium, includeTime: Bool = true) -> String {
        let formatter = createDateFormatter(dateStyle: dateStyle, includeTime: includeTime)
        return formatter.string(from: date)
    }
    
    /// Convenience method to format a date with full style (for summary headers)
    func formatFullDateTime(_ date: Date) -> String {
        return formatDate(date, dateStyle: .full, includeTime: true)
    }
    
    /// Convenience method to format a date with short style (for metadata)
    func formatShortDateTime(_ date: Date) -> String {
        return formatDate(date, dateStyle: .short, includeTime: true)
    }
    
    /// Convenience method to format a date with medium style (for general use)
    func formatMediumDateTime(_ date: Date) -> String {
        return formatDate(date, dateStyle: .medium, includeTime: true)
    }
}