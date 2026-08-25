#if os(macOS)
import SwiftUI

struct MacStorageLocalStorageCard: View {
    let storageText: String

    var body: some View {
        MacSettingsCard(title: "Local Storage", systemImage: "internaldrive", tint: .teal) {
            HStack(alignment: .firstTextBaseline) {
                MacSettingsLabel(
                    title: "Total Recordings Storage",
                    subtitle: "Space used by local audio recordings",
                    systemImage: "externaldrive",
                    tint: .teal
                )

                Spacer(minLength: 12)

                Text(storageText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Total recordings storage")
            }

            Text("Imported transcripts do not consume audio storage and are excluded from this total.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
