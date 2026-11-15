import SwiftUI
import SwiftData

@main
struct InvoiceManagerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Invoice.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // 若模型变更导致迁移失败，重建容器（会清空旧数据）
            print("ModelContainer error: \(error). Recreating...")
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
