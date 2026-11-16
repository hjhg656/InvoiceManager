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
                Button {
                    startFetch()
                } label: {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text(statusText.isEmpty ? "连接中…" : statusText)
                        }
                    } else {
                        Text("拉取最近发票附件")
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
                    Text(errorText)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section("说明") {
                Text("必须使用「授权码 / 应用专用密码」。\n\n• QQ：设置 → 账户 → 开启 IMAP → 生成授权码\n• 163：设置 → IMAP → 授权码\n• Gmail：两步验证 → 应用专用密码\n\n扫描最近 45 天收件箱中的 PDF / 图片附件。")
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

            Section("选择要导入（\(selected.count)/\(attachments.count)）") {
                ForEach(attachments) { att in
                    HStack(spacing: 12) {
                        Image(systemName: selected.contains(att.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(att.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(att.fileName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(2)
                            Text(att.subject.isEmpty ? "无主题" : att.subject)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            HStack {
                                if let d = att.date {
                                    Text(d, format: .dateTime.month().day().hour().minute())
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
                            Text("正在导入…")
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
        let account = EmailAccount(email: email, host: host, port: portNum, useTLS: true)
        EmailAccountStore.saveAccount(account)
        EmailAccountStore.savePassword(password, account: email)

        let hostCopy = host
        let emailCopy = email
        let passwordCopy = password

        fetchTask?.cancel()
        fetchTask = Task {
            do {
                try Task.checkCancellation()
                await MainActor.run { statusText = "已连接，正在登录…" }

                let client = IMAPClient(host: hostCopy, port: portNum)
                let list = try await client.fetchInvoiceAttachments(
                    email: emailCopy,
                    password: passwordCopy,
                    limit: 25
                )

                try Task.checkCancellation()

                await MainActor.run {
                    attachments = list
                    selected = Set(list.map(\.id))
                    statusText = list.isEmpty
                        ? "未找到 PDF/图片附件。请确认授权码正确，且近期邮件里有发票附件。"
                        : "找到 \(list.count) 个附件，请勾选后导入"
                    phase = .results
                    isLoading = false
                    statusText = statusText
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
        var count = 0
        let chosen = attachments.filter { selected.contains($0.id) }
        for att in chosen {
            let base = (att.fileName as NSString).deletingPathExtension
            let fileParsed = OCRService.parseFileName(base)
            let ocr = await OCRService.recognize(from: att.data)

            let inv = Invoice(
                amount: ocr.amount ?? fileParsed.amount ?? 0,
                date: ocr.date ?? att.date ?? Date(),
                vendor: ocr.vendor ?? fileParsed.vendor ?? base,
                kind: .transport,
                status: .pending,
                notes: att.subject.isEmpty ? base : att.subject,
                imageData: att.data,
                fileName: att.fileName,
                ocrText: ocr.fullText,
                source: "email"
            )
            modelContext.insert(inv)
            count += 1
        }
        try? modelContext.save()
        isLoading = false
        statusText = "已导入 \(count) 张"
        dismiss()
    }
}
