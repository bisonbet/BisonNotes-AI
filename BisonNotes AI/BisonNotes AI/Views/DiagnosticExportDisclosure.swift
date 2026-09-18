import SwiftUI

struct DiagnosticExportDisclosureModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Detailed Diagnostic Report", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Review & Share") {
                onConfirm()
            }
        } message: {
            Text(
                "This detailed report may contain recording identifiers, file information, "
                    + "technical logs, recovery inventory, and raw Apple diagnostic data. "
                    + "Review the generated file before sharing it."
            )
        }
    }
}

extension View {
    func diagnosticExportDisclosure(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(DiagnosticExportDisclosureModifier(
            isPresented: isPresented,
            onConfirm: onConfirm
        ))
    }
}
