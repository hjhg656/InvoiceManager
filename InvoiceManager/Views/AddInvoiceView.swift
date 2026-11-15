import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import PDFKit

struct AddInvoiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var date = Date()
    @State private var vendor = ""
    @State private var category = "交通"
    @State private var notes = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var showCamera = false
    @State private var showDocPicker = false
    @State private var importSource = "manual"
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private let categories = ["餐饮", "交通", "住宿", "办公", "通讯", "购物", "医疗", "其他"]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.10, green: 0.11, blue: 0.16).ignoresSafeArea()

                Form {
                    Section {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 8)
                    } header: {
                        Text("金额（必填）")
                    }
                    .listRowBackground(rowBG)

                    Section("基本信息") {
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                        TextField("商家 / 开票方", text: $vendor)
                        Picker("分类", selection: $category) {
                            ForEach(categories, id: \.self) { Text($0) }
                        }
                    }
                    .listRowBackground(rowBG)

                    Section {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 220)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                                .listRowBackground(rowBG)
                        } else if imageData != nil {
                            Label("已附带文件（PDF）", systemImage: "doc.richtext.fill")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .listRowBackground(rowBG)
                        }

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            rowLabel("从相册选择", "photo.on.rectangle")
                        }
                        .listRowBackground(rowBG)

                        Button { showCamera = true } label: {
                            rowLabel("拍照", "camera")
                        }
                        .listRowBackground(rowBG)

                        Button { showDocPicker = true } label: {
                            rowLabel("从文件导入 PDF / 图片（可多选）", "folder")
                        }
                        .listRowBackground(rowBG)

                        if let statusMessage {
                            Text(statusMessage)
                                .font(.footnote)
                                .foregroundStyle(statusIsError ? .red : .green)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("附件")
                    }

                    Section("备注") {
                        TextField("可选", text: $notes, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    .listRowBackground(rowBG)

                    Section {
                        Text("电子发票 PDF 可一次选多张，会自动按文件名识别金额并保存。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("添加发票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveOne() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                Task { await loadPhoto(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(imageData: $imageData)
                    .ignoresSafeArea()
                    .onDisappear { refreshPreviewFromImageData(source: "photo") }
            }
            .sheet(isPresented: $showDocPicker) {
                DocumentPicker { urls in
                    importFiles(urls)
                }
                .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var rowBG: some View { Color.white.opacity(0.06) }

    private var canSave: Bool {
        Double(amountText.replacingOccurrences(of: ",", with: "")) != nil
            && !(amountText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func rowLabel(_ title: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(title).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Photo

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                await MainActor.run {
                    imageData = data
                    previewImage = UIImage(data: data)
                    importSource = "photo"
                    setStatus("已选择相册图片", error: false)
                }
            }
        } catch {
            await MainActor.run { setStatus("相册读取失败：\(error.localizedDescription)", error: true) }
        }
    }

    private func refreshPreviewFromImageData(source: String) {
        guard let imageData else { return }
        previewImage = UIImage(data: imageData)
        importSource = source
        setStatus("已添加图片", error: false)
    }

    // MARK: - Files (UIDocumentPicker)

    private func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else {
            setStatus("未选择文件", error: true)
            return
        }

        var saved = 0
        var lastPreview: UIImage?
        var lastData: Data?
        var lastAmount = ""
        var lastVendor = ""

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)

            do {
                if FileManager.default.fileExists(atPath: temp.path) {
                    try FileManager.default.removeItem(at: temp)
                }
                try FileManager.default.copyItem(at: url, to: temp)
                let data = try Data(contentsOf: temp)
                try? FileManager.default.removeItem(at: temp)

                let name = url.deletingPathExtension().lastPathComponent
                let parsed = parseFileName(name)

                // 预览：PDF 渲第一页，图片直接显示
                let preview = makePreview(data: data, urlHint: url)

                if urls.count == 1 {
                    // 单文件：填表，用户再点保存
                    imageData = data
                    previewImage = preview
                    importSource = "file"
                    if let a = parsed.amount {
                        amountText = String(format: "%.2f", a)
                        lastAmount = amountText
                    }
                    if vendor.isEmpty, let v = parsed.vendor {
                        vendor = v
                        lastVendor = v
                    }
                    category = "交通"
                    notes = name
                    lastData = data
                    lastPreview = preview
                } else {
                    // 多文件：直接写入数据库
                    let inv = Invoice(
                        amount: parsed.amount ?? 0,
                        date: date,
                        vendor: parsed.vendor ?? name,
                        category: "交通",
                        notes: name,
                        imageData: data,
                        source: "file"
                    )
                    modelContext.insert(inv)
                    saved += 1
                }
            } catch {
                setStatus("无法读取 \(url.lastPathComponent)：\(error.localizedDescription)", error: true)
            }
        }

        // 确保 SwiftData 落盘
        try? modelContext.save()

        if urls.count == 1 {
            if lastData != nil {
                var msg = "已载入文件"
                if !lastAmount.isEmpty { msg += "，金额 ¥\(lastAmount)" }
                if !lastVendor.isEmpty { msg += "，\(lastVendor)" }
                msg += "。请点右上角保存。"
                setStatus(msg, error: false)
                _ = lastPreview
            }
        } else if saved > 0 {
            setStatus("已导入 \(saved) 张发票", error: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dismiss()
            }
        }
    }

    private func makePreview(data: Data, urlHint: URL) -> UIImage? {
        if let img = UIImage(data: data) { return img }
        // PDF 第一页
        if let doc = PDFDocument(data: data), let page = doc.page(at: 0) {
            let rect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2
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
        return nil
    }

    private func parseFileName(_ fileName: String) -> (amount: Double?, vendor: String?) {
        var amount: Double?
        var vendor: String?

        if let re = try? NSRegularExpression(pattern: #"(\d+\.\d{1,2})\s*元"#) {
            let range = NSRange(fileName.startIndex..., in: fileName)
            if let m = re.firstMatch(in: fileName, range: range),
               let r = Range(m.range(at: 1), in: fileName) {
                amount = Double(fileName[r])
            }
        }

        if let s = fileName.firstIndex(of: "【"), let e = fileName.firstIndex(of: "】") {
            let inner = String(fileName[fileName.index(after: s)..<e])
            if let dash = inner.firstIndex(of: "-") {
                vendor = String(inner[..<dash])
                    .replacingOccurrences(of: "特选", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                vendor = inner
            }
        }
        return (amount, vendor)
    }

    private func saveOne() {
        guard let amount = Double(amountText.replacingOccurrences(of: ",", with: "")) else {
            setStatus("请填写有效金额", error: true)
            return
        }
        let inv = Invoice(
            amount: amount,
            date: date,
            vendor: vendor.trimmingCharacters(in: .whitespaces),
            category: category,
            notes: notes.trimmingCharacters(in: .whitespaces),
            imageData: imageData,
            source: importSource
        )
        modelContext.insert(inv)
        try? modelContext.save()
        dismiss()
    }

    private func setStatus(_ text: String, error: Bool) {
        statusMessage = text
        statusIsError = error
    }
}

// MARK: - 更可靠的文件选择器

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.pdf, .image, .jpeg, .png, .heic]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let data = img.jpegData(compressionQuality: 0.8) {
                parent.imageData = data
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
