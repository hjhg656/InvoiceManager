import Foundation
import SwiftData

enum ExportService {

    static func makeCSV(invoices: [Invoice]) -> URL? {
        var lines: [String] = ["\u{FEFF}日期,商家,票种,状态,金额,备注,来源,文件名"]
        let df = DateFormatter()
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
            return url
        } catch {
            return nil
        }
    }

    static func makeAttachmentsFolder(invoices: [Invoice]) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票附件-\(stamp())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var count = 0
        for inv in invoices {
            guard let data = inv.imageData, !data.isEmpty else { continue }
            let fname = safeFileName(for: inv, data: data)
            do {
                try data.write(to: root.appendingPathComponent(fname))
                count += 1
            } catch { continue }
        }
        return count > 0 ? root : nil
    }

    static func makeFinancePackage(invoices: [Invoice]) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("报销材料-\(stamp())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        if let csv = makeCSV(invoices: invoices) {
            try? FileManager.default.copyItem(at: csv, to: root.appendingPathComponent(csv.lastPathComponent))
        }

        let attDir = root.appendingPathComponent("附件", isDirectory: true)
        try? FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
        var count = 0
        for inv in invoices {
            guard let data = inv.imageData, !data.isEmpty else { continue }
            try? data.write(to: attDir.appendingPathComponent(safeFileName(for: inv, data: data)))
            count += 1
        }

        let total = invoices.reduce(0.0) { $0 + $1.amount }
        let readme = """
        报销材料说明
        ------------
        1. CSV 用 Excel / Numbers 打开
        2. 「附件」文件夹是发票原件
        3. 共 \(invoices.count) 条，附件 \(count) 个
        合计：¥\(String(format: "%.2f", total))
        """
        try? readme.write(to: root.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)
        return root
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
        try? data.write(to: url)
        return url
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

    private static func esc(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    private static func safeFileName(for inv: Invoice, data: Data) -> String {
        if let fn = inv.fileName, !fn.isEmpty {
            return fn.replacingOccurrences(of: "/", with: "-")
        }
        let vendor = inv.vendor.isEmpty ? "发票" : inv.vendor
        let amount = String(format: "%.2f", inv.amount)
        let ext = (data.count > 4 && data[0] == 0x25 && data[1] == 0x50) ? "pdf" : "jpg"
        return "\(vendor)-\(amount).\(ext)".replacingOccurrences(of: "/", with: "-")
    }
}
