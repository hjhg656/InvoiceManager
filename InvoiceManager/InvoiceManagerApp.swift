import SwiftUI
import SwiftData

@main
struct InvoiceManagerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Invoice.self, ExpenseBatch.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            try? FileManager.default.removeItem(at: config.url)
            return try! ModelContainer(for: schema, configurations: [config])
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
