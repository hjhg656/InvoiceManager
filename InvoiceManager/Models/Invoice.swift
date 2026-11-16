import Foundation
import SwiftData

enum InvoiceStatus: String, Codable, CaseIterable, Identifiable {
    case pending = "待提交"
    case submitted = "已上交"
    case reimbursed = "已报销"
    var id: String { rawValue }
}

enum InvoiceKind: String, Codable, CaseIterable, Identifiable {
    case transport = "交通"
    case meal = "餐饮"
    case hotel = "住宿"
    case office = "办公"
    case telecom = "通讯"
    case shopping = "购物"
    case medical = "医疗"
    case other = "其他"
    var id: String { rawValue }
}

@Model
final class ExpenseBatch {
    @Attribute(.unique) var id: UUID
    var name: String
    var note: String
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Invoice.batch)
    var invoices: [Invoice]?

    init(name: String, note: String = "") {
        self.id = UUID()
        self.name = name
        self.note = note
        self.createdAt = Date()
        self.invoices = []
    }

    var totalAmount: Double {
        (invoices ?? []).reduce(0) { $0 + $1.amount }
    }

    var count: Int { (invoices ?? []).count }
}

@Model
final class Invoice {
    @Attribute(.unique) var id: UUID
    var amount: Double
    var date: Date
    var vendor: String
    var category: String
    var kindRaw: String
    var statusRaw: String
    var notes: String
    var imageData: Data?
    var fileName: String?
    var ocrText: String?
    var createdAt: Date
    var source: String

    var batch: ExpenseBatch?

    init(
        amount: Double = 0,
        date: Date = Date(),
        vendor: String = "",
        kind: InvoiceKind = .other,
        status: InvoiceStatus = .pending,
        notes: String = "",
        imageData: Data? = nil,
        fileName: String? = nil,
        ocrText: String? = nil,
        source: String = "manual"
    ) {
        self.id = UUID()
        self.amount = amount
        self.date = date
        self.vendor = vendor
        self.category = kind.rawValue
        self.kindRaw = kind.rawValue
        self.statusRaw = status.rawValue
        self.notes = notes
        self.imageData = imageData
        self.fileName = fileName
        self.ocrText = ocrText
        self.createdAt = Date()
        self.source = source
    }

    var kind: InvoiceKind {
        get { InvoiceKind(rawValue: kindRaw) ?? .other }
        set {
            kindRaw = newValue.rawValue
            category = newValue.rawValue
        }
    }

    var status: InvoiceStatus {
        get { InvoiceStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
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
