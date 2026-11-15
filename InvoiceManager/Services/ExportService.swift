import Foundation
import UIKit

enum ExportService {

    /// 生成带 BOM 的 CSV，Excel 打开中文不乱码
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

        let name = "发票台账-\(stamp()).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// 把附件写出到文件夹，返回文件夹 URL（分享时系统可打包）
    static func makeAttachmentsFolder(invoices: [Invoice]) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票附件-\(stamp())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var count = 0
        for inv in invoices {
            guard let data = inv.imageData, !data.isEmpty else { continue }
            let fname = safeFileName(for: inv, data: data)
            let fileURL = root.appendingPathComponent(fname)
            do {
                try data.write(to: fileURL)
                count += 1
            } catch {
                continue
            }
        }
        return count > 0 ? root : nil
    }

    /// CSV + 附件放同一目录，方便一次交给财务
    static func makeFinancePackage(invoices: [Invoice]) -> URL? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("报销材料-\(stamp())", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // CSV
        if let csv = makeCSV(invoices: invoices) {
            let dest = root.appendingPathComponent(csv.lastPathComponent)
            try? FileManager.default.copyItem(at: csv, to: dest)
        }

        // 附件子目录
        let attDir = root.appendingPathComponent("附件", isDirectory: true)
        try? FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
        var count = 0
        for inv in invoices {
            guard let data = inv.imageData, !data.isEmpty else { continue }
            let fname = safeFileName(for: inv, data: data)
            try? data.write(to: attDir.appendingPathComponent(fname))
            count += 1
        }

        // 写一份说明
        let readme = """
        报销材料说明
        ------------
        1. CSV 可用 Excel / Numbers 打开
        2. 「附件」文件夹内为发票原件（PDF 或图片）
        3. 共 \(invoices.count) 条记录，其中 \(count) 个附件
        合计金额：¥\(String(format: "%.2f", invoices.reduce(0) { $0 + $1.amount }))
        """
        try? readme.write(to: root.appendingPathComponent("说明.txt"), atomically: true, encoding: .utf8)

        return root
    }

    /// 本地备份（JSON，含 base64 附件，用于恢复）
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
        let items = invoices.map { inv in
            Item(
                amount: inv.amount,
                date: inv.date,
                vendor: inv.vendor,
                kindRaw: inv.kindRaw,
                statusRaw: inv.statusRaw,
                notes: inv.notes,
                fileName: inv.fileName,
                source: inv.source,
                imageBase64: inv.imageData?.base64EncodedString()
            )
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(items) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("发票备份-\(stamp()).json")
        try? data.write(to: url)
        return url
    }

    static func restoreBackup(from url: URL, into context: ModelContext) throws -> Int {
        let data = try Data(contentsOf: url)
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
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    private static func safeFileName(for inv: Invoice, data: Data) -> String {
        if let fn = inv.fileName, !fn.isEmpty {
            return fn.replacingOccurrences(of: "/", with: "-")
        }
        let vendor = inv.vendor.isEmpty ? "发票" : inv.vendor
        let amount = String(format: "%.2f", inv.amount)
        let ext = isPDF(data) ? "pdf" : "jpg"
        return "\(vendor)-\(amount).\(ext)".replacingOccurrences(of: "/", with: "-")
    }

    private static func isPDF(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0x25 && data[1] == 0x50
    }
}

// 避免循环引用，在 Export 里用到 ModelContext
import SwiftData
