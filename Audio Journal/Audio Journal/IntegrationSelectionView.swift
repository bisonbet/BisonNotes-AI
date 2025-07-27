//
//  IntegrationSelectionView.swift
//  Audio Journal
//
//  Selection view for choosing between Reminders and Calendar integration
//

import SwiftUI

// MARK: - Integration Selection View

struct IntegrationSelectionView: View {
    let title: String
    let subtitle: String
    let onRemindersSelected: () -> Void
    let onCalendarSelected: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.accentColor)
                    
                    Text(title)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                    
                    Text(subtitle)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 40)
                
                Spacer()
                
                // Selection Options
                VStack(spacing: 16) {
                    // Reminders Option
                    Button(action: {
                        onRemindersSelected()
                        dismiss()
                    }) {
                        HStack(spacing: 16) {
                            Image(systemName: "checklist")
                                .font(.title2)
                                .foregroundColor(.green)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Add to Reminders")
                                    .font(.headline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                Text("Create a reminder in the Reminders app")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    // Calendar Option
                    Button(action: {
                        onCalendarSelected()
                        dismiss()
                    }) {
                        HStack(spacing: 16) {
                            Image(systemName: "calendar")
                                .font(.title2)
                                .foregroundColor(.blue)
                                .frame(width: 32)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Add to Calendar")
                                    .font(.headline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                
                                Text("Create an event in the Calendar app")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal)
                
                Spacer()
                
                // Cancel Button
                Button("Cancel") {
                    dismiss()
                }
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
            .navigationTitle("Add to System")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

struct IntegrationSelectionView_Previews: PreviewProvider {
    static var previews: some View {
        IntegrationSelectionView(
            title: "Add Task to System",
            subtitle: "Choose where you'd like to add this task",
            onRemindersSelected: {},
            onCalendarSelected: {}
        )
    }
} 