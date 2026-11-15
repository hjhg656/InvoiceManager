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
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var importSource = "manual"
    @State private var importError: String?
    @State private var importSuccess: String?
    @State private var pendingFileCount = 0

    private let categories = ["餐饮", "交通", "住宿", "办公", "通讯", "购物", "医疗", "其他"]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.10, green: 0.11, blue: 0.16)
                    .ignoresSafeArea()

                Form {
                    Section {
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .padding(.vertical, 8)
                    } header: {
                        Text("金额")
                    }
                    .listRowBackground(glassRow)

                    Section("基本信息") {
                        DatePicker("日期", selection: $date, displayedComponents: .date)
                        TextField("商家 / 开票方", text: $vendor)
                        Picker("分类", selection: $category) {
                            ForEach(categories, id: \.self) { Text($0) }
                        }
                    }
                    .listRowBackground(glassRow)

                    Section {
                        if let imageData, let ui = UIImage(data: imageData) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                                .listRowBackground(glassRow)
                        } else if imageData != nil {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "doc.richtext.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.secondary)
                                    Text("已选择 PDF 文件")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if !amountText.isEmpty {
                                        Text("识别金额 ¥\(amountText)")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }
                                }
                                .padding(.vertical, 24)
                                Spacer()
                            }
                            .listRowBackground(glassRow)
                        }

                        if let importSuccess {
                            Text(importSuccess)
                                .font(.footnote)
                                .foregroundStyle(.green)
                                .listRowBackground(Color.clear)
                        }

                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            importLabel(title: "从相册选择", icon: "photo.on.rectangle")
                        }
                        .listRowBackground(glassRow)

                        Button {
                            showCamera = true
                        } label: {
                            importLabel(title: "拍照", icon: "camera")
                        }
                        .listRowBackground(glassRow)

                        Button {
                            importError = nil
                            importSuccess = nil
                            showFileImporter = true
                        } label: {
                            importLabel(title: "从文件导入（可多选 PDF）", icon: "folder")
                        }
                        .listRowBackground(glassRow)

                        if let importError {
                            Text(importError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("发票文件 / 图片")
                    }

                    Section("备注") {
                        TextField("可选备注", text: $notes, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .listRowBackground(glassRow)

                    Section {
                        Text("电子发票 PDF 文件名里通常带金额（如「约车-27.92元」），导入时会自动识别。可一次选多张批量导入。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("添加发票")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pendingFileCount > 1 ? "保存 \(pendingFileCount) 张" : "保存") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(amountText.isEmpty && pendingFileCount == 0)
                }
            }
            .onChange(of: selectedPhoto) { _, newItem in
                Task {
                    guard let newItem else { return }
                    do {
                        if let data = try await newItem.loadTransferable(type: Data.self) {
                            await MainActor.run {
                                imageData = data
                                importSource = "photo"
                                importError = nil
                                importSuccess = "已选择相册图片"
                                pendingFileCount = 0
                            }
                        }
                    } catch {
                        await MainActor.run {
                            importError = "读取相册失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(imageData: $imageData)
                    .ignoresSafeArea()
                    .onDisappear {
                        if imageData != nil {
                            importSource = "photo"
                            importError = nil
                            importSuccess = "已拍摄照片"
                            pendingFileCount = 0
                        }
                    }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .jpeg, .png, .heic],
                allowsMultipleSelection: true
            ) { result in
                // 必须在主线程处理，并先复制出沙盒
                DispatchQueue.main.async {
                    handleFileImport(result)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var glassRow: some View {
        Color.white.opacity(0.06)
    }

    private func importLabel(title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - 文件导入（关键修复）

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            // 用户取消也会走到这里，忽略取消
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return }
            importError = "选择失败：\(error.localizedDescription)"

        case .success(let urls):
            guard !urls.isEmpty else {
                importError = "未选择文件"
                return
            }

            var successCount = 0
            var lastData: Data?
            var lastName = ""

            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }

                // 先拷贝到临时目录，避免权限立刻失效
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)

                do {
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    let data = try Data(contentsOf: tempURL)
                    try? FileManager.default.removeItem(at: tempURL)

                    let fileName = url.deletingPathExtension().lastPathComponent
                    let parsed = parseChineseEInvoice(fileName: fileName)

                    if urls.count == 1 {
                        // 单张：填到表单，等用户点保存
                        imageData = data
                        importSource = "file"
                        lastData = data
                        lastName = fileName
                        if let amt = parsed.amount {
                            amountText = String(format: "%.2f", amt)
                        }
                        if vendor.isEmpty, let v = parsed.vendor {
                            vendor = v
                        }
                        category = "交通"
                        pendingFileCount = 0
                    } else {
                        // 多张：直接入库
                        let inv = Invoice(
                            amount: parsed.amount ?? 0,
                            date: date,
                            vendor: parsed.vendor ?? fileName,
                            category: "交通",
                            notes: fileName,
                            imageData: data,
                            source: "file"
                        )
                        modelContext.insert(inv)
                        successCount += 1
                    }
                } catch {
                    importError = "读取 \(url.lastPathComponent) 失败：\(error.localizedDescription)"
                }
            }

            if urls.count == 1 {
                if lastData != nil {
                    importSuccess = "已导入：\(lastName)"
                    importError = nil
                }
            } else if successCount > 0 {
                importSuccess = "已批量导入 \(successCount) 张发票"
                importError = nil
                // 多选直接关掉添加页
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    dismiss()
                }
            }
        }
    }

    /// 从常见电子发票文件名解析金额和商家
    /// 例：【365约车特选-27.92元-1个行程】高德...子发票
    private func parseChineseEInvoice(fileName: String) -> (amount: Double?, vendor: String?) {
        var amount: Double?
        var vendor: String?

        // 金额：xx.xx元 或 -xx.xx元
        if let regex = try? NSRegularExpression(pattern: #"(\d+\.\d{1,2})\s*元"#) {
            let range = NSRange(fileName.startIndex..., in: fileName)
            if let match = regex.firstMatch(in: fileName, range: range),
               let r = Range(match.range(at: 1), in: fileName) {
                amount = Double(fileName[r])
            }
        }

        // 商家：括号内第一段，去掉金额部分
        if let start = fileName.firstIndex(of: "【"),
           let end = fileName.firstIndex(of: "】") {
            let inner = String(fileName[fileName.index(after: start)..<end])
            // 取第一个 - 之前的部分作为商家
            if let dash = inner.firstIndex(of: "-") {
                vendor = String(inner[..<dash])
                    .replacingOccurrences(of: "特选", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else {
                vendor = inner
            }
        } else {
            // 没有【】就取文件名前面一段
            let parts = fileName.split(separator: "-")
            if let first = parts.first {
                vendor = String(first)
            }
        }

        return (amount, vendor)
    }

    private func save() {
        let amount = Double(amountText.replacingOccurrences(of: ",", with: "")) ?? 0
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
        dismiss()
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
