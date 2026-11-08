//
//  NSManagedObject+AssignIfChanged.swift
//  BisonNotes AI
//
//  Writes that leave an unchanged row untouched.
//

import CoreData

/// Lets any managed object skip an assignment that would not change anything.
protocol AssignIfChanged: NSManagedObject {}

extension NSManagedObject: AssignIfChanged {}

extension AssignIfChanged {
    /// Assigns `value` only when it differs from the current one.
    ///
    /// A managed-object setter does not compare: assigning the value a property
    /// already holds still marks the object updated, so the next save can write
    /// the row again. The iCloud restore leg overwrites on equal timestamps, which
    /// is the steady state, so it re-assigned every field and relationship of
    /// every recording, transcript and summary on every sync. MetricKit reported
    /// 1–4 GB of writes a day with Core Data's SQLite saves a large share, and
    /// rewrites that change nothing are the cheapest part of that to remove.
    ///
    /// Relationships compare by object identity, which is what `isEqual` means
    /// for a managed object.
    func assignIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<Self, Value>,
        _ value: Value
    ) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }
}
