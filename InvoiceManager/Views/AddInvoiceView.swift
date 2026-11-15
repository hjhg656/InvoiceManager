import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
    @State private var fileName: String?
    @State private var showCamera = false
    @State private var showDocPicker = false
    @State private var importSource = "manual"
    @State private var status: String?
    @State private var statusError = false

    private let categories = ["餐饮", "交通", "住宿", "办公", "通讯", "购物", "医疗", "其他"]

    var body: some View {
        NavigationStack {
            Form {
                Section("金额（必填）") {
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title.weight(.bold))
                }

                Section("基本信息") {
                    DatePicker("日期", selection: $date, displayedComponents: .date)
                    TextField("商家 / 开票方", text: $vendor)
                    Picker("分类", selection: $category) {
                        ForEach(categories, id: \.self) { Text($0) }
                    }
                }

                Section("附件") {
                    if let imageData, let ui = UIImage(data: imageData) {
                        Image(uiImage: ui)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .frame(maxWidth: .infinity)
                    } else if imageData != nil {
                        Label(fileName ?? "已选择 PDF", systemImage: "doc.richtext.fill")
                            .foregroundStyle(.secondary)
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showCamera = true
                    } label: {
                        Label("拍照", systemImage: "camera")
                    }

                    Button {
                        showDocPicker = true
                    } label: {
                        Label("从文件导入（可多选 PDF）", systemImage: "folder")
                    }

                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(statusError ? .red : .green)
                    }
                }

                Section("备注") {
                    TextField("可选", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    Text("多选电子发票 PDF 时会自动识别文件名中的金额并直接保存到列表。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        .disabled(!canSave)
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
                            status = "已添加照片"
                            statusError = false
                        }
                    }
            }
            .sheet(isPresented: $showDocPicker) {
                DocumentPicker { urls in
                    importURLs(urls)
                }
                .ignoresSafeArea()
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
                status = "已选择相册图片"
                statusError = false
            }
        }
    }

    private func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else {
            status = "未选择文件"
            statusError = true
            return
        }

        var saved = 0

        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }

            // asCopy:true 时一般已是 App 可访问路径，仍做一次兜底复制
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                status = "读不了 \(url.lastPathComponent)"
                statusError = true
                continue
            }

            let name = url.lastPathComponent
            let base = url.deletingPathExtension().lastPathComponent
            let parsed = parseFileName(base)

            if urls.count == 1 {
                imageData = data
                fileName = name
                importSource = "file"
                if let a = parsed.amount {
                    amountText = String(format: "%.2f", a)
                }
                if vendor.isEmpty, let v = parsed.vendor {
                    vendor = v
                }
                if notes.isEmpty { notes = base }
                category = "交通"
                status = "已载入 \(name)" + (parsed.amount != nil ? "，金额已识别，请点保存" : "，请填写金额后保存")
                statusError = false
            } else {
                let inv = Invoice(
                    amount: parsed.amount ?? 0,
                    date: date,
                    vendor: parsed.vendor ?? base,
                    category: "交通",
                    notes: base,
                    imageData: data,
                    fileName: name,
                    source: "file"
                )
                modelContext.insert(inv)
                saved += 1
            }
        }

        if urls.count > 1 {
            do {
                try modelContext.save()
                status = "已保存 \(saved) 张到列表"
                statusError = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    dismiss()
                }
            } catch {
                status = "保存失败：\(error.localizedDescription)"
                statusError = true
            }
        }
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

        if let s = fileName.firstIndex(of: "【"),
           let e = fileName.firstIndex(of: "】") {
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
            status = "请填写有效金额"
            statusError = true
            return
        }
        let inv = Invoice(
            amount: amount,
            date: date,
            vendor: vendor.trimmingCharacters(in: .whitespaces),
            category: category,
            notes: notes.trimmingCharacters(in: .whitespaces),
            imageData: imageData,
            fileName: fileName,
            source: importSource
        )
        modelContext.insert(inv)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            status = "保存失败：\(error.localizedDescription)"
            statusError = true
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf, .image, .jpeg, .png, .heic],
            asCopy: true
        )
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
