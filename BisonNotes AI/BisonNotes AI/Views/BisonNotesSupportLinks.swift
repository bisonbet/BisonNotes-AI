import StoreKit
import SwiftUI

struct BisonNotesSupportLinks: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsCoffeeLink = false

    var body: some View {
        BisonNotesSupportLinksContent(showsCoffeeLink: showsCoffeeLink)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }

                // External payment links are permitted in the US storefront.
                // Keep the link hidden when StoreKit cannot identify a storefront.
                showsCoffeeLink = false
                let storefront = await Storefront.current
                guard !Task.isCancelled else { return }
                showsCoffeeLink = storefront?.countryCode == "USA"

                for await storefront in Storefront.updates {
                    guard !Task.isCancelled else { return }
                    showsCoffeeLink = storefront.countryCode == "USA"
                }
            }
    }
}

private struct BisonNotesSupportLinksContent: View {
    let showsCoffeeLink: Bool

    private let repositoryURL = URL(string: "https://github.com/bisonbet/BisonNotes-AI")!
    private let coffeeURL = URL(string: "https://buymeacoffee.com/Bisonnetworking")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Link(destination: repositoryURL) {
                Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .accessibilityHint("Opens the BisonNotes AI source repository in your browser.")

            if showsCoffeeLink {
                Text(
                    "If BisonNotes saves you time, buying me a coffee helps support "
                        + "its continued development. Thank you!"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link(destination: coffeeURL) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Opens Buy Me a Coffee in your browser to optionally support development.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Support links - US storefront") {
    BisonNotesSupportLinksContent(showsCoffeeLink: true)
        .padding()
}

#Preview("Support links - other storefront") {
    BisonNotesSupportLinksContent(showsCoffeeLink: false)
        .padding()
}
#endif
