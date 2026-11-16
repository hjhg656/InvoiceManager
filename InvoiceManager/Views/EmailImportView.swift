import SwiftUI
import SwiftData

struct EmailImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var host = "imap.qq.com"
    @State private var port = "993"
    @State private var presetIndex = 0

    @State private var isLoading = false
    @State private var statusText = ""
    @State private var errorText: String?
    @State private var attachments: [EmailAttachment] = []
    @State private var selected: Set<UUID> = []
    @State private var phase: Phase = .login
    @State private var fetchTask: Task<Void, Never>?

    enum Phase { case login, results }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .login: loginForm
                case .results: resultsList
                }
            }
            .navigationTitle("邮箱导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        fetchTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: restoreAccount)
            .onDisappear { fetchTask?.cancel() }
        }
    }

    private var loginForm: some View {
        Form {
            Section("邮箱服务商") {
                Picker("服务商", selection: $presetIndex) {
                    ForEach(EmailAccount.presets.indices, id: \.self) { i in
                        Text(EmailAccount.presets[i].name).tag(i)
                    }
                }
                .onChange(of: presetIndex) { _, i in
                    let p = EmailAccount.presets[i]
                    if !p.host.isEmpty {
                        host = p.host
                        port = String(p.port)
                    }
                }
            }

            Section("账号") {
                TextField("邮箱地址", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("授权码（不是登录密码）", text: $password)
            }

            Section("服务器") {
                TextField("IMAP 主机", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("端口", text: $port)
                    .keyboardType(.numberPad)
            }

            Section {
                Button { startFetch() } label: {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text(statusText.isEmpty ? "连接中…" : statusText)
                        }
                    } else {
                        Text("拉取发票附件")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isLoading || email.isEmpty || password.isEmpty || host.isEmpty)

                if isLoading {
                    Button("取消", role: .destructive) {
                        fetchTask?.cancel()
                        isLoading = false
                        statusText = ""
                        errorText = "已取消"
                    }
                }
            }

            if let errorText {
                Section {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
            }

            Section("规则") {
                Text("• 只导入「电子发票」PDF\n• 自动跳过「电子行程单」\n• 若是 ZIP 压缩包，会解压并只取其中的发票 PDF\n• 文件名如【富安出行-12.44元】会识别金额和商家")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resultsList: some View {
        List {
            Section {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("电子发票（已排除行程单）\(selected.count)/\(attachments.count)") {
                ForEach(attachments) { att in
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(att.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(att.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayTitle(att))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text(att.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            HStack {
                                if let amount = OCRService.parseFileName(att.fileName).amount {
                                    Text(String(format: "¥%.2f", amount))
                                        .foregroundStyle(.orange)
                                }
                                if let d = att.date {
                                    Text(d, format: .dateTime.year().month().day())
                                }
                                Text(ByteCountFormatter.string(fromByteCount: Int64(att.data.count), countStyle: .file))
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selected.contains(att.id) { selected.remove(att.id) }
                        else { selected.insert(att.id) }
                    }
                }
            }

            Section {
                Button {
                    Task { await importSelected() }
                } label: {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("OCR 识别导入中…")
                        }
                    } else {
                        Text("导入所选（\(selected.count)）")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(selected.isEmpty || isLoading)

                Button("重新拉取") {
                    phase = .login
                    attachments = []
                    selected = []
                    errorText = nil
                }
            }
        }
    }

    private func displayTitle(_ att: EmailAttachment) -> String {
        let parsed = OCRService.parseFileName(att.fileName)
        if let v = parsed.vendor, !OCRService.isGenericName(v) { return v }
        if let v = MIMEDecoder.vendorFromSubject(att.subject) { return v }
        if !att.subject.isEmpty { return att.subject }
        return att.fileName
    }

    private func restoreAccount() {
        if let acc = EmailAccountStore.loadAccount() {
            email = acc.email
            host = acc.host
            port = String(acc.port)
            if let pw = EmailAccountStore.loadPassword(account: acc.email) {
                password = pw
            }
            if let idx = EmailAccount.presets.firstIndex(where: { $0.host == acc.host }) {
                presetIndex = idx
            } else {
                presetIndex = EmailAccount.presets.count - 1
            }
        }
    }

    private func startFetch() {
        errorText = nil
        isLoading = true
        statusText = "正在连接 \(host)…"

        let portNum = Int(port) ?? 993
        EmailAccountStore.saveAccount(EmailAccount(email: email, host: host, port: portNum, useTLS: true))
        EmailAccountStore.savePassword(password, account: email)

        let hostCopy = host
        let emailCopy = email
        let passwordCopy = password

        fetchTask?.cancel()
        fetchTask = Task {
            do {
                try Task.checkCancellation()
                await MainActor.run { statusText = "搜索发票邮件（跳过行程单）…" }

                let client = IMAPClient(host: hostCopy, port: portNum)
                let list = try await client.fetchInvoiceAttachments(
                    email: emailCopy,
                    password: passwordCopy,
                    limit: 40
                )

                try Task.checkCancellation()

                await MainActor.run {
                    attachments = list
                    selected = Set(list.map(\.id))
                    statusText = list.isEmpty
                        ? "未找到电子发票 PDF。行程单已自动忽略；若是 RAR 压缩包暂不支持，请用 ZIP 或直接 PDF。"
                        : "找到 \(list.count) 张电子发票（已排除行程单，ZIP 已解压）"
                    phase = .results
                    isLoading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    isLoading = false
                    statusText = ""
                    errorText = "已取消"
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    statusText = ""
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func importSelected() async {
        isLoading = true
        let chosen = attachments.filter { selected.contains($0.id) }

        for att in chosen {
            let ocr = await OCRService.enrich(
                data: att.data,
                fileName: att.fileName,
                subject: att.subject
            )

            let fileParsed = OCRService.parseFileName(att.fileName)
            let vendor: String = {
                if let v = fileParsed.vendor, !OCRService.isGenericName(v) { return v }
                if let v = MIMEDecoder.vendorFromSubject(att.subject) { return v }
                if let v = ocr.vendor, !OCRService.isGenericName(v) { return v }
                return "高德打车"
            }()

            let amount = ocr.amount ?? fileParsed.amount ?? 0

            let inv = Invoice(
                amount: amount,
                date: ocr.date ?? att.date ?? Date(),
                vendor: vendor,
                kind: .transport,
                status: .pending,
                notes: att.subject.isEmpty ? att.fileName : att.subject,
                imageData: att.data,
                fileName: att.fileName,
                ocrText: ocr.fullText,
                source: "email"
            )
            modelContext.insert(inv)
        }
        try? modelContext.save()
        isLoading = false
        dismiss()
    }
}
