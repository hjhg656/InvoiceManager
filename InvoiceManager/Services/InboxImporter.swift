import Foundation
import SwiftData

/// 分享扩展 / 外部丢进 App Group 的文件，启动时导入
enum InboxImporter {
    static let appGroupId = "group.com.example.InvoiceManager"

    static var inboxURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent("inbox", isDirectory: true)
    }

    @MainActor
    static func importPending(into context: ModelContext) -> Int {
        guard let inbox = inboxURL else { return 0 }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: nil
        ), !files.isEmpty else { return 0 }

        var count = 0
        for url in files {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let base = url.deletingPathExtension().lastPathComponent
            let parsed = OCRService.parseFileName(base)
            let inv = Invoice(
                amount: parsed.amount ?? 0,
                date: Date(),
                vendor: parsed.vendor ?? base,
                kind: .transport,
                status: .pending,
                notes: "来自分享：\(base)",
                imageData: data,
                fileName: url.lastPathComponent,
                source: "share"
            )
            context.insert(inv)
            try? FileManager.default.removeItem(at: url)
            count += 1
        }
        try? context.save()
        return count
    }
}
