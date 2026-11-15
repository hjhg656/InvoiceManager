import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AddInvoiceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = ""
    @State private var date = Date()
    @State private var vendor = ""
    @State private var category = "餐饮"
    @State private var notes = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var importSource = "manual"
    @State private var importError: String?

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
                        // 预览
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
                                }
                                .padding(.vertical, 24)
                                Spacer()
                            }
                            .listRowBackground(glassRow)
                        }

                        // 三个导入入口 —— 不用嵌套 Button+overlay，直接拆开
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
                            showFileImporter = true
                        } label: {
                            importLabel(title: "从文件导入（PDF / 图片）", icon: "folder")
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
                        Text("邮件里的发票：先把附件存到「文件」App，再点上面「从文件导入」。")
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
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(amountText.isEmpty)
                }
            }
            .onChange(of: selectedPhoto) { _, newItem in
                Task {
                    guard let newItem else { return }
                    do {
                        if let data = try await newItem.loadTransferable(type: Data.self) {
                            imageData = data
                            importSource = "photo"
                            importError = nil
                        }
                    } catch {
                        importError = "读取相册图片失败：\(error.localizedDescription)"
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
                        }
                    }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .jpeg, .png, .heic, UTType(filenameExtension: "jpg")].compactMap { $0 },
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
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

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = "选择文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else {
                importError = "未选择文件"
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                imageData = data
                importSource = "file"
                importError = nil
                if vendor.isEmpty {
                    let name = url.deletingPathExtension().lastPathComponent
                    if !name.isEmpty { vendor = name }
                }
            } catch {
                importError = "读取文件失败：\(error.localizedDescription)"
            }
        }
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
