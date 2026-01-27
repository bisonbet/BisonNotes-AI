//
//  DateSectionHelper.swift
//  Audio Journal
//
//  Created by Claude on 1/26/26.
//

import Foundation

enum DateSection: Comparable {
    case today
    case yesterday
    case thisWeek
    case lastWeek
    case thisMonth
    case lastMonth
    case older(monthYear: String) // "January 2026", "December 2025", etc.

    var title: String {
        switch self {
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .thisWeek:
            return "This Week"
        case .lastWeek:
            return "Last Week"
        case .thisMonth:
            return "This Month"
        case .lastMonth:
            return "Last Month"
        case .older(let monthYear):
            return monthYear
        }
    }

    // Custom sorting order
    static func < (lhs: DateSection, rhs: DateSection) -> Bool {
        let order = [today, yesterday, thisWeek, lastWeek, thisMonth, lastMonth]

        if let lhsIndex = order.firstIndex(where: { Self.matches($0, lhs) }),
           let rhsIndex = order.firstIndex(where: { Self.matches($0, rhs) }) {
            return lhsIndex < rhsIndex
        }

        // Handle older sections
        if case .older(let lhsMonth) = lhs, case .older(let rhsMonth) = rhs {
            // Compare dates to sort by most recent first
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMMM yyyy"
            if let lhsDate = dateFormatter.date(from: lhsMonth),
               let rhsDate = dateFormatter.date(from: rhsMonth) {
                return lhsDate > rhsDate // Reverse order for newer first
            }
        }

        // Older sections come after predefined sections
        if case .older = lhs { return false }
        if case .older = rhs { return true }

        return false
    }

    private static func matches(_ lhs: DateSection, _ rhs: DateSection) -> Bool {
        switch (lhs, rhs) {
        case (.today, .today),
             (.yesterday, .yesterday),
             (.thisWeek, .thisWeek),
             (.lastWeek, .lastWeek),
             (.thisMonth, .thisMonth),
             (.lastMonth, .lastMonth):
            return true
        default:
            return false
        }
    }
}

extension DateSection: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
    }

    static func == (lhs: DateSection, rhs: DateSection) -> Bool {
        lhs.title == rhs.title
    }
}

struct DateSectionHelper {
    static func section(for date: Date) -> DateSection {
        let calendar = Calendar.current
        let now = Date()

        // Today
        if calendar.isDateInToday(date) {
            return .today
        }

        // Yesterday
        if calendar.isDateInYesterday(date) {
            return .yesterday
        }

        // This Week (excluding today and yesterday)
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
           date >= weekStart {
            return .thisWeek
        }

        // Last Week
        if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           let lastWeekInterval = calendar.dateInterval(of: .weekOfYear, for: lastWeekStart),
           date >= lastWeekInterval.start && date < lastWeekInterval.end {
            return .lastWeek
        }

        // This Month (excluding this week)
        if let monthStart = calendar.dateInterval(of: .month, for: now)?.start,
           date >= monthStart {
            return .thisMonth
        }

        // Last Month
        if let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: now),
           let lastMonthInterval = calendar.dateInterval(of: .month, for: lastMonthStart),
           date >= lastMonthInterval.start && date < lastMonthInterval.end {
            return .lastMonth
        }

        // Older - use month and year
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM yyyy"
        let monthYear = dateFormatter.string(from: date)
        return .older(monthYear: monthYear)
    }

    /// Groups items by date section
    static func groupBySection<T>(_ items: [T], dateKeyPath: KeyPath<T, Date>) -> [(section: DateSection, items: [T])] {
        let grouped = Dictionary(grouping: items) { item in
            section(for: item[keyPath: dateKeyPath])
        }

        return grouped
            .sorted { $0.key < $1.key }
            .map { (section: $0.key, items: $0.value) }
    }
}
