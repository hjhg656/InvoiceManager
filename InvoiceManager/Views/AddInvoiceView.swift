import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AddInvoiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var date = Date()
    @State private var vendor = ""
    @State private var kind: InvoiceKind = .transport
    @State private var status: InvoiceStatus = .pending
    @State private var notes = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var fileName: String?
    @State private var ocrText: String = ""
    @State private var showCamera = false
    @State private var showDocPicker = false
    @State private var showEmailImport = false
    @State private var importSource = "manual"
    @State private var isOCR = false
    @State private var statusMsg: String?
    @State private var statusError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("金额（可 OCR 后修改）") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title.weight(.bold))
                    if isOCR {
                        HStack {
                            ProgressView()
                            Text("正在识别发票…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("基本信息") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("商家 / 开票方", text: $vendor)
                    Picker("票种", selection: $kind) {
                        ForEach(InvoiceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("状态", selection: $status) {
                        ForEach(InvoiceStatus.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("导入 & OCR") {
                    if let imageData, let ui = UIImage(data: imageData) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                    } else if imageData != nil {
                        Label(fileName ?? "已选择 PDF", systemImage: "doc.richtext.fill")
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("相册图片", systemImage: "photo.on.rectangle")
                    }
                    Button { showCamera = true } label: {
                        Label("拍照", systemImage: "camera")
                    }
                    Button { showDocPicker = true } label: {
                        Label("文件（PDF/图片，可多选）", systemImage: "folder")
                    }
                    Button { showEmailImport = true } label: {
                        Label("从邮箱导入", systemImage: "envelope.badge")
                    }

                    if imageData != nil {
                        Button {
                            Task { await runOCR() }
                        } label: {
                            Label("重新 OCR 识别", systemImage: "text.viewfinder")
                        }
                        .disabled(isOCR)
                    }

                    if let statusMsg {
                        Text(statusMsg)
                            .font(.footnote)
                            .foregroundStyle(statusError ? .red : .green)
                    }
                }

                if !ocrText.isEmpty {
                    Section("OCR 原文（可对照修改上方字段）") {
                        Text(ocrText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("备注") {
                    TextField("可选", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
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
                        .disabled(!canSave || isOCR)
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                Task { await loadPhoto(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(imageData: $imageData)
                    .ignoresSafeArea()
                    .onDisappear {
                        if imageData != nil {
                            importSource = "photo"
                            Task { await runOCR() }
                        }
                    }
            }
            .sheet(isPresented: $showDocPicker) {
                DocumentPicker { urls in
                    Task { await importURLs(urls) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showEmailImport) {
                EmailImportView()
            }
        }
    }

    private var canSave: Bool {
        Double(amountText.replacingOccurrences(of: ",", with: "")) != nil
            && !amountText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            await MainActor.run {
                imageData = data
                fileName = nil
                importSource = "photo"
            }
            await runOCR()
        }
    }

    private func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }

        if urls.count == 1, let url = urls.first {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                await MainActor.run {
                    statusMsg = "无法读取文件"
                    statusError = true
                }
                return
            }
            let name = url.lastPathComponent
            let base = url.deletingPathExtension().lastPathComponent
            let parsed = OCRService.parseFileName(base)
            await MainActor.run {
                imageData = data
                fileName = name
                importSource = "file"
                if let a = parsed.amount { amountText = String(format: "%.2f", a) }
                if vendor.isEmpty, let v = parsed.vendor { vendor = v }
                if notes.isEmpty { notes = base }
                kind = .transport
            }
            await runOCR()
            return
        }

        var saved = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let base = url.deletingPathExtension().lastPathComponent
            let name = url.lastPathComponent
            let fileParsed = OCRService.parseFileName(base)
            let ocr = await OCRService.recognize(from: data)
            let inv = Invoice(
                amount: ocr.amount ?? fileParsed.amount ?? 0,
                date: ocr.date ?? date,
                vendor: ocr.vendor ?? fileParsed.vendor ?? base,
                kind: .transport,
                status: .pending,
                notes: base,
                imageData: data,
                fileName: name,
                ocrText: ocr.fullText,
                source: "file"
            )
            await MainActor.run {
                modelContext.insert(inv)
                saved += 1
            }
        }
        await MainActor.run {
            try? modelContext.save()
            statusMsg = "已导入 \(saved) 张"
            statusError = false
            dismiss()
        }
    }

    private func runOCR() async {
        guard let imageData else { return }
        await MainActor.run { isOCR = true }
        let result = await OCRService.recognize(from: imageData)
        await MainActor.run {
            isOCR = false
ocrText = result.fullText
            if let a = result.amount { amountText = String(format: "%.2f", a) }
            if let v = result.vendor, vendor.isEmpty { vendor = v }
            if let d = result.date { date = d }
            if amountText.isEmpty, let fn = fileName {
                let p = OCRService.parseFileName(fn)
                if let a = p.amount { amountText = String(format: "%.2f", a) }
                if vendor.isEmpty, let v = p.vendor { vendor = v }
            }
            statusMsg = result.amount != nil ? "OCR 已填入金额，请核对后保存" : "OCR 完成，请手动填写金额"
            statusError = false
        }
    }

    private func saveOne() {
        guard let amount = Double(amountText.replacingOccurrences(of: ",", with: "")) else {
            statusMsg = "请填写有效金额"
            statusError = true
            return
        }
        let inv = Invoice(
            amount: amount,
            date: date,
            vendor: vendor.trimmingCharacters(in: .whitespaces),
            kind: kind,
            status: status,
            notes: notes.trimmingCharacters(in: .whitespaces),
            imageData: imageData,
            fileName: fileName,
            ocrText: ocrText.isEmpty ? nil : ocrText,
            source: importSource
        )
        modelContext.insert(inv)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            statusMsg = "保存失败：\(error.localizedDescription)"
            statusError = true
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf, .image, .jpeg, .png, .heic], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
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
            if let img = info[.originalImage] as? UIImage, let data = img.jpegData(compressionQuality: 0.85) {
                parent.imageData = data
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
