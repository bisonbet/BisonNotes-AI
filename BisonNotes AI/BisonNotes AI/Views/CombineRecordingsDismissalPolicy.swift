//
//  CombineRecordingsDismissalPolicy.swift
//  BisonNotes AI
//

enum CombineRecordingsDismissalPolicy {
    static func allowsDismissal(isCombining: Bool) -> Bool {
        !isCombining
    }
}
