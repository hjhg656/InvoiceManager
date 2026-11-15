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

                    Section("发票文件 / 图片") {
                        if let imageData, let ui = UIImage(data: imageData) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                        } else if imageData != nil {
                            // PDF 或其他非图片：显示占位
                            HStack {
                                Image(systemName: "doc.richtext.fill")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text("已选择文件（PDF）")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        }

                        HStack(spacing: 12) {
                            importButton(title: "相册", icon: "photo.on.rectangle") {
                                // PhotosPicker 用下面的隐藏控件
                            }
                            .overlay {
                                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                    Color.clear
                                }
                            }

                            importButton(title: "拍照", icon: "camera") {
                                showCamera = true
                            }

                            importButton(title: "文件", icon: "folder") {
                                showFileImporter = true
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }
                    .listRowBackground(glassRow)

                    Section("备注") {
                        TextField("可选备注", text: $notes, axis: .vertical)
                            .lineLimit(3...6)
                    }
                    .listRowBackground(glassRow)

                    Section {
                        Text("支持从「文件」App 导入 PDF 或图片。邮箱附件可先存到文件再导入。")
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
                    if let data = try? await newItem?.loadTransferable(type: Data.self) {
                        imageData = data
                        importSource = "photo"
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(imageData: $imageData)
                    .ignoresSafeArea()
                    .onDisappear {
                        if imageData != nil { importSource = "photo" }
                    }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .jpeg, .png, .heic],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var glassRow: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(.ultraThinMaterial)
    }

    private func importButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { return }

        // 如果是图片，直接当预览；PDF 也存进去，列表用文档图标
        imageData = data
        importSource = "file"

        // 尝试从文件名猜商家
        if vendor.isEmpty {
            let name = url.deletingPathExtension().lastPathComponent
            if !name.isEmpty { vendor = name }
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
        p.sourceType = .camera
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
