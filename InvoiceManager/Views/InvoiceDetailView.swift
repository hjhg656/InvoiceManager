import SwiftUI
import SwiftData

struct InvoiceDetailView: View {
    @Bindable var invoice: Invoice
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: [Any] = []
    @State private var showShare = false

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
                }
            }

            Section("金额") {
                Text(String(format: "¥%.2f", invoice.amount))
                    .font(.largeTitle.weight(.bold))
            }

            Section("状态") {
                Picker("报销状态", selection: $invoice.status) {
                    ForEach(InvoiceStatus.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: invoice.status) { _, _ in
                    try? modelContext.save()
                }
            }

            Section("信息") {
                LabeledContent("商家", value: invoice.vendor.isEmpty ? "—" : invoice.vendor)
                LabeledContent("票种", value: invoice.kind.rawValue)
                LabeledContent("日期") {
                    Text(invoice.date, format: .dateTime.year().month().day())
                }
                LabeledContent("来源", value: sourceLabel)
            }

            if !invoice.notes.isEmpty {
                Section("备注") { Text(invoice.notes) }
            }

            if let ocr = invoice.ocrText, !ocr.isEmpty {
                Section("OCR 原文") {
                    Text(ocr).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if invoice.imageData != nil {
                    Button {
                        exportOne()
                    } label: {
                        Label("导出此附件", systemImage: "square.and.arrow.up")
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
            ShareSheet(items: shareItems)
        }
    }

    private var sourceLabel: String {
        switch invoice.source {
        case "photo": return "拍照 / 相册"
        case "file": return "文件导入"
        default: return "手动录入"
        }
    }

    private func exportOne() {
        guard let data = invoice.imageData else { return }
        let name = invoice.fileName ?? "发票-\(String(format: "%.2f", invoice.amount)).bin"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        shareItems = [url]
        showShare = true
    }
}
