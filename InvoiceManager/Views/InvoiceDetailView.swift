import SwiftUI

struct InvoiceDetailView: View {
    @Bindable var invoice: Invoice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            Form {
                if let data = invoice.imageData, let ui = UIImage(data: data) {
                    Section {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Section("金额") {
                    Text(String(format: "¥%.2f", invoice.amount))
                        .font(.title)
                        .fontWeight(.bold)
                }

                Section("信息") {
                    LabeledContent("商家", value: invoice.vendor.isEmpty ? "—" : invoice.vendor)
                    LabeledContent("分类", value: invoice.category)
                    LabeledContent("日期") {
                        Text(invoice.date, format: .dateTime.year().month().day())
                    }
                    LabeledContent("来源", value: sourceLabel)
                }

                if !invoice.notes.isEmpty {
                    Section("备注") {
                        Text(invoice.notes)
                    }
                }

                Section {
                    Button("删除发票", role: .destructive) {
                        modelContext.delete(invoice)
                        dismiss()
                    }
                }
            }
            .navigationTitle("发票详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var sourceLabel: String {
        switch invoice.source {
        case "photo": return "拍照/相册"
        case "email": return "邮件"
        default: return "手动录入"
        }
    }
}
