import SwiftUI
import SwiftData

@main
struct InvoiceManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Invoice.self)
    }
}
