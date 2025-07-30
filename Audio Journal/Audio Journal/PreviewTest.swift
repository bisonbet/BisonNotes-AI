import SwiftUI

struct PreviewTest: View {
    var body: some View {
        ContentView()
            .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
    }
}

#Preview {
    PreviewTest()
}