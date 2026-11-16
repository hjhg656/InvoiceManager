import UIKit
import UniformTypeIdentifiers

/// 分享扩展：把图片 / PDF 写入 App Group inbox，主 App 启动时导入
class ShareViewController: UIViewController {

    private let appGroupId = "group.com.example.InvoiceManager"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "保存到发票"

        let label = UILabel()
        label.text = "正在保存…"
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        Task { await saveAll() }
    }

    private func saveAll() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish()
            return
        }

        var saved = 0
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    if await saveProvider(provider, type: UTType.pdf.identifier, ext: "pdf") { saved += 1 }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if await saveProvider(provider, type: UTType.image.identifier, ext: "jpg") { saved += 1 }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier) {
                    if await saveProvider(provider, type: UTType.jpeg.identifier, ext: "jpg") { saved += 1 }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
                    if await saveProvider(provider, type: UTType.png.identifier, ext: "png") { saved += 1 }
                }
            }
        }

        await MainActor.run {
            let alert = UIAlertController(
                title: saved > 0 ? "已保存 \(saved) 个文件" : "没有可保存的文件",
                message: saved > 0 ? "打开「发票台账」即可看到" : nil,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
                self.finish()
            })
            self.present(alert, animated: true)
        }
    }

    private func saveProvider(_ provider: NSItemProvider, type: String, ext: String) async -> Bool {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                defer { cont.resume(returning: true) }
                var data: Data?
                var name = "share-\(UUID().uuidString).\(ext)"

                if let url = item as? URL {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    data = try? Data(contentsOf: url)
                    name = url.lastPathComponent
                } else if let img = item as? UIImage {
                    data = img.jpegData(compressionQuality: 0.85)
                } else if let d = item as? Data {
                    data = d
                }

                guard let data, !data.isEmpty else { return }
                self.writeToInbox(data: data, fileName: name)
            }
        }
    }

    private func writeToInbox(data: Data, fileName: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) else { return }
        let inbox = container.appendingPathComponent("inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let safe = fileName.replacingOccurrences(of: "/", with: "-")
        let dest = inbox.appendingPathComponent(safe)
        try? data.write(to: dest, options: .atomic)
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
