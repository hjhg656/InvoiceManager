import Foundation
import SwiftData

@Model
final class Invoice {
    @Attribute(.unique) var id: UUID
    var amount: Double
    var date: Date
    var vendor: String
    var category: String
    var notes: String
    /// 发票附件（图片或 PDF 原始数据）
    var imageData: Data?
    var fileName: String?
    var createdAt: Date
    var source: String

    init(
        amount: Double = 0,
        date: Date = Date(),
        vendor: String = "",
        category: String = "其他",
        notes: String = "",
        imageData: Data? = nil,
        fileName: String? = nil,
        source: String = "manual"
    ) {
        self.id = UUID()
        self.amount = amount
        self.date = date
        self.vendor = vendor
        self.category = category
        self.notes = notes
        self.imageData = imageData
        self.fileName = fileName
        self.createdAt = Date()
        self.source = source
    }

    var monthKey: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: date)
    }
}
