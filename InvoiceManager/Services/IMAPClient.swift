import Foundation
import Network

struct EmailAttachment {
    var fileName: String
    var data: Data
    var subject: String
    var date: Date?
}

enum IMAPError: LocalizedError {
    case connectionFailed(String)
    case loginFailed(String)
    case commandFailed(String)
    case timeout
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "连接失败：\(s)"
        case .loginFailed(let s): return "登录失败：\(s)"
        case .commandFailed(let s): return "命令失败：\(s)"
        case .timeout: return "连接超时"
        case .parseFailed: return "解析邮件失败"
        }
    }
}

/// 精简 IMAP 客户端：登录 → 搜最近邮件 → 拉 PDF/图片附件
actor IMAPClient {
    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private var buffer = Data()
    private var tagCounter = 0

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(port)
    }

    func fetchInvoiceAttachments(
        email: String,
        password: String,
        limit: Int = 30
    ) async throws -> [EmailAttachment] {
        try await connect()
        try await expectGreeting()
        try await login(email: email, password: password)
        try await selectInbox()
        let uids = try await searchRecent(limit: limit)
        var results: [EmailAttachment] = []

        for uid in uids {
            if let atts = try? await fetchAttachments(uid: uid) {
                results.append(contentsOf: atts)
            }
            if results.count >= 40 { break }
        }

        try? await logout()
        connection?.cancel()
        connection = nil
        return results
    }

    // MARK: - Connection

    private func connect() async throws {
        let params = NWParameters.tls
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )
        self.connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let e):
                    cont.resume(throwing: IMAPError.connectionFailed(e.localizedDescription))
                case .cancelled:
                    cont.resume(throwing: IMAPError.connectionFailed("已取消"))
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
        startReceiveLoop()
    }

    private func startReceiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            Task {
                guard let self else { return }
                if let data, !data.isEmpty {
                    await self.appendBuffer(data)
                }
                if error == nil && !isComplete {
                    await self.startReceiveLoop()
                }
            }
        }
    }

    private func appendBuffer(_ data: Data) {
        buffer.append(data)
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "A\(tagCounter)"
    }

    private func send(_ line: String) async throws {
        guard let connection else { throw IMAPError.connectionFailed("未连接") }
        let payload = Data((line + "\r\n").utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    private func readUntilTag(_ tag: String, timeoutSeconds: TimeInterval = 30) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let text = String(data: buffer, encoding: .utf8) ?? String(data: buffer, encoding: .isoLatin1) {
                let lines = text.components(separatedBy: "\r\n")
                if let idx = lines.firstIndex(where: { $0.hasPrefix("\(tag) ") }) {
                    let collected = lines[0...idx].joined(separator: "\r\n")
                    // 消费掉已读部分
                    if let range = text.range(of: collected) {
                        let rest = String(text[range.upperBound...])
                        buffer = Data(rest.utf8)
                    } else {
                        buffer.removeAll()
                    }
                    return collected
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IMAPError.timeout
    }

    private func expectGreeting() async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let text = String(data: buffer, encoding: .utf8),
               text.contains("* OK") || text.lowercased().contains("imap") {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IMAPError.connectionFailed("未收到服务器问候")
    }

    private func login(email: String, password: String) async throws {
        let tag = nextTag()
        // 转义密码中的特殊字符
        let user = quote(email)
        let pass = quote(password)
        try await send("\(tag) LOGIN \(user) \(pass)")
        let resp = try await readUntilTag(tag)
        if resp.contains("\(tag) OK") { return }
        throw IMAPError.loginFailed(resp.components(separatedBy: "\r\n").last ?? resp)
    }

    private func selectInbox() async throws {
        let tag = nextTag()
        try await send("\(tag) SELECT INBOX")
        let resp = try await readUntilTag(tag)
        guard resp.contains("\(tag) OK") else {
            throw IMAPError.commandFailed("无法打开收件箱")
        }
    }

    private func searchRecent(limit: Int) async throws -> [Int] {
        // 最近 45 天
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -45, to: Date()) ?? Date()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd-MMM-yyyy"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        let sinceStr = df.string(from: since)

        let tag = nextTag()
        try await send("\(tag) UID SEARCH SINCE \(sinceStr)")
        let resp = try await readUntilTag(tag)

        var uids: [Int] = []
        for line in resp.components(separatedBy: "\r\n") {
            if line.hasPrefix("* SEARCH") {
                let parts = line.split(separator: " ").dropFirst(2)
                uids = parts.compactMap { Int($0) }
            }
        }
        // 取最新的 limit 封
        return Array(uids.suffix(limit).reversed())
    }

    private func fetchAttachments(uid: Int) async throws -> [EmailAttachment] {
        let tag = nextTag()
        try await send("\(tag) UID FETCH \(uid) (BODY.PEEK[] BODY.PEEK[HEADER.FIELDS (SUBJECT DATE)])")
        let resp = try await readUntilTag(tag, timeoutSeconds: 60)

        // 提取 literal 正文
        guard let body = extractLiteral(from: resp) else { return [] }

        let subject = parseHeaderField(resp, name: "Subject") ?? parseHeaderField(String(data: body, encoding: .utf8) ?? "", name: "Subject") ?? ""
        let date = parseDate(from: resp) ?? parseDate(from: String(data: body, encoding: .utf8) ?? "")

        return parseMIMEAttachments(data: body, subject: subject, date: date)
    }

    private func logout() async throws {
        let tag = nextTag()
        try await send("\(tag) LOGOUT")
        _ = try? await readUntilTag(tag, timeoutSeconds: 5)
    }

    // MARK: - MIME / helpers

    private func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func extractLiteral(from response: String) -> Data? {
        // 找 {size}\r\n 形式的 IMAP literal
        guard let open = response.range(of: "{"),
              let close = response.range(of: "}", range: open.upperBound..<response.endIndex) else {
            return response.data(using: .utf8)
        }
        let sizeStr = response[open.upperBound..<close.lowerBound]
        guard let size = Int(sizeStr), size > 0 else { return response.data(using: .utf8) }

        let after = response[close.upperBound...]
        let payload: Substring
        if after.hasPrefix("\r\n") {
            payload = after.dropFirst(2)
        } else if after.hasPrefix("\n") {
            payload = after.dropFirst()
        } else {
            payload = after
        }
        let data = Data(payload.utf8)
        if data.count >= size {
            return data.prefix(size)
        }
        // buffer 可能用了 isoLatin1，回退整段
        return data
    }

    private func parseHeaderField(_ text: String, name: String) -> String? {
        let lines = text.components(separatedBy: CharacterSet.newlines)
        let prefix = name.lowercased() + ":"
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func parseDate(from text: String) -> Date? {
        guard let raw = parseHeaderField(text, name: "Date") else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }

    private func parseMIMEAttachments(data: Data, subject: String, date: Date?) -> [EmailAttachment] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }

        // 找 boundary
        guard let boundaryLine = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.lowercased().contains("boundary=") }) else {
            // 可能是整封就是 PDF
            if isPDF(data) {
                return [EmailAttachment(fileName: "invoice.pdf", data: data, subject: subject, date: date)]
            }
            return []
        }

        var boundary = ""
        if let range = boundaryLine.range(of: "boundary=", options: .caseInsensitive) {
            var b = String(boundaryLine[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\"';"))
            boundary = b
        }
        guard !boundary.isEmpty else { return [] }

        let parts = text.components(separatedBy: "--\(boundary)")
        var result: [EmailAttachment] = []

        for part in parts {
            let lower = part.lowercased()
            let isPDF = lower.contains("application/pdf") || lower.contains("filename=\".pdf") || lower.contains("filename=.pdf") || lower.contains("name=\".pdf")
            let isImage = lower.contains("image/jpeg") || lower.contains("image/png") || lower.contains("image/jpg")
                || lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png")

            guard isPDF || isImage else { continue }

            let fileName = extractFileName(from: part) ?? (isPDF ? "invoice.pdf" : "invoice.jpg")

            // 正文在空行后
            guard let sep = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else { continue }
            var bodyStr = String(part[sep.upperBound...])
            // 去掉结尾 boundary 残留
            if let end = bodyStr.range(of: "\r\n--") {
                bodyStr = String(bodyStr[..<end.lowerBound])
            }
            bodyStr = bodyStr.trimmingCharacters(in: .whitespacesAndNewlines)

            let encoding: String
            if lower.contains("content-transfer-encoding: base64") {
                encoding = "base64"
            } else if lower.contains("content-transfer-encoding: quoted-printable") {
                encoding = "qp"
            } else {
                encoding = "binary"
            }

            let payload: Data?
            switch encoding {
            case "base64":
                let cleaned = bodyStr.components(separatedBy: CharacterSet.whitespacesAndNewlines).joined()
                payload = Data(base64Encoded: cleaned)
            case "qp":
                payload = decodeQuotedPrintable(bodyStr)
            default:
                payload = bodyStr.data(using: .isoLatin1)
            }

            guard let payload, !payload.isEmpty else { continue }
            // 只要像发票的：pdf 或图片，且不要太小
            if payload.count < 800 { continue }
            result.append(EmailAttachment(fileName: fileName, data: payload, subject: subject, date: date))
        }
        return result
    }

    private func extractFileName(from part: String) -> String? {
        let patterns = [
            #"filename\*=UTF-8''([^;\s]+)"#,
            #"filename="([^"]+)""#,
            #"filename=([^;\s]+)"#,
            #"name="([^"]+)""#
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
               let m = re.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)),
               let r = Range(m.range(at: 1), in: part) {
                var name = String(part[r])
                name = name.removingPercentEncoding ?? name
                return name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private func decodeQuotedPrintable(_ s: String) -> Data? {
        var out = Data()
        let chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == 61, i + 2 < chars.count { // '='
                let hex = String(bytes: [chars[i+1], chars[i+2]], encoding: .ascii) ?? ""
                if let byte = UInt8(hex, radix: 16) {
                    out.append(byte)
                    i += 3
                    continue
                }
            }
            if chars[i] == 13 || chars[i] == 10 {
                i += 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private func isPDF(_ data: Data) -> Bool {
        data.count > 4 && data[0] == 0x25 && data[1] == 0x50
    }
}
