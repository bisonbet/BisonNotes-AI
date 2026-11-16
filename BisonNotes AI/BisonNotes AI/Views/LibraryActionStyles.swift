import SwiftUI

/// Opaque surfaces keep small action icons readable in either appearance,
/// including when Reduce Transparency is enabled.
struct LibraryIconButtonStyle: ButtonStyle {
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        contrast == .increased ? Color.primary : Color(.separator),
                        lineWidth: contrast == .increased ? 2 : 1
                    )
            }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Filled actions use white on the dark brand blue. A disabled processing
/// action remains a readable status, rather than fading its text into the card.
struct LibraryPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Color.white : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(
                isEnabled ? Color.bisonPrimaryAction : Color(.tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
