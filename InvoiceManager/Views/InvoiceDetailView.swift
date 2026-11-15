import SwiftUI
import SwiftData

struct InvoiceDetailView: View {
    @Bindable var invoice: Invoice
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var shareURL: URL?

    var body: some View {
        List {
            if let data = invoice.imageData, let ui = UIImage(data: data) {
                Section {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                }
            } else if invoice.imageData != nil {
                Section {
                    Label(invoice.fileName ?? "PDF 附件", systemImage: "doc.richtext.fill")
                        .foregroundStyle(.secondary)
                }
            }

            Section("金额") {
                Text(String(format: "¥%.2f", invoice.amount))
                    .font(.largeTitle.weight(.bold))
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
                if invoice.imageData != nil {
                    Button {
                        shareAttachment()
                    } label: {
                        Label("导出此发票附件", systemImage: "square.and.arrow.up")
                    }
                }

                Button("删除", role: .destructive) {
                    modelContext.delete(invoice)
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
    }

    private var sourceLabel: String {
        switch invoice.source {
        case "photo": return "拍照 / 相册"
        case "file": return "文件导入"
        case "email": return "邮件"
        default: return "手动录入"
        }
    }

    private func shareAttachment() {
        guard let data = invoice.imageData else { return }
        let name = invoice.fileName
            ?? (isPDF(data)
                ? "\(invoice.vendor)-\(String(format: "%.2f", invoice.amount)).pdf"
                : "\(invoice.vendor)-\(String(format: "%.2f", invoice.amount)).jpg")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        shareURL = url
        showShare = true
    }

    private func isPDF(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0x25 && data[1] == 0x50 && data[2] == 0x44 && data[3] == 0x46
    }
}
