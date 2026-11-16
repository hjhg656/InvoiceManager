import Foundation
import Network

struct EmailAttachment: Identifiable {
    let id = UUID()
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
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let s): return "连接失败：\(s)"
        case .loginFailed(let s): return "登录失败：\(s)\n请确认已开启 IMAP，并使用授权码"
        case .commandFailed(let s): return s
        case .timeout: return "连接超时，请检查网络或服务器地址"
        case .cancelled: return "已取消"
        }
    }
}

final class IMAPClient: @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "imap.client")
    private var connection: NWConnection?
    private var buffer = Data()
    private let bufferLock = NSLock()
    private var tagCounter = 0
    private var closed = false

    init(host: String, port: Int) {
        self.host = host
        self.port = UInt16(clamping: port)
    }

    func fetchInvoiceAttachments(
        email: String,
        password: String,
        limit: Int = 40
    ) async throws -> [EmailAttachment] {
        try await connect(timeout: 20)
        defer { close() }

        try await waitForGreeting(timeout: 15)
        try await login(email: email, password: password)
        try await selectInbox()

        var uids = try await searchInvoiceRelated(limit: limit)
        if uids.isEmpty {
            uids = try await searchRecent(limit: limit)
        }

        var results: [EmailAttachment] = []
        for uid in uids {
            if results.count >= 50 { break }
            if let atts = try? await fetchMessageAttachments(uid: uid) {
                results.append(contentsOf: atts)
            }
        }
        return results
    }

    // MARK: - Connection (same stable pattern)

    private func connect(timeout: TimeInterval) async throws {
        closed = false
        bufferLock.lock(); buffer.removeAll(); bufferLock.unlock()

        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 993,
            using: params
        )
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if once.mark() {
                    conn.cancel()
                    cont.resume(throwing: IMAPError.timeout)
                }
            }
            timer.resume()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.mark() { timer.cancel(); cont.resume() }
                case .failed(let err):
                    if once.mark() {
                        timer.cancel()
                        cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                    }
                case .cancelled:
                    if once.mark() {
                        timer.cancel()
                        cont.resume(throwing: IMAPError.cancelled)
                    }
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.startReceive(conn)
        }
    }

    private func startReceive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.bufferLock.lock()
                if self.buffer.count < 12 * 1024 * 1024 { self.buffer.append(data) }
                self.bufferLock.unlock()
            }
            if error == nil && !isComplete && !self.closed { self.startReceive(conn) }
        }
    }

    private func close() {
        closed = true
        connection?.cancel()
        connection = nil
        bufferLock.lock(); buffer.removeAll(); bufferLock.unlock()
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "A\(tagCounter)"
    }

    private func sendLine(_ line: String) async throws {
        guard let connection, !closed else { throw IMAPError.connectionFailed("未连接") }
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

    private func waitForGreeting(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = currentText()
            if text.contains("* OK") || text.uppercased().contains("IMAP") { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw IMAPError.connectionFailed("服务器无响应")
    }

    private func runCommand(_ command: String, timeout: TimeInterval = 25) async throws -> String {
        let tag = nextTag()
        try await sendLine("\(tag) \(command)")
        return try await readUntilTagged(tag, timeout: timeout)
    }

    private func readUntilTagged(_ tag: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let okPrefix = "\(tag) OK"
        let noPrefix = "\(tag) NO"
        let badPrefix = "\(tag) BAD"

        while Date() < deadline {
            bufferLock.lock()
            let snapshot = buffer
            bufferLock.unlock()
            let text = String(data: snapshot, encoding: .isoLatin1) ?? ""

            if let range = text.range(of: "\r\n\(okPrefix)")
                ?? text.range(of: "\n\(okPrefix)")
                ?? text.range(of: okPrefix) {
                var endIdx = range.upperBound
                if let lineEnd = text.range(of: "\r\n", range: endIdx..<text.endIndex) {
                    endIdx = lineEnd.upperBound
                } else if let lineEnd = text.range(of: "\n", range: endIdx..<text.endIndex) {
                    endIdx = lineEnd.upperBound
                }
                let collected = String(text[..<endIdx])
                let consumed = collected.data(using: .isoLatin1)?.count ?? 0
                bufferLock.lock()
                if buffer.count >= consumed { buffer.removeFirst(consumed) }
                else { buffer.removeAll() }
                bufferLock.unlock()
                return collected
            }

            if text.contains(noPrefix) || text.contains(badPrefix) {
                let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                bufferLock.lock(); buffer.removeAll(); bufferLock.unlock()
                throw IMAPError.commandFailed(lines.suffix(3).joined(separator: " | "))
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        throw IMAPError.timeout
    }

    private func currentText() -> String {
        bufferLock.lock(); let d = buffer; bufferLock.unlock()
        return String(data: d, encoding: .isoLatin1) ?? ""
    }

    private func login(email: String, password: String) async throws {
        do {
            _ = try await runCommand("LOGIN \(imapQuote(email)) \(imapQuote(password))", timeout: 20)
        } catch {
            if case IMAPError.commandFailed(let msg) = error { throw IMAPError.loginFailed(msg) }
            throw error
        }
    }

    private func selectInbox() async throws {
        _ = try await runCommand("SELECT INBOX", timeout: 15)
    }

    private func searchInvoiceRelated(limit: Int) async throws -> [Int] {
        let keywords = ["发票", "高德", "滴滴", "行程", "电子发票", "开票"]
        var all: Set<Int> = []
        for kw in keywords {
            if let resp = try? await runCommand("UID SEARCH SUBJECT \(imapQuote(kw))", timeout: 20) {
                parseSearchUIDs(resp).forEach { all.insert($0) }
            }
        }
        return Array(all.sorted().suffix(limit).reversed())
    }

    private func searchRecent(limit: Int) async throws -> [Int] {
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "dd-MMM-yyyy"
        let sinceStr = df.string(from: since)
        let resp: String
        do {
            resp = try await runCommand("UID SEARCH SINCE \(sinceStr)", timeout: 30)
        } catch {
            let all = try await runCommand("UID SEARCH ALL", timeout: 30)
            return Array(parseSearchUIDs(all).suffix(limit).reversed())
        }
        return Array(parseSearchUIDs(resp).suffix(limit).reversed())
    }

    private func parseSearchUIDs(_ resp: String) -> [Int] {
        var uids: [Int] = []
        for line in resp.components(separatedBy: "\r\n") where line.uppercased().hasPrefix("* SEARCH") {
            uids.append(contentsOf: line.split(separator: " ").dropFirst(2).compactMap { Int($0) })
        }
        return uids
    }

    private func fetchMessageAttachments(uid: Int) async throws -> [EmailAttachment] {
        let headerResp = try await runCommand(
            "UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (SUBJECT DATE)])",
            timeout: 20
        )
        var subject = headerField(headerResp, "Subject") ?? ""
        subject = MIMEDecoder.decodeEncodedWords(subject)
        let date = parseEmailDate(headerField(headerResp, "Date"))

        let full: String
        do {
            full = try await runCommand("UID FETCH \(uid) BODY.PEEK[]", timeout: 60)
        } catch {
            return []
        }

        guard let literal = extractLargestLiteral(from: full) else { return [] }
        return expandToInvoiceAttachments(from: literal, subject: subject, date: date)
    }

    /// 解析 MIME，过滤行程单，解开 ZIP
    private func expandToInvoiceAttachments(from data: Data, subject: String, date: Date?) -> [EmailAttachment] {
        var rawParts = collectRawParts(from: data, subject: subject, date: date)

        // 若只有行程单没有发票，仍不导入行程单
        var invoices: [EmailAttachment] = []

        for part in rawParts {
            // ZIP 压缩包
            if isZip(part.data) || part.fileName.lowercased().hasSuffix(".zip") {
                let extracted = ZipExtractor.extractInvoicePDFs(from: part.data)
                for item in extracted {
                    invoices.append(EmailAttachment(
                        fileName: (item.name as NSString).lastPathComponent,
                        data: item.data,
                        subject: subject,
                        date: date
                    ))
                }
                continue
            }

            if InvoiceFileFilter.isItinerary(part.fileName) { continue }

            if isPDF(part.data) {
                // 文件名像行程单也跳过
                if InvoiceFileFilter.isItinerary(part.fileName) { continue }
                // 优先要带「发票」的；若文件名不含发票但主题是高德电子发票且不是行程单，也收
                let nameOK = InvoiceFileFilter.isInvoice(part.fileName)
                    || (!part.fileName.lowercased().contains("行程") && part.data.count > 5_000)
                if nameOK {
                    invoices.append(part)
                }
            } else if isJPEG(part.data) || isPNG(part.data) {
                invoices.append(part)
            }
        }

        // 同一邮件若同时有「电子发票」和别的 PDF，只留电子发票
        let preferred = invoices.filter { InvoiceFileFilter.isInvoice($0.fileName) }
        if !preferred.isEmpty { return preferred }

        return invoices
    }

    private func collectRawParts(from data: Data, subject: String, date: Date?) -> [EmailAttachment] {
        if isPDF(data) {
            return [EmailAttachment(fileName: defaultPDFName(subject), data: data, subject: subject, date: date)]
        }
        if isZip(data) {
            return [EmailAttachment(fileName: "attachments.zip", data: data, subject: subject, date: date)]
        }

        guard let text = String(data: data, encoding: .isoLatin1),
              let boundary = findBoundary(in: text) else {
            if isJPEG(data) || isPNG(data) {
                return [EmailAttachment(fileName: "image.jpg", data: data, subject: subject, date: date)]
            }
            return []
        }

        var result: [EmailAttachment] = []
        let parts = text.components(separatedBy: "--\(boundary)")

        for part in parts {
            if part.count < 80 { continue }
            let lower = part.lowercased()

            let looksPDF = lower.contains("application/pdf") || lower.contains(".pdf")
            let looksZip = lower.contains("application/zip") || lower.contains("application/x-zip")
                || lower.contains(".zip") || lower.contains("application/octet-stream")
            let looksImg = lower.contains("image/jpeg") || lower.contains("image/png")
                || lower.contains(".jpg") || lower.contains(".png")

            guard looksPDF || looksZip || looksImg else { continue }

            var fileName = extractFileName(part).map {
                MIMEDecoder.decodeEncodedWords($0.removingPercentEncoding ?? $0)
            } ?? ""

            guard let headerEnd = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n") else { continue }
            var body = String(part[headerEnd.upperBound...])
            if let endMark = body.range(of: "\r\n--") {
                body = String(body[..<endMark.lowerBound])
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)

            let payload: Data?
            if lower.contains("content-transfer-encoding: base64") {
                let cleaned = body.components(separatedBy: CharacterSet.whitespacesAndNewlines).joined()
                payload = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters)
            } else if lower.contains("quoted-printable") {
                payload = MIMEDecoder.decodeQuotedPrintableData(body)
            } else {
                payload = body.data(using: .isoLatin1)
            }

            guard let bytes = payload, bytes.count >= 400 else { continue }

            if fileName.isEmpty {
                if isPDF(bytes) { fileName = defaultPDFName(subject) }
                else if isZip(bytes) { fileName = "attachments.zip" }
                else { fileName = "file.bin" }
            }

            result.append(EmailAttachment(fileName: fileName, data: bytes, subject: subject, date: date))
        }
        return result
    }

    private func defaultPDFName(_ subject: String) -> String {
        if subject.contains("发票") { return "\(subject).pdf" }
        return "电子发票.pdf"
    }

    private func extractLargestLiteral(from response: String) -> Data? {
        var best: Data?
        var bestSize = 0
        var search = response.startIndex
        while search < response.endIndex {
            guard let open = response.range(of: "{", range: search..<response.endIndex),
                  let close = response.range(of: "}", range: open.upperBound..<response.endIndex) else { break }
            let sizeStr = response[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "+", with: "")
            guard let size = Int(sizeStr), size > 50 else {
                search = close.upperBound
                continue
            }
            var payloadStart = close.upperBound
            if response[payloadStart...].hasPrefix("\r\n") {
                payloadStart = response.index(payloadStart, offsetBy: 2)
            } else if response[payloadStart...].hasPrefix("\n") {
                payloadStart = response.index(payloadStart, offsetBy: 1)
            }
            guard let data = String(response[payloadStart...]).data(using: .isoLatin1) else {
                search = close.upperBound
                continue
            }
            let slice = Data(data.prefix(size))
            if slice.count > bestSize {
                bestSize = slice.count
                best = slice
            }
            search = close.upperBound
        }
        return best
    }

    private func findBoundary(in text: String) -> String? {
        let lower = text.lowercased()
        guard let r = lower.range(of: "boundary=") else { return nil }
        let origin = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))
        var rest = String(text[origin...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("\"") {
            rest = String(rest.dropFirst())
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        let cut = rest.prefix(while: { !$0.isWhitespace && $0 != ";" && $0 != "\r" && $0 != "\n" })
        let b = String(cut).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return b.isEmpty ? nil : b
    }

    private func extractFileName(_ part: String) -> String? {
        let patterns = [
            #"filename\*=UTF-8''([^\s;]+)"#,
            #"filename="([^"]+)""#,
            #"filename=([^\s;]+)"#,
            #"name="([^"]+)""#
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive) else { continue }
            let range = NSRange(part.startIndex..., in: part)
            if let m = re.firstMatch(in: part, range: range),
               let r = Range(m.range(at: 1), in: part) {
                return String(part[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private func headerField(_ text: String, _ name: String) -> String? {
        let lines = text.components(separatedBy: "\r\n")
        let key = name.lowercased() + ":"
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix(key) {
                var value = String(t.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    if next.hasPrefix(" ") || next.hasPrefix("\t") {
                        value += " " + next.trimmingCharacters(in: .whitespaces)
                        j += 1
                    } else { break }
                }
                return value
            }
            i += 1
        }
        return nil
    }

    private func parseEmailDate(_ raw: String?) -> Date? {
        guard var raw else { return nil }
        raw = raw.trimmingCharacters(in: .whitespaces)
        let formats = ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: raw) { return d }
        }
        return nil
    }

    private func imapQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func isPDF(_ d: Data) -> Bool {
        d.count > 4 && d[0] == 0x25 && d[1] == 0x50 && d[2] == 0x44 && d[3] == 0x46
    }
    private func isJPEG(_ d: Data) -> Bool { d.count > 2 && d[0] == 0xFF && d[1] == 0xD8 }
    private func isPNG(_ d: Data) -> Bool { d.count > 4 && d[0] == 0x89 && d[1] == 0x50 }
    private func isZip(_ d: Data) -> Bool { d.count > 4 && d[0] == 0x50 && d[1] == 0x4B && (d[2] == 0x03 || d[2] == 0x05 || d[2] == 0x07) }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func mark() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
