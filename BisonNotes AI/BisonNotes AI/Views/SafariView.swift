//
//  SafariView.swift
//  Audio Journal
//
//  Reusable SFSafariViewController wrapper for SwiftUI
//

import SwiftUI
#if !targetEnvironment(macCatalyst)
import SafariServices
#endif

#if !targetEnvironment(macCatalyst)
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let safariVC = SFSafariViewController(url: url)
        safariVC.preferredBarTintColor = UIColor.systemBackground
        safariVC.preferredControlTintColor = UIColor.systemBlue
        safariVC.dismissButtonStyle = .close
        return safariVC
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No updates needed
    }
}
#endif
