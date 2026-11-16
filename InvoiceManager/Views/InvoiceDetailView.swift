import SwiftUI
import SwiftData
import PDFKit

struct InvoiceDetailView: View {
    @Bindable var invoice: Invoice
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var sharePayload: SharePayload?
    @State private var showFullPreview = false

    var body: some View {
        List {
            // 预览区
            Section {
                previewBlock
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("发票预览")
            }

            Section("金额") {
                Text(String(format: "¥%.2f", invoice.amount))
                    .font(.largeTitle.weight(.bold))
            }

            Section("状态") {
                Picker("报销状态", selection: $invoice.statusRaw) {
                    ForEach(InvoiceStatus.allCases) { s in
                        Text(s.rawValue).tag(s.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: invoice.statusRaw) { _, _ in try? modelContext.save() }

                if let batch = invoice.batch {
                    LabeledContent("所属批次", value: batch.name)
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
                    Button { exportOne() } label: {
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
        .sheet(item: $sharePayload) { ActivityView(activityItems: $0.urls) }
        .fullScreenCover(isPresented: $showFullPreview) {
            FullPreviewView(data: invoice.imageData, fileName: invoice.fileName)
        }
    }

    @ViewBuilder
    private var previewBlock: some View {
        if let data = invoice.imageData {
            Button {
                showFullPreview = true
            } label: {
                VStack(spacing: 8) {
                    if let ui = UIImage(data: data) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let pdfImage = PDFPreview.renderFirstPage(data: data) {
                        Image(uiImage: pdfImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                Text("PDF")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(8)
                            }
                    } else {
                        Label(invoice.fileName ?? "附件", systemImage: "doc.richtext.fill")
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                    Text("点按查看大图")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text("无附件")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private var sourceLabel: String {
        switch invoice.source {
        case "photo": return "拍照 / 相册"
        case "file": return "文件导入"
        case "share": return "系统分享"
        default: return "手动录入"
        }
    }

    private func exportOne() {
        guard let data = invoice.imageData, !data.isEmpty else { return }
        let name = invoice.fileName ?? "发票-\(String(format: "%.2f", invoice.amount)).dat"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: url, options: .atomic)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        sharePayload = SharePayload(urls: [url], title: name)
    }
}

enum PDFPreview {
    static func renderFirstPage(data: Data) -> UIImage? {
        guard data.count > 4, data[0] == 0x25, data[1] == 0x50,
              let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else { return nil }
        let rect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
        }
    }
}

struct FullPreviewView: View {
    let data: Data?
    let fileName: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let data {
                    if let ui = UIImage(data: data) {
                        ZoomableImage(image: ui)
                    } else if isPDF(data) {
                        PDFKitView(data: data)
                    } else {
                        ContentUnavailableView("无法预览", systemImage: "doc.questionmark")
                    }
                } else {
                    ContentUnavailableView("无内容", systemImage: "doc")
                }
            }
            .background(Color.black)
            .navigationTitle(fileName ?? "预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func isPDF(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0x25 && data[1] == 0x50
    }
}

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) })
                .onTapGesture(count: 2) {
                    withAnimation { scale = scale > 1.1 ? 1 : 2 }
                }
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .black
        v.document = PDFDocument(data: data)
        return v
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
