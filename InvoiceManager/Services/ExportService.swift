import Foundation
import SwiftData

enum ExportService {

    /// Excel 可打开的 CSV（UTF-8 BOM）
    static func makeCSV(invoices: [Invoice]) -> URL? {
        var lines: [String] = ["\u{FEFF}日期,商家,票种,状态,金额,备注,来源,文件名"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"

        for inv in invoices.sorted(by: { $0.date > $1.date }) {
            let cols = [
                df.string(from: inv.date),
                esc(inv.vendor),
                esc(inv.kind.rawValue),
                esc(inv.status.rawValue),
                String(format: "%.2f", inv.amount),
                esc(inv.notes),
                esc(inv.source),
                esc(inv.fileName ?? "")
            ]
            lines.append(cols.joined(separator: ","))
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票台账-\(stamp()).csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            // 确认写成功
            guard FileManager.default.fileExists(atPath: url.path),
                  (try? Data(contentsOf: url))?.isEmpty == false else { return nil }
            return url
        } catch {
            print("CSV error: \(error)")
            return nil
        }
    }

    /// 把每张有附件的发票写成独立文件，返回可分享的 URL 列表
    static func attachmentFileURLs(invoices: [Invoice]) -> [URL] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv-att-\(stamp())", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var result: [URL] = []
        var index = 1
        for inv in invoices {
            guard let data = inv.imageData, !data.isEmpty else { continue }
            let name = uniqueName(for: inv, data: data, index: index)
            let fileURL = dir.appendingPathComponent(name)
            do {
                try data.write(to: fileURL, options: .atomic)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    result.append(fileURL)
                    index += 1
                }
            } catch {
                print("write att error: \(error)")
            }
        }
        return result
    }

    static func makeBackup(invoices: [Invoice]) -> URL? {
        struct Item: Codable {
            var amount: Double
            var date: Date
            var vendor: String
            var kindRaw: String
            var statusRaw: String
            var notes: String
            var fileName: String?
            var source: String
            var imageBase64: String?
        }
        let items = invoices.map {
            Item(
                amount: $0.amount,
                date: $0.date,
                vendor: $0.vendor,
                kindRaw: $0.kindRaw,
                statusRaw: $0.statusRaw,
                notes: $0.notes,
                fileName: $0.fileName,
                source: $0.source,
                imageBase64: $0.imageData?.base64EncodedString()
            )
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(items) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票备份-\(stamp()).json")
        do {
            try data.write(to: url, options: .atomic)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        } catch {
            return nil
        }
    }

    static func restoreBackup(from url: URL, into context: ModelContext) throws -> Int {
        struct Item: Codable {
            var amount: Double
            var date: Date
            var vendor: String
            var kindRaw: String
            var statusRaw: String
            var notes: String
            var fileName: String?
            var source: String
            var imageBase64: String?
        }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let items = try dec.decode([Item].self, from: data)
        for item in items {
            let inv = Invoice(
                amount: item.amount,
                date: item.date,
                vendor: item.vendor,
                kind: InvoiceKind(rawValue: item.kindRaw) ?? .other,
                status: InvoiceStatus(rawValue: item.statusRaw) ?? .pending,
                notes: item.notes,
                imageData: item.imageBase64.flatMap { Data(base64Encoded: $0) },
                fileName: item.fileName,
                source: item.source
            )
            context.insert(inv)
        }
        try context.save()
        return items.count
    }

    // MARK: - helpers

    private static func esc(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func uniqueName(for inv: Invoice, data: Data, index: Int) -> String {
        let ext = isPDF(data) ? "pdf" : "jpg"
        if let fn = inv.fileName, !fn.isEmpty {
            return "\(index)-\(fn.replacingOccurrences(of: "/", with: "-"))"
        }
        let vendor = inv.vendor.isEmpty ? "发票" : inv.vendor
        let amount = String(format: "%.2f", inv.amount)
        return "\(index)-\(vendor)-\(amount).\(ext)".replacingOccurrences(of: "/", with: "-")
    }

    private static func isPDF(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0x25 && data[1] == 0x50
    }
}
