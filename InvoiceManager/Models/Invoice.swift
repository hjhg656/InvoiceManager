import Foundation
import SwiftData

@Model
final class Invoice {
    var id: UUID
    var amount: Double
    var date: Date
    var vendor: String
    var category: String
    var notes: String
    @Attribute(.externalStorage) var imageData: Data?
    var createdAt: Date
    var source: String   // manual / photo / file / email

    init(
        amount: Double = 0,
        date: Date = Date(),
        vendor: String = "",
        category: String = "其他",
        notes: String = "",
        imageData: Data? = nil,
        source: String = "manual"
    ) {
        self.id = UUID()
        self.amount = amount
        self.date = date
        self.vendor = vendor
        self.category = category
        self.notes = notes
        self.imageData = imageData
        self.createdAt = Date()
        self.source = source
    }

    var monthKey: String {
        let f = DateFormatter()
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
